# OpenCode Task Loop 与上下文管理深度解析

本文深入分析 OpenCode 的任务循环机制以及上下文管理的实现细节，包括系统提示词组装、消息管理、工具执行、上下文压缩等核心机制。

---

## 一、整体架构概览

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         Session Prompt (主入口)                          │
│                    packages/opencode/src/session/prompt.ts               │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                         主循环 (loop 函数)                                │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │  while (true) {                                                  │   │
│  │    1. 获取消息历史 (MessageV2.filterCompacted)                    │   │
│  │    2. 检查完成条件                                               │   │
│  │    3. 处理子任务 (subtask)                                        │   │
│  │    4. 处理上下文压缩 (compaction)                                 │   │
│  │    5. 正常处理流程 → SessionProcessor.process                     │   │
│  │  }                                                               │   │
│  └─────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                      SessionProcessor (流处理器)                         │
│                    packages/opencode/src/session/processor.ts            │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │  处理 LLM 流式响应:                                               │   │
│  │  - text-start/delta/end (文本输出)                                │   │
│  │  - reasoning-start/delta/end (推理过程)                           │   │
│  │  - tool-input-start/call/result/error (工具调用)                  │   │
│  │  - start-step/finish-step (步骤跟踪)                              │   │
│  └─────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 二、主循环详解 (prompt.ts:259-640)

### 2.1 循环入口与状态管理

```typescript
export const loop = fn(Identifier.schema("session"), async (sessionID) => {
  const abort = start(sessionID)  // 创建 AbortController
  if (!abort) {
    // 如果已经在运行中，加入等待队列
    return new Promise<MessageV2.WithParts>((resolve, reject) => {
      const callbacks = state()[sessionID].callbacks
      callbacks.push({ resolve, reject })
    })
  }

  using _ = defer(() => cancel(sessionID))  // 确保清理

  let step = 0
  const session = await Session.get(sessionID)
  while (true) {
    SessionStatus.set(sessionID, { type: "busy" })
    // ... 循环体
  }
})
```

**关键设计：**
- 使用 `AbortController` 支持用户随时中断
- 单会话单执行，新请求加入队列等待
- 使用 `defer` 确保资源清理

### 2.2 消息历史获取与解析

```typescript
let msgs = await MessageV2.filterCompacted(MessageV2.stream(sessionID))

let lastUser: MessageV2.User | undefined
let lastAssistant: MessageV2.Assistant | undefined
let lastFinished: MessageV2.Assistant | undefined
let tasks: (MessageV2.CompactionPart | MessageV2.SubtaskPart)[] = []

// 反向遍历消息，找到关键节点
for (let i = msgs.length - 1; i >= 0; i--) {
  const msg = msgs[i]
  if (!lastUser && msg.info.role === "user") lastUser = msg.info as MessageV2.User
  if (!lastAssistant && msg.info.role === "assistant") lastAssistant = msg.info as MessageV2.Assistant
  if (!lastFinished && msg.info.role === "assistant" && msg.info.finish)
    lastFinished = msg.info as MessageV2.Assistant
  // ...
}
```

**消息类型定义** (message-v2.ts):
- `User`: 用户消息，包含 agent、model、parts 等
- `Assistant`: AI 回复，包含 cost、tokens、finish 状态等
- `Part` 类型: text、tool、reasoning、file、compaction、subtask 等

### 2.3 循环结束条件检测

```typescript
if (
  lastAssistant?.finish &&
  !["tool-calls", "unknown"].includes(lastAssistant.finish) &&
  lastUser.id < lastAssistant.id
) {
  log.info("exiting loop", { sessionID })
  break
}
```

**结束条件：**
- AI 有明确的 finish 原因
- 不是 "tool-calls"（说明是自然结束，不是等待工具执行）
- AI 消息 ID 大于用户消息 ID（确保已经响应了最新的用户输入）

### 2.4 四种处理分支

