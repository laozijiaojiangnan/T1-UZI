# OpenSpec 研究报告

> **阅读指南**：
> - 🟦 蓝色区块 = **必读**，核心内容
> - 🟨 黄色区块 = **进阶**，理解核心后再看
> - ⚪ 灰色折叠 = **细节**，需要时才展开

---

## 🟦 30 秒了解

### 一句话解释

**OpenSpec 是一个"装修清单"工具**——让你在改代码前先写清楚"改哪里、怎么改"，AI 按清单帮你改，改完打勾归档。

### 装修类比（核心！）

| OpenSpec | 装修房子 |
|----------|----------|
| **全局 Spec** | 户口本——记录房子现在什么样 |
| **Delta** | 变更申请书——只写"我要改什么" |
| **Change** | 一个装修项目——一个文件夹装所有资料 |
| **Archive** | 完工存档——更新户口本 |

### 决策树：我该用吗？

```
我要改代码了
    │
    ├── 项目有 3+ 个功能？
    │       ├── 否 → 【不用】直接写
    │       │
    │       └── 是 → 经常改到一半发现理解错了？
    │               ├── 否 → 【不用】
    │               │
    │               └── 是 → 【⭐ 推荐用】
    │
    └── 1 个月后会忘记为什么改？
            └── 是 → 【⭐ 推荐用】
```

---

## 🟦 快速开始（3 步）

### 第 1 步：安装
```bash
npm install -g @fission-ai/openspec
```

### 第 2 步：初始化
```bash
cd your-project
openspec init
# 选择你的 AI 工具（Cursor/Claude/...）
```

### 第 3 步：创建第一个变更
```bash
openspec change new my-first-feature
```

---

## 🟦 5 分钟实战

**目标**：添加一个 `/health` 接口，返回 `{"status": "ok"}`

### Step 1：创建变更（30 秒）
```bash
openspec change new health-check
```

### Step 2：写 Proposal（1 分钟）
编辑 `openspec/changes/health-check/proposal.md`：

```markdown
# 提案：健康检查接口

## 为什么要做
需要监控 API 是否正常运行。

## 范围
- 包含：GET /health 接口
- 不包含：数据库检查（以后做）
```

### Step 3：生成设计（30 秒）
```bash
openspec change continue health-check
```

AI 生成了 `design.md` 和 `tasks.md`。

### Step 4：编码（2 分钟）
在 AI 助手执行：
```
/opsx:apply
```

AI 读取 `tasks.md`，帮你写代码。

### Step 5：归档（30 秒）
```bash
openspec change archive health-check
```

**完成！** 你的规范现在保存在 `openspec/specs/` 里。

---

## 🟦 核心概念详解

### 为什么需要 Delta？

**问题**：两个人同时改登录功能

**直接改文件**：
```
你改 auth.md → 同事也改 auth.md → Git 冲突！
```

**用 Delta**：
```
openspec/changes/
├── your-change/specs/auth.md      # 你只写你改的
└── colleague-change/specs/auth.md  # 同事只写他改的
```
归档时才合并，**互不干扰**。

### Delta 三要素

```markdown
# 认证模块变更

## 新增需求                    ← ADDED
### 双因素认证
- 系统必须支持短信验证码

## 修改需求                    ← MODIFIED
### 会话过期时间
- 会话必须在 15 分钟后过期  ← 原来是 30 分钟

## 删除需求                    ← REMOVED
### 旧版认证
- （不再需要）
```

### 归档时发生什么？

```
变更前：                      归档后：

openspec/specs/auth.md        openspec/specs/auth.md
├── 登录功能                   ├── 登录功能
└── 登出功能                   ├── 登出功能
                              ├── 双因素认证      ← 新增追加
                              └── 会话过期: 15分钟  ← 修改替换

changes/add-2fa/              changes/archive/2025-01-24-add-2fa/
specs/auth.md                 specs/auth.md
└── 变更: 新增双因素认证        └── 变更: 新增双因素认证
```

