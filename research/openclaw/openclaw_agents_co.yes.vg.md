# OpenClaw Agent Runtime 模块深度剖析

## 1. 模块定义 (Input/Output)

- **输入**：用户消息（文本/图片）+ Session 历史 + 工具定义 + System Prompt 参数 + 认证凭证
- **输出**：AI 回复（流式文本块）+ 工具调用结果 + 更新后的 Session 文件 + Token 使用统计
- **核心职责**：它是整个系统的**大脑和心脏**——接收经 Channel 标准化后的用户消息，驱动 LLM 完成"思考→工具调用→回复"的完整循环，并管理认证轮转、上下文压缩、子 Agent 编排等所有运行时生命周期。

---

## 2. 核心数据结构 (The "State")

### 2.1 运行参数：RunEmbeddedPiAgentParams

```typescript
interface RunEmbeddedPiAgentParams {
  // —— Session 上下文 ——
  sessionId: string              // 会话唯一标识
  sessionKey: string             // 路由键，格式: agent|channel|userId|chat
  sessionFile: string            // JSONL 文件路径，持久化对话历史
  workspaceDir: string           // 工作目录（sandbox 根）

  // —— 模型选择 ——
  provider: string               // "anthropic" | "openai" | "google" 等
  model: string                  // "claude-opus-4-6" 等
  authProfileId?: string         // 认证配置 ID，用于多 Key 轮转

  // —— 思考控制 ——
  thinkLevel: "off" | "minimal" | "low" | "medium" | "high" | "xhigh"
  // 控制 extended thinking 的深度，失败时可自动降级

  // —— 工具控制 ——
  disableTools?: boolean         // 禁用所有工具（纯聊天模式）
  toolResultFormat?: "markdown" | "plain"  // 工具输出格式

  // —— 流式回调 ——
  onBlockReply: (payload) => void     // 文本块回调（给渠道发送）
  onToolResult: (payload) => void     // 工具执行结果回调
  onReasoningStream: (payload) => void // 推理过程流式回调

  // —— 生命周期 ——
  timeoutMs?: number             // 单次调用超时
  abortSignal?: AbortSignal      // 外部中止信号
}
```

### 2.2 流式状态机：EmbeddedPiSubscribeState

这是整个流式处理的"记忆体"，跟踪一次 LLM 调用中所有中间状态：

```typescript
interface EmbeddedPiSubscribeState {
  // —— 文本累积 ——
  assistantTexts: string[]       // 已完成的文本块数组
  deltaBuffer: string            // 当前累积的流式文本增量
  blockBuffer: string            // 等待切块发送的缓冲区

  // —— 块状态检测 ——
  blockState: {
    thinking: boolean            // 是否在 <think> 标签内
    final: boolean               // 是否在最终回答区域
    inlineCode: boolean          // 是否在行内代码中
  }

  // —— 工具追踪 ——
  toolMetaById: Map<string, ToolMeta>      // 按 ID 追踪工具元信息
  toolSummaryById: Map<string, string>     // 工具执行摘要
  lastToolError?: string                    // 最后一个工具错误

  // —— 消息去重 ——
  messagingToolSentTexts: string[]   // 已通过 message 工具发出的文本
  messagingToolSentTargets: string[] // 已发送的目标渠道
  // 用于防止 block reply 重复发送 message 工具已发过的内容

  // —— Compaction 协调 ——
  compactionInFlight: boolean        // 是否正在压缩
  compactionRetryPromise?: Promise   // 等待压缩重试的 Promise
  pendingCompactionRetry: boolean    // 是否有待处理的重试
}
```

### 2.3 认证轮转：AuthProfile

```typescript
interface AuthProfile {
  profileId: string              // 配置文件 ID
  provider: string               // 对应的模型提供商
  credential?: ApiKeyCredential | OAuthCredential  // 凭证
  failureCount?: number          // 连续失败次数
  lastFailedAt?: number          // 上次失败时间戳
  cooldownUntilMs?: number       // 冷却期截止时间
  lastUsedAt?: number            // 上次使用时间（用于 round-robin）
}
// 冷却时间采用指数退避：10s → 60s → 300s
```

