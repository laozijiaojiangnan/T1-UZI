# Superpowers Skills 中文翻译索引

本文档列出了 superpowers 项目中所有 skill 的中文翻译文件。

## Skill 列表

| 序号 | 文件名 | Skill 名称 | 说明 |
|------|--------|-----------|------|
| 01 | [brainstorming.md](./kimi/01-brainstorming.md) | 头脑风暴 | 在进行任何创造性工作之前使用，探索用户意图、需求和设计 |
| 02 | [using-superpowers.md](./kimi/02-using-superpowers.md) | 使用 Superpowers | 每次对话开始时使用，建立如何查找和使用 skill 的方法 |
| 03 | [test-driven-development.md](./kimi/03-test-driven-development.md) | 测试驱动开发 (TDD) | 实现任何功能或修复 bug 时使用，RED-GREEN-REFACTOR 流程 |
| 04 | [systematic-debugging.md](./kimi/04-systematic-debugging.md) | 系统化调试 | 遇到任何 bug 或测试失败时使用，四个阶段调试法 |
| 05 | [writing-plans.md](./kimi/05-writing-plans.md) | 编写计划 | 有规格或需求的多步骤任务时使用，编写实现计划 |
| 06 | [executing-plans.md](./kimi/06-executing-plans.md) | 执行计划 | 执行书面实现计划时使用，批量执行并设置检查点 |
| 07 | [subagent-driven-development.md](./kimi/07-subagent-driven-development.md) | 子代理驱动开发 | 当前会话中执行独立任务时使用，每个任务新鲜子代理 |
| 08 | [dispatching-parallel-agents.md](./kimi/08-dispatching-parallel-agents.md) | 并行代理调度 | 2+ 个独立任务可并行工作时使用 |
| 09 | [requesting-code-review.md](./kimi/09-requesting-code-review.md) | 请求代码审查 | 完成任务或实现主要功能时使用 |
| 10 | [receiving-code-review.md](./kimi/10-receiving-code-review.md) | 接收代码审查 | 接收代码审查反馈时使用，需要技术严谨 |
| 11 | [finishing-a-development-branch.md](./kimi/11-finishing-a-development-branch.md) | 完成开发分支 | 实现完成后使用，指导如何合并、PR 或清理 |
| 12 | [using-git-worktrees.md](./kimi/12-using-git-worktrees.md) | 使用 Git 工作树 | 开始功能工作时使用，创建隔离工作区 |
| 13 | [verification-before-completion.md](./kimi/13-verification-before-completion.md) | 完成前验证 | 声称工作完成时使用，证据先于断言 |
| 14 | [writing-skills.md](./kimi/14-writing-skills.md) | 编写 Skills | 创建或编辑 skill 时使用，TDD 应用于流程文档 |

## 工作流程图

```
┌─────────────────────────────────────────────────────────────────┐
│                        Superpowers 工作流程                       │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌─────────────┐     ┌─────────────┐     ┌─────────────────┐   │
│  │  头脑风暴    │ --> │  编写计划    │ --> │ Git 工作树(可选) │   │
│  │ brainstorming│     │writing-plans│     │using-git-worktrees│ │
│  └─────────────┘     └─────────────┘     └─────────────────┘   │
│        │                                              │         │
│        v                                              v         │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │                   执行阶段 (二选一)                       │   │
│  │  ┌─────────────────┐        ┌─────────────────────────┐ │   │
│  │  │ 子代理驱动开发   │   或   │ 执行计划 (并行会话)      │ │   │
│  │  │subagent-driven- │        │executing-plans          │ │   │
│  │  │   development   │        │                         │ │   │
│  │  └─────────────────┘        └─────────────────────────┘ │   │
│  └─────────────────────────────────────────────────────────┘   │
│        │                         │                             │
│        v                         v                             │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │                    代码审查环节                           │   │
│  │  ┌─────────────────┐        ┌─────────────────────────┐ │   │
│  │  │  请求代码审查    │ <----> │  接收代码审查           │ │   │
│  │  │requesting-code- │        │receiving-code-review    │ │   │
│  │  │    review       │        │                         │ │   │
│  │  └─────────────────┘        └─────────────────────────┘ │   │
│  └─────────────────────────────────────────────────────────┘   │
│        │                                                       │
│        v                                                       │
│  ┌─────────────────┐     ┌─────────────────────────────────┐   │
│  │  完成开发分支    │ --> │         完成前验证               │   │
│  │finishing-a-dev- │     │ verification-before-completion   │   │
│  │  elopment-branch│     │                                 │   │
│  └─────────────────┘     └─────────────────────────────────┘   │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  核心 Skills (贯穿全程):                                  │   │
│  │  • 使用 Superpowers (using-superpowers)                   │   │
│  │  • 测试驱动开发 (test-driven-development)                  │   │
│  │  • 系统化调试 (systematic-debugging)                      │   │
│  │  • 编写 Skills (writing-skills) - 用于维护 skills         │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

## 核心概念

- **RED-GREEN-REFACTOR**: TDD 的核心循环（红-绿-重构）
- **YAGNI**: You Ain't Gonna Need It（你不需要它）
- **TDD**: Test-Driven Development（测试驱动开发）
- **DRY**: Don't Repeat Yourself（不要重复自己）

## 原文位置

英文原文位于：`vendors/superpowers/skills/`
