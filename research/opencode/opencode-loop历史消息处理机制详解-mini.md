# OpenCode Loop 历史消息处理机制详解（Mini版）

## 一、核心问题

在开发一个 AI 编程助手时，我们需要解决以下核心问题：

1. **如何让 AI 持续工作？** - 用户说一句话，AI 可能需要做几十步操作
2. **如何管理长对话？** - 对话越来越长，但 LLM 有上下文窗口限制
3. **如何安全地执行代码？** - AI 可能删除文件、执行危险命令
4. **如何处理工具调用？** - AI 需要读文件、写代码、执行命令

OpenCode 的设计围绕这些问题展开，本文重点讲解**消息处理和压缩**的设计思路。

---

## 二、消息数据模型设计

### 2.1 为什么需要 Part（片段）设计？

**单一消息可能包含多种内容**：
- 用户说了一段话
- 附带了 5 个文件
- 还引用了另一个 Agent
- 可能还有系统提示词注入

如果用单一字符串存储，无法增量更新，也无法精确控制每种内容。

**OpenCode 的解决方案**：用 Part（片段）解耦不同类型的内容。

```typescript
// packages/opencode/src/session/message-v2.ts:330-348
export const Part = z.discriminatedUnion("type", [
  TextPart,           // 文本内容 - 用户/助手的普通文字
  SubtaskPart,        // 子任务调用 - 调用其他 Agent
  ReasoningPart,      // 推理过程 - Claude 的思考过程
  FilePart,           // 文件附件 - 图片、二进制等
  ToolPart,           // 工具调用 - read/write/execute 等
  StepStartPart,      // 步骤开始标记
  StepFinishPart,     // 步骤完成标记
  SnapshotPart,       // 文件快照
  PatchPart,          // 文件变更 - 记录了哪些文件被修改
  AgentPart,          // Agent 切换 - @mention 其他 Agent
  RetryPart,          // 重试信息
  CompactionPart,     // 压缩标记 - 标记压缩点
])
```

### 2.2 消息存储结构

```
Storage:
├── ["session", projectID, sessionID] → Session.Info
├── ["message", sessionID, messageID] → MessageV2.Info (消息元数据)
└── ["part", messageID, partID] → MessageV2.Part (片段独立存储)

为什么这样设计？
- Part 可能频繁更新（流式输出），单独存储避免整个消息重写
- 可以只加载需要的部分（比如只加载文本，不加载大文件）
- 支持增量更新，减少 IO
```

### 2.3 User 和 Assistant 消息的区别

```typescript
// packages/opencode/src/session/message-v2.ts:305-328 (User)
export const User = Base.extend({
  role: z.literal("user"),
  time: z.object({ created: z.number() }),
  summary: z.object({           // 用于会话摘要
    title: z.string().optional(),
    body: z.string().optional(),
    diffs: Snapshot.FileDiff.array(),
  }).optional(),
  agent: z.string(),            // 使用的 Agent
  model: z.object({             // 使用的模型
    providerID: z.string(),
    modelID: z.string(),
  }),
  system: z.string().optional(), // 自定义系统提示词
  tools: z.record(...).optional(), // 工具开关
})

// packages/opencode/src/session/message-v2.ts:350-392 (Assistant)
export const Assistant = Base.extend({
  role: z.literal("assistant"),
  time: z.object({
    created: z.number(),
    completed: z.number().optional(),
  }),
  error: APIError.Schema.optional(),
  parentID: z.string(),         // 父消息 ID（关联 User 消息）
  modelID: z.string(),
  providerID: z.string(),
  agent: z.string(),
  cost: z.number(),             // 成本统计
  tokens: z.object({            // Token 统计
    input: z.number(),
    output: z.number(),
    reasoning: z.number(),
    cache: z.object({ read: z.number(), write: z.number() }),
  }),
  finish: z.string().optional(), // 完成原因：stop/tool-calls/error
  summary: z.boolean().optional(), // 是否已压缩摘要
})
```

