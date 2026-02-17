# OpenClaw Gateway 模块深度分析

## 1. 模块定义 (Input/Output)

- **输入是什么**：来自多种来源的消息和指令——WebSocket 连接的 JSON-RPC 请求帧（CLI、手机 App、Web UI 发来的 90+ 种方法调用）、HTTP 请求（Hooks 触发器、OpenAI 兼容 API、Slack 回调等）、以及 Agent Runtime 产生的内部事件流（工具调用结果、LLM 流式文本等）。
- **输出是什么**：JSON-RPC 响应帧（对请求的直接回复）和 WebSocket 事件帧（广播给所有/指定客户端的实时通知：聊天增量、Agent 状态变化、Presence、定时任务完成等），以及转发到外部渠道（Telegram、WhatsApp 等）的消息。
- **核心职责**：**它是整个 OpenClaw 系统的中央神经系统——一个基于 WebSocket 的 RPC 总线 + 事件广播中心**，所有外部客户端和内部子系统都通过它交互。

---

## 2. 核心数据结构 (The "State")

Gateway 的运行时状态不依赖任何数据库，完全靠内存中的 Map 和 Set 维护。以下是最关键的几个：

### 2.1 客户端连接池

```typescript
// 所有已认证的 WebSocket 客户端
type GatewayWsClient = {
  socket: WebSocket;        // 底层 WebSocket 连接
  connect: ConnectParams;   // 握手时客户端声明的身份信息（角色、权限、设备 ID 等）
  connId: string;           // 连接唯一 ID（UUID）
  presenceKey?: string;     // 在线状态的标识符
  clientIp?: string;        // 客户端 IP（用于认证降级判断）
};

// 运行时用一个 Set 管理
const clients: Set<GatewayWsClient>;
```

**业务含义**：这个 Set 就是 Gateway 的"通讯录"。每条消息广播时，遍历这个 Set 给每个客户端发帧。Set 的选择意味着——不需要按 key 查找客户端，只需要做全量遍历或条件过滤。

### 2.2 聊天运行状态

```typescript
// 追踪正在进行的 Agent 对话
type ChatRunState = {
  registry: ChatRunRegistry;              // session → 排队的 ChatRunEntry[]
  buffers: Map<string, string>;           // runId → 累积的 assistant 文本（流式拼接）
  deltaSentAt: Map<string, number>;       // runId → 上一次发送 delta 的时间戳（节流用）
  abortedRuns: Map<string, number>;       // runId → 被中止的运行记录
};

type ChatRunEntry = {
  sessionKey: string;       // 对话键，格式：agentId|channelId|userId|chatType
  clientRunId: string;      // 客户端给这次对话分配的 ID
};

type ChatRunRegistry = {
  add: (sessionId, entry) => void;      // 入队
  peek: (sessionId) => entry;            // 查看队首
  shift: (sessionId) => entry;           // 出队（FIFO）
  remove: (sessionId, clientRunId) => entry;  // 精确移除
};
```

**业务含义**：这是一个**每 Session 一个 FIFO 队列**的结构。当一个 Session 同时收到多条消息时（比如用户连发两句话），它们会按顺序排队执行，避免 Agent 并发处理导致上下文混乱。`buffers` 用来做流式文本的"攒批"——不是每个 token 都发给客户端，而是攒一段时间再发。

### 2.3 Node 注册表

```typescript
// 远程设备/节点的注册中心
class NodeRegistry {
  private nodesById: Map<string, NodeSession>;      // nodeId → 节点会话
  private nodesByConn: Map<string, string>;          // connId → nodeId（反向索引）
  private pendingInvokes: Map<string, PendingInvoke>; // requestId → 待响应的远程调用
}

type NodeSession = {
  nodeId: string;             // 节点唯一 ID
  connId: string;             // 对应的 WebSocket connId
  client: GatewayWsClient;   // WebSocket 客户端引用
  caps: string[];             // 节点能力声明（如 "shell", "browser"）
  commands: string[];         // 可执行的命令列表
  permissions?: Record<string, boolean>;  // 权限声明
};
```

**业务含义**：Node 是 OpenClaw 的"远程手脚"——手机、平板等设备通过 WebSocket 连入 Gateway，注册为 Node。Gateway 可以向 Node 发起 RPC 调用（`invoke`），比如让手机执行某个操作。`pendingInvokes` 用 Promise + Timer 实现了经典的异步 RPC 等待模式。

### 2.4 广播系统与鉴权模型

