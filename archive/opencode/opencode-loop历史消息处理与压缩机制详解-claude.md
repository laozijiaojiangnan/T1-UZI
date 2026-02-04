# OpenCode Loop 历史消息处理与压缩机制详解

> 本文聚焦于 OpenCode 在 agent loop 中如何管理历史消息——用户输入、模型回答、工具输出、系统提示词分别如何处理，以及当上下文溢出时如何进行消息压缩。重点讲清设计思路和背后的"为什么"。

---

## 一、全景概览：消息在 Loop 里的一生

在 OpenCode 里，每一轮 loop 都要把"所有历史消息"拿出来，经过一系列处理后发给 LLM。这个过程可以拆成四个阶段：

```
① 消息收集 → ② 消息过滤 → ③ 消息转换 → ④ 拼装发送
```

每个阶段的核心问题都不同：

| 阶段   | 核心问题                    | 对应代码                          |
| ---- | ----------------------- | ----------------------------- |
| ① 收集 | 从存储里把消息读出来              | `MessageV2.stream()`          |
| ② 过滤 | 如果之前做过压缩，丢掉压缩点之前的旧消息    | `MessageV2.filterCompacted()` |
| ③ 转换 | 把内部格式转成 LLM 能理解的格式      | `MessageV2.toModelMessages()` |
| ④ 拼装 | 系统提示词 + 历史消息 + 特殊提示拼在一起 | `LLM.stream()`                |

下面逐层展开。

---

## 二、消息的存储结构：Message + Part 两层设计

OpenCode 没有把消息存成一个大 JSON，而是把它拆成了两层：

```
Message（元信息层）
  ├── id, role, sessionID, tokens, cost ...
  │
  └── Part（内容层）
       ├── TextPart      → 文本
       ├── ToolPart       → 工具调用 + 结果
       ├── ReasoningPart  → 模型的 thinking 过程
       ├── FilePart       → 文件/图片
       ├── CompactionPart → 压缩标记点
       ├── SubtaskPart    → 子任务
       ├── StepStartPart  → 一轮 LLM 调用的开始标记
       ├── StepFinishPart → 一轮 LLM 调用的结束标记（含 token 统计）
       └── PatchPart      → 代码变更记录
```

**存储路径**：

```
message/{sessionID}/{messageID}   →  消息元信息
part/{messageID}/{partID}         →  消息内容片段
```

**为什么要这样拆？**

核心原因是**流式更新**。LLM 的输出是一个字一个字来的，工具执行有 pending → running → completed 的状态流转。如果消息是一整块，每来一个字就要重写整条消息。拆成 Part 后，每次只需要更新一个小片段，前端也能实时看到每个 Part 的变化。

**关键代码**（`message-v2.ts`）：

```typescript
// 用户消息的元信息
export const User = Base.extend({
  role: z.literal("user"),
  agent: z.string(),           // 使用的 Agent（如 build、plan）
  model: z.object({            // 指定的模型
    providerID: z.string(),
    modelID: z.string(),
  }),
  system: z.string().optional(), // 消息级别的自定义系统提示
})

// 助手消息的元信息
export const Assistant = Base.extend({
  role: z.literal("assistant"),
  parentID: z.string(),        // 关联的用户消息 ID
  summary: z.boolean().optional(), // 标记：这条消息是压缩摘要
  cost: z.number(),
  tokens: z.object({           // 这轮调用的 token 使用量
    input: z.number(),
    output: z.number(),
    reasoning: z.number(),
    cache: z.object({ read: z.number(), write: z.number() }),
  }),
  finish: z.string().optional(), // LLM 结束原因：stop / tool-calls / length
})
```

**优点**：增量更新高效、支持流式渲染、每个 Part 可独立查询。

**缺点**：读取完整消息需要多次 IO（先读 message，再读所有 part），长会话下碎片化严重。

---

## 三、消息收集：从后往前读

`MessageV2.stream()` 负责从存储里按时间倒序读出消息：

