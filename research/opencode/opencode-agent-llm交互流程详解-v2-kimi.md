# OpenCode 是如何与 AI 对话的？

本文用通俗的语言，带你走完 OpenCode 从接收用户输入到完成任务的全过程。

---

## 先打个比喻：OpenCode 像什么？

想象你是一个**项目经理（OpenCode）**，要指挥一个**外包团队（AI 模型）**完成一个项目。这个外包团队：

- 不能直接碰你的电脑（隔离性）
- 但可以通过你执行命令（工具调用）
- 有时需要查资料（文件读取）
- 有时需要下属协助（子代理）
- 会告诉你每一步要做什么（流式响应）

OpenCode 就是这个"项目经理"，负责在**你和 AI 之间搭建一座桥梁**。

---

## 第一阶段：接收需求（输入处理）

### 发生了什么？

你在终端输入：`帮我重构 auth.ts 里的登录函数`

OpenCode 首先做三件事：

```typescript
// 1. 创建"紧急停止按钮"
// 如果后续执行中你想中断，按 Ctrl+C 就能立刻停止
const controller = new AbortController()

// 2. 把你的话包装成"标准消息格式"
// 就像把口头需求写成正式的工单
const message = {
  id: "msg_001",           // 工单编号
  role: "user",            // 是谁提的需求
  sessionID: "sess_123",   // 属于哪个项目
  time: Date.now(),        // 什么时间
  agent: "build",          // 指派给哪个团队
  parts: [...]             // 具体内容（可能包含多个部分）
}

// 3. 检查权限配置
// 就像先确认这个团队有没有权限改 auth.ts
const permissions = [
  { permission: "read", action: "allow", pattern: "*" },      // 可以读任何文件
  { permission: "edit", action: "ask", pattern: "*.env" },    // 改环境文件要问我
]
```

### 为什么这样设计？

| 设计 | 原因 | 好处 |
|------|------|------|
| AbortController | AI 执行可能很慢 | 用户随时能中断，不卡死 |
| 标准化消息 | 用户输入形式多样 | 统一格式后，后续处理更简单 |
| 前置权限检查 | 避免执行到一半才发现没权限 | 提前发现问题，减少无效调用 |

### 潜在问题

- **启动有开销**：哪怕你只是问个"你好"，也要走这套初始化流程
- **权限粒度有限**：目前是基于文件路径匹配，不能精确到"第几行代码"

---

## 第二阶段：理解需求（消息构造）

### 发生了什么？

用户输入可能很复杂：
- `@auth-agent 看看这个登录函数`（@ 提到某个代理）
- `@src/auth.ts 帮我重构`（@ 提到某个文件）
- `!`git status``（嵌入 shell 命令）

OpenCode 需要把这些"混合输入"拆解成 AI 能理解的格式。

#### 场景 1：你 @ 了一个文件

```typescript
// 用户输入：@src/auth.ts 帮我重构这个
// OpenCode 会：

// 1. 检测到 @src/auth.ts，读取文件内容
const fileContent = await readFile("src/auth.ts")

// 2. 构造"合成消息"——让 AI 知道"我帮你读了文件"
const syntheticMessage = {
  type: "text",
  synthetic: true,  // 标记：这是系统生成的，不是用户写的
  text: `Called the Read tool with the following input: {"filePath":"src/auth.ts"}\n\n${fileContent}`
}

// 3. 最终发给 AI 的消息包含两部分：
//    - 用户的原始需求"帮我重构这个"
//    - 系统生成的"我已读取 src/auth.ts，内容是..."
```

#### 场景 2：你 @ 了一个代理