---

## 🟨 完整例子：添加登录功能

### 第 1 步：创建变更
```bash
openspec change new add-login
```

生成：
```
openspec/changes/add-login/
├── proposal.md      # 待填写
├── specs/           # 待填写
├── design.md        # AI 生成
├── tasks.md         # AI 生成
└── .openspec.yaml   # 配置
```

### 第 2 步：写 Delta 规范
在 `specs/auth.spec.md` 里写：

```markdown
# 认证模块变更

## 新增需求
### 用户登录功能
系统必须允许用户使用用户名和密码登录。

#### 场景：登录成功
- 假设用户输入了正确的密码
- 当用户点击登录按钮
- 那么用户看到仪表盘页面

#### 场景：密码错误
- 假设用户输入了错误的密码
- 当用户点击登录按钮
- 那么显示"密码错误"提示
```

### 第 3 步：让 AI 生成设计
```bash
openspec change continue add-login
```

AI 读取你的 Delta，生成 `design.md`：
```markdown
# 设计：用户登录功能

## 方案
1. 创建登录页面 LoginPage.tsx
2. 创建认证接口 auth.ts
3. 添加密码校验逻辑
```

### 第 4 步：让 AI 生成任务清单
```bash
openspec change continue add-login
```

生成 `tasks.md`：
```markdown
# 任务清单

## 1. 前端
- [ ] 创建登录页面 LoginPage.tsx
- [ ] 添加路由 /login

## 2. 后端
- [ ] 创建 POST /api/login 接口
- [ ] 添加密码校验

## 3. 测试
- [ ] 测试正确密码登录
- [ ] 测试错误密码提示
```

### 第 5 步：让 AI 帮你写代码
在 Cursor/Claude 里执行：
```
/opsx:apply
```

AI 读取 `tasks.md`，一个一个帮你写。每完成一个，你打勾 `[x]`。

### 第 6 步：归档
```bash
openspec change archive add-login
```

---

## 🟨 工件流水线

### 4 个车间

```
车间1: Proposal        车间2: Specs        车间3: Design       车间4: Tasks
┌──────────────┐      ┌──────────────┐    ┌──────────────┐    ┌──────────────┐
│ 写清楚       │      │ 写清楚       │    │ AI生成       │    │ AI生成       │
│ "为什么要做" │ ───→ │ "要做什么"   │ ──→│ "怎么做"     │ ──→│ "一步步做"   │
└──────────────┘      └──────────────┘    └──────────────┘    └──────────────┘
      │                      │
      └──────────────────────┘
```

### ff vs continue

| 命令 | 作用 | 什么时候用 |
|------|------|-----------|
| `/opsx:ff` | Fast Forward，批量生成所有缺失工件 | 你写好了 Proposal，想一口气生成 Specs+Design+Tasks |
| `/opsx:continue` | 只生成下一个缺失工件 | 你想一步步来，先 review 完 Specs 再生成 Design |

### 时序图

```
你          AI助手       OpenSpec      文件系统
│            │            │             │
├─/opsx:new→│            │             │
│            ├───────────→│             │
│            │            ├─创建文件夹──→│
│            │            │←────────────┤
│←───────────┤            │             │
│            │            │             │
├─/opsx:ff──→│            │             │
│            ├───────────→│             │
│            │            ├─查依赖图────→│
│            │            ├─拓扑排序     │
│            │            ├─生成文件────→│
│←───────────┤            │             │
│            │            │             │
├─/opsx:apply→│           │             │
│            ├────────────┼─读tasks.md──→│
│            │            │←────────────┤
│            │            │             │
│←───────────┤            │             │
```

---

## ❌ 出错了怎么办

### 错误 1：AI 生成的设计不对

**现象**：Design 里说要改数据库，但 Proposal 里明确说了不改。

**解决**：
1. 直接编辑 `design.md`，删除数据库相关内容
2. 或者重新生成：`openspec change continue <name> --regenerate`

