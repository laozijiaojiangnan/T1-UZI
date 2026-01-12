# Superpowers 研究报告

> **声明**：本报告基于 `superpowers` 源码分析，侧重于设计思想与架构取舍。

## 1. 概览

### 1.1 项目简介
**Superpowers** 不是一个独立的 Agent 软件，而是一套**通用的软件工程技能库 (Skillset)**，或者说是针对 AI Coding Agent 的**思维框架 (Meta-Framework)**。它旨在“教会”现有的 Agent（如 Claude Code, OpenCode, Codex）遵循严谨的软件工程流程，而非仅仅生成代码。

### 1.2 核心设计哲学
*   **Prompt Engineering as Code**：将复杂的工程流程（如 TDD、Code Review）固化为结构化的 Prompt 文档 (`SKILL.md`)。
*   **Enforced Workflow (强制工作流)**：不建议，而是**强制**。例如在 TDD 技能中，Agent 被明确禁止在测试失败前编写实现代码，甚至被要求删除未测代码。
*   **Platform Agnostic (平台无关)**：通过适配层支持多种 Agent 平台，核心技能定义保持统一。
*   **Context Resilience (上下文韧性)**：特别针对 Agent 上下文窗口限制做了优化，支持在上下文压缩 (Compaction) 后重新注入核心指令。

### 1.3 目录结构概览

| 目录 | 说明 |
| :--- | :--- |
| `skills/` | **技能定义**。核心目录，每个子目录包含一个 `SKILL.md` 定义特定技能。 |
| `lib/` | **共享核心**。包含 `skills-core.js`，负责跨平台的技能解析和查找逻辑。 |
| `.opencode/` | **OpenCode 适配**。包含 OpenCode 插件实现 (`plugin/superpowers.js`)。 |
| `.codex/` | **Codex 适配**。包含 Codex 的 Shell 包装脚本 (`superpowers-codex`)。 |
| `docs/` | **文档**。包含各平台的安装和使用指南。 |

## 2. 核心机制：技能 (Skills)

Superpowers 的灵魂在于其定义的 Skills。每个 Skill 都是一份精心设计的 Prompt，不仅告诉 Agent 做什么，还明确了**不做什么**。

### 2.1 典型技能示例

#### Brainstorming (头脑风暴)
*   **目的**：防止 Agent 一上来就写代码。
*   **机制**：强制 Agent 进行苏格拉底式对话，一次只问一个问题，直到完全理解需求，并生成分段的设计文档供用户确认。

#### Test-Driven Development (TDD)
*   **目的**：确保代码质量和可维护性。
*   **机制**：采用极具压迫感的 Prompt 语气（"Delete it. Start over."），强制执行红-绿-重构循环。它明确禁止了"先写代码再补测试"的常见偷懒行为。

### 2.2 技能加载与优先级
系统支持三层技能加载顺序，允许用户覆盖默认行为：
1.  **Project Skills** (`.opencode/skills/`)：项目级定制，优先级最高。
2.  **Personal Skills** (`~/.config/opencode/skills/`)：用户级定制。
3.  **Superpowers Skills** (`vendors/superpowers/skills/`)：内置标准库。

## 3. 平台集成架构

Superpowers 采用"核心共享 + 平台适配"的架构。

```mermaid
graph TD
    Skills[Skills Library (Markdown)] --> Core[Shared Core (skills-core.js)]
    
    Core --> OpenCodeAdapter[OpenCode Plugin]
    Core --> CodexAdapter[Codex Shell Wrapper]
    Core --> ClaudeAdapter[Claude Code Plugin]
    
    OpenCodeAdapter --> OpenCode[OpenCode Agent]
    CodexAdapter --> Codex[Codex Agent]
    ClaudeAdapter --> Claude[Claude Code Agent]
```

### 3.1 OpenCode 集成
*   **实现方式**：原生 JS 插件。
*   **关键技术**：
    *   **Hook 注入**：利用 `chat.message` 钩子在每次会话开始时注入上下文。
    *   **抗压缩**：监听 `session.compacted` 事件，在上下文被压缩后自动重新加载技能，防止 Agent "失忆"。

### 3.2 Codex 集成
*   **实现方式**：Shell Wrapper。
*   **关键技术**：提供一个 Node.js 脚本 `superpowers-codex`。用户通过自然语言指示 Codex 运行该脚本（如 "Run use-skill brainstorming"），从而将技能内容作为命令输出注入到 Codex 的上下文中。

## 4. 结论与建议

### 4.1 优势
*   **提升 AI 上限**：将初级 Junior Agent 提升为遵循最佳实践的 Senior Engineer。
*   **流程标准化**：确保团队内的所有 AI 辅助开发都遵循相同的 TDD 和 Review 流程。
*   **低成本迁移**：技能定义与平台解耦，未来迁移到新 Agent 平台只需编写简单的适配层。

### 4.2 落地建议
*   **必装插件**：无论使用哪种 Coding Agent，都强烈建议安装 Superpowers。它能有效防止 AI 产生"看似能跑但无法维护"的代码。
*   **定制企业规范**：企业可以 Fork 该仓库，修改 `skills/` 中的 Markdown 文件（例如加入内部的代码规范链接或特定的 Review 流程），打造企业专属的 AI 开发规范。
*   **用于 Onboarding**：不仅用于 AI，这些清晰的 `SKILL.md` 文档本身也是人类新员工学习 TDD 和设计流程的绝佳教材。