```typescript
// message-v2.ts:609
export const stream = fn(Identifier.schema("session"), async function* (sessionID) {
  const list = await Array.fromAsync(await Storage.list(["message", sessionID]))
  // 关键：从新到旧遍历
  for (let i = list.length - 1; i >= 0; i--) {
    yield await get({ sessionID, messageID: list[i][2] })
  }
})
```

**为什么从后往前读？** 因为后面的 `filterCompacted()` 需要先看到最新消息，一旦找到压缩点就可以提前停止，避免读取已被压缩替代的旧消息。这是一个**惰性加载**的优化——不需要把整个会话历史全部加载进内存。

---

## 四、消息过滤：在压缩点截断

这是最巧妙的设计之一。`filterCompacted()` 决定了"LLM 到底能看到多少历史"：

```typescript
// message-v2.ts:642
export async function filterCompacted(stream: AsyncIterable<MessageV2.WithParts>) {
  const result = [] as MessageV2.WithParts[]
  const completed = new Set<string>()

  for await (const msg of stream) {
    result.push(msg)

    // 关键条件：遇到一个"已完成压缩"的压缩点就停下来
    if (
      msg.info.role === "user" &&
      completed.has(msg.info.id) &&
      msg.parts.some((part) => part.type === "compaction")
    )
      break

    // 助手消息如果是摘要且已完成，记录它对应的用户消息 ID
    if (msg.info.role === "assistant" && msg.info.summary && msg.info.finish)
      completed.add(msg.info.parentID)
  }

  result.reverse()  // 翻转回时间正序
  return result
}
```

**设计思路**：

这里有一个"标记—匹配"的两步逻辑：

1. **从新往旧遍历**，先遇到助手的摘要消息（`summary=true`），记住它的 `parentID`
2. 继续往旧走，遇到对应的用户消息里有 `CompactionPart`，说明这是一个已完成的压缩点
3. 在这个点截断——它之前的所有消息都被摘要替代了，不需要再读

这就像书签一样：压缩操作会在历史消息里"插入一个书签"，下次读的时候只从书签位置开始读。

**所以 LLM 看到的历史是这样的**：

```
[压缩点的用户消息: "What did we do so far?"]
[摘要: "到目前为止我们做了 X、Y、Z..."]
[后续的真实对话消息...]
```

**优点**：不需要删除旧消息，只需要在读取时跳过，保留了完整的历史记录可供回溯。

**缺点**：每次 loop 都要扫描消息流来找压缩点，长会话中这个扫描本身也有成本。

---

## 五、消息转换：内部格式 → LLM 格式

`toModelMessages()` 把 OpenCode 的内部消息格式转成 Vercel AI SDK 的 `UIMessage` 格式，再通过 `convertToModelMessages()` 转成最终的 `ModelMessage`。

### 5.1 用户消息的转换

```typescript
// message-v2.ts:476
if (msg.info.role === "user") {
  const userMessage: UIMessage = { id: msg.info.id, role: "user", parts: [] }
  for (const part of msg.parts) {
    // 文本：跳过被标记为 ignored 的
    if (part.type === "text" && !part.ignored)
      userMessage.parts.push({ type: "text", text: part.text })

    // 文件：text/plain 已被转成文本，不再作为文件发送
    if (part.type === "file" && part.mime !== "text/plain" && part.mime !== "application/x-directory")
      userMessage.parts.push({ type: "file", url: part.url, mediaType: part.mime })

    // 压缩点：转成一个固定的提问
    if (part.type === "compaction")
      userMessage.parts.push({ type: "text", text: "What did we do so far?" })
  }
}
```

**关键细节**：`CompactionPart` 被转换成 `"What did we do so far?"`，这让 LLM 在压缩流程中自然地回答"到目前为止做了什么"，摘要就生成了。这个设计的巧妙之处在于——压缩操作被伪装成了一个正常的用户提问。

### 5.2 助手消息的转换

