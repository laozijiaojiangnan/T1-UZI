# Superpowers 库研究报告

> 本报告旨在帮助开发者理解 Superpowers 的设计思想与架构取舍，聚焦于如何构建一个完整的 AI 编程工作流。

## 一、项目概览

### 1.1 是什么

Superpowers 是一套**为 AI 编程代理设计的完整软件开发工作流**，它通过一组可组合的「技能（Skills）」和初始化指令，让 AI 代理在编程时遵循一套经过验证的最佳实践。

**核心理念**：不要一上来就写代码，而是先理解需求、设计方案、制定计划，再通过 TDD 和系统化流程逐步实现。

### 1.2 解决的问题

| 问题 | Superpowers 的解决方案 |
|------|----------------------|
| AI 盲目写代码 | 强制先 brainstoming，理解意图后再动手 |
| AI 代码质量不可控 | TDD 流程 + 两阶段代码审查 |
| 任务太大难以追踪 | 将任务拆解为 2-5 分钟的原子步骤 |
| AI 容易偏离计划 | 钩子系统和技能触发机制强制约束行为 |
| 代码难以维护 | YAGNI、DRY、频繁提交原则 |

### 1.3 适用场景

- 需要 AI 代理长时间独立工作（数小时）
- 对代码质量有较高要求
- 团队需要约束 AI 代理的行为边界
- 希望 AI 遵循 TDD 等工程化实践

---

## 二、目录结构概览

```
superpowers/
├── .claude-plugin/          # Claude Code 插件配置
│   ├── marketplace.json     # 市场元数据
│   └── plugin.json          # 插件声明
├── .codex/                  # Codex 集成配置
│   ├── INSTALL.md           # 安装说明
│   ├── superpowers-bootstrap.md
│   └── superpowers-codex
├── .opencode/               # OpenCode 集成配置
│   ├── INSTALL.md
│   └── plugins/superpowers.js
├── agents/                  # 特殊代理配置
│   └── code-reviewer.md
├── commands/                # 命令定义
│   ├── brainstorm.md
│   ├── execute-plan.md
│   └── write-plan.md
├── docs/                    # 文档
│   ├── plans/               # 设计文档模板
│   ├── README.codex.md
│   └── README.opencode.md
├── hooks/                   # 钩子系统
│   ├── hooks.json           # 钩子配置
│   └── session-start.sh     # 会话启动脚本
├── lib/                     # 核心库
│   └── skills-core.js       # 技能管理核心逻辑
├── skills/                  # 技能库（核心）
│   ├── brainstorming/       # 头脑风暴
│   ├── writing-plans/       # 制定计划
│   ├── executing-plans/     # 执行计划
│   ├── subagent-driven-development/  # 子代理开发
│   ├── test-driven-development/      # TDD
│   ├── using-git-worktrees/ # Git Worktree 管理
│   ├── finishing-a-development-branch/
│   ├── requesting-code-review/
│   ├── receiving-code-review/
│   ├── systematic-debugging/
│   └── writing-skills/      # 技能编写指南
├── tests/                   # 测试用例
│   ├── claude-code/
│   └── subagent-driven-dev/
├── RELEASE-NOTES.md
└── README.md
```

---

## 三、核心模块职责表

| 模块 | 职责 | 关键依赖 | 扩展点 |
|------|------|----------|--------|
| **skills-core.js** | 技能发现、解析、路径解析 | Node.js fs/path | 可扩展技能加载器 |
| **hooks/hooks.json** | 会话生命周期钩子 | Claude Code 钩子系统 | 可添加新钩子 |
| **brainstorming** | 需求澄清、设计探索 | 无 | 可添加问题模板 |
| **writing-plans** | 任务拆解、计划生成 | brainstorming 结果 | 可自定义任务模板 |
| **executing-plans** | 计划分批执行、检查点 | writing-plans 产物 | 可调整批次大小 |
| **subagent-driven-development** | 子代理调度、两阶段审查 | executing-plans | 可自定义审查规则 |
| **test-driven-development** | 红-绿-重构流程 | 执行环境 | 可添加测试框架适配 |
| **using-git-worktrees** | 隔离工作区管理 | Git | 可扩展分支策略 |

