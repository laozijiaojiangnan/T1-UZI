# MySQL Server 架构深度分析

> 版本: 9.6.0 (INNOVATION)
> 分析日期: 2026-02-25

## 1. 核心矛盾与存在意义

### 痛点还原

在没有 MySQL 之前，开发者面临的数据管理困境是**地狱级的**：

- **文件级操作**：想存取数据？自己写文件格式、自己管理索引、自己处理并发冲突
- **写 SQL Parser**：2000 行 SQL 语句，手工拆词分析？玩命
- **单机 vs 分布式**：想把数据分散到多台机器？从头造轮子
- **崩溃恢复**：断电了数据怎么恢复？写 WAL、写 checkpoint，全部自己来
- **客户端协议**：怎么和服务器通信？自己设计二进制协议

### 一句话定义

**MySQL = 帮开发者把「如何高效存储和查询数据」这个复杂问题，直接打包成一个开箱即用的 SQL 服务。**

它用三层架构（协议层→SQL层→存储层）把「网络通信」「SQL 解析执行」「数据持久化」全部封装好，开发者只需要写 SQL 就能操作数据。

### 适用场景

| 场景 | 推荐度 |
|------|--------|
| Web 应用后端数据存储 | ⭐⭐⭐⭐⭐ 必选 |
| 日志/时序数据分析 | ⭐⭐⭐⭐ 适合（MySQL 8.0+） |
| 事务型业务系统 | ⭐⭐⭐⭐⭐ 适合（InnoDB） |
| 超大规模分布式存储 | ⭐⭐ 谨慎（考虑 TiDB/CockroachDB） |
| 简单 KV 缓存 | ⭐ 不推荐（用 Redis） |
| 复杂 OLAP 分析 | ⭐⭐ 勉强（用 ClickHouse） |

---

## 2. 静态架构解剖