```
┌────────────────────────────────────────────────────────────┐
│                     主循环处理分支                           │
├────────────────────────────────────────────────────────────┤
│  1. 子任务 (subtask)                                        │
│     - 当用户通过 @agent 调用子代理时触发                      │
│     - 创建独立的 assistant message                          │
│     - 使用 TaskTool 执行子任务                              │
│     - 执行完成后可选择性地添加合成用户消息                     │
├────────────────────────────────────────────────────────────┤
│  2. 上下文压缩 (compaction)                                  │
│     - 当 token 数量超过阈值时触发                            │
│     - 创建 compaction 代理进行对话总结                       │
│     - 用总结替换旧消息，释放上下文空间                        │
├────────────────────────────────────────────────────────────┤
│  3. 上下文溢出检测 (overflow)                                │
│     - 检查 lastFinished.tokens 是否超过模型上限              │
│     - 如果溢出，创建 compaction task                         │
│     - 在下次循环处理压缩                                     │
├────────────────────────────────────────────────────────────┤
│  4. 正常处理流程                                             │
│     - 调用 SessionProcessor.process                          │
│     - 与 LLM 进行流式交互                                    │
│     - 处理工具调用和响应                                     │
└────────────────────────────────────────────────────────────┘
```

---

## 三、上下文组装流程

### 3.1 系统提示词组装

系统提示词由三部分组成 (llm.ts:69-99):

```typescript
const system = []
system.push(
  [
    // 1. 代理特定的提示词 或 提供商特定的提示词
    ...(input.agent.prompt ? [input.agent.prompt] : isCodex ? [] : SystemPrompt.provider(input.model)),
    // 2. 传入的自定义系统提示
    ...input.system,
    // 3. 用户消息中的系统提示
    ...(input.user.system ? [input.user.system] : []),
  ].filter((x) => x).join("\n")
)

// 触发插件钩子，允许修改系统提示
await Plugin.trigger(
  "experimental.chat.system.transform",
  { sessionID: input.sessionID, model: input.model },
  { system }
)
```

**提供商特定提示词** (system.ts:18-25):

| 模型 | 提示词文件 | 特点 |
|------|-----------|------|
| GPT-5/Codex | `codex_header.txt` | 使用 instructions 参数传递 |
| GPT-4/o1/o3 | `beast.txt` | 自主代理风格，强调独立思考 |
| Gemini | `gemini.txt` | Google 模型特定优化 |
| Claude | `anthropic.txt` | 包含任务管理、工具使用指南 |
| 其他 | `qwen.txt` | 无 Todo 功能的简化版本 |

### 3.2 环境信息注入

```typescript
export async function environment(model: Provider.Model) {
  return [
    `You are powered by the model named ${model.api.id}. The exact model ID is ${model.providerID}/${model.api.id}`,
    `Here is some useful information about the environment you are running in:`,
    `<env>`,
    `  Working directory: ${Instance.directory}`,
    `  Is directory a git repo: ${project.vcs === "git" ? "yes" : "no"}`,
    `  Platform: ${process.platform}`,
    `  Today's date: ${new Date().toDateString()}`,
    `</env>`,
    // ...
  ].join("\n")
}
```

### 3.3 消息历史转换

**toModelMessages** (message-v2.ts:436-607):

```typescript
export function toModelMessages(input: WithParts[], model: Provider.Model): ModelMessage[] {
  const result: UIMessage[] = []

  for (const msg of input) {
    if (msg.info.role === "user") {
      // 处理用户消息：
      // - text part → text message
      // - file part → file message (如果是二进制文件)
      // - compaction → "What did we do so far?"
      // - subtask → "The following tool was executed by the user"
    }

    if (msg.info.role === "assistant") {
      // 处理 AI 消息：
      // - text → text part
      // - tool → tool-call / tool-result
      // - reasoning → reasoning part
    }
  }

  // 转换为 ModelMessage 格式
  return convertToModelMessages(result, { tools })
}
```

**关键转换规则：**
- 用户消息中的 `compaction` part 转换为文本 "What did we do so far?"
- 用户消息中的 `subtask` part 转换为工具执行提示
- 工具调用状态映射：completed → output-available, error → output-error
- 未完成的中断工具调用标记为 "[Tool execution was interrupted]"

### 3.4 提醒插入机制

```typescript
// Plan 模式提醒
if (input.agent.name === "plan") {
  userMessage.parts.push({
    type: "text",
    text: PROMPT_PLAN,  // "You are in plan mode..."
    synthetic: true,
  })
}

