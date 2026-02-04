# OpenCode 主循环与上下文管理详解

> 本报告深入分析 OpenCode 的主循环（loop）机制和历史消息处理策略，包括消息压缩、上下文管理等核心设计。

---

## 一、主循环架构概览

### 1.1 循环结构

OpenCode 的主循环位于 `prompt.ts:259` 的 `loop` 函数中，这是一个**单次会话独占**的循环设计：

```typescript
export const loop = fn(Identifier.schema("session"), async (sessionID) => {
    const abort = start(sessionID)  // 获取或创建 AbortController
    if (!abort) {
        // 如果会话正在运行，将回调加入队列等待
        return new Promise<MessageV2.WithParts>((resolve, reject) => {
            const callbacks = state()[sessionID].callbacks
            callbacks.push({ resolve, reject })
        })
    }

    using _ = defer(() => cancel(sessionID))
    let step = 0

    while (true) {
        // ... 处理逻辑
        step++
        // ...
    }
})
```

**设计思想**：同一会话同时只能有一个 loop 在运行，防止并发导致的状态混乱。

### 1.2 循环的退出条件

```typescript
// prompt.ts:296-302
if (
    lastAssistant?.finish &&
    !["tool-calls", "unknown"].includes(lastAssistant.finish) &&
    lastUser.id < lastAssistant.id
) {
    log.info("exiting loop", { sessionID })
    break
}
```

**退出的条件**：
1. 最后一条 assistant 消息已完成（有 finish 状态）
2. finish 原因不是 `tool-calls` 或 `unknown`（即模型不需要继续调用工具）
3. 最后的用户消息早于该 assistant 消息（正常对话顺序）

---

## 二、消息模型与数据流

### 2.1 三层消息结构

```
Session (会话)
    └── Message (消息)
            └── Part (内容片段)
```

**Part 类型**：
- `text` - 文本内容
- `tool` - 工具调用
- `reasoning` - 推理过程（如 o1 的 thinking）
- `file` - 文件附件（图片、PDF 等）
- `compaction` - 压缩标记
- `subtask` - 子任务
- `step-start/step-finish` - 步骤边界
- `snapshot/patch` - 文件快照

### 2.2 消息持久化策略

消息按**增量方式**存储：

```typescript
// message-v2.ts:373-379
export const updatePart = fn(UpdatePartInput, async (input) => {
    const part = "delta" in input ? input.part : input
    const delta = "delta" in input ? input.delta : undefined
    await Storage.write(["part", part.messageID, part.id], part)
    Bus.publish(MessageV2.Event.PartUpdated, { part, delta })
    return part
})
```

**设计亮点**：
- 支持流式更新：`delta` 参数允许只传输变化的部分
- 事件驱动：每次更新都发布事件，UI 可实时响应

---

## 三、历史消息加载与过滤

### 3.1 filterCompacted：消息过滤机制

```typescript
// message-v2.ts:642-657
export async function filterCompacted(stream: AsyncIterable<MessageV2.WithParts>) {
    const result = [] as MessageV2.WithParts[]
    const completed = new Set<string>()

    for await (const msg of stream) {
        result.push(msg)

        // 遇到压缩点，停止继续往前加载
        if (
            msg.info.role === "user" &&
            completed.has(msg.info.id) &&
            msg.parts.some((part) => part.type === "compaction")
        ) break

        // 标记已压缩的 assistant 消息
        if (msg.info.role === "assistant" && msg.info.summary && msg.info.finish)
            completed.add(msg.info.parentID)
    }

    result.reverse()
    return result
}
```

**设计思想**：
- **压缩点作为分界线**：遇到 `compaction` 类型的 part 时停止加载更早的消息
- **summary 标记**：带有 `summary: true` 的 assistant 消息表示它是一个压缩摘要

### 3.2 消息转换：toModelMessages

将内部消息格式转换为 LLM API 格式：

```typescript
// message-v2.ts:436-607 (简化版)
export function toModelMessages(input: WithParts[], model: Provider.Model): ModelMessage[] {
    const result: UIMessage[] = []
    const toolNames = new Set<string>()

    for (const msg of input) {
        if (msg.parts.length === 0) continue

        if (msg.info.role === "user") {
            // 处理用户消息
            for (const part of msg.parts) {
                if (part.type === "text" && !part.ignored)
                    userMessage.parts.push({ type: "text", text: part.text })
                // ... 处理文件、compaction、subtask 等
            }
        }

        if (msg.info.role === "assistant") {
            // 处理助手消息
            for (const part of msg.parts) {
                if (part.type === "tool") {
                    // 关键：已压缩的工具输出会被替换为占位符
                    const outputText = part.state.time.compacted
                        ? "[Old tool result content cleared]"
                        : part.state.output
                    // ...
                }
            }
        }
    }

    return convertToModelMessages(result, { tools })
}
```

