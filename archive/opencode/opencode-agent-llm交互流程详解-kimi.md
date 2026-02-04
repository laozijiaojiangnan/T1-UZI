# OpenCode Agent 与 LLM 交互完整流程详解

本文档详细讲解从用户输入需求到 OpenCode 完成任务的完整流程，包括每一步的设计意图、优缺点分析。

---

## 整体流程概览

```
┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│  1. 输入接收  │ → │  2. 消息构造  │ → │  3. 代理选择  │ → │  4. 工具准备  │
└─────────────┘    └─────────────┘    └─────────────┘    └─────────────┘
                                                                ↓
┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│  8. 结果返回  │ ← │  7. 循环执行  │ ← │  6. 流式处理  │ ← │  5. LLM 请求 │
└─────────────┘    └─────────────┘    └─────────────┘    └─────────────┘
```

---

## 第一步：输入接收与初步处理

### 代码位置
`session/prompt.ts:152` - `prompt()` 函数

### 做了什么

当用户在终端输入需求（如"帮我重构这个函数"）后：

1. **创建 AbortController** - 用于后续取消操作
2. **调用 `createUserMessage()`** - 将用户输入转换为结构化的消息对象
3. **权限处理** - 将旧的 tools 格式转换为新的 permission 格式（向后兼容）
4. **进入主循环** - 调用 `loop()` 开始处理

```typescript
// 简化示意
export const prompt = fn(PromptInput, async (input) => {
  const session = await Session.get(input.sessionID)
  const message = await createUserMessage(input)  // 构造用户消息

  // 权限转换（兼容旧配置）
  const permissions: PermissionNext.Ruleset = []
  for (const [tool, enabled] of Object.entries(input.tools ?? {})) {
    permissions.push({ permission: tool, action: enabled ? "allow" : "deny", pattern: "*" })
  }

  return loop(input.sessionID)  // 进入主处理循环
})
```

### 为什么要这么做

- **统一消息格式**：无论用户输入是纯文本、文件引用（@file）还是代理调用（@agent），都转换为统一的 MessageV2 格式
- **权限前置**：在开始处理前就确定权限边界，避免中途出现权限冲突
- **支持取消**：通过 AbortController 实现用户随时中断操作

### 优点

1. **向后兼容**：旧版配置可以无缝迁移
2. **统一抽象**：所有输入类型都收敛到同一处理流程
3. **可中断**：用户随时可以取消长时间运行的任务

### 缺点

1. **前置开销**：即使简单查询也需要走完整个初始化流程
2. **权限粒度较粗**：基于 pattern 的权限匹配，复杂场景下可能不够灵活

---

## 第二步：用户消息构造

### 代码位置
`session/prompt.ts:827` - `createUserMessage()` 函数

### 做了什么

这一步非常精巧，处理各种输入类型的转换：

#### 1. 基础信息构造
```typescript
const info: MessageV2.Info = {
  id: input.messageID ?? Identifier.ascending("message"),
  role: "user",
  sessionID: input.sessionID,
  time: { created: Date.now() },
  agent: agent.name,
  model: input.model ?? agent.model ?? (await lastModel(input.sessionID)),
}
```

#### 2. 文件引用处理（@file）
- **普通文件**：读取内容，转换为 FilePart
- **目录**：调用 ListTool 列出目录内容
- **文本文件**：调用 ReadTool 读取内容，生成合成消息（"Called the Read tool..."）
- **MCP 资源**：从 MCP 服务器获取资源内容

#### 3. 代理引用处理（@agent）
当用户输入 `@explore 搜索所有 API 端点` 时：
- 创建 AgentPart 标记引用的代理
- **自动生成提示词**：附加一段合成文本，指示 LLM 调用 task 工具并指定 subagent

```typescript
if (part.type === "agent") {
  return [
    { type: "agent", name: part.name, ... },
    {
      type: "text",
      synthetic: true,
      text: " Use the above message and context to generate a prompt and call the task tool with subagent: " + part.name
    }
  ]
}
```

#### 4. 插件钩子触发
```typescript
await Plugin.trigger("chat.message", { sessionID, agent, model }, { message: info, parts })
```

### 为什么要这么做

- **透明化文件操作**：让 LLM 知道哪些文件被读取了，便于追踪和调试
- **代理调用自动化**：用户只需 @agent，系统自动构造完整的工具调用指令
- **插件扩展点**：允许插件在消息创建时注入额外内容

### 优点

1. **用户友好**：@file 和 @agent 的语法非常直观
2. **可追溯**：每条消息都记录了完整的操作历史
3. **可扩展**：插件可以在消息层面修改内容

