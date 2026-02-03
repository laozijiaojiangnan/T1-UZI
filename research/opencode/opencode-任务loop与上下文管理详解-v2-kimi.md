# OpenCode 任务循环与上下文管理解析

## 一句话概括

OpenCode 通过一个**无限循环**来驱动 AI 对话，每次循环处理一个"回合"：检查历史消息 → 组装上下文 → 调用 AI → 处理响应 → 执行工具 → 继续循环，直到 AI 不再调用工具为止。

---

## 一、整体设计理念

### 1.1 消息即状态

OpenCode 采用了**消息驱动架构**——系统没有独立的状态机，所有状态都存储在消息历史中。这类似于 Redux 的理念：状态 = 初始状态 + 消息历史。

**好处：**
- 随时可以从任意消息点开始 fork 新会话
- 完整的操作日志，便于回溯
- 系统重启后状态不丢失

**结构层次：**
```
Session (会话)
├── Message (消息)
│   ├── User Message (用户输入)
│   └── Assistant Message (AI 回复)
│       └── Parts (消息片段)
│           ├── text (文本回复)
│           ├── tool (工具调用)
│           ├── reasoning (思考过程)
│           └── ...
```

### 1.2 三层上下文架构

OpenCode 在组装发给 AI 的消息时，采用三层递进的设计：

| 层级 | 内容 | 作用 |
|-----|------|------|
| **系统层** | 你是谁、能用哪些工具、当前环境 | 告诉 AI 的基本设定 |
| **历史层** | 之前的对话记录 | 给 AI 的记忆 |
| **动态层** | 当前模式的特殊提示 | 如 Plan 模式的额外约束 |

---

## 二、任务循环详解

### 2.1 循环的本质

OpenCode 的任务循环解决一个核心问题：**AI 完成任务往往需要多轮交互**。

举个例子：
```
用户：帮我修一个 bug
AI：我先看看代码 → 调用 Read 工具
AI：发现问题，需要修改 → 调用 Edit 工具
AI：运行测试验证 → 调用 Bash 工具
AI：测试通过，完成了 → 结束
```

每一轮"思考 → 调用工具 → 获得结果 → 继续思考"就是一个循环迭代。

### 2.2 循环的四个分支

每次进入循环，OpenCode 会依次检查四种情况：

```
┌────────────────────────────────────────┐
│  有新的子任务？                        │
│  (用户通过 @agent 调用了子代理)        │
│  → 执行子任务，然后继续循环            │
└────────────────────────────────────────┘
                   ↓ 否
┌────────────────────────────────────────┐
│  有待处理的压缩任务？                  │
│  (上下文太长需要总结)                  │
│  → 调用压缩代理生成摘要，继续循环      │
└────────────────────────────────────────┘
                   ↓ 否
┌────────────────────────────────────────┐
│  上下文已溢出？                        │
│  (token 数超过模型上限)                │
│  → 创建压缩任务，下次循环处理          │
└────────────────────────────────────────┘
                   ↓ 否
┌────────────────────────────────────────┐
│  正常处理：调用 LLM 进行对话           │
│  → 等待 AI 响应，处理工具调用          │
└────────────────────────────────────────┘
```

### 2.3 什么时候结束？

循环结束的条件很简单：**AI 回复了内容，且没有调用任何工具**。

具体来说：
- 如果 AI 调用了工具（finish reason 是 "tool-calls"），循环继续
- 如果 AI 自然结束（finish reason 是 "stop"/"end_turn" 等），循环结束

---

## 三、上下文是如何组装的？

### 3.1 系统提示词的构成

系统提示词告诉 AI "你是谁、你能做什么"。OpenCode 的系统提示由几部分组成：

**1) 基础身份提示**
不同 AI 模型看到的基础提示不同：
- Claude 看到："You are OpenCode, the best coding agent..."
- GPT 看到："You are opencode, an agent - please keep going until..."

**2) 环境信息**
```
You are powered by the model named claude-sonnet-4-5-20251101
Here is some useful information about the environment:
<env>
  Working directory: /Users/jiangnan/Desktop/project
  Is directory a git repo: yes
  Platform: darwin
  Today's date: Wed Jan 28 2026
</env>
```

