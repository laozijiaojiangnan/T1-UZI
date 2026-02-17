---
name: requesting-code-review
description: 在完成任务、实现主要功能，或合并前验证工作符合需求时使用
---

# 请求代码审查

在问题级联前派发 superpowers:code-reviewer subagent 捕获问题。

**核心原则：** 早审查，常审查。

## 何时请求审查

**强制：**
- subagent 驱动开发中每个任务后
- 完成主要功能后
- 合并到 main 前

**可选但有价值：**
- 卡住时（新鲜视角）
- 重构前（基线检查）
- 修复复杂 bug 后

## 如何请求

**1. 获取 git SHAs：**
```bash
BASE_SHA=$(git rev-parse HEAD~1)  # 或 origin/main
HEAD_SHA=$(git rev-parse HEAD)
```

**2. 派发 code-reviewer subagent：**

使用 Task 工具与 superpowers:code-reviewer 类型，填写 `code-reviewer.md` 模板

**占位符：**
- `{WHAT_WAS_IMPLEMENTED}` - 你刚构建了什么
- `{PLAN_OR_REQUIREMENTS}` - 它应该做什么
- `{BASE_SHA}` - 起始提交
- `{HEAD_SHA}` - 结束提交
- `{DESCRIPTION}` - 简要摘要

**3. 根据反馈行动：**
- 立即修复 Critical 问题
- 继续前修复 Important 问题
- 稍后记录 Minor 问题
- 如果审查者错了，用理由反驳

## 示例

```
[刚完成任务 2：添加验证功能]

你：让我在继续前请求代码审查。

BASE_SHA=$(git log --oneline | grep "任务 1" | head -1 | awk '{print $1}')
HEAD_SHA=$(git rev-parse HEAD)

[派发 superpowers:code-reviewer subagent]
  WHAT_WAS_IMPLEMENTED: 对话索引的验证和修复功能
  PLAN_OR_REQUIREMENTS: docs/plans/deployment-plan.md 的任务 2
  BASE_SHA: a7981ec
  HEAD_SHA: 3df7661
  DESCRIPTION: 添加了 verifyIndex() 和 repairIndex()，4 种问题类型

[Subagent 返回]：
  优点：干净架构，真实测试
  问题：
    重要：缺少进度指示器
    轻微：Magic number (100) 用于报告间隔
  评估：准备继续

你：[修复进度指示器]
[继续任务 3]
```

## 与工作流集成

**Subagent 驱动开发：**
- 每个任务后审查
- 在问题复合前捕获
- 进入下一任务前修复

**执行计划：**
- 每批次（3 任务）后审查
- 获取反馈，应用，继续

**临时开发：**
- 合并前审查
- 卡住时审查

## 红旗

**绝不：**
- 因为"简单"跳过审查
- 忽略 Critical 问题
- 有未修复 Important 问题就继续
- 与有效技术反馈争论

**如果审查者错了：**
- 用技术理由反驳
- 展示证明有效的代码/测试
- 请求澄清

模板见：requesting-code-review/code-reviewer.md
