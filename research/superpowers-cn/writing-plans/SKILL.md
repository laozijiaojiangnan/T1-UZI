---
name: writing-plans
description: 当你有规格或多步骤任务的需求时，在接触代码之前使用
---

# 编写计划

## 概述

编写全面的实现计划，假设工程师对我们的代码库零上下文且品味欠佳。记录他们需要知道的一切：每个任务要接触哪些文件、代码、测试、他们可能需要检查的文档、如何测试它。将整个计划作为小颗粒度的任务给出。DRY. YAGNI. TDD. 频繁提交。

假设他们是熟练的开发者，但几乎不了解我们的工具集或问题领域。假设他们不太懂好的测试设计。

**开始时宣布：** "我正在使用 writing-plans skill 来创建实现计划。"

**上下文：** 这应该在专用的 worktree 中运行（由 brainstorming skill 创建）。

**保存计划到：** `docs/plans/YYYY-MM-DD-<feature-name>.md`

## 小颗粒度任务

**每个步骤是一个动作（2-5 分钟）：**
- "编写失败测试" - 步骤
- "运行它确保失败" - 步骤
- "实现最小代码让测试通过" - 步骤
- "运行测试确保通过" - 步骤
- "提交" - 步骤

## 计划文档头部

**每个计划必须以这个头部开始：**

```markdown
# [功能名称] 实现计划

> **给 Claude：** 必需子技能：使用 superpowers:executing-plans 逐任务实现此计划。

**目标：** [一句话描述构建什么]

**架构：** [2-3 句关于方案]

**技术栈：** [关键技术/库]

---
```

## 任务结构

```markdown
### 任务 N: [组件名称]

**文件：**
- 创建: `exact/path/to/file.py`
- 修改: `exact/path/to/existing.py:123-145`
- 测试: `tests/exact/path/to/test.py`

**步骤 1: 编写失败测试**

```python
def test_specific_behavior():
    result = function(input)
    assert result == expected
```

**步骤 2: 运行测试验证失败**

运行: `pytest tests/path/test.py::test_name -v`
预期: FAIL with "function not defined"

**步骤 3: 编写最小实现**

```python
def function(input):
    return expected
```

**步骤 4: 运行测试验证通过**

运行: `pytest tests/path/test.py::test_name -v`
预期: PASS

**步骤 5: 提交**

```bash
git add tests/path/test.py src/path/file.py
git commit -m "feat: add specific feature"
```
```

## 记住

- 始终使用精确文件路径
- 计划中包含完整代码（不是"添加验证"）
- 精确命令及预期输出
- 使用 @ 语法引用相关 skills
- DRY, YAGNI, TDD, 频繁提交

## 执行交接

保存计划后，提供执行选择：

**"计划已完成并保存到 `docs/plans/<filename>.md`。两种执行选项：**

**1. Subagent 驱动（本会话）** - 我为每个任务派新鲜 subagent，任务间审查，快速迭代

**2. 并行会话（分开）** - 用 executing-plans 开启新会话，批量执行带检查点

**选择哪种方式？"**

**如果选择 Subagent 驱动：**
- **必需子技能：** 使用 superpowers:subagent-driven-development
- 保持在本会话
- 每个任务新鲜 subagent + 代码审查

**如果选择并行会话：**
- 引导他们在 worktree 中开启新会话
- **必需子技能：** 新会话使用 superpowers:executing-plans