**设计思想**：
- User 消息存储"输入"，Assistant 消息存储"输出"
- `parentID` 建立 User → Assistant 的关联
- `summary` 标记这个回合是否已压缩

**优点**：
- 数据结构清晰，职责分离
- 便于统计成本和 Token
- 便于追踪文件变更（PatchPart）

**缺点**：
- 存储结构复杂，需要多次查询
- Part 分散存储增加 IO 开销

---

## 三、主循环：消息是如何被处理的

### 3.1 循环结构概览

```typescript
// packages/opencode/src/session/prompt.ts:259-640
export const loop = fn(Identifier.schema("session"), async (sessionID) => {
  const abort = start(sessionID)
  if (!abort) {
    // 如果已经在运行，加入等待队列
    return new Promise((resolve, reject) => {
      callbacks.push({ resolve, reject })
    })
  }

  while (true) {
    // 1. 加载历史消息
    let msgs = await MessageV2.filterCompacted(MessageV2.stream(sessionID))

    // 2. 查找关键消息
    let lastUser: MessageV2.User | undefined
    let lastAssistant: MessageV2.Assistant | undefined
    let lastFinished: MessageV2.Assistant | undefined

    // 3. 检查是否需要退出
    if (lastAssistant?.finish && !["tool-calls", "unknown"].includes(lastAssistant.finish)) {
      break  // 任务完成，退出循环
    }

    // 4. 处理待办任务（Subtask / Compaction）
    const task = tasks.pop()
    if (task?.type === "subtask") { /* 执行子任务 */ continue }
    if (task?.type === "compaction") { /* 执行压缩 */ continue }

    // 5. 检查是否需要压缩
    if (await SessionCompaction.isOverflow({ tokens: lastFinished.tokens, model })) {
      await SessionCompaction.create({ ... })
      continue
    }

    // 6. 正常处理：构建 Prompt + 调用 LLM
    const processor = SessionProcessor.create({ ... })
    const result = await processor.process({ ... })

    // 7. 处理结果
    if (result === "stop") break
    if (result === "compact") { /* 触发压缩 */ }
  }
  SessionCompaction.prune({ sessionID })  // 循环结束后修剪
})
```

### 3.2 消息加载与过滤

```typescript
// packages/opencode/src/session/message-v2.ts:609-627
export const stream = fn(Identifier.schema("session"), async function* (sessionID) {
  const list = await Array.fromAsync(await Storage.list(["message", sessionID]))
  // 倒序遍历，从最新到最旧
  for (let i = list.length - 1; i >= 0; i--) {
    yield await get({ sessionID, messageID: list[i][2] })
  }
})

// 过滤已压缩的消息，只保留需要的上下文
// packages/opencode/src/session/message-v2.ts:642-657
export async function filterCompacted(stream: AsyncIterable<MessageV2.WithParts>) {
  const result = [] as MessageV2.WithParts[]
  const completed = new Set<string>()

  for await (const msg of stream) {
    result.push(msg)
    // 遇到 compaction 标记且已完成的会话，停止
    if (msg.info.role === "user" &&
        completed.has(msg.info.id) &&
        msg.parts.some(p => p.type === "compaction")) {
      break
    }
    // 标记已摘要的助手消息
    if (msg.info.role === "assistant" && msg.info.summary && msg.info.finish) {
      completed.add(msg.info.parentID)
    }
  }
  result.reverse()  // 转成正序
  return result
}
```

**设计思想**：
- 倒序读取：从最新消息开始，因为最近的对话最重要
- 过滤已压缩的消息：避免重复处理，节省 Token
- `completed` 集合：标记哪些会话已经被压缩摘要

**为什么倒序读取？**
1. 最近的对话最重要，先处理可以快速找到 `lastUser`、`lastAssistant`
2. 方便判断是否需要退出循环（看最新消息的状态）
3. 压缩时只需要处理旧的消息

**优点**：
- 快速定位最新状态
- 减少不必要的历史加载

**缺点**：
- 倒序转正序有额外开销
- 复杂的消息过滤逻辑

---

## 四、消息格式转换：如何告诉 LLM

