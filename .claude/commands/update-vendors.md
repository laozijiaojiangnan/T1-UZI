---
allowed-tools: Bash(*)
description: 更新所有 vendors/ 目录下的第三方库，自动切换到代理模式并执行更新脚本
---

# 更新第三方库

执行以下步骤更新所有 vendors/ 目录下的第三方库：

## 1. 切换到代理模式并执行更新脚本

```bash
proxy && bash /Users/jiangnan/Desktop/T1-UZI/update-repos.sh 2>&1
```

## 2. 等待脚本执行完成

脚本会遍历 vendors/ 目录下的所有 git 仓库，对每个仓库执行 `git pull --ff-only`。

## 3. 总结更新结果

根据命令输出，总结：
- 哪些仓库已更新（显示更新的文件数量和主要变更）
- 哪些仓库已是最新版本
- 是否有更新失败的仓库