**3) 代理特定提示**
不同代理有不同约束。比如 Plan 代理会看到：
```
You are in plan mode. You MUST NOT make any edits...
```

**4) 用户自定义提示**
用户可以在配置中添加自己的系统提示。

### 3.2 消息历史的处理

**过滤已压缩内容**

OpenCode 不会把所有历史消息都发给 AI。它会使用 `filterCompacted` 函数过滤：

```
原始消息: [msg1, msg2, compaction, msg3, msg4, compaction, msg5]
过滤后:  [msg5, msg4, msg3]  (最近的 compaction 之后的消息)
```

**消息类型转换**

内部的 Part 格式会转换成 AI SDK 需要的格式：

| 内部 Part | 转换后 |
|----------|-------|
| text | text message |
| file (二进制) | file message |
| tool (completed) | tool-result |
| tool (error) | tool-result with error |
| compaction | "What did we do so far?" |
| subtask | "The following tool was executed..." |

### 3.3 动态提醒插入

OpenCode 会在特定时机插入系统提醒，帮助 AI 理解当前状态：

**Plan 模式提醒**
当用户切换到 Plan 代理时，会自动附加：
```
You are in plan mode. You MUST NOT make any edits...
```

**Plan → Build 切换提醒**
当从 Plan 切换到 Build 时，会提醒：
```
You just finished plan mode. The user wants you to execute the plan.
```

**后续消息包装**
如果 AI 已经执行了几步，用户又发新消息，会包装成：
```
<system-reminder>
The user sent the following message: {用户消息}
Please address this message and continue with your tasks.
</system-reminder>
```

---

## 四、流式响应处理

### 4.1 为什么需要流式处理？

AI 的响应是"打字机式"的——一个字一个字出来。OpenCode 需要实时处理这些片段，以便：
- **实时显示**：用户不用等 AI 全部想完
- **快速中断**：如果发现 AI 理解错了，用户可以马上打断
- **工具触发**：AI 一说出要调用工具，立即执行

### 4.2 事件类型

LLM 流会发送各种事件，OpenCode 主要处理这些：

| 事件 | 含义 | 处理 |
|-----|------|------|
| `text-delta` | AI 又输出了几个字 | 追加到文本片段，更新 UI |
| `reasoning-delta` | AI 的思考内容 | 追加到 reasoning 片段 |
| `tool-call` | AI 决定调用工具 | 立即执行工具 |
| `tool-result` | 工具执行完成 | 把结果返回给 AI |
| `finish-step` | 一轮思考结束 | 统计用量，检查是否需要压缩 |

### 4.3 Doom Loop 防护

如果 AI 陷入循环（反复调用同一个工具，参数也一样），OpenCode 会检测并介入：

```
检测到：连续 3 次调用相同的工具，参数相同
处理：弹窗询问用户 "AI 似乎在重复操作，是否继续？"
```

这防止了 AI 无限循环消耗 token。

---

## 五、上下文压缩机制

### 5.1 为什么需要压缩？

每个模型都有上下文上限（比如 Claude 是 200k tokens）。当对话变长时：
1. 可能超出上限导致错误
2. 长上下文会让 AI 注意力分散
3. 不必要的旧工具输出占用空间

### 5.2 压缩的触发条件

OpenCode 在每次 AI 回复后检查：
```
当前 token 数 > 模型上限的 80% ?
→ 触发压缩
```

### 5.3 压缩的工作流程

**第一步：创建压缩任务**
插入一个特殊的用户消息，包含 `compaction` part。

**第二步：使用专门的压缩代理**
创建一个特殊的 Assistant Message，使用 `compaction` 代理（这个代理没有工具权限，只能生成文本）。

**第三步：生成总结**
把历史对话发给压缩代理，让它回答：
```
Provide a detailed prompt for continuing our conversation above.
Focus on: what we did, what we're doing, which files we're working on...
```

**第四步：用总结替换旧消息**
下次循环时，`filterCompacted` 会：
1. 找到最近的 compaction 消息
2. 只保留 compaction 之后的消息
3. 之前的详细内容被 summary 替代

### 5.4 工具结果的裁剪（Prune）

除了主动压缩，OpenCode 还会自动"遗忘"旧的工具输出：