// Plan → Build 切换提醒
const wasPlan = input.messages.some((msg) => msg.info.role === "assistant" && msg.info.agent === "plan")
if (wasPlan && input.agent.name === "build") {
  userMessage.parts.push({
    type: "text",
    text: BUILD_SWITCH,  // "You just finished plan mode..."
    synthetic: true,
  })
}

// 后续步骤用户消息包装
if (step > 1 && lastFinished) {
  part.text = [
    "<system-reminder>",
    "The user sent the following message:",
    part.text,
    "",
    "Please address this message and continue with your tasks.",
    "</system-reminder>",
  ].join("\n")
}
```

---

## 四、流式响应处理 (processor.ts)

### 4.1 处理器架构

```typescript
export function create(input: {
  assistantMessage: MessageV2.Assistant
  sessionID: string
  model: Provider.Model
  abort: AbortSignal
}) {
  const toolcalls: Record<string, MessageV2.ToolPart> = {}
  let snapshot: string | undefined  // 文件快照
  let blocked = false               // 是否被权限拒绝
  let attempt = 0                   // 重试次数
  let needsCompaction = false       // 是否需要压缩

  return {
    async process(streamInput: LLM.StreamInput) {
      while (true) {
        try {
          const stream = await LLM.stream(streamInput)
          for await (const value of stream.fullStream) {
            // 处理各种事件类型
          }
        } catch (e) {
          // 错误处理和重试逻辑
        }
      }
    }
  }
}
```

### 4.2 事件类型处理

| 事件类型 | 处理逻辑 | 存储位置 |
|---------|---------|---------|
| `start` | 设置 session 状态为 busy | SessionStatus |
| `text-start` | 创建新的 TextPart | parts 数组 |
| `text-delta` | 追加文本，实时更新 UI | Session.updatePart |
| `text-end` | 触发 text.complete 钩子 | Plugin.trigger |
| `reasoning-start` | 创建 ReasoningPart | parts 数组 |
| `reasoning-delta` | 追加推理内容 | Session.updatePart |
| `reasoning-end` | 完成推理 | Session.updatePart |
| `tool-input-start` | 创建 ToolPart (pending) | toolcalls 映射 |
| `tool-call` | 更新为 running，检查 doom loop | Session.updatePart |
| `tool-result` | 更新为 completed | Session.updatePart |
| `tool-error` | 更新为 error，检查是否 blocked | Session.updatePart |
| `start-step` | 创建 snapshot，记录 StepStartPart | Snapshot.track |
| `finish-step` | 统计用量，创建 StepFinishPart | Session.updatePart |

### 4.3 Doom Loop 防护

```typescript
const lastThree = parts.slice(-DOOM_LOOP_THRESHOLD)

if (
  lastThree.length === DOOM_LOOP_THRESHOLD &&
  lastThree.every(
    (p) =>
      p.type === "tool" &&
      p.tool === value.toolName &&
      p.state.status !== "pending" &&
      JSON.stringify(p.state.input) === JSON.stringify(value.input),
  )
) {
  // 连续 3 次调用相同工具且参数相同
  await PermissionNext.ask({
    permission: "doom_loop",
    patterns: [value.toolName],
    // ...
  })
}
```

### 4.4 步骤跟踪与文件变更

```typescript
case "start-step":
  snapshot = await Snapshot.track()  // 记录文件状态
  await Session.updatePart({
    type: "step-start",
    snapshot,
    // ...
  })
  break

case "finish-step":
  const usage = Session.getUsage({ model, usage: value.usage })
  await Session.updatePart({
    type: "step-finish",
    reason: value.finishReason,
    snapshot: await Snapshot.track(),  // 记录结束状态
    tokens: usage.tokens,
    cost: usage.cost,
    // ...
  })

  // 计算文件变更
  if (snapshot) {
    const patch = await Snapshot.patch(snapshot)
    if (patch.files.length) {
      await Session.updatePart({
        type: "patch",
        hash: patch.hash,
        files: patch.files,
      })
    }
  }

  // 检查是否需要上下文压缩
  if (await SessionCompaction.isOverflow({ tokens: usage.tokens, model })) {
    needsCompaction = true
  }
  break