```typescript
// 用户输入：@explore 搜索所有 API 端点
// OpenCode 会：

// 1. 创建 AgentPart 标记你提到了 explore 代理
const agentPart = {
  type: "agent",
  name: "explore"
}

// 2. 自动生成一段"提示词"，告诉 AI 该怎么用这个代理
const hintMessage = {
  type: "text",
  synthetic: true,
  text: "Use the above message and context to generate a prompt and call the task tool with subagent: explore"
  // 翻译：根据上面的消息和上下文，生成一个提示词，然后调用 task 工具，指定 subagent 为 explore
}

// 这样 AI 就知道：用户想让我用 explore 代理去搜索 API
```

### 设计思想：透明化

**核心原则**：让 AI 清楚地知道"发生了什么"。

当 OpenCode 帮你读取了一个文件，它不会偷偷塞给 AI，而是**明确告诉 AI**："我调用了 Read 工具，读取了 src/auth.ts，内容是..."

这样做的好处：
1. **可追踪**：AI 知道信息来源，回答更准确
2. **可调试**：如果读错文件，你能在日志里看到
3. **可学习**：AI 能从工具调用中学习如何更好地使用工具

### 潜在问题

- **消息膨胀**：每个文件操作都生成一段文本，长对话时上下文会很长
- **重复劳动**：如果 AI 已经知道文件内容，再读一遍就是浪费

---

## 第三阶段：主循环（核心处理逻辑）

### 发生了什么？

这是整个系统最核心的一段逻辑。OpenCode 使用一个 **while(true) 循环** 来持续与 AI 交互，直到任务完成。

```
开始
  ↓
检查是否已有 AI 回复？是 → 任务完成，结束
  ↓ 否
检查是否有未完成的子任务？是 → 执行子任务
  ↓ 否
检查上下文是否过长？是 → 压缩上下文
  ↓ 否
调用 AI → 获取回复
  ↓
AI 要求执行工具？是 → 执行工具 → 把结果给 AI → 继续循环
  ↓ 否
AI 直接回复？是 → 展示给用户 → 结束
```

### 为什么要用循环？

因为 AI 完成任务往往不是"一问一答"就能搞定的，可能需要多轮交互：

```
用户：帮我修复 bug
  ↓
AI：我先看看相关文件 → 调用 Read 工具读取 bug.ts
  ↓
AI：发现问题了，需要修改第 10 行 → 调用 Edit 工具
  ↓
AI：改好了，我再验证一下 → 调用 Bash 运行测试
  ↓
AI：测试通过，这是修复后的代码 → 完成任务
```

每一轮循环，AI 可能会：
- 调用一个或多个工具（并行）
- 输出思考过程（reasoning）
- 输出最终结果（text）

### 关键机制 1：上下文压缩

当对话太长时（接近 AI 的上下文上限），OpenCode 会触发**压缩机制**：

```typescript
// 检查：当前 token 数是否超过模型上限的 80%？
if (await SessionCompaction.isOverflow({ tokens: lastFinished.tokens, model })) {
  // 创建一个"压缩任务"
  await SessionCompaction.create({ sessionID, agent, model, auto: true })
  // 压缩会把旧消息总结成摘要，释放 token 空间
  continue  // 压缩后继续循环
}
```

**压缩过程**：
1. 找一个专门的"compaction"代理
2. 把旧消息发给这个代理："请总结这些对话的关键信息"
3. 用总结替换原始消息，释放空间

### 关键机制 2：子任务（Subtask）

复杂任务可以分解给专门的子代理：

```typescript
// 用户需要同时查多个地方
// OpenCode 可以创建多个子任务并行执行

const subtask1 = {
  type: "subtask",
  agent: "explore",           // 用 explore 代理
  description: "查找 API 路由",
  prompt: "搜索 src/routes 目录下的所有接口定义"
}

const subtask2 = {
  type: "subtask",
  agent: "explore",
  description: "查找数据库模型",
  prompt: "搜索 src/models 目录下的所有模型"
}

// 这两个子任务可以并行执行，节省时间
```

### 设计思想：状态自包含

OpenCode 的会话状态**完全存储在消息历史中**。这意味着：

- 你可以随时 fork 一个会话（从某条消息开始分支）
- 你可以查看完整的操作日志
- 系统重启后，只要消息还在，状态就能恢复