```typescript
// 鉴权解析结果
type ResolvedGatewayAuth = {
  mode: "none" | "token" | "password" | "trusted-proxy";
  token?: string;               // Bearer token
  password?: string;            // 密码
  allowTailscale: boolean;      // 是否允许 Tailscale 身份认证
  trustedProxy?: { userHeader: string; requiredHeaders?: string[] };
};

// 权限层级：5 种 scope
// operator.admin  → 完全控制
// operator.read   → 只读操作（health、sessions.list、models.list 等）
// operator.write  → 读写操作（send、chat.send、node.invoke 等）
// operator.approvals → 执行审批
// operator.pairing   → 设备配对
```

**业务含义**：鉴权是四层防护——`none`（本地回环自动信任）、`token`（API Token）、`password`（密码）、`trusted-proxy`（反向代理注入的身份 Header）。再加上 Tailscale 作为零信任网络的补充路径。权限模型用 Set 做 O(1) 的方法名查找，非常高效。

---

## 3. 核心流程伪代码 (The "Happy Path")

### 3.1 Gateway 启动流程

```python
def start_gateway_server(port=18789):
    # 阶段 1：配置引导
    config = read_config_file()
    if config.has_legacy_issues:
        migrate_legacy_config(config)
    validate_config(config)
    auto_enable_plugins(config)

    # 阶段 2：解析运行时参数
    auth = resolve_auth(config)        # 确定认证模式
    bind_host = resolve_bind_host()    # 确定监听地址
    gateway_methods = list_base_methods() + plugin_methods + channel_methods  # 合并所有 RPC 方法

    # 阶段 3：创建运行时基础设施
    http_server = create_http_server()     # HTTP 服务（处理 Hooks、OpenAI API 等）
    wss = new WebSocketServer(noServer)    # WS 服务（挂在 HTTP 上，共用端口）
    clients = Set()                         # 客户端连接池
    broadcast = create_broadcaster(clients) # 广播函数

    # 阶段 4：挂载处理器
    attach_ws_handlers(wss, clients, auth, methods, broadcast)  # WS 消息处理
    attach_http_handlers(http_server, hooks, openai, slack)      # HTTP 路由

    # 阶段 5：启动附属系统
    start_channels()           # 启动 38 个消息渠道
    start_cron_service()       # 启动定时任务
    start_heartbeat_runner()   # 启动心跳
    start_discovery()          # 启动 mDNS/Bonjour 服务发现
    start_plugins()            # 启动插件服务
    start_config_reloader()    # 启动配置文件热重载监听

    return { close: close_handler }
```

### 3.2 WebSocket 连接建立（握手协议）

```python
def on_ws_connection(socket, upgrade_request):
    conn_id = uuid()

    # 这里是为了防止恶意连接：先发 challenge，要求客户端在握手时证明自己
    nonce = uuid()
    send(socket, { type: "event", event: "connect.challenge", payload: { nonce } })

    # 设置握手超时（防止半开连接耗尽资源）
    handshake_timer = setTimeout(close, HANDSHAKE_TIMEOUT)

    def on_message(raw_data):
        frame = parse_json(raw_data)

        if frame.type == "connect":
            # 阶段 1：验证协议版本
            if not compatible_protocol(frame.protocol):
                send_error("protocol mismatch")
                return

            # 阶段 2：认证
            auth_result = authorize(frame.token, frame.password, request)
            if not auth_result.ok:
                send_error("unauthorized")
                close()
                return

            # 阶段 3：注册客户端
            client = { socket, connect: frame, conn_id }
            clients.add(client)
            clear_timeout(handshake_timer)

            # 阶段 4：回复 HelloOk（告知客户端可用的方法和事件列表）
            send(socket, {
                type: "hello.ok",
                methods: gateway_methods,
                events: gateway_events,
                canvas_host_url: ...,
            })

            # 阶段 5：广播在线状态变更
            broadcast("presence", { presence: list_presence() })

        elif frame.type == "request":
            # 这里是所有 RPC 调用的入口
            handle_gateway_request(frame)

    socket.on("message", on_message)
```

### 3.3 RPC 请求分发

```python
def handle_gateway_request(request, client):
    method = request.method  # 如 "chat.send", "sessions.list", "config.get"

    # 这里是为了实现 RBAC：每个方法都有最低权限要求
    auth_error = authorize_method(method, client.scopes)
    if auth_error:
        respond_error(auth_error)
        return

    # 查找处理器（先查插件注册的，再查核心内置的）
    handler = extra_handlers.get(method) or core_handlers.get(method)
    if not handler:
        respond_error("unknown method")
        return

    # 执行处理器
    handler({ request, params: request.params, client, respond, context })
```

