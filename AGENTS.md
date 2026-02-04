# CLAUDE.md

分析 GitHub 仓库的研究项目。

## 核心原则

- 如果是研究【repo】使用 `github-repo-analyzer` skill
- 如果是研究【核心模块】使用 `github-module-analyzer` skill

## 目录结构

- notes: 我自己写的文档
- research: 存放所有的研究报告
- archive: 存放已废弃的研究报告（回收站）
- vendors: 存放所有第三方库，全都是 git pull 拉下来的

## 研究报告生成要求

#### repo 研究报告

路径：`research/{repo_name}/{repo_name}.md`

#### 核心模块研究报告

路径：`research/{repo_name}/{repo_name}-{核心模块名}.md`
