# OpenCode Loop 历史消息处理机制深度解析

本文深入分析 OpenCode 任务循环中历史消息的处理方式，包括消息收集、转换、压缩和裁剪等核心机制，揭示其设计思想与权衡。

---

## 一、整体架构概览

OpenCode 采用**消息驱动架构**——系统没有独立的状态机，所有状态都存储在消息历史中。整个交互流程围绕一个核心 `while(true)` 循环展开。

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           主循环 (loop 函数)                              │
│                    packages/opencode/src/session/prompt.ts               │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│   while (true) {                                                        │
│     1. 获取消息历史 ───────► MessageV2.filterCompacted()                  │
│     2. 检查完成条件 ───────► 分析 lastUser/lastAssistant/lastFinished     │
│     3. 处理子任务 ─────────► SubtaskPart 处理                            │
│     4. 处理上下文压缩 ─────► CompactionPart 处理                         │
│     5. 正常处理流程 ───────► SessionProcessor.process                    │
│   }                                                                     │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                      消息转换层 (toModelMessages)                         │
│                    packages/opencode/src/session/message-v2.ts           │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│   内部 Part 格式 ──────► AI SDK ModelMessage 格式                        │
│                                                                         │
│   • text ─────────────► text message                                    │
│   • file ─────────────► file message (二进制文件)                         │
│   • tool ─────────────► tool-call / tool-result                         │
│   • compaction ───────► "What did we do so far?"                        │
│   • subtask ──────────► "The following tool was executed..."            │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 二、消息历史获取：filterCompacted

### 2.1 核心问题

长对话会积累大量消息，直接全部发给 AI 会导致：
1. **超出上下文限制**——每个模型都有 token 上限
2. **信息过载**——AI 注意力分散，难以定位关键信息
3. **成本激增**——长上下文意味着更高的 API 费用

### 2.2 解决方案：压缩点机制

OpenCode 使用**压缩点（Compaction Point）**来截断历史消息，只保留有效上下文。

**关键代码**（message-v2.ts:642-657）：

```typescript
export async function filterCompacted(stream: AsyncIterable<MessageV2.WithParts>) {
  const result: MessageV2.WithParts[] = []
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

    // 标记已完成的 summary assistant message
    if (msg.info.role === "assistant" && msg.info.summary && msg.info.finish)
      completed.add(msg.info.parentID)
  }

  result.reverse()
  return result
}
```

### 2.3 工作原理图解

```
原始消息历史（从新到旧）:
┌─────┐   ┌─────┐   ┌───────────┐   ┌─────┐   ┌─────┐   ┌─────┐
│msg6 │ → │msg5 │ → │msg4(com.) │ → │msg3 │ → │msg2 │ → │msg1 │
└─────┘   └─────┘   └───────────┘   └─────┘   └─────┘   └─────┘
  │         │            │
  │         │            └─ 包含 CompactionPart，标记 parentID=msg3
  │         │
  │         └─ 遍历到这里，发现 msg3 在 completed 集合中，且包含 compaction
  │            停止遍历
  │
  └─ 保留的消息

filterCompacted 后:
┌─────┐   ┌─────┐
│msg6 │   │msg5 │
└─────┘   └─────┘
  (只保留 compaction 点之后的消息)
```

**设计思想**：
- **压缩点是逻辑边界**——每次压缩都会创建一个"总结消息"，之前的详细对话被摘要替代
- **单向遍历即截止**——从新消息往旧消息遍历，遇到压缩点就停止，保证 O(n) 复杂度
- **状态自包含**——无需外部状态，仅凭消息内容即可判断哪些该保留

**优点**：
1. **自动管理**——无需用户手动清理历史
2. **保持连贯**——保留最近对话，确保上下文连贯
3. **节省 token**——旧消息被摘要替代，大幅减少 token 消耗

**缺点**：
1. **信息丢失**——压缩过程中可能丢失细节
2. **无法回滚**——压缩后的消息无法恢复到原始状态
3. **延迟累积**——每次都要遍历所有消息，长会话性能下降