LLM 不认识 OpenCode 的内部格式，需要转换。

### 4.1 转换函数

```typescript
// packages/opencode/src/session/message-v2.ts:436-607
export function toModelMessages(input: WithParts[], model: Provider.Model): ModelMessage[] {
  const result: UIMessage[] = []
  const toolNames = new Set<string>()

  for (const msg of input) {
    if (msg.info.role === "user") {
      // 用户消息：提取文本和文件
      const userMessage: UIMessage = { id: msg.info.id, role: "user", parts: [] }
      for (const part of msg.parts) {
        if (part.type === "text" && !part.ignored)
          userMessage.parts.push({ type: "text", text: part.text })
        if (part.type === "file" && part.mime !== "text/plain")
          userMessage.parts.push({ type: "file", url: part.url, mediaType: part.mime })
      }
      result.push(userMessage)
    }

    if (msg.info.role === "assistant") {
      // 助手消息：提取文本、工具调用结果、推理过程
      const assistantMessage: UIMessage = { id: msg.info.id, role: "assistant", parts: [] }
      for (const part of msg.parts) {
        if (part.type === "text")
          assistantMessage.parts.push({ type: "text", text: part.text })
        if (part.type === "tool" && part.state.status === "completed") {
          // 关键：如果已压缩，替换为占位符
          const outputText = part.state.time.compacted
            ? "[Old tool result content cleared]"
            : part.state.output
          assistantMessage.parts.push({
            type: (`tool-${part.tool}`) as `tool-${string}`,
            state: "output-available",
            toolCallId: part.callID,
            input: part.state.input,
            output: outputText,  // 这里是关键
          })
        }
        if (part.type === "reasoning")
          assistantMessage.parts.push({ type: "reasoning", text: part.text })
      }
      result.push(assistantMessage)
    }
  }

  // 最后调用 AI SDK 的转换函数
  return convertToModelMessages(result, { tools })
}
```

### 4.2 系统提示词构建

```typescript
// packages/opencode/src/session/llm.ts:69-82
const system = []
system.push([
  // 优先级：Agent 提示词 > Provider 提示词
  ...(input.agent.prompt ? [input.agent.prompt] : SystemPrompt.provider(input.model)),
  // 自定义提示词
  ...input.system,
  // 用户消息中的系统提示词
  ...(input.user.system ? [input.user.system] : []),
].join("\n"))
```

**设计思想**：
- 分层叠加：Agent → Provider → 自定义 → 用户
- 不同模型有不同提示词（Claude/GPT/Gemini）
- 支持运行时注入（Plugin）

**优点**：
- 灵活可控，支持多种模型
- 插件可扩展

**缺点**：
- 提示词可能过长
- 需要维护多个提示词模板

---

## 五、工具调用与结果处理

### 5.1 工具执行流程

```typescript
// packages/opencode/src/session/processor.ts:126-194
case "tool-call": {
  const match = toolcalls[value.toolCallId]
  if (match) {
    // 1. 更新为 running 状态
    await Session.updatePart({
      ...match,
      tool: value.toolName,
      state: {
        status: "running",
        input: value.input,
        time: { start: Date.now() },
      },
    })

    // 2. 死循环检测
    const parts = await MessageV2.parts(input.assistantMessage.id)
    const lastThree = parts.slice(-3)  // 最近 3 次
    if (allSameTool(lastThree, value)) {
      // 3 次相同工具调用，询问用户
      await PermissionNext.ask({ ... })
    }
  }
}

case "tool-result": {
  const match = toolcalls[value.toolCallId]
  if (match && match.state.status === "running") {
    // 3. 写入结果
    await Session.updatePart({
      ...match,
      state: {
        status: "completed",
        input: value.input ?? match.state.input,
        output: value.output.output,
        title: value.output.title,
        time: { start: match.state.time.start, end: Date.now() },
        attachments: value.output.attachments,
      },
    })
  }
}
```

### 5.2 死循环检测（Doom Loop）