```typescript
// message-v2.ts:513
if (msg.info.role === "assistant") {
  // 有错误且没有有效内容的消息直接跳过
  if (msg.info.error && !hasValidContent) continue

  for (const part of msg.parts) {
    if (part.type === "text")
      assistantMessage.parts.push({ type: "text", text: part.text })

    if (part.type === "tool") {
      if (part.state.status === "completed") {
        // 关键：已被修剪的工具输出用占位符替代
        const outputText = part.state.time.compacted
          ? "[Old tool result content cleared]"
          : part.state.output
        // ... 构建 tool result
      }
      // 未完成的工具调用标记为中断
      if (part.state.status === "pending" || part.state.status === "running")
        // errorText: "[Tool execution was interrupted]"
    }

    if (part.type === "reasoning")
      assistantMessage.parts.push({ type: "reasoning", text: part.text })
  }
}
```

**两个重要的处理**：

1. **已修剪的工具输出**：用 `"[Old tool result content cleared]"` 替代原文。这样 LLM 知道"这里以前有个工具调用，结果已经清掉了"，不会困惑为什么有工具调用却没有结果。
2. **未完成的工具调用**：标记为 `"[Tool execution was interrupted]"`。因为 Anthropic 等 API 要求每个 `tool_use` 必须有对应的 `tool_result`，否则会报错。

### 5.3 最终转换

```typescript
// 过滤掉只包含 step-start 的空消息后，调用 AI SDK 的转换函数
return convertToModelMessages(
  result.filter((msg) => msg.parts.some((part) => part.type !== "step-start")),
  { tools }
)
```

**优点**：转换逻辑集中在一个函数里，对各种边界情况有统一处理。

**缺点**：`toModelMessages` 函数需要遍历所有消息的所有 Part，长会话下性能有压力。且工具输出的 `toModelOutput` 处理逻辑嵌在闭包里，不太直观。

---

## 六、消息拼装：系统提示词 + 历史 + 特殊处理

### 6.1 系统提示词的组装

在 `llm.ts` 中，系统提示词被组装成一个数组（通常 1-2 个元素），这样 Anthropic API 可以利用 prompt caching：

```typescript
// llm.ts:69
const system = []
system.push(
  [
    // 第一部分：Agent 提示词或 Provider 默认提示词（大段静态文本，适合缓存）
    ...(input.agent.prompt ? [input.agent.prompt] : SystemPrompt.provider(input.model)),
    // 第二部分：用户自定义系统提示
    ...input.system,
    // 第三部分：消息级自定义提示
    ...(input.user.system ? [input.user.system] : []),
  ].filter((x) => x).join("\n"),
)
```

**设计思路**：将系统提示词拆成两段（header + rest），header 部分是大段的静态指令，在多轮对话中不会变化，可以被 API 缓存，节省成本。

```typescript
// llm.ts:94 — 保持两段结构以利用缓存
if (system.length > 2 && system[0] === header) {
  const rest = system.slice(1)
  system.length = 0
  system.push(header, rest.join("\n"))
}
```

### 6.2 最终发送给 LLM 的消息结构

```typescript
// llm.ts:242
return streamText({
  messages: [
    // 系统提示词（1-2条 system message）
    ...system.map((x): ModelMessage => ({ role: "system", content: x })),
    // 历史消息（经过 filterCompacted + toModelMessages 处理后的）
    ...input.messages,
  ],
  tools: ...,
  model: ...,
})
```

### 6.3 Loop 中的特殊消息注入

在 `prompt.ts` 的 loop 中，消息发送前还有几处"注入"操作：

**① 多轮提醒包装**（`prompt.ts:579`）：

当 step > 1 时，如果用户在 LLM 工作过程中插入了新消息，这些消息会被包装成 `<system-reminder>` 标签：

```typescript
if (step > 1 && lastFinished) {
  for (const msg of sessionMessages) {
    if (msg.info.role !== "user" || msg.info.id <= lastFinished.id) continue
    for (const part of msg.parts) {
      if (part.type !== "text" || part.ignored || part.synthetic) continue
      part.text = [
        "<system-reminder>",
        "The user sent the following message:",
        part.text,
        "",
        "Please address this message and continue with your tasks.",
        "</system-reminder>",
      ].join("\n")
    }
  }
}
```