---

## 三、消息转换：toModelMessages

获取到过滤后的消息后，需要转换为 AI SDK 需要的格式。

### 3.1 转换规则

**关键代码**（message-v2.ts:436-607）：

```typescript
export function toModelMessages(input: WithParts[], model: Provider.Model): ModelMessage[] {
  for (const msg of input) {
    if (msg.info.role === "user") {
      // 用户消息处理
      for (const part of msg.parts) {
        if (part.type === "text" && !part.ignored)
          userMessage.parts.push({ type: "text", text: part.text })

        if (part.type === "file" && part.mime !== "text/plain")
          userMessage.parts.push({
            type: "file",
            url: part.url,
            mediaType: part.mime,
            filename: part.filename,
          })

        // compaction 转换为特殊提示
        if (part.type === "compaction")
          userMessage.parts.push({
            type: "text",
            text: "What did we do so far?",
          })

        // subtask 转换为工具执行提示
        if (part.type === "subtask")
          userMessage.parts.push({
            type: "text",
            text: "The following tool was executed by the user",
          })
      }
    }

    if (msg.info.role === "assistant") {
      // AI 消息处理
      for (const part of msg.parts) {
        if (part.type === "text")
          assistantMessage.parts.push({ type: "text", text: part.text })

        if (part.type === "tool") {
          if (part.state.status === "completed") {
            // 关键：被裁剪的工具结果显示占位符
            const outputText = part.state.time.compacted
              ? "[Old tool result content cleared]"
              : part.state.output

            assistantMessage.parts.push({
              type: "tool-" + part.tool,
              state: "output-available",
              toolCallId: part.callID,
              input: part.state.input,
              output: outputText,
            })
          }

          // 未完成的中断工具调用
          if (part.state.status === "pending" || part.state.status === "running")
            assistantMessage.parts.push({
              type: "tool-" + part.tool,
              state: "output-error",
              toolCallId: part.callID,
              errorText: "[Tool execution was interrupted]",
            })
        }
      }
    }
  }
}
```

### 3.2 转换逻辑详解

| 内部 Part 类型 | 转换后 | 说明 |
|--------------|--------|------|
| `text` (用户) | text message | 普通文本消息 |
| `file` (非纯文本) | file message | 图片、PDF 等二进制文件 |
| `compaction` | "What did we do so far?" | 触发压缩代理生成总结 |
| `subtask` | 工具执行描述 | 告知 AI 这是一个子任务结果 |
| `text` (AI) | text message | AI 的回复内容 |
| `tool` (completed) | tool-result | 工具执行结果 |
| `tool` (error) | tool-result with error | 错误信息 |
| `tool` (pending/running) | tool-result with interrupt | 中断标记 |
| `reasoning` | reasoning | 思考过程 |

**为什么要这样设计？**

1. **透明化原则**：让 AI 清楚知道"发生了什么"
   - compaction 变成 "What did we do so far?" —— 明确告诉 AI 这是历史总结
   - subtask 变成工具执行描述 —— AI 知道这是另一个代理的结果

2. **容错设计**：处理中断场景
   - 未完成的中断工具调用标记为 "[Tool execution was interrupted]"
   - 防止 Anthropic/Claude API 因缺少 tool_result 而报错

3. **裁剪感知**：被裁剪的工具结果显示占位符
   - 让 AI 知道"这里曾经有内容，但已被清理"
   - 避免 AI 误以为没有执行过该工具

---

## 四、上下文压缩：compaction.ts

### 4.1 触发条件

**关键代码**（compaction.ts:30-39）：

```typescript
export async function isOverflow(input: { tokens: MessageV2.Assistant["tokens"]; model: Provider.Model }) {
  const config = await Config.get()
  if (config.compaction?.auto === false) return false

  const context = input.model.limit.context
  if (context === 0) return false

  const count = input.tokens.input + input.tokens.cache.read + input.tokens.output
  const output = Math.min(input.model.limit.output, SessionPrompt.OUTPUT_TOKEN_MAX)
  const usable = input.model.limit.input || context - output

  return count > usable  // 超过可用上下文空间
}
```