### 潜在问题

- **无限循环风险**：如果 AI 反复犯同样的错误，会陷入死循环
- **压缩信息丢失**：重要细节可能在压缩中被遗漏
- **状态依赖复杂**：消息顺序、时间戳等隐含信息容易出错

---

## 第四阶段：准备工具

### 发生了什么？

在真正调用 AI 之前，OpenCode 需要告诉 AI：**你现在能用什么工具**。

```typescript
// 1. 获取所有可用工具
const allTools = await ToolRegistry.tools({ modelID, providerID }, agent)

// 2. 根据权限过滤
const allowedTools = allTools.filter(tool => {
  // 检查这个工具是否被当前 Agent 的权限允许
  return PermissionNext.isAllowed(tool.id, agent.permission)
})

// 3. 把工具包装成 AI SDK 需要的格式
const wrappedTools = {}
for (const tool of allowedTools) {
  wrappedTools[tool.id] = {
    description: tool.description,      // 工具是做什么的
    parameters: tool.parameters,        // 需要什么参数（JSON Schema）
    execute: async (args, options) => {  // 执行函数
      // 权限检查
      await checkPermission(tool.id, args)
      // 执行工具
      const result = await tool.execute(args, context)
      // 记录结果
      return result
    }
  }
}
```

### 权限系统详解

OpenCode 的权限不是简单的"能/不能"，而是**基于规则的匹配**：

```typescript
// Agent 的权限配置示例
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
// edit("src/index.ts") → 匹配规则 3 → allow
// edit(".env.local") → 匹配规则 2 → ask
// edit("node_modules/foo/index.js") → 匹配规则 4 → deny
```

### 设计思想：最小权限原则

每个 Agent 只拥有完成其任务所需的最小权限：

| Agent | 权限特点 | 用途 |
|-------|----------|------|
| build | 完整读写权限 | 默认开发模式 |
| plan | 只读权限（不能 edit） | 规划阶段，先不动代码 |
| explore | 只能 grep/read/list | 代码库探索，安全无副作用 |
| general | 不能操作 Todo | 子代理，专注特定任务 |

### 潜在问题

- **规则冲突**：复杂的规则链可能导致意外行为
- **性能开销**：每次工具调用都要遍历权限列表
- **用户体验**：频繁弹窗询问权限会打断工作流

---

## 第五阶段：调用 AI

### 发生了什么？

OpenCode 使用 Vercel 的 AI SDK 与各种 LLM 提供商交互。

```typescript
// 准备系统提示词
const systemPrompt = [
  // 基础系统提示（不同提供商不同）
  ...SystemPrompt.provider(model),

  // Agent 特定的提示（如 plan 模式会附加"不要修改文件"）
  ...(agent.prompt ? [agent.prompt] : []),

  // 环境信息（当前目录、操作系统、日期等）
  ...SystemPrompt.environment(model),
]

// 准备消息历史
const messages = [
  // 系统提示
  ...systemPrompt.map(text => ({ role: "system", content: text })),

  // 用户和 AI 的历史对话
  ...history.map(msg => convertToModelFormat(msg)),
]

// 调用 AI（流式）
const stream = await streamText({
  model: languageModel,           // 如 claude-3-5-sonnet
  messages: messages,
  tools: wrappedTools,            // 告诉 AI 有哪些工具可用
  temperature: 0.7,               // 创造性程度
  maxTokens: 32000,               // 最大输出长度
  headers: {                      // 认证信息
    "x-api-key": apiKey,
  },
})
```

### 多提供商适配

不同的 AI 提供商（OpenAI、Anthropic、Google）有不同的参数格式，OpenCode 通过**转换层**处理：

