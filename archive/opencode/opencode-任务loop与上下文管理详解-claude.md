# OpenCode 任务 Loop 与上下文管理详解

> 本文档深入分析 OpenCode 的核心任务循环机制和上下文管理实现，基于源码 `packages/opencode/src/session/` 目录的代码分析。

---

## 目录

1. [核心文件概览](#核心文件概览)
2. [任务 Loop 主流程](#任务-loop-主流程)
3. [系统提示词的构建](#系统提示词的构建)
4. [消息上下文管理](#消息上下文管理)
5. [工具输出处理](#工具输出处理)
6. [LLM 响应处理](#llm-响应处理)
7. [上下文压缩机制](#上下文压缩机制)
8. [关键数据结构](#关键数据结构)
9. [设计亮点与改进空间](#设计亮点与改进空间)

---

## 核心文件概览

| 文件               | 行数    | 职责                  |
| ---------------- | ----- | ------------------- |
| `prompt.ts`      | ~1800 | 任务循环入口、用户消息创建、工具解析  |
| `llm.ts`         | ~300  | LLM 流式调用封装、系统提示组装   |
| `processor.ts`   | ~400  | 流式响应处理、工具调用跟踪、死循环检测 |
| `message-v2.ts`  | ~750  | 消息数据结构定义、消息格式转换     |
| `compaction.ts`  | ~225  | 上下文压缩、工具输出修剪        |
| `system.ts`      | ~55   | 环境信息系统提示            |
| `instruction.ts` | ~165  | 用户自定义指令加载           |
| `index.ts`       | ~500  | Session CRUD、消息存储   |

---

## 任务 Loop 主流程

### 2.1 Loop 入口点

任务循环的入口在 `prompt.ts` 的 `SessionPrompt.loop()` 函数：

```typescript
// prompt.ts:259-640
export const loop = fn(Identifier.schema("session"), async (sessionID) => {
  const abort = start(sessionID)  // 获取 AbortController
  if (!abort) {
    // 会话正忙，等待现有循环完成
    return new Promise<MessageV2.WithParts>((resolve, reject) => {
      const callbacks = state()[sessionID].callbacks
      callbacks.push({ resolve, reject })
    })
  }

  using _ = defer(() => cancel(sessionID))  // 确保退出时清理

  let step = 0
  const session = await Session.get(sessionID)

  while (true) {
    SessionStatus.set(sessionID, { type: "busy" })
    log.info("loop", { step, sessionID })
    if (abort.aborted) break

    // 1. 获取消息历史（过滤已压缩的）
    let msgs = await MessageV2.filterCompacted(MessageV2.stream(sessionID))

    // 2. 查找最后的用户消息和助手消息
    let lastUser: MessageV2.User | undefined
    let lastAssistant: MessageV2.Assistant | undefined
    let lastFinished: MessageV2.Assistant | undefined

    // 3. 检查退出条件
    if (lastAssistant?.finish &&
        !["tool-calls", "unknown"].includes(lastAssistant.finish) &&
        lastUser.id < lastAssistant.id) {
      break  // LLM 已完成回答，退出循环
    }

    step++

    // 4. 处理子任务、压缩、或正常 LLM 调用
    // ... 详见下文
  }
})
```

### 2.2 Loop 退出条件

Loop 在以下情况下会退出：

| 条件 | 代码位置 | 说明 |
|------|---------|------|
| `abort.aborted` | prompt.ts:275 | 用户主动取消 |
| `finish` 为非 tool-calls | prompt.ts:296-303 | LLM 认为任务完成 |
| `result === "stop"` | prompt.ts:619 | 处理器返回停止信号 |
| `processor.message.error` | processor.ts:399 | 发生不可恢复的错误 |
| `blocked` | processor.ts:398 | 权限被拒绝 |

### 2.3 Loop 内部分支

每轮循环会根据消息状态走不同分支：

```
Loop 开始
    │
    ├─ 待处理的 subtask? ──────→ 执行子任务工具
    │
    ├─ 待处理的 compaction? ───→ 执行上下文压缩
    │
    ├─ 上下文溢出? ────────────→ 触发自动压缩
    │
    └─ 正常处理 ───────────────→ 调用 LLM
           │
           ├─ result = "continue" → 继续循环
           ├─ result = "stop" ────→ 退出循环
           └─ result = "compact" ─→ 触发压缩后继续
```

---

## 系统提示词的构建

### 3.1 系统提示词组成层次

系统提示词由多个层次组成，在 `llm.ts` 中组装：

```typescript
// llm.ts:69-82
const system = []
system.push(
  [
    // 1. Agent 提示词（如果有）或 Provider 默认提示词
    ...(input.agent.prompt ? [input.agent.prompt] : SystemPrompt.provider(input.model)),

    // 2. 自定义系统提示（传入的额外提示）
    ...input.system,

    // 3. 用户消息级别的自定义系统提示
    ...(input.user.system ? [input.user.system] : []),
  ]
    .filter((x) => x)
    .join("\n"),
)
```

### 3.2 Provider 系统提示选择

根据模型 ID 选择不同的基础提示词：

```typescript
// system.ts:18-25
export function provider(model: Provider.Model) {
  if (model.api.id.includes("gpt-5")) return [PROMPT_CODEX]
  if (model.api.id.includes("gpt-") || model.api.id.includes("o1") || model.api.id.includes("o3"))
    return [PROMPT_BEAST]
  if (model.api.id.includes("gemini-")) return [PROMPT_GEMINI]
  if (model.api.id.includes("claude")) return [PROMPT_ANTHROPIC]
  return [PROMPT_ANTHROPIC_WITHOUT_TODO]  // 默认使用 qwen.txt
}
```

### 3.3 环境信息系统提示

包含运行时环境信息：

```typescript
// system.ts:27-51
export async function environment(model: Provider.Model) {
  return [
    [
      `You are powered by the model named ${model.api.id}...`,
      `Here is some useful information about the environment you are running in:`,
      `<env>`,
      `  Working directory: ${Instance.directory}`,
      `  Is directory a git repo: ${project.vcs === "git" ? "yes" : "no"}`,
      `  Platform: ${process.platform}`,
      `  Today's date: ${new Date().toDateString()}`,
      `</env>`,
      // ...
    ].join("\n"),
  ]
}
```

### 3.4 用户自定义指令

从多个位置加载用户指令文件：

```typescript
// instruction.ts:13-17
const FILES = [
  "AGENTS.md",    // 项目级
  "CLAUDE.md",    // 兼容 Claude Code
  "CONTEXT.md",   // 已弃用
]

// instruction.ts:19-27
function globalFiles() {
  const files = [path.join(Global.Path.config, "AGENTS.md")]
  if (!Flag.OPENCODE_DISABLE_CLAUDE_CODE_PROMPT) {
    files.push(path.join(os.homedir(), ".claude", "CLAUDE.md"))  // 全局
  }
  // ...
}
```

### 3.5 完整的系统提示词结构

```
┌─────────────────────────────────────────────────────────────┐
│  系统提示词（按顺序拼接）                                    │
├─────────────────────────────────────────────────────────────┤
│  1. Agent 提示词 / Provider 默认提示词                      │
│     └─ anthropic.txt / gemini.txt / beast.txt 等           │
│                                                             │
│  2. 环境信息                                                │
│     └─ 模型名、工作目录、平台、日期                         │
│                                                             │
│  3. 用户自定义指令                                          │
│     ├─ 全局: ~/.config/opencode/AGENTS.md                  │
│     ├─ 兼容: ~/.claude/CLAUDE.md                           │
│     └─ 项目: ./AGENTS.md 或 ./CLAUDE.md                    │
│                                                             │
│  4. 消息级自定义系统提示                                    │
│     └─ input.user.system                                   │
└─────────────────────────────────────────────────────────────┘
```

---

## 消息上下文管理

### 4.1 消息数据结构

OpenCode 使用分层存储结构：

```typescript
// message-v2.ts - 核心类型定义

// 用户消息
export const User = Base.extend({
  role: z.literal("user"),
  time: z.object({ created: z.number() }),
  agent: z.string(),           // 使用的 Agent
  model: z.object({            // 指定的模型
    providerID: z.string(),
    modelID: z.string(),
  }),
  system: z.string().optional(),  // 消息级系统提示
  tools: z.record(z.string(), z.boolean()).optional(),  // 工具开关
})

// 助手消息
export const Assistant = Base.extend({
  role: z.literal("assistant"),
  parentID: z.string(),        // 关联的用户消息 ID
  modelID: z.string(),
  providerID: z.string(),
  agent: z.string(),
  cost: z.number(),            // 花费
  tokens: z.object({           // Token 统计
    input: z.number(),
    output: z.number(),
    reasoning: z.number(),
    cache: z.object({ read: z.number(), write: z.number() }),
  }),
  finish: z.string().optional(),  // 结束原因
  error: z.discriminatedUnion("name", [...]).optional(),
})

// 消息部分（Part）- 消息的组成单元
export const Part = z.discriminatedUnion("type", [
  TextPart,       // 文本内容
  ReasoningPart,  // 推理内容（thinking）
  FilePart,       // 文件/图片
  ToolPart,       // 工具调用
  StepStartPart,  // 步骤开始标记
  StepFinishPart, // 步骤结束标记（含 token 统计）
  PatchPart,      // 代码变更记录
  AgentPart,      // @agent 引用
  SubtaskPart,    // 子任务定义
  CompactionPart, // 压缩标记
  // ...
])
```

### 4.2 消息存储结构

```
存储路径                              存储内容
────────────────────────────────────────────────────────
session/{projectID}/{sessionID}   →  会话元信息
message/{sessionID}/{messageID}   →  消息元信息（不含内容）
part/{messageID}/{partID}         →  消息部分（文本、工具调用等）
```

### 4.3 消息转换为 LLM 输入

`toModelMessages()` 将内部消息格式转换为 AI SDK 格式：

```typescript
// message-v2.ts:436-607
export function toModelMessages(input: WithParts[], model: Provider.Model): ModelMessage[] {
  const result: UIMessage[] = []

  for (const msg of input) {
    if (msg.parts.length === 0) continue

    if (msg.info.role === "user") {
      const userMessage: UIMessage = {
        id: msg.info.id,
        role: "user",
        parts: [],
      }
      for (const part of msg.parts) {
        // 文本部分
        if (part.type === "text" && !part.ignored)
          userMessage.parts.push({ type: "text", text: part.text })

        // 文件部分（排除 text/plain，因为已转为文本）
        if (part.type === "file" && part.mime !== "text/plain")
          userMessage.parts.push({
            type: "file",
            url: part.url,
            mediaType: part.mime,
          })

        // 压缩标记转为特殊文本
        if (part.type === "compaction")
          userMessage.parts.push({ type: "text", text: "What did we do so far?" })
      }
      result.push(userMessage)
    }

    if (msg.info.role === "assistant") {
      // 跳过有错误且无有效内容的消息
      if (msg.info.error && !(AbortedError && hasContent)) continue

      const assistantMessage: UIMessage = {
        id: msg.info.id,
        role: "assistant",
        parts: [],
      }

      for (const part of msg.parts) {
        // 文本输出
        if (part.type === "text")
          assistantMessage.parts.push({ type: "text", text: part.text })

        // 工具调用
        if (part.type === "tool") {
          if (part.state.status === "completed") {
            // 如果已压缩，输出占位符
            const outputText = part.state.time.compacted
              ? "[Old tool result content cleared]"
              : part.state.output

            assistantMessage.parts.push({
              type: `tool-${part.tool}`,
              state: "output-available",
              toolCallId: part.callID,
              input: part.state.input,
              output: outputText,
            })
          }
          // 错误/中断状态也需要处理...
        }

        // 推理内容（thinking）
        if (part.type === "reasoning")
          assistantMessage.parts.push({ type: "reasoning", text: part.text })
      }

      if (assistantMessage.parts.length > 0)
        result.push(assistantMessage)
    }
  }

  // 使用 AI SDK 的 convertToModelMessages 进行最终转换
  return convertToModelMessages(result, { tools })
}
```

### 4.4 消息流获取与过滤

```typescript
// message-v2.ts:609-657
export const stream = fn(Identifier.schema("session"), async function* (sessionID) {
  const list = await Array.fromAsync(await Storage.list(["message", sessionID]))
  // 从新到旧遍历
  for (let i = list.length - 1; i >= 0; i--) {
    yield await get({ sessionID, messageID: list[i][2] })
  }
})

// 过滤已压缩的消息
export async function filterCompacted(stream: AsyncIterable<MessageV2.WithParts>) {
  const result = [] as MessageV2.WithParts[]
  const completed = new Set<string>()

  for await (const msg of stream) {
    result.push(msg)
    // 如果遇到压缩点且该点已完成，停止
    if (msg.info.role === "user" &&
        completed.has(msg.info.id) &&
        msg.parts.some((part) => part.type === "compaction"))
      break
    // 记录已完成摘要的用户消息
    if (msg.info.role === "assistant" && msg.info.summary && msg.info.finish)
      completed.add(msg.info.parentID)
  }

  result.reverse()  // 转为从旧到新
  return result
}
```

---

## 工具输出处理

### 5.1 工具执行流程

工具在 `processor.ts` 中通过流式事件处理：

```typescript
// processor.ts - 流式事件处理
for await (const value of stream.fullStream) {
  switch (value.type) {
    case "tool-input-start":
      // 创建 pending 状态的工具调用记录
      const part = await Session.updatePart({
        type: "tool",
        tool: value.toolName,
        callID: value.id,
        state: {
          status: "pending",
          input: {},
          raw: "",
        },
      })
      toolcalls[value.id] = part
      break

    case "tool-call":
      // 更新为 running 状态
      await Session.updatePart({
        ...match,
        state: {
          status: "running",
          input: value.input,
          time: { start: Date.now() },
        },
      })

      // 死循环检测
      const lastThree = parts.slice(-DOOM_LOOP_THRESHOLD)
      if (lastThree 连续相同调用) {
        await PermissionNext.ask({ permission: "doom_loop", ... })
      }
      break

    case "tool-result":
      // 更新为 completed 状态，保存输出
      await Session.updatePart({
        ...match,
        state: {
          status: "completed",
          input: value.input,
          output: value.output.output,      // 工具输出文本
          metadata: value.output.metadata,  // 工具元数据
          title: value.output.title,
          time: { start, end: Date.now() },
          attachments: value.output.attachments,  // 附件（如截图）
        },
      })
      break

    case "tool-error":
      // 更新为 error 状态
      await Session.updatePart({
        ...match,
        state: {
          status: "error",
          error: value.error.toString(),
          time: { start, end: Date.now() },
        },
      })

      // 权限拒绝时可能需要停止循环
      if (value.error instanceof PermissionNext.RejectedError) {
        blocked = shouldBreak
      }
      break
  }
}
```

### 5.2 工具输出结构

```typescript
// 工具执行返回格式（tool/tool.ts）
interface ToolResult {
  title: string              // 显示标题
  metadata: Record<string, any>  // 元数据（如 truncated、outputPath）
  output: string             // 文本输出（可能被截断）
  attachments?: FilePart[]   // 附件（图片、文件等）
}
```

### 5.3 工具输出截断

长输出会被截断以节省上下文：

```typescript
// MCP 工具输出处理示例
const truncated = await Truncate.output(textParts.join("\n\n"), {}, input.agent)
const metadata = {
  truncated: truncated.truncated,
  ...(truncated.truncated && { outputPath: truncated.outputPath }),
}
return {
  output: truncated.content,  // 截断后的内容
  metadata,
}
```

---

## LLM 响应处理

### 6.1 流式响应事件类型

```typescript
// processor.ts 处理的事件类型
switch (value.type) {
  case "start":          // 流开始
  case "reasoning-start" // 推理开始（thinking）
  case "reasoning-delta" // 推理增量
  case "reasoning-end"   // 推理结束
  case "text-start"      // 文本开始
  case "text-delta"      // 文本增量（逐字输出）
  case "text-end"        // 文本结束
  case "tool-input-start"// 工具参数开始
  case "tool-input-delta"// 工具参数增量
  case "tool-input-end"  // 工具参数结束
  case "tool-call"       // 工具调用确认
  case "tool-result"     // 工具执行完成
  case "tool-error"      // 工具执行错误
  case "start-step"      // 步骤开始
  case "finish-step"     // 步骤结束（含 token 统计）
  case "error"           // 流错误
  case "finish"          // 流结束
}
```

### 6.2 文本增量处理

```typescript
// processor.ts:279-326
case "text-start":
  currentText = {
    id: Identifier.ascending("part"),
    messageID: input.assistantMessage.id,
    sessionID: input.assistantMessage.sessionID,
    type: "text",
    text: "",
    time: { start: Date.now() },
  }
  break

case "text-delta":
  if (currentText) {
    currentText.text += value.text  // 累积文本
    // 增量更新存储（带 delta 标记用于 UI 动画）
    await Session.updatePart({
      part: currentText,
      delta: value.text,
    })
  }
  break

case "text-end":
  if (currentText) {
    currentText.text = currentText.text.trimEnd()
    // 插件处理（如后处理）
    const textOutput = await Plugin.trigger(
      "experimental.text.complete",
      { sessionID, messageID, partID },
      { text: currentText.text },
    )
    currentText.text = textOutput.text
    await Session.updatePart(currentText)
  }
  currentText = undefined
  break
```

### 6.3 推理内容（Thinking）处理

```typescript
// processor.ts:62-101
case "reasoning-start":
  reasoningMap[value.id] = {
    type: "reasoning",
    text: "",
    time: { start: Date.now() },
    metadata: value.providerMetadata,
  }
  break

case "reasoning-delta":
  const part = reasoningMap[value.id]
  part.text += value.text
  if (part.text)
    await Session.updatePart({ part, delta: value.text })
  break

case "reasoning-end":
  part.time.end = Date.now()
  await Session.updatePart(part)
  delete reasoningMap[value.id]
  break
```

### 6.4 步骤结束与 Token 统计

```typescript
// processor.ts:236-277
case "finish-step":
  const usage = Session.getUsage({
    model: input.model,
    usage: value.usage,
    metadata: value.providerMetadata,
  })

  // 更新助手消息的累计统计
  input.assistantMessage.finish = value.finishReason
  input.assistantMessage.cost += usage.cost
  input.assistantMessage.tokens = usage.tokens

  // 记录步骤结束标记
  await Session.updatePart({
    type: "step-finish",
    reason: value.finishReason,
    tokens: usage.tokens,
    cost: usage.cost,
  })

  // 记录代码变更
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

  // 检查是否需要压缩
  if (await SessionCompaction.isOverflow({ tokens, model })) {
    needsCompaction = true
  }
  break
```

---

## 上下文压缩机制

### 7.1 压缩触发条件

```typescript
// compaction.ts:30-39
export async function isOverflow(input: { tokens, model }) {
  const config = await Config.get()
  if (config.compaction?.auto === false) return false  // 可禁用

  const context = input.model.limit.context
  if (context === 0) return false

  const count = input.tokens.input + input.tokens.cache.read + input.tokens.output
  const output = Math.min(input.model.limit.output, OUTPUT_TOKEN_MAX)
  const usable = input.model.limit.input || context - output

  return count > usable  // 当前 token 数超过可用限制
}
```

### 7.2 工具输出修剪（Prune）

在上下文压缩前，先修剪旧的工具输出：

```typescript
// compaction.ts:41-90
export const PRUNE_MINIMUM = 20_000   // 最小修剪量
export const PRUNE_PROTECT = 40_000   // 保护最近的 token

export async function prune(input: { sessionID: string }) {
  const msgs = await Session.messages({ sessionID })
  let total = 0
  let pruned = 0
  const toPrune = []
  let turns = 0

  // 从后向前遍历
  loop: for (let msgIndex = msgs.length - 1; msgIndex >= 0; msgIndex--) {
    const msg = msgs[msgIndex]
    if (msg.info.role === "user") turns++
    if (turns < 2) continue  // 保护最近 2 轮
    if (msg.info.role === "assistant" && msg.info.summary) break  // 到达上次压缩点

    for (const part of msg.parts.reverse()) {
      if (part.type === "tool" && part.state.status === "completed") {
        if (part.state.time.compacted) break loop  // 已被修剪过

        const estimate = Token.estimate(part.state.output)
        total += estimate

        if (total > PRUNE_PROTECT) {
          pruned += estimate
          toPrune.push(part)
        }
      }
    }
  }

  // 如果修剪量足够大，执行修剪
  if (pruned > PRUNE_MINIMUM) {
    for (const part of toPrune) {
      part.state.time.compacted = Date.now()  // 标记为已修剪
      await Session.updatePart(part)
    }
  }
}
```

修剪后，`toModelMessages()` 会将修剪过的工具输出转换为占位符：

```typescript
const outputText = part.state.time.compacted
  ? "[Old tool result content cleared]"   // 占位符
  : part.state.output
```

### 7.3 上下文摘要压缩

当修剪不够时，会生成摘要来压缩上下文：

```typescript
// compaction.ts:92-193
export async function process(input: {
  parentID: string
  messages: MessageV2.WithParts[]
  sessionID: string
  abort: AbortSignal
  auto: boolean
}) {
  const agent = await Agent.get("compaction")  // 使用专用 compaction agent

  // 创建摘要消息
  const msg = await Session.updateMessage({
    role: "assistant",
    agent: "compaction",
    summary: true,  // 标记为摘要消息
    // ...
  })

  const processor = SessionProcessor.create({...})

  // 压缩提示词
  const defaultPrompt =
    "Provide a detailed prompt for continuing our conversation above. " +
    "Focus on information that would be helpful for continuing the conversation, " +
    "including what we did, what we're doing, which files we're working on, " +
    "and what we're going to do next..."

  // 调用 LLM 生成摘要
  const result = await processor.process({
    agent,
    tools: {},  // 压缩时不使用工具
    messages: [
      ...MessageV2.toModelMessages(input.messages, model),
      {
        role: "user",
        content: [{ type: "text", text: promptText }],
      },
    ],
  })

  // 如果是自动压缩，添加继续提示
  if (result === "continue" && input.auto) {
    await Session.updateMessage({
      role: "user",
      // ...
    })
    await Session.updatePart({
      type: "text",
      synthetic: true,
      text: "Continue if you have next steps",
    })
  }
}
```

### 7.4 压缩后的消息过滤

`filterCompacted()` 会在压缩点截断历史：

```typescript
// message-v2.ts:642-657
export async function filterCompacted(stream) {
  const result = [] as MessageV2.WithParts[]
  const completed = new Set<string>()

  for await (const msg of stream) {
    result.push(msg)

    // 如果遇到已完成的压缩点，停止获取更早的消息
    if (msg.info.role === "user" &&
        completed.has(msg.info.id) &&
        msg.parts.some((part) => part.type === "compaction"))
      break

    // 记录已完成摘要的消息
    if (msg.info.role === "assistant" && msg.info.summary && msg.info.finish)
      completed.add(msg.info.parentID)
  }

  result.reverse()
  return result
}
```

---

## 关键数据结构

### 8.1 完整的上下文组装流程

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          上下文组装流程                                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  1. 系统提示词层                                                            │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │ system[0]: Agent/Provider 提示词 + 环境信息 + 用户指令                │   │
│  │ system[1]: 动态部分（如果有）                                         │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│  2. 历史消息层（经过压缩过滤）                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │ [User Message 1]                                                     │   │
│  │   └─ TextPart: "帮我创建一个日期格式化函数"                          │   │
│  │                                                                      │   │
│  │ [Assistant Message 1]                                                │   │
│  │   ├─ TextPart: "好的，我来帮你..."                                   │   │
│  │   └─ ToolPart: { tool: "edit", output: "..." | "[cleared]" }        │   │
│  │                                                                      │   │
│  │ [User Message 2 - 压缩点]                                            │   │
│  │   └─ CompactionPart                                                  │   │
│  │                                                                      │   │
│  │ [Assistant Message 2 - 摘要]                                         │   │
│  │   └─ TextPart: "到目前为止我们做了..."                               │   │
│  │                                                                      │   │
│  │ [User Message 3]                                                     │   │
│  │   └─ TextPart: "继续添加测试"                                        │   │
│  │                                                                      │   │
│  │ [Assistant Message 3]                                                │   │
│  │   ├─ ReasoningPart: "<think>我需要...</think>"                       │   │
│  │   ├─ TextPart: "我来添加测试..."                                     │   │
│  │   └─ ToolPart: { tool: "edit", state: "completed", output: "..." }  │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│  3. 特殊处理层（可选）                                                      │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │ - 达到最大步数时: 插入 MAX_STEPS 提示                                │   │
│  │ - 多轮提醒: 用 <system-reminder> 包装队列中的用户消息                │   │
│  │ - Plan 模式: 插入 plan 模式特殊指令                                  │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 8.2 消息部分状态机

```
ToolPart 状态流转:

  pending ──→ running ──→ completed
     │           │             │
     │           │             └──→ compacted（修剪后）
     │           │
     │           └─────→ error
     │
     └─────────────────→ error（中断）
```

### 8.3 Loop 状态机

```
                    ┌────────────────┐
                    │     start      │
                    └────────┬───────┘
                             │
                             ▼
              ┌──────────────────────────────┐
              │         while (true)          │
              │  ┌────────────────────────┐  │
              │  │ 获取消息历史            │  │
              │  │ 检查退出条件            │  │
              │  │ step++                  │  │
              │  └──────────┬─────────────┘  │
              │             │                 │
              │  ┌──────────▼─────────────┐  │
              │  │  subtask pending?       │──┼──→ 执行子任务 ──→ continue
              │  └──────────┬─────────────┘  │
              │             │ no             │
              │  ┌──────────▼─────────────┐  │
              │  │  compaction pending?    │──┼──→ 执行压缩 ──→ continue
              │  └──────────┬─────────────┘  │
              │             │ no             │
              │  ┌──────────▼─────────────┐  │
              │  │  context overflow?      │──┼──→ 创建压缩任务 ──→ continue
              │  └──────────┬─────────────┘  │
              │             │ no             │
              │  ┌──────────▼─────────────┐  │
              │  │  processor.process()    │  │
              │  │  (调用 LLM)             │  │
              │  └──────────┬─────────────┘  │
              │             │                 │
              │  ┌──────────▼─────────────┐  │
              │  │  result?                │  │
              │  │  - "continue" ─────────┼──┼──→ 继续循环
              │  │  - "compact" ──────────┼──┼──→ 创建压缩 → continue
              │  │  - "stop" ─────────────┼──┼──→ break
              │  └────────────────────────┘  │
              └──────────────────────────────┘
                             │
                             ▼
                    ┌────────────────┐
                    │   退出循环      │
                    │   prune()       │
                    │   返回结果      │
                    └────────────────┘
```

---

## 设计亮点与改进空间

### 9.1 设计亮点

| 亮点 | 说明 |
|------|------|
| **分层存储** | Message → Part 分离存储，支持增量更新和流式显示 |
| **流式处理** | 完整的流式事件处理，支持文本、推理、工具调用 |
| **智能压缩** | 多级压缩策略：先修剪工具输出，再生成摘要 |
| **死循环检测** | 检测连续相同工具调用，防止 LLM 陷入死循环 |
| **可中断设计** | 使用 AbortController，支持随时取消任务 |
| **步骤追踪** | StepStart/StepFinish 标记，精确追踪每轮 LLM 调用 |
| **快照系统** | 每轮调用前后记录 git 状态，支持回滚 |
| **插件钩子** | 多处 Plugin.trigger 调用，支持扩展处理逻辑 |

### 9.2 改进空间

| 方面 | 现状 | 可能的改进 |
|------|------|-----------|
| **prompt.ts 体积** | ~1800 行 | 可拆分为 prompt-loop.ts、prompt-message.ts 等 |
| **压缩策略** | 固定阈值 | 可支持动态阈值、不同模型差异化 |
| **消息过滤** | 遍历全部消息 | 可利用索引加速，特别是长会话 |
| **错误恢复** | 基本重试 | 可增加更智能的错误分类和恢复策略 |
| **并发控制** | 简单锁 | 可支持会话级别的并发读写 |

---

## 参考文件路径

| 文件 | 路径 |
|------|------|
| prompt.ts | `packages/opencode/src/session/prompt.ts` |
| llm.ts | `packages/opencode/src/session/llm.ts` |
| processor.ts | `packages/opencode/src/session/processor.ts` |
| message-v2.ts | `packages/opencode/src/session/message-v2.ts` |
| compaction.ts | `packages/opencode/src/session/compaction.ts` |
| system.ts | `packages/opencode/src/session/system.ts` |
| instruction.ts | `packages/opencode/src/session/instruction.ts` |
| index.ts | `packages/opencode/src/session/index.ts` |
| anthropic.txt | `packages/opencode/src/session/prompt/anthropic.txt` |