**为什么？** 这是为了防止 LLM 被用户的新消息"打断"。包装成 system-reminder 后，LLM 会把它当作"需要处理的额外信息"而不是"丢弃之前的工作重新开始"。

**② 最大步数限制**（`prompt.ts:607`）：

```typescript
messages: [
  ...MessageV2.toModelMessages(sessionMessages, model),
  // 如果已到达最大步数，插入一条助手消息强制结束
  ...(isLastStep ? [{ role: "assistant", content: MAX_STEPS }] : []),
]
```

通过"把话塞进助手嘴里"的方式，强制 LLM 在最后一步输出总结而不是继续调用工具。

---

## 七、工具输出的处理：截断与保全

工具输出是消耗上下文空间的大户。OpenCode 对它有两道防线：

### 7.1 第一道：实时截断（Truncate）

工具执行完毕时，如果输出太长，立即截断：

```typescript
// truncation.ts
export const MAX_LINES = 2000
export const MAX_BYTES = 50 * 1024  // 50KB

export async function output(text: string, options: Options = {}, agent?: Agent.Info): Promise<Result> {
  const lines = text.split("\n")
  const totalBytes = Buffer.byteLength(text, "utf-8")

  // 不超限则原样返回
  if (lines.length <= maxLines && totalBytes <= maxBytes) {
    return { content: text, truncated: false }
  }

  // 超限则截断，把完整输出存到文件
  const filepath = path.join(DIR, id)
  await Bun.write(Bun.file(filepath), text)

  // 返回截断后的内容 + 提示信息
  return {
    content: `${preview}\n\n...${removed} ${unit} truncated...\n\n${hint}`,
    truncated: true,
    outputPath: filepath,
  }
}
```

**设计思路**：截断后的完整输出被保存到磁盘文件，LLM 可以后续通过 Read/Grep 工具去读取感兴趣的部分。这样做的好处是：不浪费上下文空间，但信息没有真正丢失。

**优点**：固定上限，单次工具输出不会撑爆上下文。

**缺点**：阈值是硬编码的（2000 行 / 50KB），不同模型的上下文窗口大小差异很大，但截断标准是一样的。

### 7.2 第二道：事后修剪（Prune）

在 loop 退出时，会调用 `SessionCompaction.prune()` 对旧的工具输出做"回溯修剪"：

```typescript
// compaction.ts:41
export const PRUNE_MINIMUM = 20_000   // 至少修剪 2 万 token 才值得
export const PRUNE_PROTECT = 40_000   // 保护最近 4 万 token 的工具输出

export async function prune(input: { sessionID: string }) {
  let total = 0
  let pruned = 0
  let turns = 0

  // 从后向前遍历所有消息
  loop: for (let msgIndex = msgs.length - 1; msgIndex >= 0; msgIndex--) {
    const msg = msgs[msgIndex]
    if (msg.info.role === "user") turns++
    if (turns < 2) continue              // ① 保护最近 2 轮
    if (msg.info.role === "assistant" && msg.info.summary) break loop  // ② 到达上次压缩点就停

    for (let partIndex = msg.parts.length - 1; partIndex >= 0; partIndex--) {
      const part = msg.parts[partIndex]
      if (part.type === "tool" && part.state.status === "completed") {
        if (PRUNE_PROTECTED_TOOLS.includes(part.tool)) continue  // ③ skill 类工具不修剪
        if (part.state.time.compacted) break loop                 // ④ 已修剪过就停
        const estimate = Token.estimate(part.state.output)
        total += estimate
        if (total > PRUNE_PROTECT) {  // ⑤ 超过保护区后开始标记
          pruned += estimate
          toPrune.push(part)
        }
      }
    }
  }

  // 修剪量超过最小阈值才执行
  if (pruned > PRUNE_MINIMUM) {
    for (const part of toPrune) {
      part.state.time.compacted = Date.now()  // 打上"已修剪"标记
      await Session.updatePart(part)
    }
  }
}
```

**Token 估算**使用的是最简单的方法：

```typescript
// token.ts
const CHARS_PER_TOKEN = 4
export function estimate(input: string) {
  return Math.max(0, Math.round((input || "").length / CHARS_PER_TOKEN))
}
```