**触发逻辑**：
```
当前 token 数 > (上下文上限 - 输出预留) ?
├─ 是 → 触发压缩
└─ 否 → 继续正常处理
```

### 4.2 压缩流程

**关键代码**（compaction.ts:92-193）：

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

### 4.3 压缩过程图解

```
压缩前：
┌─────────┐   ┌─────────┐   ┌─────────┐   ┌─────────┐   ┌─────────┐
│ User:   │   │ AI:     │   │ AI:     │   │ User:   │   │ AI:     │
│ "帮我修  │   │ "我看   │   │ "调用   │   │ "还有   │   │ "我再   │
│  bug"   │   │ 看代码" │   │ Read"   │   │ 这个问题"│   │ 看看"   │
└─────────┘   └─────────┘   └─────────┘   └─────────┘   └─────────┘
     │             │             │             │             │
     └─────────────┴─────────────┘             └─────────────┘
           (大量详细对话)                          (当前轮)

压缩后：
┌─────────────────────────────────────┐   ┌─────────┐   ┌─────────┐
│ Compaction Summary:                 │   │ User:   │   │ AI:     │
│ "用户要求修复 bug，我们已经定位到    │   │ "还有   │   │ "我再   │
│  问题在 auth.ts 第 42 行，正在分析   │   │ 这个问题"│   │ 看看"   │
│  根本原因..."                        │   └─────────┘   └─────────┘
└─────────────────────────────────────┘
        (摘要替代详细对话)

filterCompacted 后的效果：
┌─────────┐   ┌─────────┐
│ User:   │   │ AI:     │
│ "还有   │   │ "我再   │
│ 这个问题"│   │ 看看"   │
└─────────┘   └─────────┘
```

**设计思想**：
- **专门代理负责**：使用 `compaction` 代理（无工具权限，纯文本生成）来生成总结
- **渐进式压缩**：不是一次性清理所有历史，而是逐步压缩
- **保留上下文窗口**：确保模型始终有足够的空间处理当前任务

**优点**：
1. **智能总结**：由 AI 生成摘要，保留关键信息
2. **自动触发**：无需用户干预
3. **可配置**：用户可关闭自动压缩

**缺点**：
1. **额外成本**：压缩本身需要调用 LLM，产生额外费用
2. **信息损失**：摘要无法 100% 保留原始信息
3. **延迟增加**：压缩过程会阻塞主循环

---

## 五、工具结果裁剪：prune

除了主动压缩，OpenCode 还会自动"遗忘"旧的工具输出。

### 5.1 裁剪策略

**关键代码**（compaction.ts:41-90）：

```typescript
export const PRUNE_MINIMUM = 20_000   // 最少裁剪 token 数
export const PRUNE_PROTECT = 40_000   // 保护最近 40k token

const PRUNE_PROTECTED_TOOLS = ["skill"]  // 保护 skill 工具结果

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
    if (turns < 2) continue  // 保护最近 2 轮
    if (msg.info.role === "assistant" && msg.info.summary) break loop

    for (let partIndex = msg.parts.length - 1; partIndex >= 0; partIndex--) {
      const part = msg.parts[partIndex]
      if (part.type === "tool" && part.state.status === "completed") {
        if (PRUNE_PROTECTED_TOOLS.includes(part.tool)) continue

        if (part.state.time.compacted) break loop
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

### 5.2 裁剪策略图解

```
工具结果历史（从新到旧）：
┌──────────┐   ┌──────────┐   ┌──────────┐   ┌──────────┐   ┌──────────┐
│ Tool 5   │   │ Tool 4   │   │ Tool 3   │   │ Tool 2   │   │ Tool 1   │
│ Read     │   │ Bash     │   │ Read     │   │ Grep     │   │ Read     │
│ 5k tok   │   │ 2k tok   │   │ 50k tok  │   │ 1k tok   │   │ 10k tok  │
└──────────┘   └──────────┘   └──────────┘   └──────────┘   └──────────┘
     │              │              │              │              │
     │              │              │              │              │
     └──────────────┴──────────────┘              │              │
          保护区域 (最近 2 轮 + 40k token)         │              │
                                                  │              │
     ┌────────────────────────────────────────────┘              │
     │         裁剪区域 (超过 40k 的部分)                         │
     │                                                           │
     ▼                                                           ▼