---

## 四、核心设计思想

### 4.1 技能（Skill）是什么

**技能 = 场景触发 + 行为规范 + 示例代码**

每个技能是一个独立的文件夹，包含 `SKILL.md` 文件，采用 YAML 前置元数据：

```markdown
---
name: skill-name
description: "Use when [condition] - [what it does]"
---

# Skill 标题

## Overview
技能说明...

## The Process
执行步骤...
```

**技能的核心要素**：
1. **触发条件**：`description` 字段描述何时使用
2. **行为规范**：明确的步骤、约束、红线
3. **示例**：好/坏对比，帮助理解

### 4.2 钩子驱动的自动化

Superpowers 使用钩子系统实现「强制约束」：

```json
// hooks/hooks.json
{
  "hooks": {
    "SessionStart": [{
      "matcher": "startup|resume|clear|compact",
      "hooks": [{
        "type": "command",
        "command": "${CLAUDE_PLUGIN_ROOT}/hooks/session-start.sh"
      }]
    }]
  }
}
```

**设计取舍**：
- 优点：在会话开始时自动加载技能，无需人工干预
- 局限：当前仅支持会话启动钩子，粒度较粗

### 4.3 工作流编排架构

```
┌─────────────────────────────────────────────────────────────┐
│                    用户启动会话                               │
└─────────────────────────┬───────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────┐
│                    钩子系统触发                               │
│              (加载 skills-core.js)                           │
└─────────────────────────┬───────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────┐
│                    brainstorm (必须)                         │
│              理解需求 → 探索方案 → 设计确认                    │
└─────────────────────────┬───────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────┐
│                 using-git-worktrees (推荐)                   │
│              创建独立分支 → 隔离工作区                         │
└─────────────────────────┬───────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────┐
│                   writing-plans (必须)                       │
│           拆解为 2-5 分钟原子步骤 → 完整代码和命令             │
└─────────────────────────┬───────────────────────────────────┘
                          │
            ┌─────────────┴─────────────┐
            ▼                           ▼
┌─────────────────────┐     ┌─────────────────────────────┐
│  subagent-driven-   │     │      executing-plans        │
│  development        │     │  (独立会话分批执行)          │
│  (同会话子代理)      │     │                             │
└─────────────────────┘     └─────────────────────────────┘
            │                           │
            └─────────────┬─────────────┘
                          ▼
┌─────────────────────────────────────────────────────────────┐
│              test-driven-development (每任务)                │
│                  红-绿-重构循环                               │
└─────────────────────────┬───────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────┐
│              requesting-code-review (阶段性)                 │
│              规范合规性 → 代码质量 → 修复循环                  │
└─────────────────────────┬───────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────┐
│            finishing-a-development-branch                    │
│            验证测试 → 合并/PR 选项 → 清理                      │
└─────────────────────────────────────────────────────────────┘
```

### 4.4 子代理开发模式（Subagent-Driven Development）

这是 Superpowers 的核心创新之一：

| 阶段 | 执行者 | 审查者 | 目的 |
|------|--------|--------|------|
| 实现 | 子代理 A | - | 按 TDD 实现功能 |
| 规范审查 | - | 子代理 B | 确认符合设计规范 |
| 质量审查 | - | 子代理 C | 检查代码质量 |

**设计优势**：
- 避免上下文污染：每个任务用全新子代理
- 两阶段审查：先看「对不对」，再看「好不好」
- 自动循环：审查发现问题 → 原实现者修复 → 再次审查

---

## 五、关键机制详解

### 5.1 TDD 流程（Test-Driven Development）