### 3.4 Agent 事件广播（聊天消息流式推送）

```python
def create_agent_event_handler():
    def on_agent_event(event):
        session_key = resolve_session_key(event.run_id)
        client_run_id = chat_run_state.peek(event.run_id)?.client_run_id or event.run_id

        if event.stream == "assistant" and event.data.text:
            # 这里是为了节省带宽：不是每个 token 都推送，而是每 150ms 推送一次
            buffers[client_run_id] += event.data.text
            if now - last_sent[client_run_id] < 150:
                return  # 节流，跳过
            last_sent[client_run_id] = now

            # 广播 delta 给所有 WebSocket 客户端
            broadcast("chat", { runId, sessionKey, state: "delta", message: { text: buffered } })
            # 同时推送给渠道订阅者（Telegram/WhatsApp 的 Node）
            node_send_to_session(session_key, "chat", payload)

        elif event.stream == "lifecycle" and event.data.phase in ("end", "error"):
            # 对话结束，发送最终状态
            final_text = buffers.pop(client_run_id)
            broadcast("chat", { runId, sessionKey, state: "final", message: { text: final_text } })

            # 清理状态
            cleanup_run_state(event.run_id)

    return on_agent_event
```

### 3.5 广播机制（背压 + 权限过滤）

```python
def broadcast(event, payload, opts):
    if clients.size == 0:
        return

    seq += 1
    frame = json({ type: "event", event, payload, seq })

    for client in clients:
        # 这里是为了实现权限隔离：不同 scope 的客户端只能收到自己有权看到的事件
        if not has_event_scope(client, event):
            continue

        # 这里是为了防止慢客户端拖垮整个系统
        if client.socket.bufferedAmount > MAX_BUFFERED_BYTES:
            if opts.dropIfSlow:
                continue       # 丢弃非关键消息（如 tick、delta）
            else:
                client.socket.close(1008, "slow consumer")  # 踢掉慢客户端
                continue

        client.socket.send(frame)
```

---

## 4. 设计推演与对比 (The "Why")

### 4.1 笨办法：每个渠道一个独立服务器

**如果不用 Gateway 这种"总线"设计**，最直觉的做法是：Telegram Bot 是一个进程，WhatsApp Bot 是另一个进程，CLI 又是一个进程。每个进程内部自己管理 Agent 运行、Session 存储、配置加载。

**后果**：
- **状态同步噩梦**：用户在 Telegram 上聊了一半，切到 CLI 继续——两个进程怎么共享对话记录？引入数据库？还是文件锁？每加一个渠道就多一条同步链路，复杂度是 O(n^2)。
- **资源浪费**：每个进程都加载一份完整的 Agent Runtime、LLM 客户端、配置系统。38 个渠道就是 38 份重复内存。
- **运维地狱**：想更新配置？得重启 38 个进程。想看健康状态？得逐个查 38 个端口。

**Gateway 怎么解决的**：

一个进程，一个端口，一个 WebSocket 服务。38 个渠道作为"Channel Plugin"挂在 Gateway 上，共享同一个 Agent Runtime、同一套 Session 存储、同一份配置。所有客户端（CLI、App、Web UI）通过统一的 WebSocket RPC 协议交互。

复杂度从 O(n^2) 降到 O(n)——每个渠道只需要跟 Gateway 通信，不需要知道其他渠道的存在。

### 4.2 笨办法：HTTP 轮询代替 WebSocket 推送

**如果不用 WebSocket**，客户端只能通过 HTTP 轮询获取 Agent 的流式回复。

**后果**：
- **延迟巨大**：LLM 每生成一个 token 都应该立刻推送给用户。轮询间隔哪怕只有 100ms，用户感知到的流畅度也会大打折扣。
- **资源浪费**：38 个渠道 + N 个客户端，每秒几百次无效轮询，光 TCP 连接开销就不小。
- **不支持服务端主动推送**：Gateway 需要在 Agent 完成任务时通知客户端、在健康状态变化时广播、在配置热重载时告知所有连接——这些都需要服务端主动推送。

**Gateway 怎么解决的**：

WebSocket 长连接 + 事件驱动。Gateway 维护一个 `clients: Set<GatewayWsClient>`，任何事件（Agent 输出、Presence 变化、Cron 完成）都通过 `broadcast()` 函数一次性推送给所有客户端。

更精妙的是**背压控制**：如果某个客户端的发送缓冲区超过 `MAX_BUFFERED_BYTES`（默认 4MB），对于非关键消息（`dropIfSlow: true`）直接丢弃，对于关键消息则断开连接。这防止了一个慢客户端（比如网络差的手机）拖垮整个广播系统。