```typescript
// Anthropic 支持系统提示词缓存
if (provider === "anthropic") {
  options.systemPromptCaching = true
}

// Google Gemini 需要特殊的 schema 格式
if (provider === "google") {
  schema = convertToGeminiSchema(schema)
}

// OpenAI Codex 有特殊的使用模式
if (provider === "openai" && auth.type === "oauth") {
  // 系统提示通过 instructions 参数传递
  options.instructions = systemPrompt
}
```

### 设计思想：提供商无关

用户可以在配置中自由切换模型：

```json
{
  "provider": {
    "anthropic": { "default": true },
    "openai": { "models": { "gpt-4": { "enabled": true } } }
  }
}
```

OpenCode 会自动处理不同提供商的差异，用户无感知。

### 潜在问题

- **特性受限**：为了兼容多个提供商，只能用"最小公倍数"功能
- **转换开销**：参数需要多层转换，增加延迟
- **调试困难**：问题可能出在转换层，难以定位

---

## 第六阶段：流式处理响应

### 发生了什么？

AI 的响应是**流式**的，就像打字机一样，一个字一个字出现。OpenCode 需要实时处理这些片段。

```typescript
// 遍历流中的每个事件
for await (const event of stream.fullStream) {
  switch (event.type) {

    // ========== 文本输出 ==========
    case "text-start":
      // AI 开始说话，创建文本片段
      currentText = { type: "text", text: "", ... }
      break

    case "text-delta":
      // AI 又输出了几个字，追加到文本
      currentText.text += event.text
      // 实时更新 UI（用户能看到打字效果）
      await updateUI(currentText)
      break

    case "text-end":
      // AI 说完了，保存文本
      await savePart(currentText)
      break

    // ========== 推理过程 ==========
    case "reasoning-start":
      // AI 开始思考（如 Claude 的 <thinking>）
      currentReasoning = { type: "reasoning", text: "", ... }
      break

    case "reasoning-delta":
      // AI 的思考内容
      currentReasoning.text += event.text
      break

    case "reasoning-end":
      // 思考结束
      await savePart(currentReasoning)
      break

    // ========== 工具调用 ==========
    case "tool-input-start":
      // AI 开始构造工具调用（还在生成参数）
      toolCall = { type: "tool", tool: event.toolName, state: "pending", ... }
      break

    case "tool-call":
      // AI 提交了完整的工具调用请求
      toolCall.state = "running"
      toolCall.input = event.input  // 参数

      // 执行工具！
      executeTool(toolCall).then(result => {
        // 工具执行完，结果返回给 AI
        return { type: "tool-result", output: result }
      })
      break

    case "tool-result":
      // 工具执行成功，保存结果
      toolCall.state = "completed"
      toolCall.output = event.output
      await savePart(toolCall)
      break

    case "tool-error":
      // 工具执行失败
      toolCall.state = "error"
      toolCall.error = event.error
      await savePart(toolCall)
      break
  }
}
```

### 防死循环机制：Doom Loop

如果 AI 反复调用同一个工具，传入同样的参数，可能是陷入了死循环：

```typescript
// 检查最近 3 个工具调用
const lastThree = parts.slice(-3)

if (lastThree.every(p =>
  p.tool === currentTool &&                    // 同一个工具
  JSON.stringify(p.input) === JSON.stringify(currentInput)  // 相同参数
)) {
  // 询问用户：AI 似乎在重复同样的操作，要继续吗？
  await askUser({
    type: "doom_loop",
    message: `AI 已连续 3 次调用 ${currentTool}，参数相同。是否继续？`
  })
}
```

### 设计思想：渐进式输出

流式处理的优势：
1. **用户体验好**：不用等 AI 全部想完，先看一部分
2. **快速反馈**：如果 AI 理解错了，用户可以马上打断
3. **资源友好**：不需要缓存整个大响应

### 潜在问题

- **状态管理复杂**：需要跟踪多个并发的工具调用
- **错误恢复难**：流中途出错，可能丢失部分数据
- **提供商差异**：不同提供商的事件顺序可能不同

---

## 第七阶段：工具执行与反馈

