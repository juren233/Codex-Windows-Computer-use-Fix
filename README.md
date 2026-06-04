# Codex Windows Computer Use Fix

[简体中文](README.zh-CN.md) | English

Repair local bundled-plugin state for Codex Desktop on Windows when `Computer Use`, `Chrome`, or `Browser` becomes unavailable.

## Overview

This repository provides a PowerShell 7 script that repairs local Codex Desktop plugin state on Windows.

It is designed for cases where bundled plugins are installed, but Codex Desktop can no longer start or discover the Windows Computer Use helper because local marketplace or plugin cache state drifted.

## Symptoms

This script is likely useful when you see one or more of these signals:

- `Computer Use` is shown as unavailable in Codex Desktop settings
- Codex Desktop logs contain `Windows Computer Use helper paths are unavailable`
- Codex Desktop logs contain `not_in_bundled_marketplace_plugin_names`
- `.tmp\bundled-marketplaces\openai-bundled` is incomplete
- `notify` in `config.toml` points to a missing `codex-computer-use.exe`
- `\\.\pipe\codex-computer-use-*` does not appear after Codex Desktop starts

## Requirements

- Windows
- Codex Desktop for Windows
- PowerShell 7 or newer
- Read access to the Codex Desktop AppX installation directory
- Write access to the Codex home directory, usually `$env:USERPROFILE\.codex`

## Quick Start

Fully quit Codex Desktop before running the repair.

Preview the actions first:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File ".\repair-codex-computer-use.ps1" -DryRun
```

Run the repair:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File ".\repair-codex-computer-use.ps1"
```

After the script finishes, reopen Codex Desktop. The Computer Use native pipe is only injected during Desktop startup.

## What The Script Does

The script performs these actions:

1. Locates the bundled plugin source from the Codex Desktop AppX package
2. Stops `extension-host.exe` if it is running from the Codex bundled plugin cache
3. Backs up and rebuilds `.tmp\bundled-marketplaces\openai-bundled`
4. Syncs `browser`, `chrome`, `computer-use`, and `latex` into the plugin cache
5. Recreates `latest` junctions using each plugin's real `plugin.json` version
6. Updates the `notify` helper path in `config.toml`
7. Ensures these bundled plugins are enabled:
   - `browser@openai-bundled`
   - `chrome@openai-bundled`
   - `computer-use@openai-bundled`

The script reads the real plugin version from each bundled plugin's `plugin.json`. It does not assume the Codex Desktop app package version is the same as the plugin version.

## Parameters

| Parameter | Default | Description |
| --- | --- | --- |
| `-DryRun` | `false` | Preview actions without changing files |
| `-CodexHome` | `$env:USERPROFILE\.codex` | Codex home directory |
| `-PackageName` | `OpenAI.Codex` | AppX package name |
| `-BundledSourceRoot` | empty | Manually provide the `openai-bundled` source directory |

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

## Verification

After restarting Codex Desktop, use these signals to verify the repair:

1. `Computer Use` is available in settings
2. Codex Desktop logs contain `bundled_plugins_runtime_marketplace_written pluginCount=4`
3. Codex Desktop logs contain `computer-use native pipe startup ready`
4. A named pipe matching `\\.\pipe\codex-computer-use-*` exists
5. Computer Use no longer fails with `helper paths are unavailable`

## When This Script Will Not Help

This script repairs local bundled marketplace, plugin cache, and helper path drift. It does not fix every Computer Use failure.

It will not help when:

1. Codex Desktop is not installed
2. The bundled source directory inside the AppX package is missing or corrupted
3. The installation is not the Windows AppX build and no `-BundledSourceRoot` is provided
4. PowerShell 7 is unavailable
5. Codex home is not at `$env:USERPROFILE\.codex` and `-CodexHome` is not provided
6. `config.toml` is too corrupted to edit safely by section
7. Security software or system policy blocks `codex-computer-use.exe`
8. A new Codex Desktop release changes plugin IDs, helper filenames, directory layout, or marketplace behavior
9. The failure is caused by account entitlement, rollout state, server-side configuration, model capability exposure, or session tool exposure
10. `\\.\pipe\codex-computer-use-*` already exists but Computer Use fails with a different runtime or business error

## Safety Notes

- The script backs up the existing `.tmp\bundled-marketplaces\openai-bundled` directory before rebuilding it
- The script stops `extension-host.exe` only when it is running from the Codex bundled plugin cache
- The script modifies `$CodexHome\config.toml`
- The script does not create, clone, or initialize a Git repository
- Run `-DryRun` first when diagnosing a new failure