### 2.4 子 Agent 注册：SubagentRunRecord

```typescript
interface SubagentRunRecord {
  runId: string                  // 唯一运行 ID
  childSessionKey: string        // 子 Agent 的 Session Key
  requesterSessionKey: string    // 父 Agent 的 Session Key
  task: string                   // 人类可读的任务描述
  cleanup: "delete" | "keep"     // 完成后是否删除子 Session
  model?: string                 // 子 Agent 专用模型
  outcome?: "ok" | "error" | "timeout"  // 运行结果
  archiveAtMs?: number           // 自动归档时间
}
```

---

## 3. 核心流程伪代码 (The "Happy Path")

### 3.1 主运行循环：runEmbeddedPiAgent

```python
def run_embedded_pi_agent(params):
    # ① 解析模型
    model = resolve_model(params.provider, params.model)
    context_window = model.context_window

    # ② 构建认证候选链
    profile_candidates = resolve_auth_profile_order(config)
    usage = UsageAccumulator()  # Token 计数器

    # ③ 主循环：遍历认证配置直到成功
    for profile in profile_candidates:
        if profile.is_in_cooldown():
            continue  # 跳过冷却中的配置

        try:
            # ④ 执行单次 LLM 调用尝试
            result = run_embedded_attempt(
                session_file=params.session_file,
                model=model,
                auth_profile=profile,
                think_level=params.think_level,
                callbacks=params.callbacks
            )

            # ⑤ 累积 Token 使用量
            usage.merge(result.usage)
            # 关键：上下文大小只取最后一次调用的 cache_read，而非累加
            # 因为每次调用都会报告 cache_read ≈ 当前上下文大小

            profile.mark_good()  # 标记认证成功
            return result

        except AuthError:
            profile.mark_failure()          # 记录失败
            continue                        # 尝试下一个配置

        except RateLimitError:
            profile.set_cooldown(exponential_backoff())
            continue

        except ContextOverflowError:
            # ⑥ 上下文溢出 → 触发 Compaction
            compact_session(params.session_file, model)
            retry()  # 最多重试 3 次

        except ThinkingError:
            # ⑦ 思考级别降级
            params.think_level = downgrade(params.think_level)
            retry()

    raise FailoverError("所有认证配置均已耗尽")
```

### 3.2 单次 LLM 尝试：runEmbeddedAttempt

```python
def run_embedded_attempt(params):
    # ① 加载/创建 Session
    session_manager = SessionManager.from_file(params.session_file)
    session = create_agent_session(session_manager)

    # ② 构建 System Prompt
    system_prompt = build_embedded_system_prompt(
        identity=agent_identity,
        skills=workspace_skills,
        tools=available_tools,
        workspace=workspace_dir
    )
    session.set_system_prompt(system_prompt)

    # ③ 创建工具集
    tools = create_openclaw_coding_tools(workspace_dir, sandbox)
    # 包含: read/write/edit 文件、bash 执行、浏览器、消息发送等
    session.register_tools(tools)

    # ④ 设置流式订阅——这是事件驱动的核心
    subscriber = subscribe_embedded_pi_session(
        session=session,
        on_block_reply=params.on_block_reply,    # 文本块 → 发给用户
        on_tool_result=params.on_tool_result,    # 工具结果 → 通知调用方
    )

    # ⑤ 检测 Prompt 中的图片引用
    images = detect_and_load_prompt_images(params.prompt)

    # ⑥ 调用 LLM（PI Agent SDK 内部处理 tool_use 循环）
    #    SDK 会自动循环：LLM回复 → 含tool_use → 执行工具 → 结果注入 → 再次调用LLM
    await session.prompt(params.prompt, images=images)

    # ⑦ 等待可能的 Compaction 重试
    await subscriber.wait_for_compaction_retry()

    # ⑧ 返回结果
    return {
        final_assistant: session.last_assistant_message,
        session_file: params.session_file,
        usage: subscriber.get_usage_totals()
    }
```

