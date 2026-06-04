# Codex Windows Computer Use 修复脚本

简体中文 | [English](README.md)

用于修复 Windows 版 Codex Desktop 中 `Computer Use`、`Chrome`、`Browser` bundled 插件本地状态损坏的问题。

## 概述

这个仓库提供一个 PowerShell 7 修复脚本，用于修复 Windows 版 Codex Desktop 的本地 bundled 插件状态。

它适用于插件明明已经安装，但 Codex Desktop 因为本地 marketplace、插件缓存或 helper 路径漂移，无法启动或发现 Windows Computer Use helper 的情况。

## 适用现象

出现以下现象时，这个脚本通常有用：

- Codex Desktop 设置中显示 `Computer Use` 不可用
- Codex Desktop 日志中出现 `Windows Computer Use helper paths are unavailable`
- Codex Desktop 日志中出现 `not_in_bundled_marketplace_plugin_names`
- `.tmp\bundled-marketplaces\openai-bundled` 目录残缺
- `config.toml` 里的 `notify` 指向已经不存在的旧版 `codex-computer-use.exe`
- Codex Desktop 启动后没有出现 `\\.\pipe\codex-computer-use-*`

## 环境要求

- Windows
- Windows 版 Codex Desktop
- PowerShell 7 或更高版本
- 当前用户可以读取 Codex Desktop AppX 安装目录
- 当前用户可以写入 Codex home 目录，默认是 `$env:USERPROFILE\.codex`

## 快速开始

从最新 Release 下载 `repair-codex-computer-use.ps1`：

<https://github.com/juren233/Codex-Windows-Computer-use-Fix/releases/latest>

也可以直接用 PowerShell 下载：

```powershell
Invoke-WebRequest -Uri "https://github.com/juren233/Codex-Windows-Computer-use-Fix/releases/latest/download/repair-codex-computer-use.ps1" -OutFile ".\repair-codex-computer-use.ps1"
```

运行修复前，建议先完全退出 Codex Desktop。脚本启动时如果没有传 `-Language`，会先要求选择语言。

先预演将要执行的动作：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File ".\repair-codex-computer-use.ps1" -DryRun
```

执行正式修复：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File ".\repair-codex-computer-use.ps1"
```

脚本执行完成后，需要重新打开 Codex Desktop。`Computer Use` 的 native pipe 只会在 Desktop 启动阶段重新注入。

`-DryRun` 是当前状态检查加修复计划。因为它不会真正写入、重建或备份，所以可能显示某些项目当前未就绪；确认计划后去掉 `-DryRun` 才会执行正式修复。

如果用于自动化，也可以跳过交互式语言选择：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File ".\repair-codex-computer-use.ps1" -Language zh-CN
```

## 脚本会做什么

脚本会自动执行以下动作：

1. 从 Codex Desktop AppX 包中定位 bundled 插件源目录
2. 停止从 Codex bundled 插件缓存中启动的 `extension-host.exe`
3. 备份并重建 `.tmp\bundled-marketplaces\openai-bundled`
4. 将 `browser`、`chrome`、`computer-use`、`latex` 同步到插件缓存
5. 根据每个插件真实 `plugin.json` 版本号重建 `latest` junction
6. 即使版本目录已经存在，也会校验关键文件，缓存残缺时会备份后重建
7. 备份并修正 `config.toml` 中的 `notify` helper 路径
8. 确保以下 bundled 插件启用：
   - `browser@openai-bundled`
   - `chrome@openai-bundled`
   - `computer-use@openai-bundled`
9. 执行最终硬校验，关键项不通过时以失败退出

脚本会读取每个 bundled 插件 `plugin.json` 中的真实插件版本号，不会把 Codex Desktop 的 App 包版本误当成插件版本。

## 参数

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `-DryRun` | `false` | 只预览动作，不写入文件 |
| `-CodexHome` | `$env:USERPROFILE\.codex` | Codex home 目录 |
| `-PackageName` | `OpenAI.Codex` | AppX 包名 |
| `-BundledSourceRoot` | 空 | 手动指定 `openai-bundled` 源目录 |
| `-Language` | 启动时选择 | `zh-CN` 或 `en-US` |
| `-Yes` | `false` | 跳过最终确认提示 |

示例：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File ".\repair-codex-computer-use.ps1" -CodexHome "D:\CodexHome"
```

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File ".\repair-codex-computer-use.ps1" -PackageName "OpenAI.Codex"
```

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File ".\repair-codex-computer-use.ps1" -BundledSourceRoot "C:\Path\To\openai-bundled"
```

