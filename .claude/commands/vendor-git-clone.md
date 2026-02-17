---
allowed-tools: Bash(git:*)
description: 克隆 GitHub 仓库到 vendors/ 目录，如已存在则更新，并切换到代理模式
---

# Vendor Git Clone

克隆 GitHub 仓库到 vendors/ 目录。如果仓库已存在，则执行更新。

## 参数

- `$ARGUMENTS` - GitHub 仓库地址，支持格式：
  - SSH: `git@github.com:owner/repo.git`
  - HTTPS: `https://github.com/owner/repo.git`

## 工作流程

### 1. 解析仓库名

从 URL 中提取仓库名：
- `git@github.com:MoonshotAI/kimi-cli.git` → `kimi-cli`
- `https://github.com/anthropics/claude-code.git` → `claude-code`

### 2. 克隆或更新仓库

```bash
# 切换到 vendors 目录
cd /Users/jiangnan/Desktop/T1-UZI/vendors

# 检查目录是否已存在
if [ -d "$REPO_NAME/.git" ]; then
  cd "$REPO_NAME"
  git fetch origin
  git pull origin main
else
  git clone "$GITHUB_URL"
  cd "$REPO_NAME"
fi
```

### 3. 切换到代理模式

```bash
proxy
git remote -v
unproxy
```

## 示例

```
/vendor-git-clone git@github.com:MoonshotAI/kimi-cli.git
```