```

---

## 五、工具执行与上下文

### 5.1 工具上下文 (Tool.Context)

```typescript
export type Context = {
  sessionID: string        // 会话 ID
  messageID: string        // 当前消息 ID
  callID: string          // 工具调用唯一 ID
  agent: string           // 当前代理名称
  abort: AbortSignal      // 取消信号
  messages: WithParts[]   // 完整对话历史
  extra: Record<string, any>  // 额外数据

  // 更新工具状态
  metadata: (input: { title?: string; metadata?: any }) => Promise<void>

  // 权限检查
  ask: (request: PermissionNext.Request) => Promise<void>
}
```

### 5.2 工具注册与权限过滤

```typescript
async function resolveTools(input: {
  agent: Agent.Info
  model: Provider.Model
  session: Session.Info
  // ...
}) {
  const tools: Record<string, AITool> = {}

  // 1. 从 ToolRegistry 获取工具
  for (const item of await ToolRegistry.tools(
    { modelID: input.model.api.id, providerID: input.model.providerID },
    input.agent,
  )) {
    // 2. 转换 schema 格式
    const schema = ProviderTransform.schema(input.model, z.toJSONSchema(item.parameters))

    tools[item.id] = tool({
      id: item.id,
      description: item.description,
      inputSchema: jsonSchema(schema),
      async execute(args, options) {
        // 3. 创建上下文
        const ctx = context(args, options)

        // 4. 触发插件钩子
        await Plugin.trigger("tool.execute.before", { tool: item.id, ... }, { args })

        // 5. 执行工具
        const result = await item.execute(args, ctx)

        // 6. 触发 after 钩子
        await Plugin.trigger("tool.execute.after", { tool: item.id, ... }, result)

        return result
      },
    })
  }

  // 7. 添加 MCP 工具
  for (const [key, item] of Object.entries(await MCP.tools())) {
    // ...
  }

  return tools
}
```

### 5.3 工具结果格式

```typescript
// 成功结果
{
  title: string,           // 简短描述（5-10字）
  output: string,          // 工具输出内容
  metadata: any,           // 额外元数据
  attachments?: FilePart[], // 附件（图片等）
}

// 错误处理
if (error instanceof PermissionNext.RejectedError ||
    error instanceof Question.RejectedError) {
  blocked = shouldBreak  // 用户拒绝，可能终止循环
}
```

---

## 六、上下文压缩机制 (compaction.ts)

### 6.1 溢出检测

```typescript
export async function isOverflow(input: {
  tokens: MessageV2.Assistant["tokens"]
  model: Provider.Model
}) {
  const context = input.model.limit.context
  if (context === 0) return false

  const count = input.tokens.input + input.tokens.cache.read + input.tokens.output
  const output = Math.min(input.model.limit.output, SessionPrompt.OUTPUT_TOKEN_MAX)
  const usable = input.model.limit.input || context - output

  return count > usable  // 超过可用上下文空间
}
```

### 6.2 压缩执行流程

```typescript
export async function process(input: {
  parentID: string
  messages: MessageV2.WithParts[]
  sessionID: string
  abort: AbortSignal
  auto: boolean
}) {
  // 1. 使用专门的 compaction 代理
  const agent = await Agent.get("compaction")

  // 2. 创建压缩消息的 assistant message
  const msg = await Session.updateMessage({
    role: "assistant",
    agent: "compaction",
    summary: true,  // 标记为总结消息
    // ...
  })

  // 3. 调用 LLM 进行总结
  const result = await processor.process({
    messages: [
      ...MessageV2.toModelMessages(input.messages, model),
      {
        role: "user",
        content: "Provide a detailed prompt for continuing our conversation above..."
      }
    ],
    tools: {},  // 压缩时不提供工具
    system: [],
    // ...
  })

  // 4. 如果自动模式，添加继续提示
  if (result === "continue" && input.auto) {
    await Session.updatePart({
      type: "text",
      text: "Continue if you have next steps",
      synthetic: true,
    })
  }
}
```

### 6.3 压缩后消息过滤

```typescript
export async function filterCompacted(stream: AsyncIterable<WithParts>) {
  const result: WithParts[] = []
  const completed = new Set<string>()

  for await (const msg of stream) {
    result.push(msg)

    // 如果用户消息包含 compaction part 且已经处理过，停止
    if (
      msg.info.role === "user" &&
      completed.has(msg.info.id) &&
      msg.parts.some((part) => part.type === "compaction")
    )
      break

    // 标记已完成的 assistant message
    if (msg.info.role === "assistant" && msg.info.summary && msg.info.finish)
      completed.add(msg.info.parentID)
  }

  result.reverse()
  return result
}
```

### 6.4 旧工具结果裁剪 (Prune)

```typescript
export const PRUNE_MINIMUM = 20_000  // 最少裁剪 token 数
export const PRUNE_PROTECT = 40_000  // 保护最近 40k token