### 缺点

1. **隐式转换复杂**：文件读取的错误处理逻辑分散，维护成本高
2. **合成消息冗长**：大量"Called the Read tool..."消息可能干扰 LLM
3. **同步读取阻塞**：大文件读取会阻塞消息构造

---

## 第三步：主循环与上下文准备

### 代码位置
`session/prompt.ts:259` - `loop()` 函数

### 做了什么

这是整个交互流程的"心脏"，采用 **while(true)** 循环实现多轮对话：

#### 1. 消息历史检索
```typescript
let msgs = await MessageV2.filterCompacted(MessageV2.stream(sessionID))
```
- 获取会话中的所有消息
- **自动过滤已压缩消息**（compaction）节省上下文空间

#### 2. 查找关键消息
```typescript
for (let i = msgs.length - 1; i >= 0; i--) {
  const msg = msgs[i]
  if (!lastUser && msg.info.role === "user") lastUser = msg.info as MessageV2.User
  if (!lastAssistant && msg.info.role === "assistant") lastAssistant = msg.info as MessageV2.Assistant
  if (!lastFinished && msg.info.role === "assistant" && msg.info.finish) lastFinished = msg.info as MessageV2.Assistant
}
```

#### 3. 结束条件判断
```typescript
if (lastAssistant?.finish && !["tool-calls", "unknown"].includes(lastAssistant.finish) && lastUser.id < lastAssistant.id) {
  log.info("exiting loop", { sessionID })
  break
}
```
- 如果上一条助手消息已完成（非工具调用导致），且时间戳晚于用户消息，则结束循环

#### 4. 子任务处理（Subtask）
如果存在待处理的子任务（通过 Task 工具创建）：
- 创建专门的 Agent 执行子任务
- 子任务完成后生成合成用户消息继续主流程

#### 5. 上下文压缩检测
```typescript
if (lastFinished && lastFinished.summary !== true && (await SessionCompaction.isOverflow({ tokens: lastFinished.tokens, model }))) {
  await SessionCompaction.create({ sessionID, agent: lastUser.agent, model: lastUser.model, auto: true })
  continue
}
```
- 检测上下文是否溢出
- **自动触发压缩**，保持上下文在模型限制内

### 为什么要这么做

- **状态机管理**：通过消息历史推断当前状态，无需额外状态存储
- **自动压缩**：防止长对话超出模型上下文限制
- **子任务隔离**：复杂任务分解为子代理执行，避免主上下文混乱

### 优点

1. **状态自包含**：所有状态都在消息历史中，便于恢复和调试
2. **自动资源管理**：上下文压缩对用户透明
3. **任务分解**：子代理机制支持复杂多步骤任务

### 缺点

1. **循环复杂度**：while(true) + 多个 continue/break 路径，理解成本高
2. **状态推断脆弱**：依赖消息顺序和时间戳，边界情况容易出错
3. **压缩开销**：自动压缩可能导致重要信息丢失

---

## 第四步：Agent 与工具解析

### 代码位置
`session/prompt.ts:649` - `resolveTools()` 函数

### 做了什么

#### 1. Agent 获取
```typescript
const agent = await Agent.get(lastUser.agent)
```

Agent 定义包含：
- **mode**: "primary" | "subagent" - 主代理或子代理
- **permission**: 权限规则集
- **prompt**: 系统提示词
- **temperature/topP**: 模型参数
- **steps**: 最大步数限制

#### 2. 工具收集
```typescript
for (const item of await ToolRegistry.tools({ modelID: input.model.api.id, providerID: input.model.providerID }, input.agent)) {
  const schema = ProviderTransform.schema(input.model, z.toJSONSchema(item.parameters))
  tools[item.id] = tool({
    id: item.id as any,
    description: item.description,
    inputSchema: jsonSchema(schema as any),
    async execute(args, options) {
      const ctx = context(args, options)
      await Plugin.trigger("tool.execute.before", { tool: item.id, sessionID, callID }, { args })
      const result = await item.execute(args, ctx)
      await Plugin.trigger("tool.execute.after", { tool: item.id, sessionID, callID }, result)
      return result
    },
  })
}
```

#### 3. MCP 工具集成
```typescript
for (const [key, item] of Object.entries(await MCP.tools())) {
  // MCP 工具包装，统一格式转换
}
```