```
┌──────────┐     ┌──────────────┐     ┌──────────┐     ┌──────────────┐
│   RED    │ ──► │ VERIFY RED   │ ──► │  GREEN   │ ──► │ VERIFY GREEN │
│ 写测试    │     │ 确认测试失败  │     │ 写实现    │     │ 确认测试通过  │
└──────────┘     └──────────────┘     └──────────┘     └──────────────┘
      │                │                   │                 │
      │                ▼                   │                 │
      │         ┌──────────┐               │                 │
      │         │ 测试结果  │               │                 │
      │         │ 如预期？  │               │                 │
      │         └────┬─────┘               │                 │
      │              │                     │                 │
      └──────────────┘                     │                 │
               否                           │                 │
                                          ▼                 │
                                    ┌──────────┐            │
                                    │ REFACTOR │ ───────────┘
                                    │  重构     │    保持测试绿色
                                    └──────────┘
```

**铁律**：
> NO PRODUCTION CODE WITHOUT A FAILING TEST FIRST

违反此规则的处理：删除代码，从头开始。

### 5.2 计划拆解粒度

每个任务必须控制在 **2-5 分钟** 内完成：

```markdown
### Task N: 添加用户认证

**Files:**
- Create: `src/auth.ts`
- Modify: `tests/auth.test.ts`

**Step 1: 写失败的测试**
```typescript
test('用户未登录时被重定向', () => {
  const result = protectRoute();
  expect(result.redirectTo).toBe('/login');
});
```

**Step 2: 运行测试，确认失败**
```bash
npm test tests/auth.test.ts
# 期望：FAIL - protectRoute 未定义
```

**Step 3: 写最小实现**
```typescript
function protectRoute() {
  return { redirectTo: '/login' };
}
```

**Step 4: 运行测试，确认通过**
```bash
npm test tests/auth.test.ts
# 期望：PASS
```

**Step 5: 提交**
```bash
git add src/auth.ts tests/auth.test.ts
git commit -m "feat: 添加基础路由保护"
```

**文件路径必须精确、代码必须完整、命令必须可执行。**
```

### 5.3 技能解析机制（skills-core.js）

核心函数：

```javascript
// 从 SKILL.md 提取元数据
extractFrontmatter(filePath) → { name, description }

// 递归查找技能
findSkillsInDir(dir, sourceType, maxDepth) → [{ path, name, description, sourceType }]

// 解析技能路径（支持覆盖）
resolveSkillPath(skillName, superpowersDir, personalDir) → { skillFile, sourceType, skillPath }
```

**设计取舍**：
- **优点**：支持「个人技能覆盖 Superpowers 技能」，允许定制化
- **局限**：仅支持 `superpowers:` 前缀区分命名空间

---

## 六、典型用法示例

### 场景：添加一个新功能

**步骤 1：头脑风暴**
```
用户：我想要一个用户头像功能

AI：我是用 brainstorming 技能来探索这个需求。

首先，请问：
1. 头像的来源是什么？（A. 上传，B. Gravatar，C. 预设头像，D. 都要）
2. 头像的尺寸要求？（A. 固定一种，B. 多种尺寸，C. 可配置）
3. 需要缓存吗？（A. 需要，B. 不需要）
...
```

**步骤 2：生成设计文档**
```
设计文档保存到：docs/plans/2025-01-27-头像功能-design.md

包含：架构、组件、数据流、错误处理、测试策略
```

**步骤 3：创建独立工作区**
```bash
# 使用 using-git-worktrees
git worktree add ../feature-avatars HEAD
cd ../feature-avatars
```

**步骤 4：编写实施计划**
```
计划保存到：docs/plans/2025-01-27-头像功能.md

包含：每个任务的精确文件路径、完整代码、验证命令
```

**步骤 5：执行（选择子代理模式）**
```
AI：我使用 subagent-driven-development 来执行这个计划。

[读取计划，创建 TodoWrite]
[为 Task 1 调度实现子代理]
[实现子代理提问：头像尺寸配置放哪里？]
[回答后继续实现]
[调度规范审查子代理]
[调度代码质量审查子代理]
[标记 Task 1 完成]
...
```