**设计思路**：

- **保护最近 2 轮**：最新的工具输出通常是 LLM 接下来要用的，不能删
- **保护最近 4 万 token**：确保 LLM 有足够的近期上下文
- **从旧到新修剪**：越早的工具输出越不重要
- **只打标记不删除**：被修剪的 Part 依然存在存储里，只是在 `toModelMessages` 时会被替换成 `"[Old tool result content cleared]"`

**优点**：渐进式修剪，不会一次性丢失太多信息；修剪是可逆的（标记而非删除）。

**缺点**：token 估算很粗糙（4 字符 = 1 token 对中文不准确）；修剪策略不区分工具输出的重要程度，一律按时间先后处理。

---

## 八、上下文压缩：从修剪到摘要

当修剪不足以控制上下文大小时，OpenCode 会启动"摘要压缩"——用 LLM 本身来总结之前的对话。

### 8.1 触发条件

```typescript
// compaction.ts:30
export async function isOverflow(input: { tokens, model }) {
  const config = await Config.get()
  if (config.compaction?.auto === false) return false  // 可手动关闭

  const context = input.model.limit.context
  if (context === 0) return false  // 无限上下文模型不压缩

  const count = input.tokens.input + input.tokens.cache.read + input.tokens.output
  const output = Math.min(input.model.limit.output, OUTPUT_TOKEN_MAX)
  const usable = input.model.limit.input || context - output

  return count > usable  // 已用 token > 可用空间
}
```

**触发时机**：在 `processor.ts` 的 `finish-step` 事件处理中检查，以及在 `prompt.ts` 的 loop 中检查 `lastFinished.tokens`。

### 8.2 压缩流程

压缩分三步：创建压缩请求 → 执行压缩 → 过滤旧消息。

**第一步：创建压缩请求**（`compaction.ts:195`）

在消息历史里插入一个"压缩标记"：

```typescript
export const create = fn(z.object({...}), async (input) => {
  // 创建一条用户消息
  const msg = await Session.updateMessage({
    role: "user",
    model: input.model,
    sessionID: input.sessionID,
    agent: input.agent,
  })
  // 在里面放一个 CompactionPart
  await Session.updatePart({
    messageID: msg.id,
    type: "compaction",
    auto: input.auto,  // 标记是自动触发还是用户手动触发
  })
})
```

**第二步：执行压缩**（`compaction.ts:92`）

下一轮 loop 检测到有待处理的 CompactionPart 时，执行压缩：

```typescript
export async function process(input: { messages, parentID, sessionID, abort, auto }) {
  // 使用专门的 "compaction" agent
  const agent = await Agent.get("compaction")

  // 创建一条标记为 summary=true 的助手消息
  const msg = await Session.updateMessage({
    role: "assistant",
    agent: "compaction",
    summary: true,  // 关键标记
    // ...
  })

  // 压缩提示词
  const defaultPrompt =
    "Provide a detailed prompt for continuing our conversation above. " +
    "Focus on information that would be helpful for continuing the conversation, " +
    "including what we did, what we're doing, which files we're working on, " +
    "and what we're going to do next considering new session will not have " +
    "access to our conversation."

  // 调用 LLM 生成摘要（不给工具，只让它输出文本）
  const result = await processor.process({
    agent,
    tools: {},       // 压缩时不使用任何工具
    messages: [
      ...MessageV2.toModelMessages(input.messages, model),  // 全部历史
      { role: "user", content: [{ type: "text", text: promptText }] },  // 压缩指令
    ],
  })

  // 如果是自动压缩，还要插入一条"继续"的用户消息
  if (result === "continue" && input.auto) {
    await Session.updatePart({
      type: "text",
      synthetic: true,
      text: "Continue if you have next steps",
    })
  }
}
```

**第三步：后续 loop 中自动过滤**

下次 loop 调用 `filterCompacted()` 时，会发现：
1. 有一条 `summary=true` 且 `finish` 不为空的助手消息
2. 它的 `parentID` 指向一条带 `CompactionPart` 的用户消息
3. 从这个压缩点截断，不再读取更早的消息