| 模块名称 | 核心职责 | 复杂度 | 核心地位 |
|----------|----------|--------|----------|
| **sql/** | SQL 引擎大本营：解析→优化→执行 | 极高 | 灵魂 |
| **storage/innobase** | 事务存储引擎：ACID + 行锁 + MVCC | 高 | 灵魂 |
| **client/** | 命令行工具集：mysql/mysqldump/mysqlbinlog | 中 | 皮肉 |
| **mysys/** | 系统抽象层：线程/文件/内存/网络封装 | 中 | 骨架 |
| **router/** | MySQL Router：读写分离/连接池 | 中 | 皮肉 |
| **plugin/** | 插件系统：扩展认证/存储/功能 | 中 | 骨架 |
| **libmysql/** | C 语言客户端库：给各种语言提供 driver | 中 | 骨架 |

### 核心模块详解

#### 2.1 sql/ — SQL 引擎核心

这是 MySQL 最复杂的模块，包含了：

```
sql/
├── sql_yacc.yy       ← 词法+语法解析器 (SQL → AST)
├── sql_lex.h         ← 词法├── sql_parse.*       ← 解析定义
入口
├── sql_optimizer.*   ← 查询优化 (基于成本)
├── sql_executor.*    ← 执行器 (火山模型)
├── sql_class.*       ← THD 类：每个连接的生命周期管理
├── handler.h         ← 存储引擎抽象接口
├── binlog/           ← Binlog 逻辑复制
├── rpl_*             ← 主从复制相关
├── auth/             ← 认证和权限
├── iterators/        ← 迭代器执行模型 (8.0+)
└── join_optimizer/   ← Join 优化 (超图优化器)
```

**关键概念：**
- **THD (Thread Handle)**：每个客户端连接对应一个 THD 对象，是 SQL 处理的"上下文容器"
- **handler**：存储引擎的统一抽象接口，所有存储引擎（InnoDB、MyISAM 等）都实现这一接口
- **Iterator**：8.0 引入的新执行模型，用迭代器代替传统的火山模型

#### 2.2 storage/innobase — 事务存储引擎

InnoDB 是 MySQL 默认且最重要的存储引擎：

```
storage/innobase/
├── buf/              ← Buffer Pool：内存缓存
├── dict/             ← 数据字典：表/索引元数据
├── trx/              ← 事务系统：MVCC + 锁
├── row/              ← 行级操作
├── page/             ← 页面管理 (16KB/页)
├── log/              ← Redo Log：崩溃恢复
├── lock/             ← 行锁
├── btr/              ← B+树索引
└── ibuf/             ← 插入缓冲区
```

#### 2.3 client/ — 客户端工具集

```
client/
├── mysql.cc                    ← mysql CLI 交互式客户端
├── mysqldump.cc               ← 逻辑备份工具
├── mysqlbinlog.cc             ← Binlog 分析工具
├── mysqladmin.cc              ← 管理工具
├── mysqlshow.cc               ← 元数据查看
├── mysqlimport.cc             ← 数据导入
└── mysqltest.cc              ← 测试框架
```

---

## 3. 动态核心链路追踪

### 场景：一次简单的 SELECT 查询

以 `SELECT * FROM users WHERE id = 1` 为例，看数据如何流转：

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          MySQL 核心链路 (SELECT 查询)                        │
└─────────────────────────────────────────────────────────────────────────────┘

   客户端               MySQL Server                                           存储引擎
     │                     │                                                     │
     │  TCP 连接            │                                                     │
     ├────────────────────►│                                                     │
     │                     │  1. THD 创建                                        │
     │                     │  (为每个连接创建 THD 对象)                            │
     │                     ├────────────────────────────────────────────────────►│
     │                     │                                                     │
     │  SQL 文本            │                                                     │
     ├────────────────────►│                                                     │
     │                     │  2. 解析器 (sql_yacc.yy)                             │
     │                     │  SQL → 解析树                                        │
     │                     ├──┐                                                  │
     │                     │  │                                                  │
     │                     │  ▼                                                  │
     │                     │  3. 预处理器 (sql_prepare)                           │
     │                     │  检查表/列存在性                                      │
     │                     │  ├──┐                                               │
     │                     │  │  │                                               │
     │                     │  ▼  ▼                                               │
     │                     │  4. 优化器 (sql_optimizer)                           │
     │                     │  生成执行计划                                        │
     │                     │  ├──┐                                               │
     │                     │  │  │                                               │
     │                     │  ▼  ▼                                               │
     │                     │  5. 执行器 (sql_executor / iterators)                │
     │                     │  调用 handler API                                    │
     │                     │  ├──┐                                               │
     │                     │  │  │                                               │
     │                     │  ▼  ▼                                               │
     │                     ├────────────────────────────────────────────────────►│
     │                     │  6. InnoDB handler                                  │
     │                     │  - Buffer Pool 查找                                  │
     │                     │  - B+树索引定位                                      │
     │                     │  - MVCC 版本检查                                      │
     │                     │  ◄───────────────────────────────────────────────────┤
     │                     │                                                     │
     │  结果集 (协议包)      │                                                     │
     │◄────────────────────┤                                                     │
     │                     │                                                     │
```

### 链路详解

| 步骤 | 模块 | 数据变化 |
|------|------|----------|
| 1 | conn_handler | TCP 连接 → THD 对象 |
| 2 | sql_yacc.yy | SQL 文本 → 解析树 (Parse Tree) |
| 3 | sql_prepare | 解析树 → 预处理 (验证表/列) |
| 4 | sql_optimizer | 预处理 → 执行计划 (基于成本) |
| 5 | sql_executor | 执行计划 → 行迭代器 (Row Iterator) |
| 6 | handler | 调用 InnoDB API 获取数据 |
| 7 | protocol | 行数据 → MySQL 协议包 |
| 8 | net_send | 协议包 → TCP 响应 |

---

## 4. 架构评价

### 设计亮点

#### 亮点 1：插件化存储引擎架构

**handler 接口**是 MySQL 最精彩的设计之一：

```cpp
// sql/handler.h 中的抽象接口
class handler {
  virtual int ha_open(TABLE *table, const char *name,
                      int mode, uint test_if_locked) = 0;
  virtual int ha_write(TABLE *table, const uchar *buf) = 0;
  virtual int ha_update(TABLE *table, const uchar *old_buf,
                        const uchar *new_buf) = 0;
  virtual int ha_delete(TABLE *table, const uchar *buf) = 0;
  virtual int ha_rnd_next(uchar *buf) = 0;
  // ... 等等
};
```

这个设计让 MySQL：
- 可以同时加载多种存储引擎（InnoDB、MyISAM、Memory...）
- 开发者可以自己写一个存储引擎，插进去就能用
- 换存储引擎只需改一个配置，不用改上层代码

**这才是真正的「可插拔架构」！**

#### 亮点 2：Binlog 逻辑复制

MySQL 的主从复制不是简单的"把数据拷贝过去"，而是通过 **Binlog** 实现：

- 记录的是"做了什么操作"（逻辑日志），不是"数据长什么样"（物理日志）
- 支持跨版本复制、跨存储引擎复制
- 轻量级、易于解析和传输

#### 亮点 3：InnoDB 的 MVCC + 锁

- **MVCC (多版本并发控制)**：读写不冲突，真正实现快照读
- **行锁 + GAP 锁**：细粒度锁，减少冲突
- **Redo Log**：崩溃后自动恢复，ACID 不用自己写

### 潜在代价

| 代价 | 说明 |
|------|------|
| **代码复杂度极高** | 30 年历史，700+ 万行代码，新人上手极难 |
| **8.0 之前性能一般** | 老版执行器是火山模型，效率低 |
| **JSON 支持较弱** | 相比 MongoDB，JSON 操作不够原生 |
| **分区功能鸡肋** | 分区表性能提升有限，维护成本高 |
| **并行复制延迟** | 单线程 binlog 应用曾是瓶颈 |
| **GPL 许可证** | 核心代码是 GPL，企业使用有许可风险 |

---

## 5. 附录：代码规模统计

```
模块              代码行数估算    文件数
-------------------------------------------------
sql/              ~300万行       ~1500个
storage/innobase  ~100万行       ~500个
client/           ~30万行        ~100个
mysys/            ~20万行        ~200个
libmysql/         ~10万行        ~50个
router/           ~20万行        ~100个
-------------------------------------------------
总计              ~500万行       ~2500个
```

---

## 6. 参考资源

- 官方文档: https://dev.mysql.com/doc/refman/9.6/en/
- 源码: https://github.com/mysql/mysql-server
- InnoDB 原理: 《MySQL 技术内幕：InnoDB 存储引擎》