#### 4. 工具上下文构造
每个工具执行时获得丰富的上下文：
```typescript
const context = (args: any, options: ToolCallOptions): Tool.Context => ({
  sessionID: input.session.id,
  abort: options.abortSignal!,
  messageID: input.processor.message.id,
  callID: options.toolCallId,
  extra: { model: input.model, bypassAgentCheck: input.bypassAgentCheck },
  agent: input.agent.name,
  messages: input.messages,
  metadata: async (val) => { /* 更新工具执行状态 */ },
  async ask(req) { /* 权限检查 */ },
})
```

### 为什么要这么做

- **权限隔离**：不同 Agent 有不同的工具权限
- **统一接口**：内置工具和 MCP 工具对外暴露统一接口
- **可观测性**：通过 metadata 回调实时更新工具执行状态

### 优点

1. **细粒度权限**：支持基于 pattern 的权限控制（如 `edit: {"*.md": "allow", "*.js": "deny"}`）
2. **插件兼容**：MCP 工具无缝集成
3. **执行可追踪**：每个工具调用都有唯一 callID，便于追踪

### 缺点

1. **权限检查开销**：每次工具调用都要遍历权限规则
2. **MCP 转换复杂**：MCP 的复杂返回格式需要额外处理
3. **工具膨胀**：大量工具会影响 LLM 的决策质量

---

## 第五步：LLM 请求构造与发送

### 代码位置
`session/llm.ts:48` - `LLM.stream()` 函数

### 做了什么

#### 1. 系统提示词组装
```typescript
const system = []
system.push([
  ...(input.agent.prompt ? [input.agent.prompt] : isCodex ? [] : SystemPrompt.provider(input.model)),
  ...input.system,
  ...(input.user.system ? [input.user.system] : []),
].filter((x) => x).join("\n"))

// 插件钩子：允许修改系统提示词
await Plugin.trigger("experimental.chat.system.transform", { sessionID, model }, { system })
```

#### 2. 参数配置
```typescript
const params = await Plugin.trigger("chat.params", { sessionID, agent, model, provider, message: input.user }, {
  temperature: input.model.capabilities.temperature ? (input.agent.temperature ?? ProviderTransform.temperature(input.model)) : undefined,
  topP: input.agent.topP ?? ProviderTransform.topP(input.model),
  topK: ProviderTransform.topK(input.model),
  options,
})
```

#### 3. 工具过滤
```typescript
async function resolveTools(input: Pick<StreamInput, "tools" | "agent" | "user">) {
  const disabled = PermissionNext.disabled(Object.keys(input.tools), input.agent.permission)
  for (const tool of Object.keys(input.tools)) {
    if (input.user.tools?.[tool] === false || disabled.has(tool)) {
      delete input.tools[tool]
    }
  }
  return input.tools
}
```

#### 4. 消息格式转换
```typescript
const messages: ModelMessage[] = [
  ...(isCodex
    ? [{ role: "user", content: system.join("\n\n") }]  // Codex: 系统提示作为用户消息
    : system.map((x): ModelMessage => ({ role: "system", content: x }))
  ),
  ...input.messages,  // 历史消息
]
```

#### 5. 流式请求发送
```typescript
return streamText({
  temperature: params.temperature,
  topP: params.topP,
  topK: params.topK,
  providerOptions: ProviderTransform.providerOptions(input.model, params.options),
  activeTools: Object.keys(tools).filter((x) => x !== "invalid"),
  tools,
  headers: { /* 认证头 */ },
  messages,
  model: wrapLanguageModel({
    model: language,
    middleware: [
      { async transformParams(args) { /* 参数转换 */ } },
      extractReasoningMiddleware({ tagName: "think", startWithReasoning: false }),
    ],
  }),
})
```

### 为什么要这么做

- **多提供商适配**：不同提供商（OpenAI、Anthropic、Google）有不同的参数要求
- **系统提示词缓存**：Anthropic 支持系统提示词缓存，需要特殊格式
- **工具修复**：`experimental_repairToolCall` 处理 LLM 调用错误格式的工具

### 优点

1. **提供商无关**：统一接口支持 15+ 提供商
2. **参数可定制**：通过插件钩子允许修改任何参数
3. **错误恢复**：自动修复工具调用格式错误

### 缺点

1. **转换复杂**：每个提供商都有特殊的参数要求
2. **延迟较高**：多层包装增加了请求准备时间
3. **调试困难**：参数经过多层转换后难以追踪

---

## 第六步：流式响应处理

### 代码位置
`session/processor.ts:45` - `process()` 函数

### 做了什么

这是整个流程最复杂的部分，需要实时处理 LLM 的各种输出事件：

#### 事件类型处理

