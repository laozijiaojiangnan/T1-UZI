# Redis 架构深度分析

> 分析版本：Redis 8.x（vendors/redis）
> 分析日期：2026-02-25

---

## 1. 核心矛盾与存在意义 (The "Why")

### 痛点还原

在 Redis 出现之前，开发者面临的经典困境是：

**磁盘数据库太慢，内存太贵又没有结构**。

具体来说：
- MySQL/PostgreSQL 每次查询都需要磁盘 I/O，哪怕只是读一个计数器也要走索引扫描；
- 纯内存 `memcached` 只支持 string，想存个排行榜或者消息队列，你得自己把数据序列化成字符串、客户端解析、再手动维护过期逻辑——这是真实的"灾难"：网络往返次数爆炸，逻辑复杂到无法维护；
- 分布式锁、计数、限流这类场景需要**原子操作**，关系型数据库的事务开销又远超业务本身的复杂度。

### 一句话定义

> Redis 是一个**带有丰富数据结构的、单线程命令执行的内存数据库**，它用"把数据结构本身变成网络服务"这一核心概念，消灭了应用层大量的"序列化-传输-解析-重组"往返成本。

### 适用场景

| 场景 | 判断 |
|:---|:---|
| 缓存热点数据（QPS 10w+） | **必须用** |
| 分布式锁、限流、计数器 | **必须用**（原子操作） |
| 实时排行榜（ZSet） | **必须用** |
| 消息队列（Stream/List） | **适合用** |
| 全量业务数据主存储 | **杀鸡用牛刀**（用 PostgreSQL） |
| 大文件/二进制 Blob 存储 | **不应该用** |

---

## 2. 静态架构解剖 (The "Static Structure")

| 模块名称 | 核心职责 | 复杂度 | 核心地位 |
|:---|:---|:---|:---|
| **ae（Event Loop）** | 统一调度所有 I/O 和定时任务。屏蔽 epoll/kqueue/select 差异，是整个服务器的心跳 | 中 | 灵魂 |
| **server.c / server.h** | 全局状态机（`redisServer`），定义 `client`、`redisDb` 等核心数据结构，串联所有模块 | 高 | 灵魂 |
| **数据类型层（t_string / t_list / t_hash / t_set / t_zset / t_stream）** | 实现 6 种数据类型的所有命令逻辑，内部根据数据量自动切换编码格式 | 高 | 骨架 |
| **底层数据结构（sds / dict / quicklist / listpack / rax / skiplist）** | 为上层数据类型提供内存高效的底层实现，SDS 替代 C 字符串，dict 是哈希表核心 | 高 | 骨架 |
| **rdb.c（快照持久化）** | fork 子进程将内存全量序列化为二进制 RDB 文件，支持压缩，重启快速恢复 | 高 | 骨架 |
| **aof.c（日志持久化）** | 将每条写命令追加到 AOF 文件，支持 BASE + INCR 分段管理，保证更高的数据安全性 | 中 | 骨架 |
| **replication.c（主从复制）** | 管理 Master-Replica 数据同步，支持全量同步（RDB）和增量同步（replication backlog） | 高 | 皮肉 |
| **cluster.c（集群）** | 实现 16384 槽位的分片路由，节点间 Gossip 协议通信，支持自动故障转移 | 高 | 皮肉 |

---

## 3. 动态核心链路追踪 (The "Dynamic Flow")

**典型场景：客户端执行 `SET key value EX 60`**