### 错误 2：归档时冲突

**现象**：提示 "Cannot archive, spec has changed"

**原因**：全局规范在你创建变更后被修改了。

**解决**：
```bash
# 先更新你的 Delta 以匹配最新全局规范
openspec change update <name>
# 然后再归档
openspec change archive <name>
```

### 错误 3：/opsx:apply 没反应

**检查**：
1. 是否创建了 `tasks.md`？（必须先有 tasks 才能 apply）
2. 是否在正确的 AI 工具里？

---

## ⚪ 技术细节（按需展开）

**💡 为什么 AI 能识别 /opsx:new 命令？**

执行 `openspec init` 时，OpenSpec 会为你的 AI 工具生成命令文件。

**以 Cursor 为例**，生成文件：

```
.cursor/commands/opsx-new.md
```

文件内容：
```yaml
name: /opsx:new
description: 创建新变更
---
当你执行 /opsx:new <名称> 时：
1. 创建一个文件夹 openspec/changes/<名称>/
2. 生成 proposal.md 模板
```

这样 Cursor 就学会了这个命令。

---

**💡 支持 20+ 工具是怎么做到的？**

**核心思想：内容统一，格式各异**

OpenSpec 只定义"说什么"：
```typescript
{
  id: "new",
  name: "创建新变更",
  body: "创建文件夹 → 生成模板"
}
```

每个工具有自己的"翻译器"（适配器）：

| AI 工具 | 生成文件路径 | 格式特点 |
|:---|:---|:---|
| **Cursor** | `.cursor/commands/opsx-new.md` | Markdown + YAML 头 |
| **Claude** | `.claude/commands/opsx/new.md` | 纯 Markdown |
| **Codex** | `~/.codex/prompts/opsx-new.md` | TOML 格式 |

**加新工具很容易**：写一个新的适配器（约 30 行代码）。

---

## 📋 总结卡片

| 项目 | 内容 |
|------|------|
| **一句话** | 改代码前先写清单，AI 按清单帮你改 |
| **4 个文件** | proposal.md (为什么) / specs/*.md (改什么) / design.md (怎么做) / tasks.md (一步步做) |
| **5 个命令** | `init` / `change new` / `continue` / `apply` (AI 里) / `archive` |
| **Delta 三要素** | 新增 (ADDED) / 修改 (MODIFIED) / 删除 (REMOVED) |
| **什么时候用** | 项目大 + 协作多 + 怕忘 |

---

## 优化日志（10 轮重构）

| 轮次 | 主要改进 | 解决的问题 |
|:---:|:---|:---|
| 1 | 基础框架 + 装修类比 | 零基础入门 |
| 2 | 加入完整例子 | 不知道怎么操作 |
| 3 | 解释"两本 specs" | 全局 Spec vs Delta 混淆 |
| 4 | 工件流水线 + 命令区别 | ff vs continue 不知道用哪个 |
| 5 | 快速上手 + 技术细节折叠 | 门槛太高 |
| 6 | 开篇对比 + FAQ | 价值主张不清晰 |
| 7 | 决策树 + 速查版 | 不知道自己该不该用 |
| 8 | 颜色区块 + 渐进式披露 | 内容混在一起难读 |
| 9 | 5 分钟实战 + 错误处理 | 缺少动手例子 |
| 10 | 最终打磨 + 总结卡片 | 一致性检查 |

---

## 与同类工具对比

| 维度 | OpenSpec | Cursor Rules | Claude Commands |
|:---|:---|:---|:---|
| **定位** | 规范驱动开发系统 | IDE 规则文件 | AI 命令文件 |
| **核心** | Changes + Delta | `.cursorrules` | Slash Commands |
| **版本管理** | 显式归档 | 无 | 无 |
| **多工具** | 20+ | Cursor 独占 | Claude 独占 |
| **协作** | 并行变更 | 单人 | 单人 |

---

*报告生成完成 | 共 10 轮重构*