```
策略：
1. 保护最近 2 轮对话
2. 保护最近 40k tokens 的工具结果
3. 更早的工具结果，只保留 "[Old tool result content cleared]"
```

比如一个 `Read` 工具返回了 5000 行代码，但那是 10 轮对话前的事了，OpenCode 会把输出替换为 `[Old tool result content cleared]`，节省 token。

---

## 六、工具执行的上下文

### 6.1 工具如何获取上下文？

每个工具执行时，会获得一个 `Context` 对象：

```typescript
{
  sessionID,    // 当前会话 ID
  messageID,    // 当前消息 ID
  callID,       // 这次工具调用的唯一 ID
  agent,        // 当前使用的代理名称
  abort,        // 取消信号（用户按 Ctrl+C）
  messages,     // 完整的消息历史

  // 两个重要的回调
  metadata: (data) => {},  // 更新工具执行状态
  ask: (request) => {},    // 请求权限确认
}
```

### 6.2 工具执行的生命周期

```
1. AI 决定调用工具
2. OpenCode 检查权限
   ├─ deny → 返回错误
   ├─ ask → 弹窗问用户
   └─ allow → 继续
3. 创建 ToolPart，状态设为 pending
4. 执行工具
   ├─ 状态变为 running
   ├─ 工具可以调用 metadata() 更新进度
5. 执行完成
   ├─ 成功 → 状态 completed，保存输出
   └─ 失败 → 状态 error，保存错误信息
6. 结果返回给 AI，继续循环
```

### 6.3 权限检查的时机

权限检查在工具执行前进行，基于当前 Agent 的权限配置：

```
Agent 权限配置示例：
{
  "*": "allow",           // 默认允许所有
  "edit": { "*": "deny" }, // 但 plan 代理不能 edit
  "bash": { "rm -rf": "ask" } // 删除操作需要确认
}
```

---

## 七、子任务机制

### 7.1 什么是子任务？

当用户使用 `@agent` 语法（如 `@explore 搜索所有 API`），OpenCode 会创建一个子任务：

```
主循环
├── 检测到 SubtaskPart
├── 创建新的 Assistant Message
├── 使用 TaskTool 执行
│   ├── 启动子代理
│   ├── 子代理有自己的循环
│   └── 子代理完成后返回结果
├── 把结果保存为 ToolPart
└── 继续主循环
```

### 7.2 子任务的特点

- **独立执行**：子任务有自己的消息历史
- **权限隔离**：子代理使用自己的权限配置
- **并行潜力**：可以启动多个子代理并行执行
- **结果汇总**：子任务完成后，主代理会总结结果继续执行

---

## 八、关键设计思想总结

### 8.1 消息驱动 vs 状态机

| 方案 | 优点 | 缺点 |
|-----|------|------|
| **消息驱动** (OpenCode) | 可追溯、可 fork、易持久化 | 消息膨胀、查询复杂 |
| **状态机** | 查询快、内存小 | 状态丢失风险、难回溯 |

### 8.2 流式处理的权衡

**为什么选择流式？**
- 用户体验更好（不用等）
- 可以处理超大响应（边收边处理）
- 支持实时中断

**代价是什么？**
- 代码复杂度增加（要处理各种事件类型）
- 错误恢复更困难

### 8.3 上下文管理的分层策略

OpenCode 不是简单地截断历史，而是采用分层策略：

1. **保留**：最近 2 轮完整对话（保证连贯性）
2. **总结**：较旧的对话用 compaction 压缩成摘要
3. **裁剪**：工具结果只保留最近 40k tokens 的详细内容
4. **丢弃**：更早的工具结果只保留占位符

这样在保证上下文不超限的前提下，最大程度保留有用信息。

---

## 参考代码位置

如果你要看具体实现：

| 功能 | 文件路径 |
|-----|---------|
| 主循环 | `packages/opencode/src/session/prompt.ts` (loop 函数) |
| 流处理 | `packages/opencode/src/session/processor.ts` |
| LLM 调用 | `packages/opencode/src/session/llm.ts` |
| 消息定义 | `packages/opencode/src/session/message-v2.ts` |
| 上下文压缩 | `packages/opencode/src/session/compaction.ts` |
| 代理定义 | `packages/opencode/src/agent/agent.ts` |

---

*基于 OpenCode v1.1.36 分析*