export async function prune(input: { sessionID: string }) {
  const msgs = await Session.messages({ sessionID: input.sessionID })
  let total = 0
  let pruned = 0
  const toPrune = []
  let turns = 0

  // 反向遍历，保护最近 2 轮对话和 40k token
  loop: for (let msgIndex = msgs.length - 1; msgIndex >= 0; msgIndex--) {
    const msg = msgs[msgIndex]
    if (msg.info.role === "user") turns++
    if (turns < 2) continue

    for (let partIndex = msg.parts.length - 1; partIndex >= 0; partIndex--) {
      const part = msg.parts[partIndex]
      if (part.type === "tool" && part.state.status === "completed") {
        const estimate = Token.estimate(part.state.output)
        total += estimate

        if (total > PRUNE_PROTECT) {
          pruned += estimate
          toPrune.push(part)
        }
      }
    }
  }

  // 标记为已压缩
  if (pruned > PRUNE_MINIMUM) {
    for (const part of toPrune) {
      part.state.time.compacted = Date.now()
      await Session.updatePart(part)
    }
  }
}
```

**裁剪后的消息显示：** (message-v2.ts:544)
```typescript
const outputText = part.state.time.compacted
  ? "[Old tool result content cleared]"
  : part.state.output
```

---

## 七、代理与权限系统

### 7.1 内置代理类型

```typescript
const result: Record<string, Info> = {
  build: {
    mode: "primary",
    permission: PermissionNext.merge(
      defaults,
      PermissionNext.fromConfig({ question: "allow", plan_enter: "allow" }),
      user,
    ),
  },
  plan: {
    mode: "primary",
    permission: PermissionNext.merge(
      defaults,
      PermissionNext.fromConfig({
        plan_exit: "allow",
        edit: { "*": "deny" }  // Plan 模式禁止编辑
      }),
      user,
    ),
  },
  general: {
    mode: "subagent",
    permission: PermissionNext.fromConfig({ todoread: "deny", todowrite: "deny" }),
  },
  explore: {
    mode: "subagent",
    permission: PermissionNext.fromConfig({
      "*": "deny",
      grep: "allow", glob: "allow", list: "allow", read: "allow",
    }),
  },
  compaction: {
    mode: "primary",
    hidden: true,
    permission: PermissionNext.fromConfig({ "*": "deny" }),  // 无工具权限
  },
  // ... title, summary
}
```

### 7.2 权限规则格式

```typescript
const permissions = [
  // 规则 1：可以读任何文件
  { permission: "read", action: "allow", pattern: "*" },

  // 规则 2：改 .env 文件要问我
  { permission: "edit", action: "ask", pattern: "*.env" },

  // 规则 3：可以改 ts 文件
  { permission: "edit", action: "allow", pattern: "*.ts" },

  // 规则 4：但不能改 node_modules 里的
  { permission: "edit", action: "deny", pattern: "node_modules/*" },
]