```typescript
// packages/opencode/src/session/processor.ts:144-168
const lastThree = parts.slice(-DOOM_LOOP_THRESHOLD)  // DOOM_LOOP_THRESHOLD = 3

if (
  lastThree.length === DOOM_LOOP_THRESHOLD &&
  lastThree.every(p =>
    p.type === "tool" &&
    p.tool === value.toolName &&
    p.state.status !== "pending" &&
    JSON.stringify(p.state.input) === JSON.stringify(value.input)
  )
) {
  // 三次完全相同的工具调用，询问用户
  await PermissionNext.ask({
    permission: "doom_loop",
    patterns: [value.toolName],
    metadata: { tool: value.toolName, input: value.input },
  })
}
```

**设计思想**：
- AI 可能陷入重复调用同一工具的陷阱
- 检测最近 3 次调用是否完全相同
- 发现死循环时询问用户是否继续

**优点**：
- 防止 AI 卡死在无限循环中
- 用户可以介入干预

**缺点**：
- 阈值设为 3 可能过于敏感
- 有些场景确实需要重复调用（如轮询）

---

## 六、上下文压缩机制

这是 OpenCode 处理长对话的核心机制。

### 6.1 两种压缩策略

| 策略 | 触发条件 | 原理 |
|------|---------|------|
| **Prune（修剪）** | 每次循环结束 | 标记旧工具调用的内容为已清理 |
| **Compaction（压缩）** | Token 溢出时 | 调用 LLM 生成摘要，标记旧消息 |

### 6.2 Prune：旧工具调用修剪

```typescript
// packages/opencode/src/session/compaction.ts:49-90
export async function prune(input: { sessionID: string }) {
  const msgs = await Session.messages({ sessionID: input.sessionID })
  let total = 0
  let pruned = 0
  const PRUNE_PROTECT = 40_000  // 保留 40k tokens
  const PRUNE_MINIMUM = 20_000  // 至少修剪 20k tokens

  loop: for (let msgIndex = msgs.length - 1; msgIndex >= 0; msgIndex--) {
    const msg = msgs[msgIndex]
    // 找到第二个用户消息后才开始检查（保留最近一轮）
    if (msg.info.role === "user") turns++
    if (turns < 2) continue
    if (msg.info.role === "assistant" && msg.info.summary) break loop

    for (let partIndex = msg.parts.length - 1; partIndex >= 0; partIndex--) {
      const part = msg.parts[partIndex]
      if (part.type === "tool" && part.state.status === "completed") {
        // 跳过受保护的工具（如 skill）
        if (PRUNE_PROTECTED_TOOLS.includes(part.tool)) continue
        // 跳过已压缩的
        if (part.state.time.compacted) break loop

        const estimate = Token.estimate(part.state.output)
        total += estimate
        if (total > PRUNE_PROTECT) {
          pruned += estimate
          // 标记为已压缩
          part.state.time.compacted = Date.now()
          toPrune.push(part)
        }
      }
    }
  }

  if (pruned > PRUNE_MINIMUM) {
    for (const part of toPrune) {
      part.state.time.compacted = Date.now()
      await Session.updatePart(part)
    }
  }
}
```

**设计思想**：
- 倒序遍历，找到 40k tokens 的工具调用
- 超过的部分标记 `compacted = Date.now()`
- 下次转换给 LLM 时，替换为 `[Old tool result content cleared]`

**优点**：
- 实现简单，只标记不删除
- 保留上下文结构，只清理内容
- 只保留最近 40k tokens 的详细工具调用

**缺点**：
- 可能丢失重要细节
- 40k 阈值对某些模型可能不够

### 6.3 Compaction：生成摘要