```typescript
for await (const value of stream.fullStream) {
  switch (value.type) {
    case "start":
      SessionStatus.set(input.sessionID, { type: "busy" })
      break

    case "reasoning-start"/"reasoning-delta"/"reasoning-end":
      // 处理推理内容（如 Claude 的 <thinking>）
      break

    case "text-start"/"text-delta"/"text-end":
      // 处理文本输出，实时更新 UI
      break

    case "tool-input-start":
      // LLM 开始生成工具调用
      break

    case "tool-call":
      // 工具调用参数已完整，开始执行
      break

    case "tool-result":
      // 工具执行成功，结果返回给 LLM
      break

    case "tool-error":
      // 工具执行失败，错误信息返回给 LLM
      break

    case "start-step"/"finish-step":
      // 跟踪每轮迭代的开始和结束
      break
  }
}
```

#### Doom Loop 检测
```typescript
const lastThree = parts.slice(-DOOM_LOOP_THRESHOLD)
if (lastThree.length === DOOM_LOOP_THRESHOLD && lastThree.every(p => /* 相同工具相同参数 */)) {
  await PermissionNext.ask({ permission: "doom_loop", ... })  // 询问用户是否继续
}
```

### 为什么要这么做

- **实时反馈**：流式处理让用户立即看到 LLM 的思考和输出
- **工具链执行**：支持 LLM 连续调用多个工具（如先 grep 再 read 再 edit）
- **防死循环**：检测 LLM 反复调用相同工具的异常情况

### 优点

1. **用户体验好**：流式输出减少等待焦虑
2. **错误隔离**：单个工具失败不会中断整个流程
3. **防呆设计**：Doom Loop 检测避免无限循环

### 缺点

1. **状态管理复杂**：需要跟踪多个并发的工具调用状态
2. **事件顺序依赖**：不同提供商的事件顺序可能不同
3. **资源占用**：长对话需要持续保持连接

---

## 第七步：工具执行与结果反馈

### 代码位置
工具执行在 `session/processor.ts` 中触发，具体实现在 `tool/*.ts`

### 做了什么

以 Bash 工具为例：

#### 1. 权限检查
```typescript
// 在 Tool.Context 中提供 ask 方法
async ask(req) {
  await PermissionNext.ask({
    ...req,
    sessionID: input.session.id,
    tool: { messageID: input.processor.message.id, callID: options.toolCallId },
    ruleset: PermissionNext.merge(input.agent.permission, input.session.permission ?? []),
  })
}
```

#### 2. 执行与监控
```typescript
export const BashTool = Tool.define("bash", async () => {
  return {
    description: "Execute bash commands",
    parameters: z.object({ command: z.string(), timeout: z.number().optional(), description: z.string() }),
    async execute(params, ctx) {
      await ctx.ask({ permission: "bash", patterns: [params.command], metadata: params })  // 权限检查
      // ... 执行命令
      return { title: params.description, metadata: { output, exit }, output }
    },
  }
})
```

#### 3. 结果处理
```typescript
case "tool-result": {
  const match = toolcalls[value.toolCallId]
  if (match && match.state.status === "running") {
    await Session.updatePart({
      ...match,
      state: {
        status: "completed",
        input: value.input ?? match.state.input,
        output: value.output.output,
        metadata: value.output.metadata,
        title: value.output.title,
        time: { start: match.state.time.start, end: Date.now() },
        attachments: value.output.attachments,
      },
    })
    delete toolcalls[value.toolCallId]
  }
  break
}
```

### 为什么要这么做

- **安全可控**：敏感操作需要用户确认
- **可追踪**：每个工具调用的输入输出都被记录
- **可恢复**：工具执行结果作为消息的一部分存储

### 优点

1. **安全第一**：命令执行前必须经过权限检查
2. **完整记录**：所有操作可追溯，便于审计
3. **错误隔离**：单个工具失败不影响其他工具

### 缺点

1. **交互打断**：频繁询问权限影响流畅度
2. **权限判断粗**：基于 pattern 匹配，复杂场景不够精确
3. **结果存储冗余**：大输出结果会占用大量存储

---

## 第八步：循环结束与结果返回

### 代码位置
`session/prompt.ts:630` - `loop()` 函数末尾

### 做了什么

#### 1. 结果收集
```typescript
SessionCompaction.prune({ sessionID })  // 清理过期压缩
for await (const item of MessageV2.stream(sessionID)) {
  if (item.info.role === "user") continue
  const queued = state()[sessionID]?.callbacks ?? []
  for (const q of queued) {
    q.resolve(item)  // 解析等待中的 Promise
  }
  return item  // 返回最终结果
}
```