**关键处理**：
- **压缩标记处理**：`part.state.time.compacted` 存在时，工具输出被替换为 `[Old tool result content cleared]`
- **消息过滤**：跳过空消息、错误消息（除非是中断错误）

---

## 四、消息压缩策略

OpenCode 使用**两种互补的压缩策略**：

### 4.1 策略一：Prune（修剪）- 轻量级清理

**触发时机**：每次 loop 结束后自动执行

```typescript
// compaction.ts:49-90
export async function prune(input: { sessionID: string }) {
    const msgs = await Session.messages({ sessionID: input.sessionID })
    let total = 0
    const toPrune = []

    // 从后往前遍历，保留最近 2 轮对话
    loop: for (let msgIndex = msgs.length - 1; msgIndex >= 0; msgIndex--) {
        const msg = msgs[msgIndex]
        if (msg.info.role === "user") turns++
        if (turns < 2) continue  // 保留最近 2 轮
        if (msg.info.role === "assistant" && msg.info.summary) break

        for (const part of msg.parts) {
            if (part.type === "tool" && part.state.status === "completed") {
                if (PRUNE_PROTECTED_TOOLS.includes(part.tool)) continue  // 跳过 skill 等保护工具

                if (part.state.time.compacted) break loop  // 已经压缩过，停止
                const estimate = Token.estimate(part.state.output)
                total += estimate

                // 累积超过 PRUNE_PROTECT (40k) tokens 后开始标记
                if (total > PRUNE_PROTECT) {
                    toPrune.push(part)
                }
            }
        }
    }

    // 只有待清理量超过 PRUNE_MINIMUM (20k) 才执行
    if (pruned > PRUNE_MINIMUM) {
        for (const part of toPrune) {
            part.state.time.compacted = Date.now()
            await Session.updatePart(part)
        }
    }
}
```

**设计思想**：
| 参数 | 值 | 作用 |
|------|-----|------|
| `PRUNE_PROTECT` | 40,000 tokens | 保留最近 40k tokens 的工具输出 |
| `PRUNE_MINIMUM` | 20,000 tokens | 只有超过 20k 才执行清理，避免频繁操作 |
| `PRUNE_PROTECTED_TOOLS` | `["skill"]` | 某些工具的输出不清理 |

**优点**：
- 低成本：只是标记一个时间戳，不需要 LLM 调用
- 保留结构：工具调用本身保留，只是输出被替换
- 可逆：理论上可以保留原始输出（虽然当前实现没有）

**缺点**：
- 丢失细节：工具输出被占位符替换，模型无法知道具体结果
- 粗粒度：基于 token 估算，可能不够精确

### 4.2 策略二：Compact（压缩）- LLM 摘要

**触发时机**：当 token 使用量超过模型上下文限制时

```typescript
// compaction.ts:30-38
export async function isOverflow(input: {
    tokens: MessageV2.Assistant["tokens"]
    model: Provider.Model
}) {
    const config = await Config.get()
    if (config.compaction?.auto === false) return false

    const context = input.model.limit.context
    if (context === 0) return false

    const count = input.tokens.input + input.tokens.cache.read + input.tokens.output
    const output = Math.min(input.model.limit.output, SessionPrompt.OUTPUT_TOKEN_MAX)
    const usable = input.model.limit.input || context - output

    return count > usable
}
```

**压缩过程**：

```typescript
// compaction.ts:92-193
export async function process(input: {
    parentID: string
    messages: MessageV2.WithParts[]
    sessionID: string
    abort: AbortSignal
    auto: boolean
}) {
    // 1. 创建一个特殊的 assistant 消息用于存储摘要
    const msg = await Session.updateMessage({
        role: "assistant",
        mode: "compaction",
        agent: "compaction",
        summary: true,  // 标记为摘要消息
        // ...
    })

    // 2. 构建压缩提示词
    const defaultPrompt =
        "Provide a detailed prompt for continuing our conversation above. " +
        "Focus on information that would be helpful for continuing the conversation, " +
        "including what we did, what we're doing, which files we're working on, " +
        "and what we're going to do next considering new session will not have " +
        "access to our conversation."

    // 3. 调用 LLM 生成摘要
    const result = await processor.process({
        messages: [
            ...MessageV2.toModelMessages(input.messages, model),
            { role: "user", content: [{ type: "text", text: promptText }] }
        ],
        tools: {},  // 压缩时不使用工具
        // ...
    })

    // 4. 可选：添加 "Continue if you have next steps" 消息
    if (result === "continue" && input.auto) {
        const continueMsg = await Session.updateMessage({
            role: "user",
            // ...
        })
        await Session.updatePart({
            type: "text",
            text: "Continue if you have next steps",
        })
    }

    return "continue"
}
```