### 发生了什么？

当 AI 调用工具时，完整的流程是：

```
AI 决定调用工具
  ↓
构造工具调用请求（工具名 + 参数）
  ↓
OpenCode 检查权限
  ├─ 允许 → 执行工具
  ├─ 询问 → 弹窗问用户
  └─ 拒绝 → 返回错误给 AI
  ↓
工具执行
  ↓
结果返回给 AI
  ↓
AI 根据结果决定下一步
```

### 工具执行的上下文

每个工具执行时，都能获取丰富的上下文信息：

```typescript
const context = {
  sessionID: "sess_123",       // 当前会话 ID
  messageID: "msg_456",        // 当前消息 ID
  callID: "call_789",          // 这次调用的唯一 ID
  agent: "build",              // 当前使用的 Agent
  abort: AbortSignal,          // 取消信号
  messages: [...],             // 完整对话历史

  // 更新工具状态的回调
  metadata: async (data) => {
    await updateToolStatus(callID, data)
  },

  // 权限询问
  ask: async (request) => {
    return await checkPermission(request)
  }
}

// 工具用这个上下文执行
const result = await tool.execute(args, context)
```

### 以 Bash 工具为例

```typescript
const BashTool = {
  id: "bash",
  description: "执行 bash 命令",
  parameters: z.object({
    command: z.string(),        // 命令内容
    timeout: z.number().optional(),  // 超时时间
    description: z.string()     // 命令描述（5-10字）
  }),

  async execute(params, ctx) {
    // 1. 权限检查
    await ctx.ask({
      permission: "bash",
      patterns: [params.command],  // 检查这条命令是否被允许
      metadata: params
    })

    // 2. 执行命令
    const { stdout, stderr, exitCode } = await exec(params.command, {
      timeout: params.timeout,
      signal: ctx.abort  // 支持取消
    })

    // 3. 返回结果
    return {
      title: params.description,     // 简短描述
      output: stdout || stderr,      // 命令输出
      metadata: { exitCode }         // 额外信息
    }
  }
}
```

### 设计思想：安全优先

敏感操作（bash、edit、write）必须经过用户确认。确认方式：

1. **always**：用户勾选"记住我的选择"
2. **ask**：每次都要弹窗确认
3. **deny**：直接拒绝

### 潜在问题

- **频繁打断**：开发时需要频繁确认，影响效率
- **误报漏报**：基于字符串匹配的权限检查可能误判
- **上下文缺失**：用户可能不理解 AI 为什么要执行这个命令

---

## 第八阶段：任务完成与收尾

### 发生了什么？

当 AI 不再调用工具，而是直接回复用户时，循环结束：

```typescript
// 结束条件
if (lastAssistant.finish && lastAssistant.finish !== "tool-calls") {
  // AI 不是因为调用工具而结束，而是自然完成
  break  // 退出循环
}
```

收尾工作：

```typescript
// 1. 清理压缩任务
SessionCompaction.prune({ sessionID })

// 2. 统计成本
const usage = {
  input: 1500,      // 输入 token 数
  output: 800,      // 输出 token 数
  cost: 0.0045      // 预估成本（美元）
}

// 3. 保存到数据库
await Session.updateMessage({
  ...assistantMessage,
  tokens: usage,
  cost: usage.cost,
  time: { created: startTime, completed: Date.now() }
})

// 4. 返回结果给调用者
return {
  info: assistantMessage,  // 消息元数据
  parts: [                 // 消息内容片段
    { type: "text", text: "已帮你重构完成..." },
    { type: "tool", tool: "edit", state: "completed", ... },
  ]
}
```

### 会话的可追溯性

OpenCode 保存了完整的历史：