### 3.3 流式事件处理：subscribeEmbeddedPiSession

```python
def subscribe_embedded_pi_session(params):
    state = EmbeddedPiSubscribeState()  # 初始化状态机

    def on_event(event):
        match event.type:
            case "message_start":
                state.reset()  # 清空缓冲区，准备接收新消息

            case "text_delta":
                state.delta_buffer += event.text
                # 检测 <think> 标签，分离推理和回复
                visible_text = strip_block_tags(state.delta_buffer)
                # 推入块切割器：按段落/代码块边界智能分块
                block_chunker.push(visible_text)
                # 当积累到一个完整块时，回调发送给用户
                if block_chunker.has_complete_block():
                    params.on_block_reply(block_chunker.flush())

            case "tool_execution_start":
                # 先把当前文本块刷出去，再开始工具执行
                flush_pending_block_replies()
                state.tool_meta[event.tool_id] = event.tool_info

            case "tool_execution_end":
                # 去重：如果 message 工具已经发过相同文本，抑制 block reply
                if is_messaging_tool(event) and event.text in state.sent_texts:
                    suppress_next_block_reply()
                params.on_tool_result(event.result)

            case "agent_end":
                # 排空块切割器中剩余的文本
                block_chunker.drain()
                # 解决任何等待中的 Compaction Promise
                resolve_compaction_promises()

    session.subscribe(on_event)
```

### 3.4 上下文压缩：Compaction

```python
def compact_session(session_file, model):
    messages = load_session_messages(session_file)

    # ① 按 Token 比例分块（而非简单按条数）
    chunks = split_messages_by_token_share(messages, parts=2)

    # ② 对每个块调用 LLM 生成摘要
    summaries = []
    for chunk in chunks:
        if is_oversized(chunk):  # 超过上下文窗口 50% 的单条消息
            chunk = truncate(chunk)
        summary = llm.call("请总结以下对话内容", chunk)
        summaries.append(summary)

    # ③ 如果有多个摘要，合并为一个
    if len(summaries) > 1:
        final_summary = llm.call("合并以下摘要为一个连贯的总结", summaries)
    else:
        final_summary = summaries[0]

    # ④ 替换历史消息：保留最近几轮，前面替换为摘要
    strip_tool_result_details(messages)  # 清除不信任的工具载荷
    session.replace_history(
        summary_message=final_summary,
        keep_recent_turns=True  # 保留最近的对话不压缩
    )
```

---

## 4. 设计推演与对比 (The "Why")

### 4.1 笨办法：无认证轮转，单 API Key 直连

**后果**：
- 一个 Key 被限流，整个系统瘫痪，用户只能干等
- 不同 Provider 的 Key 管理逻辑散落在各处，无法统一处理
- 没有冷却机制，被限流后反复重试，可能触发更严厉的封禁

**当前设计的巧妙之处**：
Auth Profile 系统把"轮转"抽象成一个**有序候选链 + 指数退避冷却**。像飞机引擎的冗余设计——一台熄火，自动切换到备用引擎。冷却期用指数退避（10s → 60s → 300s）避免疯狂重试，`lastUsedAt` 实现 Round-Robin 均匀分摊负载。整个轮转逻辑对上层完全透明，`runEmbeddedAttempt` 不需要知道当前用的是哪个 Key。

### 4.2 笨办法：无 Compaction，对话越来越长直到爆炸

**后果**：
- 对话到一定长度，直接触发上下文窗口限制，LLM 报错
- 如果简单粗暴地截断历史，AI 会"失忆"，丢失关键上下文
- 如果每次都传完整历史，Token 消耗成本成倍增长

**当前设计的巧妙之处**：
Compaction 不是简单截断，而是**让 LLM 自己总结自己的对话**。它按 Token 比例（而非条数）分块，确保每个摘要块的上下文量一致。"把长对话变成一段精炼摘要 + 保留最近几轮原始对话"——就像书本的目录 + 当前阅读页面。更精妙的是，它只在上下文溢出时才自动触发，平时零开销。