**设计思想**：
- **用 LLM 总结 LLM**：让模型自己总结对话历史
- **聚焦未来**：提示词强调"对继续对话有帮助的信息"
- **自动延续**：如果检测到还有未完成的工作，自动添加继续提示

**优点**：
- 语义保留：摘要保留关键上下文，模型理解更准确
- 高压缩率：大量历史被压缩成一段摘要

**缺点**：
- 额外成本：需要一次额外的 LLM 调用
- 信息损失：细节可能被摘要遗漏
- 延迟增加：用户需要等待压缩完成

---

## 五、系统提示词构建

### 5.1 多层提示词合并

```typescript
// llm.ts:69-99
const system = []
system.push([
    // 1. Agent prompt 或 Provider prompt
    ...(input.agent.prompt ? [input.agent.prompt] : isCodex ? [] : SystemPrompt.provider(input.model)),
    // 2. 自定义 prompt
    ...input.system,
    // 3. 用户消息中的 system
    ...(input.user.system ? [input.user.system] : []),
].filter((x) => x).join("\n"))
```

**提示词来源优先级**：
1. **Agent prompt**：Agent 定义时指定的 prompt
2. **Provider prompt**：从 Provider 加载的默认系统提示
3. **调用时传入的 system**：如环境变量、目录上下文
4. **用户消息中的 system**：用户指定的自定义系统提示

### 5.2 提示词缓存优化

```typescript
// llm.ts:86-98
const header = system[0]
const original = clone(system)

// 允许插件修改
await Plugin.trigger("experimental.chat.system.transform", { ... }, { system })

// 保持两段结构以支持缓存
if (system.length > 2 && system[0] === header) {
    const rest = system.slice(1)
    system.length = 0
    system.push(header, rest.join("\n"))
}
```

**设计思想**：保持 `header + body` 的两段结构，便于某些 Provider 实现缓存（如 Anthropic 的缓存系统）。

---

## 六、流式处理与增量更新

### 6.1 流式事件处理

```typescript
// processor.ts:55-336 (核心循环)
for await (const value of stream.fullStream) {
    switch (value.type) {
        case "text-delta":
            // 文本增量更新
            currentText.text += value.text
            await Session.updatePart({ part: currentText, delta: value.text })
            break

        case "tool-call":
            // 工具调用开始
            await Session.updatePart({
                type: "tool",
                tool: value.toolName,
                state: { status: "running", input: value.input }
            })
            break

        case "tool-result":
            // 工具执行完成
            await Session.updatePart({
                state: { status: "completed", output: value.output.output }
            })
            break

        case "finish-step":
            // 一步完成，检查是否需要压缩
            if (await SessionCompaction.isOverflow({ tokens: usage.tokens, model })) {
                needsCompaction = true
            }
            break
    }

    if (needsCompaction) break  // 退出当前循环，触发压缩
}
```

### 6.2 系统提醒插入

当有多条用户消息排队时，给后续消息添加包装：