```typescript
// packages/opencode/src/session/compaction.ts:92-193
export async function process(input: {
  parentID: string
  messages: MessageV2.WithParts[]
  sessionID: string
  abort: AbortSignal
  auto: boolean
}) {
  const userMessage = input.messages.findLast((m) => m.info.id === input.parentID)!

  // 1. 创建一个特殊的 Assistant 消息
  const msg = await Session.updateMessage({
    id: Identifier.ascending("message"),
    role: "assistant",
    parentID: input.parentID,
    sessionID: input.sessionID,
    mode: "compaction",
    agent: "compaction",
    summary: true,  // 标记为摘要消息
    // ...
  })

  // 2. 调用 LLM 生成摘要
  const processor = SessionProcessor.create({ ... })
  const defaultPrompt =
    "Provide a detailed prompt for continuing our conversation above. " +
    "Focus on information that would be helpful for continuing the conversation, " +
    "including what we did, what we're doing, which files we're working on, " +
    "and what we're going to do next."

  const result = await processor.process({
    user: userMessage,
    agent: await Agent.get("compaction"),
    messages: [
      ...MessageV2.toModelMessages(input.messages, model),
      {
        role: "user",
        content: [{ type: "text", text: defaultPrompt }],
      },
    ],
    model,
  })

  // 3. 如果 auto=true，创建继续消息
  if (result === "continue" && input.auto) {
    await Session.updatePart({
      type: "text",
      synthetic: true,
      text: "Continue if you have next steps",
    })
  }
}
```

### 6.4 溢出检测

```typescript
// packages/opencode/src/session/compaction.ts:30-39
export async function isOverflow(input: { tokens: MessageV2.Assistant["tokens"]; model: Provider.Model }) {
  const config = await Config.get()
  if (config.compaction?.auto === false) return false

  const context = input.model.limit.context
  if (context === 0) return false

  const count = input.tokens.input + input.tokens.cache.read + input.tokens.output
  const output = Math.min(input.model.limit.output, OUTPUT_TOKEN_MAX) || OUTPUT_TOKEN_MAX
  const usable = input.model.limit.input || context - output

  return count > usable
}
```

**设计思想**：
- 判断当前已用 tokens 是否接近模型限制
- 如果接近，创建压缩任务（CompactionPart）
- 下次循环时执行压缩

### 6.5 压缩效果示意

```
压缩前（可能超过 200K tokens）：
[用户消息1][助手回复][工具结果][用户消息2][助手回复][工具结果][用户消息3]...[当前消息]

压缩后：
[摘要消息 - LLM 生成]  ← 标记 msg.info.summary = true
[用户消息3][助手回复][工具结果]...[当前消息]

历史消息处理：
- 过滤已压缩的消息时，遇到 CompactionPart 停止
- tool 输出被替换为 "[Old tool result content cleared]"
```

**优点**：
- 彻底减少 Token 消耗
- 保留关键上下文
- 支持自动和手动两种模式

**缺点**：
- 摘要质量依赖 LLM
- 可能丢失细节
- 有额外 LLM 调用成本

---

