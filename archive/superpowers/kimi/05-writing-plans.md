---
name: writing-plans
description: 在有规格或需求的多步骤任务时使用，在接触代码之前
---

# 编写计划

## 概述

编写全面的实现计划，假设工程师对我们的代码库**一无所知**且品味**值得怀疑**。记录他们需要知道的一切：每个任务要接触哪些文件、代码、测试、可能需要检查的文档、如何测试。将整个计划做成小颗粒度的任务。DRY。YAGNI。TDD。频繁提交。

假设他们是熟练的开发者，但几乎不了解我们的工具集或问题领域。假设他们不太懂好的测试设计。

**开始时宣布：** "我正在使用 writing-plans skill 来创建实现计划。"

**上下文：** 这应该在专用工作树中运行（由 brainstorming skill 创建）。

**保存计划到：** `docs/plans/YYYY-MM-DD-<功能名称>.md`

## 小颗粒度任务

**每个步骤是一个动作（2-5 分钟）：**
- "编写失败测试" - 一个步骤
- "运行测试确保它失败" - 一个步骤
- "实现最少代码让测试通过" - 一个步骤
- "运行测试确保通过" - 一个步骤
- "提交" - 一个步骤

## 计划文档头部

**每个计划必须以这个头部开始：**

```markdown
# [功能名称] 实现计划

> **给 Claude：** 必需子 skill：使用 superpowers:executing-plans 逐个任务实现此计划。

**目标：** [一句话描述要构建什么]

**架构：** [2-3 句话描述方法]

**技术栈：** [关键技术/库]

---
```

## 任务结构

```markdown
### 任务 N：[组件名称]

**文件：**
- 创建：`exact/path/to/file.py`
- 修改：`exact/path/to/existing.py:123-145`
- 测试：`tests/exact/path/to/test.py`

**步骤 1：编写失败测试**

```python
def test_specific_behavior():
    result = function(input)
    assert result == expected
```

**步骤 2：运行测试验证它失败**

运行：`pytest tests/path/test.py::test_name -v`
预期：FAIL with "function not defined"

**步骤 3：编写最少实现**

```python
def function(input):
    return expected
```

**步骤 4：运行测试验证通过**

运行：`pytest tests/path/test.py::test_name -v`
预期：PASS

**步骤 5：提交**

```bash
git add tests/path/test.py src/path/file.py
git commit -m "feat: 添加特定功能"
```
```

## 记住

- 始终使用确切的文件路径
- 计划中包含完整代码（不是"添加验证"）
- 使用 @ 语法引用相关 skills
- DRY、YAGNI、TDD、频繁提交

## 执行交接

保存计划后，提供执行选择：

**"计划完成并保存到 `docs/plans/<文件名>.md`。两种执行选项：**

**1. 子代理驱动（本会话）** - 我逐个任务调度新鲜子代理，任务间审查，快速迭代

**2. 并行会话（单独）** - 在新会话中使用 executing-plans，批量执行并设置检查点

**选择哪种方法？"**

**如果选择子代理驱动：**
- **必需子 skill：** 使用 superpowers:subagent-driven-development
- 保持在本会话
- 新鲜子代理每个任务 + 代码审查

**如果选择并行会话：**
- 引导他们在工作树中打开新会话
- **必需子 skill：** 新会话使用 superpowers:executing-plans