```
客户端 TCP 数据                         服务端主线程
─────────────────────────────────────────────────────────────────────

[1] 原始字节流 "*3\r\n$3\r\nSET\r\n..."
    │
    ▼
[ae Event Loop] (ae.c)
    │  epoll_wait() 监听到 fd 可读
    │  触发 aeFileEvent -> rfileProc 回调
    ▼
[readQueryFromClient] (networking.c)
    │  将字节追加到 client->querybuf (SDS)
    │  调用 processInputBuffer()
    ▼
[RESP 协议解析] (networking.c)
    │  按 *3 解析为 3 个 bulk string
    │  填充 client->argv[] = [SET, key, value]
    │  解析 EX 60 参数
    ▼
[processCommand] (server.c:4302)
    │  lookupCommand("SET") -> 在命令表中找到 setCommand
    │  检查 ACL 权限、内存限制、是否只读副本
    │  若 MULTI 事务中则入队，否则直接执行
    ▼
[setCommand -> setGenericCommand] (t_string.c)
    │  dbAdd() 将 key->value 写入 redisDb->keys (kvstore/dict)
    │  若有 EX 参数：setExpire() 写入 redisDb->expires
    │
    │  [Object 编码自动选择]
    │  value 是纯数字且 ≤ LONG_MAX -> OBJ_ENCODING_INT (直接存整数)
    │  value 长度 ≤ 44 字节        -> OBJ_ENCODING_EMBSTR (内联分配)
    │  其他                        -> OBJ_ENCODING_RAW (SDS 独立分配)
    ▼
[addReply] (networking.c)
    │  将 "+OK\r\n" 写入 client->buf 输出缓冲
    ▼
[ae Event Loop] 下一轮循环
    │  beforeSleep() 被调用
    │  检测到 client->buf 有数据，注册 fd 可写事件
    │  epoll_wait 返回可写 -> writeToClient()
    ▼
[客户端收到响应] "+OK"

─────────────────────────────────────────────────────────────────────
[后台异步]
    serverCron() 定时任务（每 100ms 默认）
    ├── 主动过期扫描：随机抽取 redisDb->expires 中的 key 检查
    ├── AOF flush：将 server.aof_buf 刷盘
    └── RDB 子进程管理：检查 BGSAVE 是否完成
```

**数据变化摘要：**

```
原始字节 -> [RESP 解析] -> argv 数组 -> [命令路由] -> setCommand
-> [编码选择] -> robj(type=STRING, encoding=EMBSTR/INT/RAW)
-> [写入 kvstore] -> redisDb.keys[slot] dict entry
-> [写入 expires] -> redisDb.expires[slot] dict entry
-> [生成响应] -> client->buf -> [ae 写事件] -> TCP 发出
```

---

## 4. 架构评价 (The Trade-off)

### 设计亮点：自适应编码（Adaptive Encoding）

Redis 最精彩的设计是**同一种数据类型会根据数据量和数据特征自动切换底层编码**，对上层完全透明。

以 Hash 为例：
- 元素少（≤ 128 个）且值短（≤ 64 字节）→ **listpack**（紧凑连续内存，CPU 缓存友好）
- 元素变多后 → 自动转换为 **hashtable**（O(1) 查找）

这意味着：在小数据场景，Redis 的内存占用极低，甚至比你用 JSON 序列化存到 memcached 还省；在大数据场景，它切换到高性能结构。这个设计让 Redis 在"简单场景极致省内存"和"复杂场景不降速"之间找到了完美平衡。

同样的哲学体现在：
- String: `INT` → `EMBSTR`（≤44B）→ `RAW`
- List: `listpack` → `quicklist`
- ZSet: `listpack` → `skiplist + dict`
- Set: `intset` / `listpack` → `hashtable`

**这不是配置项，是自动发生的——这就是它"好用"的根本原因之一。**

### 潜在代价：单线程命令执行 & fork 开销

为了保证**命令原子性**，Redis 的命令执行始终是单线程的（I/O 线程化是后来才加的，但命令执行本体仍是单线程）。这带来的代价：

1. **慢查询会阻塞所有客户端**：一个 `KEYS *`、`HGETALL` 百万条目、`LRANGE 0 -1` 都会让所有连接等待。生产环境的慢日志（slowlog）因此必须监控。

2. **fork 持久化的内存代价**：RDB 快照触发 `fork()`，Copy-on-Write 机制在写密集场景下会导致实际内存占用翻倍。64GB 内存的实例在 BGSAVE 期间可能需要 128GB 的物理内存。这是 Redis 在大内存场景下最大的运维陷阱。

3. **单核瓶颈**：无论服务器有多少 CPU 核，命令处理只用一个核。QPS 超过百万级别后，横向扩展（Cluster）是唯一出路。