## 如何验证

重新打开 Codex Desktop 后，可以通过以下信号判断是否恢复：

1. 设置页中 `Computer Use` 可用
2. Codex Desktop 日志中出现 `bundled_plugins_runtime_marketplace_written pluginCount=4`
3. Codex Desktop 日志中出现 `computer-use native pipe startup ready`
4. 命名管道里出现 `\\.\pipe\codex-computer-use-*`
5. Computer Use 实际调用不再报 `helper paths are unavailable`

可复制的验证命令：

```powershell
Get-ChildItem -Path "\\.\pipe\" | Where-Object { $_.Name -like "codex-computer-use-*" }
```

```powershell
$logRoot = "$env:LOCALAPPDATA\Packages\OpenAI.Codex_2p2nqsd0c76g0\LocalCache\Local\Codex\Logs"
Get-ChildItem -Path $logRoot -Recurse -Filter "codex-desktop-*.log" |
  Sort-Object LastWriteTime -Descending |
  Select-Object -First 1 |
  Select-String -Pattern "computer-use native pipe startup ready|helper paths are unavailable|not_in_bundled_marketplace_plugin_names"
```

## 日志与备份

正式修复会把完整执行日志写到：

```text
$CodexHome\repair-logs\computer-use\repair-*.log
```

脚本退出前也会打印每个备份路径。常见备份路径包括：

```text
$CodexHome\config.toml.backup-YYYYMMDD-HHMMSS
$CodexHome\.tmp\bundled-marketplaces\openai-bundled.backup-YYYYMMDD-HHMMSS
$CodexHome\plugins\cache\openai-bundled\<plugin>\<version>.backup-YYYYMMDD-HHMMSS
```

`-DryRun` 不会创建日志、备份或文件改动。正式运行会在退出前打印精确日志路径和每个备份路径。

## 什么情况下不适用

这个脚本修复的是本地 bundled marketplace、插件缓存和 helper 路径漂移。它不能修复所有 Computer Use 问题。

以下情况不适用：

1. Codex Desktop 没有安装
2. AppX 包里的 bundled 源目录缺失或损坏
3. 当前不是 Windows AppX 版 Codex，且没有通过 `-BundledSourceRoot` 指定源目录
4. PowerShell 7 不可用
5. Codex home 不在默认 `$env:USERPROFILE\.codex`，且没有通过 `-CodexHome` 指定
6. `config.toml` 已经严重损坏，无法按 TOML 章节安全修复
7. 安全软件或系统策略阻止 `codex-computer-use.exe` 启动
8. 新版 Codex Desktop 修改了插件 ID、helper 文件名、目录结构或 marketplace 机制
9. 问题来自账号权限、灰度状态、服务端配置、模型能力暴露或当前会话工具暴露
10. `\\.\pipe\codex-computer-use-*` 已经存在，但 Computer Use 报的是其他运行时错误或业务错误

## 安全说明

- 脚本会在重建前备份现有 `.tmp\bundled-marketplaces\openai-bundled` 目录
- 脚本只会停止从 Codex bundled 插件缓存中启动的 `extension-host.exe`
- 脚本会备份并修改 `$CodexHome\config.toml`
- 脚本不会创建、克隆或初始化 Git 仓库
- 诊断新问题时，建议先运行 `-DryRun`