#### 2. 消息持久化
所有消息和消息片段（Part）都被存储：
```typescript
await Session.updateMessage(input.assistantMessage)
await Session.updatePart(currentText)
```

#### 3. 成本统计
```typescript
const usage = Session.getUsage({ model: input.model, usage: value.usage, metadata: value.providerMetadata })
input.assistantMessage.cost += usage.cost
input.assistantMessage.tokens = usage.tokens
```

### 为什么要这么做

- **会话可恢复**：所有历史都被保存，可以 fork 或恢复会话
- **成本透明**：每次交互的 token 和成本都被记录
- **异步支持**：支持多个消费者等待同一结果

### 优点

1. **数据完整**：完整的操作历史便于复盘
2. **成本可控**：实时监控 API 调用成本
3. **可恢复**：会话可以在任意点 fork

### 缺点

1. **存储开销**：大量消息和文件内容占用空间
2. **查询性能**：长会话的消息流查询会变慢
3. **隐私风险**：所有操作记录都可能泄露敏感信息

---

## 关键设计模式总结

### 1. 消息驱动架构

整个系统围绕消息（Message）和消息片段（Part）构建：
- **User Message**: 用户输入
- **Assistant Message**: LLM 响应
- **Text Part**: 文本内容
- **Tool Part**: 工具调用
- **File Part**: 文件引用

**优点**：状态自包含、易于追踪、支持并发
**缺点**：消息膨胀、查询复杂

### 2. 插件钩子系统

关键位置都预留了插件钩子：
- `chat.message`: 消息创建时
- `chat.params`: 参数构造时
- `chat.headers`: 请求头发送时
- `tool.execute.before/after`: 工具执行前后

**优点**：高度可扩展、不侵入核心代码
**缺点**：插件可能相互冲突、调试困难

### 3. 权限规则引擎

基于规则的权限系统：
```typescript
permission: [
  { permission: "edit", action: "deny", pattern: "*.js" },
  { permission: "bash", action: "ask", pattern: "rm -rf *" },
]
```

**优点**：灵活配置、支持通配符
**缺点**：规则冲突时行为难预测、复杂规则性能差

### 4. 子代理机制

通过 Task 工具实现代理分解：
```typescript
{ type: "subtask", agent: "explore", prompt: "搜索所有 API", ... }
```

**优点**：任务解耦、并行执行、上下文隔离
**缺点**：结果合并复杂、调试困难

---

## 流程图：完整交互时序

```mermaid
sequenceDiagram
    participant User as 用户
    participant CLI as CLI入口
    participant Prompt as SessionPrompt
    participant Loop as 主循环
    participant Agent as Agent系统
    participant Tools as 工具注册表
    participant LLM as LLM模块
    participant Processor as 流处理器
    participant Provider as AI提供商

    User->>CLI: 输入需求
    CLI->>Prompt: prompt()
    Prompt->>Prompt: createUserMessage()
    Note over Prompt: 处理@file和@agent
    Prompt->>Loop: loop()

    loop while 需要更多步骤
        Loop->>Loop: 获取消息历史
        Loop->>Loop: 检查结束条件

        alt 上下文溢出
            Loop->>Loop: SessionCompaction
        else 正常处理
            Loop->>Agent: Agent.get()
            Agent-->>Loop: Agent配置

            Loop->>Tools: ToolRegistry.tools()
            Tools-->>Loop: 可用工具列表

            Loop->>LLM: LLM.stream()
            LLM->>Provider: streamText()
            Provider-->>LLM: 流式响应

            LLM->>Processor: processor.process()

            loop 处理流事件
                Processor->>Processor: text-delta
                Processor->>Processor: reasoning-delta

                alt 工具调用
                    Processor->>Tools: 执行工具
                    Tools-->>Processor: 结果
                end
            end

            Processor-->>Loop: 处理结果
        end
    end

    Loop-->>Prompt: 最终结果
    Prompt-->>CLI: 返回
    CLI-->>User: 展示结果
```

---

## 总结

OpenCode 的 Agent-LLM 交互流程是一个精心设计的**状态机 + 消息驱动**架构：

1. **输入层**：统一处理各种输入类型（文本、文件、代理调用）
2. **处理层**：循环处理，支持多轮工具调用
3. **执行层**：权限控制、插件扩展、错误恢复
4. **输出层**：流式响应、成本统计、持久化存储

**核心设计哲学**：
- **透明化**：所有操作都可追踪、可审计
- **可扩展**：插件系统允许深度定制
- **安全优先**：敏感操作必须用户确认
- **提供商无关**：统一接口支持多种 LLM

这个架构的代价是复杂性较高，但换来了极大的灵活性和可控性。