### 4.3 笨办法：每条消息都立刻推送

**如果不做 delta 节流**，LLM 每输出一个 token 就立刻广播一帧 WebSocket 消息。

**后果**：
- **帧爆炸**：一个 1000 token 的回复 → 1000 个 WebSocket 帧 → 每个帧都有 JSON 序列化、网络开销。
- **客户端 UI 抖动**：React/Flutter 每收到一帧就触发一次 setState/rebuild，性能崩溃。

**Gateway 怎么解决的**：

`chatRunState.deltaSentAt` 实现了一个**最小 150ms 间隔的节流器**。收到 Agent 的文本 token 后，先累积到 `buffers` 中，如果距离上次推送不到 150ms 就跳过。下一个 150ms 窗口到来时，把累积的文本一次性发出去。

最终效果：1000 个 token 变成约 20~30 帧推送，大幅减少网络和渲染开销，同时用户感知到的延迟几乎可以忽略。

### 4.4 笨办法：不做方法级鉴权

**如果所有认证通过的客户端都能调用所有方法**：

**后果**：手机 App 的只读模式客户端可以删除 Session、修改配置、执行 Shell 命令——安全性完全失控。

**Gateway 怎么解决的**：

两层防护：
1. **连接级认证**（`authorizeGatewayConnect`）：Token/Password/Tailscale/TrustedProxy 四选一，外加速率限制器防暴力破解。
2. **方法级授权**（`authorizeGatewayMethod`）：用预定义的 Set（`READ_METHODS`、`WRITE_METHODS`、`ADMIN_METHOD_PREFIXES` 等）做 O(1) 权限校验。每个客户端声明自己的 `scopes`，只能调用对应 scope 内的方法。

特别巧妙的是 `role` 机制：`node` 角色的客户端只能调用 `node.invoke.result` 和 `node.event` 这类"汇报型"方法，不能调用 `send` 或 `config.set` 等"控制型"方法。这确保了远程设备只能被 Gateway 指挥，不能反过来操控 Gateway。

---

## 5. 总结与启示

### 生活类比

Gateway 就是一个**大型机场的空中交通管制中心（ATC）**：

- **飞机**（38 个渠道 + 各种客户端）不直接互相通信，所有通信都经过管制塔台。
- **管制员**根据飞机类型（角色/权限）分配不同的航线（可调用的方法）。
- **雷达屏**（clients Set）实时追踪所有在场飞机的位置。
- **广播频道**（broadcast）向相关飞机发送天气警报（事件通知），如果某架飞机信号不好（慢客户端），就跳过或要求其离场。
- **机场只有一条跑道**（一个端口），但通过时间分片（异步事件循环）让所有飞机有序起降。

### 可复用的设计技巧

1. **"总线 + 插件"比"点对点"好**：当你有 N 个子系统需要互相通信时，不要让它们直接互联（O(n^2)），而是引入一个中央总线，每个子系统只跟总线交互（O(n)）。Gateway 的 `broadcast` + `server-methods` 就是这种模式的典范。

2. **背压是必须的**：任何涉及广播/推送的系统都必须处理"慢消费者"问题。Gateway 的 `bufferedAmount > MAX_BUFFERED_BYTES` 检查 + `dropIfSlow` 策略简洁优雅——不需要消息队列，不需要 ack 机制，直接利用 WebSocket 的内置缓冲区指标做判断。

3. **流式输出的节流是必需品**：LLM 应用中，逐 token 推送是性能杀手。150ms 的节流窗口 + buffer 累积是一个值得直接复用的模式。

4. **认证与授权分两层**：连接时做身份认证（你是谁），每次请求时做方法授权（你能做什么）。用预定义的 Set 做 O(1) 权限查找，比动态 ACL 或 ABAC 简单一个数量级，在单用户/小团队场景下完全够用。

5. **配置驱动的启动顺序**：Gateway 的启动是一个精心编排的有序过程——先加载配置、再解析鉴权、再创建 HTTP/WS 服务、再挂载处理器、最后才启动渠道和 Cron。这种"层层依赖"的启动模式比"全部并行启动"更可控，故障定位也更容易。

6. **优雅关闭的完整清单**：`createGatewayCloseHandler` 展示了一个教科书级的关闭流程——停渠道 → 停插件 → 停定时任务 → 广播 shutdown → 清定时器 → 清状态 → 断 WS → 断 HTTP。每一步都有 try-catch 防止某个子系统的关闭失败阻断整个流程。