### 8.3 压缩后的消息视图

压缩前，LLM 看到的是：

```
[用户消息 1] [助手消息 1] [用户消息 2] [助手消息 2] ... [用户消息 N]
```

压缩后，LLM 看到的变成：

```
[压缩用户消息: "What did we do so far?"]
[摘要助手消息: "到目前为止我们做了...正在做...接下来要做..."]
[自动继续消息: "Continue if you have next steps"]
[用户消息 N+1] [助手消息 N+1] ...
```

---

## 九、Loop 中各分支的处理优先级

`prompt.ts` 的 `loop()` 函数在每轮迭代中，按以下优先级处理不同情况：

```typescript
// prompt.ts:259 - 简化后的 loop 结构
while (true) {
  let msgs = await MessageV2.filterCompacted(MessageV2.stream(sessionID))

  // 1. 找到最后的用户消息、助手消息、待处理任务
  // ...

  // 2. 退出检查：助手已完成且不是 tool-calls
  if (lastAssistant?.finish && !["tool-calls", "unknown"].includes(lastAssistant.finish)
      && lastUser.id < lastAssistant.id) {
    break
  }

  // 3. 处理待办任务（按优先级）
  const task = tasks.pop()

  // 3a. 子任务（subtask）—— 优先级最高
  if (task?.type === "subtask") {
    // 执行子任务工具...
    continue
  }

  // 3b. 待处理的压缩请求 —— 第二优先级
  if (task?.type === "compaction") {
    const result = await SessionCompaction.process({...})
    continue
  }

  // 3c. 上下文溢出检测 —— 自动触发压缩
  if (lastFinished && await SessionCompaction.isOverflow({...})) {
    await SessionCompaction.create({...})  // 创建压缩请求
    continue                                // 下一轮会处理这个压缩
  }

  // 4. 正常处理：调用 LLM
  const result = await processor.process({...})
  if (result === "stop") break
  if (result === "compact") {
    await SessionCompaction.create({...})  // processor 也可以触发压缩
  }
}

// loop 退出后执行一次修剪
SessionCompaction.prune({ sessionID })
```

**设计思路**：

压缩请求被设计成了一个"任务"（CompactionPart），和子任务（SubtaskPart）共用同一套处理框架。它不是在 loop 外面一次性完成的，而是在 loop 内部作为一个特殊步骤处理。这样做的好处是：
- 压缩操作也可以被中断（通过 abort）
- 压缩失败时 loop 可以继续正常工作
- 压缩和正常对话使用同一套流式处理基础设施

---

## 十、完整的消息生命周期图

```
用户输入
  │
  ▼
┌─────────────────────────────────┐
│ createUserMessage()             │
│  ├─ 识别 @file → 调用 Read 工具  │
│  ├─ 识别 @agent → 注入 Agent 指令│
│  └─ 存储 User Message + Parts   │
└────────────┬────────────────────┘
             │
             ▼
┌─────────────────────────────────┐
│ loop() - 每轮迭代              │
│  │                              │
│  ├─① filterCompacted()         │ ← 在压缩点截断历史
│  │    读取消息流，找到最新压缩点  │
│  │                              │
│  ├─② 检查待办：subtask?        │ → 执行子任务
│  │              compaction?     │ → 执行压缩
│  │              overflow?       │ → 创建压缩请求
│  │                              │
│  ├─③ insertReminders()         │ ← 包装用户中途消息
│  │                              │
│  ├─④ toModelMessages()         │ ← 内部格式 → LLM 格式
│  │    已修剪的工具输出 → 占位符   │
│  │    未完成的工具调用 → 错误标记  │
│  │                              │
│  ├─⑤ LLM.stream()              │ ← 系统提示 + 历史 → LLM
│  │    系统提示 = Agent指令       │
│  │              + 环境信息       │
│  │              + 用户自定义指令  │
│  │                              │
│  └─⑥ processor.process()       │ ← 处理流式响应
│       text-delta → 累积文本      │
│       tool-call → 执行工具       │
│       finish-step → token统计    │
│                  → 溢出检测      │
│                                  │
│  结果 = continue → 下一轮       │
│       = stop → 退出 loop        │
│       = compact → 创建压缩请求   │
└────────────┬────────────────────┘
             │
             ▼
┌─────────────────────────────────┐
│ loop 退出后                     │
│  └─ prune() 修剪旧工具输出      │
└─────────────────────────────────┘
```