### 4.3 笨办法：无流式块切割，LLM 输出一个字发一个字

**后果**：
- 逐字发送到聊天渠道，消息碎片化严重（Telegram 可能每秒收到十几条消息）
- 或者等全部生成完再发，用户等待体验极差
- 代码块被从中间切断，格式错乱

**当前设计的巧妙之处**：
Block Chunker 是一个**语义感知的文本切割器**。它不是按字符数机械切割，而是：
- 尊重 Markdown 代码块边界（不在 `` ``` `` 中间切断）
- 按段落优先切割，保证每一块都是"可读的完整单元"
- 如果一个代码块太长被迫切割，会自动"重新打开"代码块标记，确保格式不错乱
这让用户在 Telegram/Slack 等渠道上看到的是一段段完整的回复，而不是碎片化的字符流。

### 4.4 笨办法：工具调用和文本回复各管各

**后果**：
- `message` 工具主动发了一段文字给用户，LLM 回复里又重复同样的文字 → 用户收到两遍
- 工具执行期间继续发送文本块 → 用户看到交错混乱的消息

**当前设计的巧妙之处**：
`messagingToolSentTexts` 数组充当**去重表**。流式处理器会检查 Block Reply 的文本是否已经被 `message` 工具发过——如果重复，直接抑制。同时，在工具执行开始前，先 `flush` 掉所有待发送的文本块，确保消息顺序是"文本 → 工具 → 文本"，不会交错。

### 4.5 笨办法：Token 使用量简单累加

**后果**：
- 多轮工具调用中，每次 API 调用都报告 `cache_read ≈ 当前上下文大小`
- 如果 N 次调用就简单相加，得到的 `cache_read` 是真实值的 N 倍
- 导致上下文大小估算严重失真，提前触发不必要的 Compaction

**当前设计的巧妙之处**：
`UsageAccumulator` 区分了"累计量"和"瞬时量"。`input`/`output` 做正常累加（总消耗确实需要求和），但 `lastCacheRead`/`lastCacheWrite` 只保留最后一次 API 调用的值——因为这才是当前真实的上下文占用量。这是个很容易忽略的坑（代码注释中引用了 issue #13698），但会导致系统行为严重异常。

---

## 5. 总结与启示

### 生活类比

Agent Runtime 就像一个**高端酒店的前台总管**：

- 客人（用户消息）从不同大门进来（38 个渠道），总管不关心你走哪个门
- 总管手里有一串钥匙（Auth Profiles），一把不好用就换下一把
- 跟客人对话时，总管有一个笔记本（Session），但笔记本写满了不会换新本子，而是把前面的内容**摘要到目录页**（Compaction）
- 客人的请求需要其他部门帮忙（Tool 调用），总管会先把正在说的话说完，再去找人办事，办完再回来继续
- 如果客人太多，总管可以叫副手来帮忙（Subagent），副手干完活会回报结果

### 可复用的设计技巧

1. **认证轮转 + 指数退避冷却**：任何依赖第三方 API 的系统都应该考虑多 Key 轮转，而不是把鸡蛋放在一个篮子里。关键是用冷却期防止无意义重试。

2. **累积量 vs 瞬时量分离**：在统计系统中，区分"需要求和的指标"和"需要取最新值的指标"。这在监控、计费场景中尤为重要。

3. **语义感知的流式切割**：不要机械地按字节数/时间间隔切割流式输出。理解输出内容的结构（段落、代码块），在语义边界上切割，用户体验会好一个量级。

4. **先刷后执行（Flush-Before-Execute）**：在执行副作用（如工具调用）之前，先把已积累的状态刷出去。这个模式能避免大量的状态交错问题。

5. **自动降级链**：思考级别降级（xhigh → high → medium → ...）是一个优雅的渐进退化策略。不要在第一个方案失败时就直接报错，设计一条"退路链"。

6. **去重表防重复发送**：当系统中存在多个可能产出相同内容的路径时（工具主动发送 vs 回复正文），用一个简单的去重表就能避免用户收到重复信息。