// 匹配逻辑：从后往前找第一个匹配的规则
```

---

## 八、存储与状态管理

### 8.1 存储结构

```
Storage (文件系统)
├── session/
│   └── {projectID}/
│       └── {sessionID}.json          # 会话元数据
├── message/
│   └── {sessionID}/
│       └── {messageID}.json          # 消息元数据
├── part/
│   └── {messageID}/
│       └── {partID}.json             # 消息片段
└── session_diff/
    └── {sessionID}.json              # 会话文件变更记录
```

### 8.2 消息持久化

```typescript
// 消息存储
export const updateMessage = fn(MessageV2.Info, async (msg) => {
  await Storage.write(["message", msg.sessionID, msg.id], msg)
  Bus.publish(MessageV2.Event.Updated, { info: msg })
  return msg
})

// 片段存储（支持增量更新）
export const updatePart = fn(UpdatePartInput, async (input) => {
  const part = "delta" in input ? input.part : input
  const delta = "delta" in input ? input.delta : undefined
  await Storage.write(["part", part.messageID, part.id], part)
  Bus.publish(MessageV2.Event.PartUpdated, { part, delta })
  return part
})
```

### 8.3 会话 Fork 支持

```typescript
export const fork = fn(
  z.object({
    sessionID: Identifier.schema("session"),
    messageID: Identifier.schema("message").optional(),
  }),
  async (input) => {
    const session = await createNext({ directory: Instance.directory })
    const msgs = await messages({ sessionID: input.sessionID })
    const idMap = new Map<string, string>()

    for (const msg of msgs) {
      if (input.messageID && msg.info.id >= input.messageID) break

      const newID = Identifier.ascending("message")
      idMap.set(msg.info.id, newID)

      // 克隆消息到新会话
      const cloned = await updateMessage({
        ...msg.info,
        sessionID: session.id,
        id: newID,
        parentID: idMap.get(msg.info.parentID),
      })

      // 克隆所有片段
      for (const part of msg.parts) {
        await updatePart({ ...part, id: Identifier.ascending("part"), messageID: cloned.id, sessionID: session.id })
      }
    }
    return session
  }
)
```

---

## 九、关键设计总结

### 9.1 消息驱动架构

**优点：**
- 状态完全存储在消息中，无外部状态机
- 支持随时 fork、恢复会话
- 完整的操作日志，便于审计

**挑战：**
- 消息数量膨胀，查询性能下降
- 状态推断逻辑复杂

### 9.2 流式处理

**优点：**
- 用户体验好，实时反馈
- 可中断，节省 token
- 支持 reasoning 过程展示

**挑战：**
- 状态管理复杂
- 错误恢复困难

### 9.3 分层上下文管理

| 层级 | 内容 | 管理方式 |
|-----|------|---------|
| 系统层 | 提供商提示词、环境信息 | SystemPrompt.provider() + environment() |
| 代理层 | Agent 特定提示词 | Agent.prompt |
| 会话层 | 用户自定义系统提示 | user.system |
| 消息层 | 对话历史 | MessageV2.toModelMessages() |
| 动态层 | Plan/Build 切换提醒、步骤提醒 | insertReminders() |

### 9.4 上下文压缩策略

1. **阈值检测**: 达到 80% 上下文上限时触发
2. **代理压缩**: 使用专门的 compaction 代理生成总结
3. **结果裁剪**: 自动清除旧工具调用的详细输出
4. **选择性保留**: 保护 skill 等关键工具结果

---

## 参考文件

| 文件 | 职责 |
|------|------|
| `session/prompt.ts` | 主循环、用户消息创建、命令处理 |
| `session/processor.ts` | LLM 流式响应处理 |
| `session/llm.ts` | LLM 调用、系统提示组装 |
| `session/message-v2.ts` | 消息类型定义、格式转换 |
| `session/compaction.ts` | 上下文压缩 |
| `session/system.ts` | 系统提示词模板选择 |
| `agent/agent.ts` | 代理定义与权限 |
| `session/index.ts` | 会话 CRUD、消息存储 |

---

*报告基于 OpenCode v1.1.36 代码分析*
*生成时间：2026-01-28*