┌──────────┐                                            ┌──────────┐
│ Tool 3   │ ──► 标记 compacted=true                     │ Tool 1   │ ──► 标记 compacted=true
│ 显示为   │     显示 "[Old tool result content cleared]"  │ 显示为   │     显示 "[Old tool result content cleared]"
│ [Old...] │                                            │ [Old...] │
└──────────┘                                            └──────────┘
```

**裁剪规则**：
1. **保护最近 2 轮对话**——确保当前上下文连贯
2. **保护最近 40k token**——保留相对新鲜的工具结果
3. **保护 skill 工具**——重要工具结果永不被裁剪
4. **标记而非删除**——通过 `compacted` 时间戳标记，可追踪

**优点**：
1. **渐进式清理**——不影响当前对话
2. **细粒度控制**——按工具类型保护关键结果
3. **可逆性**——标记方式保留了元数据

**缺点**：
1. **无法完全恢复**——被裁剪的内容无法自动还原
2. **估算不准确**——使用启发式估算而非精确 token 计数
3. **可能误裁**——无法判断工具结果的重要性

---

## 六、系统提示词组装

### 6.1 多层组装策略

**关键代码**（llm.ts:69-99）：

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

### 6.2 分层结构

```
系统提示词层次：
┌─────────────────────────────────────────────────────────────┐
│ 第一层：基础身份提示                                         │
│ • Claude: "You are OpenCode, the best coding agent..."      │
│ • GPT: "You are opencode, an agent - please keep going..."  │
│ • Gemini: Google 模型特定优化                                │
├─────────────────────────────────────────────────────────────┤
│ 第二层：环境信息                                             │
│ • 工作目录                                                  │
│ • Git 状态                                                  │
│ • 操作系统                                                  │
│ • 当前日期                                                  │
├─────────────────────────────────────────────────────────────┤
│ 第三层：代理特定提示                                         │
│ • Plan 模式: "You are in plan mode. You MUST NOT..."        │
│ • Build 模式: 完整工具权限                                   │
│ • Explore 代理: 只读权限                                     │
├─────────────────────────────────────────────────────────────┤
│ 第四层：用户自定义提示                                       │
│ • 配置文件中的 system prompt                                │
│ • 单次消息中的 system 字段                                  │
├─────────────────────────────────────────────────────────────┤
│ 第五层：动态提醒（非系统提示，插入到用户消息）                │
│ • Plan/Build 切换提醒                                        │
│ • 后续消息包装                                              │
└─────────────────────────────────────────────────────────────┘
```

### 6.3 动态提醒插入

**关键代码**（prompt.ts:1198-1336）：

```typescript
async function insertReminders(input: { messages: MessageV2.WithParts[]; agent: Agent.Info; session: Session.Info }) {
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
}
```

**为什么要这样设计？**

1. **分层组装**：不同来源的提示词职责清晰，便于调试
2. **插件扩展点**：`experimental.chat.system.transform` 允许插件修改系统提示
3. **动态提醒**：将模式切换提醒插入到用户消息中，比修改系统提示更灵活

---

## 七、关键设计思想总结

### 7.1 消息即状态

**核心理念**：所有状态都存储在消息历史中，没有独立的状态机。

```
状态 = 初始状态 + 消息历史
```

**优点**：
- **可追溯**——完整的操作日志
- **可分叉**——随时从任意点 fork 新会话
- **可恢复**——系统重启后状态不丢失
- **分布式友好**——多台机器可以共享同一个会话

**缺点**：
- **消息膨胀**——长会话查询性能下降
- **状态推断复杂**——需要遍历消息来推断当前状态
- **存储开销**——大量消息和文件内容占用空间

### 7.2 分层上下文管理

OpenCode 不是简单地截断历史，而是采用分层策略：

| 层级     | 策略                         | 目的     |
| ------ | -------------------------- | ------ |
| **保留** | 最近 2 轮完整对话                 | 保证连贯性  |
| **总结** | 较旧的对话用 compaction 压缩成摘要    | 保留关键信息 |
| **裁剪** | 工具结果只保留最近 40k tokens 的详细内容 | 节省空间   |
| **丢弃** | 更早的工具结果只保留占位符              | 极限压缩   |

### 7.3 流式处理与实时更新

**设计原则**：不等待 AI 完全"想完"，而是实时处理流式响应。

**事件类型处理**：
```
text-start/delta/end     → 实时显示文本
reasoning-start/delta/end → 显示思考过程
tool-input-start/call    → 创建工具调用记录
tool-result/error        → 更新工具状态
start-step/finish-step   → 跟踪步骤，检测溢出
```

**优点**：
- 用户体验好——不用等，实时反馈
- 可中断——节省 token
- 错误隔离——单个工具失败不影响整体

**缺点**：
- 实现复杂——需要处理各种事件类型
- 状态管理难——需要跟踪多个并发工具调用
- 错误恢复难——流中途出错可能丢失数据

### 7.4 权限与安全

**最小权限原则**：每个 Agent 只拥有完成其任务所需的最小权限。

| Agent | 权限特点 | 用途 |
|-------|---------|------|
| build | 完整读写权限 | 默认开发模式 |
| plan | 只读权限（不能 edit） | 规划阶段 |
| explore | 只能 grep/read/list | 代码库探索 |
| compaction | 无工具权限 | 纯总结生成 |

---

## 八、参考代码位置

| 功能 | 文件路径 | 关键函数/行 |
|-----|---------|-----------|
| 主循环 | `packages/opencode/src/session/prompt.ts` | `loop()` 第 259 行 |
| 消息过滤 | `packages/opencode/src/session/message-v2.ts` | `filterCompacted()` 第 642 行 |
| 消息转换 | `packages/opencode/src/session/message-v2.ts` | `toModelMessages()` 第 436 行 |
| 上下文压缩 | `packages/opencode/src/session/compaction.ts` | `process()` 第 92 行 |
| 工具裁剪 | `packages/opencode/src/session/compaction.ts` | `prune()` 第 49 行 |
| 溢出检测 | `packages/opencode/src/session/compaction.ts` | `isOverflow()` 第 30 行 |
| 流处理 | `packages/opencode/src/session/processor.ts` | `process()` 第 45 行 |
| LLM 调用 | `packages/opencode/src/session/llm.ts` | `stream()` 第 48 行 |
| 系统提示 | `packages/opencode/src/session/system.ts` | `provider()` |

---

## 九、总结

OpenCode 的历史消息处理机制是一个精心设计的**分层压缩系统**：

1. **filterCompacted** —— 通过压缩点截断历史，只保留有效上下文
2. **toModelMessages** —— 统一转换格式，处理各种边界情况
3. **compaction** —— 使用专门代理生成摘要，释放上下文空间
4. **prune** —— 自动裁剪旧工具结果，渐进式清理

**核心设计哲学**：
- **透明化**：让 AI 清楚知道"发生了什么"和"曾经有什么"
- **渐进式**：不是一次性清理，而是逐步压缩
- **可恢复**：消息驱动架构支持随时分叉和恢复
- **安全优先**：敏感操作必须用户确认

这个机制的代价是复杂性较高，但换来了极大的灵活性和可控性。

---

*基于 OpenCode v1.1.36 代码分析*
*生成时间：2026-01-29*