```typescript
// prompt.ts:579-594
if (step > 1 && lastFinished) {
    for (const msg of sessionMessages) {
        if (msg.info.role !== "user" || msg.info.id <= lastFinished.id) continue
        for (const part of msg.parts) {
            if (part.type !== "text" || part.ignored || part.synthetic) continue
            if (!part.text.trim()) continue

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

**设计思想**：当用户在模型执行期间发送多条消息时，确保模型不会遗漏处理。

---

## 七、设计优缺点分析

### 7.1 整体架构优点

| 方面        | 优点                                           |
| --------- | -------------------------------------------- |
| **渐进式压缩** | Prune 先清理大量旧数据，Compact 作为最后手段                |
| **非破坏性**  | 压缩只标记 `compacted` 时间戳，消息结构完整保留               |
| **可配置**   | 支持通过 `config.compaction.auto = false` 禁用自动压缩 |
| **工具保护**  | `PRUNE_PROTECTED_TOOLS` 保护关键工具输出不被清理         |
| **缓存友好**  | 提示词保持两段结构，支持 Provider 级缓存                    |

### 7.2 整体架构缺点

| 方面 | 缺点 | 影响 |
|------|------|------|
| **Prune 粗粒度** | 基于字符数估算 token，误差可能较大 | 可能压缩不足或过度压缩 |
| **Compact 成本** | 需要 LLM 调用，增加延迟和费用 | 用户体验受影响 |
| **不可逆** | Prune 后工具输出无法恢复（虽然结构保留） | 无法回溯查看旧结果 |
| **复杂度高** | filterCompacted + toModelMessages + prune + compact 四层机制 | 调试困难 |

### 7.3 关键设计决策

**Q: 为什么不用滑动窗口（保留最近 N 条消息）？**

A: OpenCode 的场景中：
- 用户可能引用很久之前的代码或决策
- 工具调用结果可能包含关键上下文
- 简单滑动窗口会丢失重要信息

**Q: 为什么 Prune 是 40k 门槛？**

A: 这是一组权衡参数：
- `PRUNE_PROTECT = 40k`：保留足够上下文（约相当于 30k 文本 + token 差异）
- `PRUNE_MINIMUM = 20k`：避免频繁触发，减少写入开销

**Q: 为什么 Compact 时不使用工具？**

A: 压缩的目标是"总结历史"，不是"继续任务"：
- 避免压缩过程中触发更多工具调用
- 防止压缩任务无限递归

---

## 八、消息流程图

```
┌─────────────────────────────────────────────────────────────────┐
│                        Loop 主循环                               │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
                    ┌─────────────────┐
                    │ filterCompacted │ ◄── 从 Storage 加载消息
                    │   过滤历史消息   │      (遇到 compaction 标记停止)
                    └────────┬────────┘
                             │
                             ▼
                    ┌─────────────────┐
                    │ toModelMessages │ ◄── 转换为 LLM API 格式
                    │   消息格式转换   │      (compacted 的工具输出 → 占位符)
                    └────────┬────────┘
                             │
                             ▼
                    ┌─────────────────┐
                    │ LLM.stream      │ ◄── 调用 LLM，处理流式响应
                    │   流式对话处理   │
                    └────────┬────────┘
                             │
                ┌────────────┼────────────┐
                │            │            │
                ▼            ▼            ▼
          ┌─────────┐  ┌─────────┐  ┌──────────┐
          │ 文本增量 │  │工具调用  │  │ 步骤完成  │
          │ 更新 Part│  │执行工具  │  │finish-step│
          └────┬────┘  └────┬────┘  └─────┬────┘
               │            │             │
               └────────────┼─────────────┘
                            ▼
                 ┌──────────────────────┐
                 │ isOverflow?          │ ◄── 检查 token 是否超限
                 └──────────┬───────────┘
                            │
               ┌────────────┼────────────┐
               │            │            │
               ▼            ▼            ▼
         ┌─────────┐  ┌─────────┐  ┌─────────┐
         │ continue│  │ compact │  │  stop   │
         │继续循环  │  │触发压缩  │  │ 退出循环 │
         └─────────┘  └────┬────┘  └─────────┘
                           │
           ┌───────────────┼───────────────┐
           │               │               │
           ▼               ▼               ▼
    ┌─────────────┐ ┌─────────────┐ ┌─────────────┐
    │    prune    │ │   compact   │ │ 返回结果     │
    │  修剪旧输出  │ │  LLM 生成摘要│ │ (循环结束时)│
    └─────────────┘ └─────────────┘ └─────────────┘
```

---

## 九、核心代码位置索引

| 功能 | 文件 | 关键行数 |
|------|------|----------|
| 主循环 | `prompt.ts` | 259-640 |
| 消息过滤 | `message-v2.ts` | 642-657 |
| 消息转换 | `message-v2.ts` | 436-607 |
| Prune 修剪 | `compaction.ts` | 49-90 |
| Compact 压缩 | `compaction.ts` | 92-193 |
| 溢出检测 | `compaction.ts` | 30-38 |
| 流式处理 | `processor.ts` | 55-336 |
| 系统提示构建 | `llm.ts` | 69-99 |

---

## 十、总结

OpenCode 的主循环和上下文管理是一个**多层次、渐进式**的设计：

1. **消息过滤层**：`filterCompacted` 按压缩点截断历史
2. **消息转换层**：`toModelMessages` 处理格式转换和占位符替换
3. **轻量压缩层**：`prune` 修剪旧工具输出
4. **重量压缩层**：`compact` 用 LLM 生成摘要

这种设计在**性能、成本、用户体验**之间做了细致的平衡，是值得参考的 AI Agent 架构实践。

---

**参考资料：**
- [OpenCode GitHub 仓库](https://github.com/anomalyco/opencode)
- 本报告基于 OpenCode 源码分析，重点关注 `packages/opencode/src/session/` 目录