---

## 十一、设计哲学总结

### 11.1 核心设计原则

| 原则 | 体现 |
|------|------|
| **标记而非删除** | 修剪只打 `compacted` 标记，不真正删除数据 |
| **惰性处理** | 压缩不在 loop 外一次完成，而是作为 loop 的一个步骤 |
| **渐进式降级** | 先截断 → 再修剪 → 最后摘要，三级防线 |
| **透明伪装** | 压缩操作被伪装成正常对话（"What did we do so far?"） |
| **缓存友好** | 系统提示词保持两段结构，静态部分可被 API 缓存 |

### 11.2 三级上下文管理策略

```
第一级：工具输出截断（Truncate）
  ├─ 时机：工具执行完毕时
  ├─ 阈值：2000 行 / 50KB
  ├─ 效果：单次输出不会太大
  └─ 代价：完整输出存磁盘，LLM 可通过工具读取

第二级：旧工具输出修剪（Prune）
  ├─ 时机：loop 退出后
  ├─ 策略：保护最近 4 万 token，修剪更早的
  ├─ 效果：修剪 Part 的输出字段被清空
  └─ 代价：LLM 知道有过工具调用但看不到结果

第三级：上下文摘要压缩（Compaction）
  ├─ 时机：token 总量超过模型可用限制
  ├─ 策略：用 LLM 生成摘要替代全部历史
  ├─ 效果：上下文大幅缩小
  └─ 代价：一次额外的 LLM 调用 + 信息不可避免地损失
```

### 11.3 优点与不足

**优点**=

1. **信息保全好**：三级策略从轻到重，尽量保留更多信息
2. **用户无感**：压缩是自动的，对用户透明
3. **架构简洁**：压缩流程复用了正常 loop 的基础设施（同一个 processor、同一套存储）
4. **可回溯**：原始数据没有被删除，理论上可以恢复
5. **可配置**：用户可以通过 `config.compaction.auto` 和 `config.compaction.prune` 关闭自动压缩/修剪

**不足**：

1. **token 估算粗糙**：使用固定的 4 字符/token 比率，中文实际约 1-2 字符/token，会严重低估
2. **修剪策略不区分重要程度**：所有工具输出一律按时间先后修剪，不考虑内容是否仍被引用
3. **压缩提示词固定**：默认摘要提示不针对不同任务场景做优化
4. **每轮都要全量扫描**：`filterCompacted()` 每次都从头遍历消息流找压缩点
5. **Prune 只在 loop 退出后执行**：如果一个很长的 loop 中间上下文就溢出了，Prune 帮不上忙，只能等 Compaction

---

## 参考文件索引

| 文件 | 路径 | 核心职责 |
|------|------|---------|
| prompt.ts | `packages/opencode/src/session/prompt.ts` | Loop 主循环、用户消息创建、消息注入 |
| llm.ts | `packages/opencode/src/session/llm.ts` | 系统提示组装、LLM 流式调用 |
| processor.ts | `packages/opencode/src/session/processor.ts` | 流式响应处理、溢出检测 |
| message-v2.ts | `packages/opencode/src/session/message-v2.ts` | 消息/Part 定义、格式转换、压缩过滤 |
| compaction.ts | `packages/opencode/src/session/compaction.ts` | 修剪（Prune）、摘要压缩（Compact） |
| truncation.ts | `packages/opencode/src/tool/truncation.ts` | 工具输出截断 |
| token.ts | `packages/opencode/src/util/token.ts` | Token 估算 |
| system.ts | `packages/opencode/src/session/system.ts` | 环境信息系统提示 |
| instruction.ts | `packages/opencode/src/session/instruction.ts` | 用户自定义指令加载 |