```
会话 sess_123
├── 消息 msg_001 (用户)
│   └── 片段："帮我重构 auth.ts"
├── 消息 msg_002 (AI)
│   ├── 片段：思考过程（reasoning）
│   ├── 片段："我先看看文件"
│   └── 片段：调用 Read 工具（状态：completed）
├── 消息 msg_003 (AI)
│   ├── 片段：思考过程
│   ├── 片段：调用 Edit 工具（状态：completed）
│   └── 片段："重构完成，修改了..."
└── ...
```

用户可以：
- 查看完整的操作日志
- 从任意消息 fork 新会话
- 回滚到之前的某个状态

### 设计思想：可审计

所有操作都被记录，便于：
1. **复盘**："AI 当时为什么要这么改？"
2. **调试**："哪个工具调用失败了？"
3. **计费**："这次对话花了多少钱？"

---

## 总结：OpenCode 的设计哲学

### 1. 消息驱动

一切状态都存储在消息中，不依赖外部状态机。

**优点**：
- 会话可随时 fork、恢复
- 分布式友好（多台机器可以共享同一个会话）

**缺点**：
- 消息膨胀，查询性能下降
- 状态推断逻辑复杂

### 2. 工具即接口

AI 通过工具与外部世界交互，OpenCode 负责桥接。

**优点**：
- 隔离性好，AI 不能直接操作电脑
- 可扩展性强，随时添加新工具

**缺点**：
- 工具过多会影响 AI 决策质量
- 工具描述需要精心设计

### 3. 流式交互

不等待 AI 完全"想完"，而是实时反馈。

**优点**：
- 用户体验好
- 可中断，节省 token

**缺点**：
- 实现复杂
- 错误恢复困难

### 4. 权限分层

不同 Agent 有不同权限，敏感操作必须确认。

**优点**：
- 安全第一
- plan/build 模式切换确保"先想后做"

**缺点**：
- 配置复杂
- 可能频繁打断用户

---

## 流程图总览

```
┌─────────────────────────────────────────────────────────────────┐
│                         用户输入                                 │
│              "帮我重构 auth.ts 里的登录函数"                      │
└──────────────────────────┬──────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────────────┐
│ 1. 输入处理                                                      │
│    • 创建 AbortController（可取消）                              │
│    • 构造标准消息格式                                             │
│    • 处理 @file/@agent 引用                                      │
└──────────────────────────┬──────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────────────┐
│ 2. 主循环 (while true)                                           │
│    ├─ 检查：是否已有完整回复？ → 结束                            │
│    ├─ 检查：有未完成的子任务？ → 执行子任务                      │
│    ├─ 检查：上下文过长？ → 触发压缩                              │
│    └─ 继续调用 AI                                               │
└──────────────────────────┬──────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────────────┐
│ 3. 准备工具                                                      │
│    • 获取可用工具列表                                             │
│    • 根据 Agent 权限过滤                                          │
│    • 包装成 AI SDK 格式                                           │
└──────────────────────────┬──────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────────────┐
│ 4. 调用 LLM                                                      │
│    • 组装系统提示（基础 + Agent + 环境）                          │
│    • 适配多提供商参数                                             │
│    • 发起流式请求                                                 │
└──────────────────────────┬──────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────────────┐
│ 5. 流式处理                                                      │
│    实时处理事件流：                                               │
│    ├─ text-delta（文本片段）→ 实时展示给用户                     │
│    ├─ reasoning-delta（思考过程）→ 可选展示                     │
│    ├─ tool-call（工具调用）→ 执行工具 → 结果返回给 AI            │
│    │                                     ↓                       │
│    │                              回到第 2 步继续循环            │
│    └─ finish（完成）→ 结束循环                                   │
└──────────────────────────┬──────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────────────┐
│ 6. 收尾                                                          │
│    • 统计 token 和成本                                            │
│    • 保存完整消息历史                                             │
│    • 返回结果                                                    │
└──────────────────────────┬──────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────────────┐
│                         展示给用户                               │
└─────────────────────────────────────────────────────────────────┘
```

---

希望这个版本更容易理解。如果有任何部分还是不清楚，请告诉我，我会进一步解释或调整。
