# Codex Windows Computer Use Fix

一个用于修复 Windows 版 Codex Desktop 中 `Computer Use` / `Chrome` / `Browser` bundled 插件本地状态损坏的 PowerShell 7 脚本。

A PowerShell 7 repair script for broken local bundled-plugin state in Codex Desktop for Windows, especially when `Computer Use`, `Chrome`, or `Browser` becomes unavailable.

## 适用问题

当 Codex Desktop 出现下面这些现象时，本脚本通常有用：

- 设置里显示 `Computer Use` 不可用
- 日志中出现 `Windows Computer Use helper paths are unavailable`
- 日志中出现 `not_in_bundled_marketplace_plugin_names`
- `.tmp\bundled-marketplaces\openai-bundled` 目录残缺
- `notify` 指向已经不存在的旧版 `codex-computer-use.exe`
- `\\.\pipe\codex-computer-use-*` 没有出现

脚本会重建 bundled marketplace、本地插件缓存、`latest` junction，并修复 `config.toml` 中的 helper 路径和插件启用项。

## Requirements

- Windows
- Codex Desktop for Windows
- PowerShell 7+
- 当前用户可以读取 Codex Desktop AppX 安装目录
- 当前用户可以写入自己的 Codex 配置目录，默认是 `$env:USERPROFILE\.codex`

## Quick Start

建议先完全退出 Codex Desktop，再运行脚本。

Preview changes with `-DryRun`:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File ".\repair-codex-computer-use.ps1" -DryRun
```

Run the repair:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File ".\repair-codex-computer-use.ps1"
```

修复完成后，必须重新打开 Codex Desktop。否则 `Computer Use` 的 native pipe 不会重新注入。

## What It Does

脚本会自动执行以下步骤：

1. 通过 `Get-AppxPackage` 定位 Codex Desktop 的 bundled 插件源目录
2. 停止可能锁住 marketplace 的 `extension-host.exe`
3. 备份并重建 `.tmp\bundled-marketplaces\openai-bundled`
4. 同步 `browser` / `chrome` / `computer-use` / `latex` 到插件缓存
5. 根据每个插件真实 `plugin.json` 的版本号重建 `latest` junction
6. 修正 `config.toml` 中的 `notify` helper 路径
7. 补回这些 bundled 插件启用项：
   - `browser@openai-bundled`
   - `chrome@openai-bundled`
   - `computer-use@openai-bundled`

The script intentionally reads the real plugin version from each bundled plugin's `plugin.json`. It does not assume that the Codex Desktop app package version is the same as the plugin version.

## Parameters

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `-DryRun` | `false` | 只预览将要执行的动作，不写入文件 |
| `-CodexHome` | `$env:USERPROFILE\.codex` | Codex 配置目录 |
| `-PackageName` | `OpenAI.Codex` | AppX 包名 |
| `-BundledSourceRoot` | 空 | 手动指定 `openai-bundled` 源目录，适合非标准安装或救急 |

Examples:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File ".\repair-codex-computer-use.ps1" -CodexHome "D:\CodexHome"
```

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File ".\repair-codex-computer-use.ps1" -PackageName "OpenAI.Codex"
```

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File ".\repair-codex-computer-use.ps1" -BundledSourceRoot "C:\Path\To\openai-bundled"
```

## How To Verify

重启 Codex Desktop 后，可以通过以下信号判断是否恢复：

1. 设置页中 `Computer Use` 可用
2. 日志中出现：
   - `bundled_plugins_runtime_marketplace_written pluginCount=4`
   - `computer-use native pipe startup ready`
3. 命名管道里出现：
   - `\\.\pipe\codex-computer-use-*`
4. `Computer Use` 实际调用不再报 `helper paths are unavailable`

## When This Script Will Not Help

这个脚本主要修复本地 bundled marketplace、插件缓存和 `notify` helper 路径漂移。下面这些情况不属于它的修复范围：

1. Codex Desktop 没有安装
2. AppX 包里的 `app\resources\plugins\openai-bundled` 本身缺失或损坏
3. 当前 Codex 不是 Windows/AppX 版，且没有通过 `-BundledSourceRoot` 指定源目录
4. PowerShell 7 不可用
5. Codex 配置不在默认 `$env:USERPROFILE\.codex`，且没有通过 `-CodexHome` 指定
6. `config.toml` 已经严重损坏，无法按 TOML 章节安全修复
7. `codex-computer-use.exe` 被安全软件、系统策略或权限限制阻止启动
8. Codex Desktop 新版本修改了插件 ID、helper 文件名、目录结构或 marketplace 机制
9. 问题来自账号权限、功能灰度、服务端开关、模型或当前会话没有暴露工具
10. `\\.\pipe\codex-computer-use-*` 已存在，但实际调用报业务层错误

In short: this script is useful for local installation-state drift. It is not a fix for account entitlement, server-side rollout, model capability exposure, or a runtime bug inside Computer Use itself.

## Safety Notes

- 脚本会备份原 `.tmp\bundled-marketplaces\openai-bundled` 目录，再重建它
- 脚本会停止当前用户 Codex 插件缓存里的 `extension-host.exe`
- 脚本会修改 `$CodexHome\config.toml`
- 脚本不会创建本地 git 仓库
- 建议先运行 `-DryRun`

## English Summary

This script repairs local bundled-plugin state for Codex Desktop on Windows.

It is designed for cases where Computer Use disappears or fails with messages such as:

- `Windows Computer Use helper paths are unavailable`
- `not_in_bundled_marketplace_plugin_names`
- missing `\\.\pipe\codex-computer-use-*`

It rebuilds the local bundled marketplace, restores plugin cache entries, recreates `latest` junctions, and updates `config.toml` so the `notify` helper path points to the real `codex-computer-use.exe` from the actual bundled plugin version.

Run a preview first:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File ".\repair-codex-computer-use.ps1" -DryRun
```

Then run the repair:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File ".\repair-codex-computer-use.ps1"
```

After the script finishes, fully quit and reopen Codex Desktop.