## 七、完整数据流图

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         用户输入                                         │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                    createUserMessage()                                   │
│  - 创建 MessageV2.User 结构                                              │
│  - 处理文件附件（转 base64）                                             │
│  - 保存到 Storage                                                        │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                    loop() [while true]                                   │
│                                                                         │
│  1. 加载消息: MessageV2.stream(sessionID)                                │
│  2. 过滤: MessageV2.filterCompacted()                                    │
│  3. 检查退出: lastAssistant.finish !== "tool-calls"                      │
│  4. 检查待办: Subtask / Compaction                                        │
│  5. 检查溢出: SessionCompaction.isOverflow()                             │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                      构建 Prompt                                         │
│                                                                         │
│  系统提示词:                                                             │
│  - Agent 提示词 / Provider 提示词                                        │
│  - 自定义提示词                                                          │
│  - 环境信息 (cwd, git, platform)                                         │
│                                                                         │
│  消息历史:                                                               │
│  - MessageV2.toModelMessages()                                           │
│  - 已压缩的工具输出 → "[Old tool result content cleared]"                │
│                                                                         │
│  工具列表:                                                               │
│  - 根据 Agent 权限过滤                                                   │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                    streamText() → LLM                                   │
│                                                                         │
│  发送格式:                                                               │
│  - role: system [提示词]                                                 │
│  - role: user [用户消息历史]                                             │
│  - role: assistant [助手消息历史]                                        │
│  - tools: [...] [可用工具定义]                                           │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                    SessionProcessor.process()                            │
│                                                                         │
│  处理流式事件:                                                           │
│  - text-start/delta/end → TextPart                                      │
│  - tool-call → ToolPart (pending → running)                             │
│  - tool-result → ToolPart (completed)                                   │
│  - reasoning-start/delta/end → ReasoningPart                            │
│  - finish-step → 统计 tokens，更新状态                                   │
│                                                                         │
│  死循环检测:                                                             │
│  - 检查最近 3 次工具调用是否相同                                         │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                         工具执行                                         │
│                                                                         │
│  1. ToolRegistry.tools() → 执行实际逻辑                                  │
│  2. 权限检查: PermissionNext.ask()                                       │
│  3. 结果处理: output, title, metadata                                    │
│  4. 插件钩子: tool.execute.before/after                                  │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                    返回结果给 LLM                                        │
│                                                                         │
│  格式:                                                                   │
│  - type: tool-result                                                    │
│  - output: 工具输出文本                                                  │
│  - attachments: 文件附件                                                 │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                    循环继续或终止                                         │
│                                                                         │
│  - continue: 回到循环开始                                                │
│  - compact: 触发上下文压缩                                               │
│  - stop: 返回最终结果                                                   │
│                                                                         │
│  循环结束后:                                                             │
│  - SessionCompaction.prune() 修剪旧工具调用                              │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 八、关键设计决策与权衡

| 决策 | 选择 | 原因 | 优点 | 缺点 |
|------|------|------|------|------|
| 消息存储 | Part 分离存储 | 流式更新需要 | 增量更新、减少 IO | 复杂度高 |
| 消息遍历 | 倒序读取 | 最近的更重要 | 快速定位最新状态 | 额外反转开销 |
| 消息过滤 | 过滤已压缩 | 避免重复处理 | 节省 Token | 可能遗漏 |
| 工具调用 | 状态机管理 | 需要追踪状态 | 结构清晰 | 代码复杂 |
| 压缩策略 | Prune + Compaction | 成本/效果平衡 | 渐进式压缩 | 两套逻辑 |
| 死循环检测 | 3 次相同调用 | 简单有效 | 防止卡死 | 可能误判 |

---

## 九、关键代码文件清单

| 文件 | 行号 | 职责 |
|------|------|------|
| `prompt.ts` | 259-640 | 主循环 loop() |
| `prompt.ts` | 827-1196 | 用户消息创建 createUserMessage() |
| `prompt.ts` | 649-825 | 工具解析 resolveTools() |
| `message-v2.ts` | 609-627 | 消息流式读取 stream() |
| `message-v2.ts` | 436-607 | 消息格式转换 toModelMessages() |
| `message-v2.ts` | 642-657 | 过滤已压缩消息 filterCompacted() |
| `processor.ts` | 45-406 | LLM 响应处理 process() |
| `compaction.ts` | 49-90 | 旧工具调用修剪 prune() |
| `compaction.ts` | 92-193 | 摘要生成 process() |
| `llm.ts` | 48-275 | LLM 调用 stream() |

---

## 十、总结

OpenCode 的消息处理设计围绕几个核心问题：

1. **如何组织消息？** - 用 Part 分离不同类型的内容，支持增量更新
2. **如何加载消息？** - 倒序读取 + 过滤已压缩，快速定位最新状态
3. **如何告诉 LLM？** - 分层提示词 + 格式转换，支持多模型
4. **如何处理工具？** - 状态机追踪 + 死循环检测
5. **如何管理长对话？** - Prune 标记 + Compaction 摘要，渐进式压缩

这套设计的核心思想是：

- **分层**：分离关注点（消息、工具、权限、压缩）
- **渐进**：默认安全，按需开放（权限）
- **可观测**：所有状态可追踪（tokens、cost、error）
- **容错**：死循环检测 + 错误重试

---

*文档生成时间：2026-01-29*
*基于 vendors/opencode 源码分析*