---

## 七、同类工具对比

| 维度 | Superpowers | 传统 Prompt 模板 | Claude Code 默认行为 |
|------|-------------|------------------|---------------------|
| **约束机制** | 钩子 + 技能自动触发 | 手动复制粘贴 | 无强制约束 |
| **工作流完整性** | 端到端（设计→计划→实现→审查） | 片段化 | 依赖人工 |
| **TDD 支持** | 内置、强制 | 需自行添加 | 无 |
| **子代理支持** | 两阶段审查模式 | 简单调度 | 无专门设计 |
| **学习曲线** | 中等（需理解技能系统） | 低 | 无需学习 |
| **定制能力** | 个人技能覆盖 | 完全自行维护 | 无 |

**Superpowers 的差异化优势**：
1. **强制约束**：通过钩子系统确保技能自动触发
2. **经过验证**：作者 Jesse Vincent 是知名开源贡献者（GitHub Copilot contributor）
3. **社区活跃**：持续更新，有完整的贡献指南

---

## 八、落地建议

### 8.1 何时采用

**推荐采用**：
- 团队需要 AI 代理独立工作数小时
- 对代码质量有明确要求
- 希望 AI 遵循工程化实践（TDD、代码审查）
- 愿意投入时间学习技能系统

**暂不推荐**：
- 快速原型探索阶段
- 团队对 TDD 等实践不熟悉
- 无法接受 AI 行为被严格约束

### 8.2 渐进式引入策略

```
阶段 1：试点 1 个技能
├─ 选择 TDD 技能作为切入点
├─ 在非关键项目试用
└─ 收集反馈

阶段 2：扩展到完整工作流
├─ 添加 brainstorming
├─ 添加 writing-plans
└─ 培训团队成员

阶段 3：定制和优化
├─ 根据团队习惯调整技能
├─ 添加团队特定的技能
└─ 建立内部技能库
```

### 8.3 注意事项

1. **技能是「约束」不是「建议」**：Superpowers 的设计目标是强制约束 AI 行为，如果团队只是想提供参考信息，不需要使用 Superpowers

2. **TDD 铁律需要团队共识**：违反 TDD 规则时「删除代码重新开始」这一要求，需要团队认可并执行

3. **子代理成本考量**：subagent-driven-development 模式每个任务调用 3 个子代理，需要评估 API 成本

4. **技能覆盖范围**：当前技能偏向后端/全栈开发，前端特定实践（如视觉回归测试）覆盖较少

### 8.4 可借鉴的设计模式

即使不采用 Superpowers，其设计思想也值得借鉴：

| 模式                       | 适用场景                     |
| ------------------------ | ------------------------ |
| YAML 前置元数据 + Markdown 内容 | 任何需要「可解析的配置 + 人类可读文档」的场景 |
| 两阶段审查（规范 → 质量）           | AI 代码审查流程设计              |
| 2-5 分钟任务粒度               | AI 任务拆解标准                |
| Git Worktree 隔离          | 保护主分支的实验性开发              |

---

## 九、总结

Superpowers 是一套**经过深思熟虑的 AI 编程工作流框架**，其核心价值在于：

1. **约束而非建议**：通过钩子和技能自动触发，确保 AI 遵循最佳实践
2. **完整端到端**：覆盖从需求理解到代码合并的完整生命周期
3. **可组合可扩展**：技能独立，支持个人覆盖团队技能
4. **重视代码质量**：TDD + 两阶段审查确保输出质量

**适合追求高质量 AI 生成代码、愿意接受结构化约束的团队**。

---

## 参考资料

- GitHub 仓库：https://github.com/obra/superpowers
- 官方文档：https://github.com/obra/superpowers/tree/main
- 安装指南：https://raw.githubusercontent.com/obra/superpowers/refs/heads/main/.claude-plugin/plugin.json
