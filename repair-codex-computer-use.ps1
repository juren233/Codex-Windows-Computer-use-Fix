[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Yes,
    [ValidateSet('zh-CN', 'en-US')]
    [string]$Language,
    [string]$CodexHome = (Join-Path $env:USERPROFILE '.codex'),
    [string]$PackageName = 'OpenAI.Codex',
    [string]$BundledSourceRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:UiLanguage = 'zh-CN'
$script:BackupPaths = [System.Collections.Generic.List[string]]::new()
$script:TranscriptStarted = $false
$script:LogPath = $null

function Select-UiLanguage {
    if (-not [string]::IsNullOrWhiteSpace($Language)) {
        $script:UiLanguage = $Language
        return
    }

    Write-Host ''
    Write-Host '==============================================='
    Write-Host ' Codex Windows Computer Use Fix'
    Write-Host '==============================================='
    Write-Host '1. 简体中文'
    Write-Host '2. English'
    Write-Host ''

    while ($true) {
        $choice = Read-Host '请选择语言 / Select language [1/2]'
        switch ($choice) {
            '1' {
                $script:UiLanguage = 'zh-CN'
                return
            }
            '2' {
                $script:UiLanguage = 'en-US'
                return
            }
            default {
                Write-Host '请输入 1 或 2 / Please enter 1 or 2.'
            }
        }
    }
}

function T {
    param(
        [string]$Zh,
        [string]$En
    )

    if ($script:UiLanguage -eq 'en-US') {
        return $En
    }
    return $Zh
}

function Write-Title {
    Write-Host ''
    Write-Host '==============================================='
    Write-Host (T 'Codex Computer Use 修复向导' 'Codex Computer Use Repair Wizard')
    Write-Host '==============================================='
}

function Write-Section {
    param(
        [string]$Zh,
        [string]$En
    )

    Write-Host ''
    Write-Host ('== ' + (T $Zh $En) + ' ==')
}

function Write-Step {
    param(
        [string]$Zh,
        [string]$En
    )

    Write-Host ('[*] ' + (T $Zh $En))
}

function Write-Ok {
    param(
        [string]$Zh,
        [string]$En
    )

    Write-Host ('[OK] ' + (T $Zh $En))
}

function Write-WarnLine {
    param(
        [string]$Zh,
        [string]$En
    )

    Write-Warning (T $Zh $En)
}

function Write-InfoLine {
    param(
        [string]$LabelZh,
        [string]$LabelEn,
        [string]$Value
    )

    Write-Host ((T $LabelZh $LabelEn) + ': ' + $Value)
}

function Assert-PowerShell7 {
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        throw (T "必须使用 PowerShell 7 或更高版本运行。当前版本: $($PSVersionTable.PSVersion)" "PowerShell 7 or newer is required. Current version: $($PSVersionTable.PSVersion)")
    }
}

function Convert-ToExtendedWindowsPath {
    param([string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if ($fullPath.StartsWith('\\?\', [System.StringComparison]::OrdinalIgnoreCase)) {
        return $fullPath
    }

    if ($fullPath.StartsWith('\\', [System.StringComparison]::OrdinalIgnoreCase)) {
        return "\\?\UNC\$($fullPath.TrimStart('\'))"
    }

    return "\\?\$fullPath"
}

function Start-RepairTranscript {
    param([string]$CodexHomePath)

    if ($DryRun) {
        Write-WarnLine 'DryRun 模式不会创建日志文件或修改文件。' 'DryRun mode does not create a log file or modify files.'
        return
    }

    $logRoot = Join-Path $CodexHomePath 'repair-logs\computer-use'
    New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
    $script:LogPath = Join-Path $logRoot ("repair-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Start-Transcript -Path $script:LogPath -Append | Out-Null
    $script:TranscriptStarted = $true
    Write-InfoLine '日志文件' 'Log file' $script:LogPath
}

function Stop-RepairTranscript {
    if ($script:TranscriptStarted) {
        Stop-Transcript | Out-Null
        $script:TranscriptStarted = $false
    }
}

function Confirm-RepairPlan {
    param(
        [string]$CodexHomePath,
        [string]$ConfigPath,
        [string]$TmpMarketplaceRoot,
        [string]$CacheMarketplaceRoot
    )

    Write-Section '执行计划' 'Repair plan'
    Write-InfoLine 'Codex home' 'Codex home' $CodexHomePath
    Write-InfoLine '配置文件' 'Config file' $ConfigPath
    Write-InfoLine 'Marketplace 目录' 'Marketplace directory' $TmpMarketplaceRoot
    Write-InfoLine '插件缓存目录' 'Plugin cache directory' $CacheMarketplaceRoot

    Write-Host ''
    Write-Host (T '脚本将执行以下动作：' 'The script will perform these actions:')
    Write-Host (T '1. 备份并重建 bundled marketplace。' '1. Back up and rebuild the bundled marketplace.')
    Write-Host (T '2. 校验并修复 bundled 插件缓存。' '2. Validate and repair the bundled plugin cache.')
    Write-Host (T '3. 重建 latest junction。' '3. Recreate latest junctions.')
    Write-Host (T '4. 备份并更新 config.toml。' '4. Back up and update config.toml.')
    Write-Host (T '5. 执行最终硬校验。' '5. Run final hard validation.')

    Write-WarnLine '请在运行正式修复前完全退出 Codex Desktop。脚本不会强制关闭 App，修复后也需要重新打开 App。' 'Fully quit Codex Desktop before running the repair. The script does not force-close the app, and you must reopen it after repair.'

    if ($DryRun -or $Yes) {
        return
    }

    $answer = Read-Host (T '确认继续？输入 Y 继续' 'Continue? Type Y to proceed')
    if ($answer -notin @('Y', 'y')) {
        throw (T '用户取消操作。' 'Operation cancelled by user.')
    }
}

function Get-LatestCodexBundledSource {
    param(
        [string]$PackageName,
        [string]$SourceOverride
    )

    if (-not [string]::IsNullOrWhiteSpace($SourceOverride)) {
        if (-not (Test-Path -LiteralPath $SourceOverride)) {
            throw (T "指定的 bundled 插件源目录不存在: $SourceOverride" "The specified bundled plugin source directory does not exist: $SourceOverride")
        }

        return [PSCustomObject]@{
            PackageVersion = 'custom'
            PluginRoot     = [System.IO.Path]::GetFullPath($SourceOverride)
        }
    }

    if (-not (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue)) {
        throw (T '当前 PowerShell 环境没有 Get-AppxPackage。请改用 -BundledSourceRoot 手动指定 openai-bundled 源目录。' 'Get-AppxPackage is not available in this PowerShell environment. Use -BundledSourceRoot to manually provide the openai-bundled source directory.')
    }

    $pkg = Get-AppxPackage -Name $PackageName | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $pkg) {
        throw (T "未找到 $PackageName 的 AppX 安装信息。可用 -BundledSourceRoot 手动指定源目录。" "Could not find AppX package information for $PackageName. You can use -BundledSourceRoot to provide the source directory manually.")
    }

    $pluginRoot = Join-Path $pkg.InstallLocation 'app\resources\plugins\openai-bundled'
    if (-not (Test-Path -LiteralPath $pluginRoot)) {
        throw (T "未找到 Codex Desktop bundled 插件源目录: $pluginRoot" "Could not find the Codex Desktop bundled plugin source directory: $pluginRoot")
    }

    [PSCustomObject]@{
        PackageVersion = [string]$pkg.Version
        PluginRoot     = $pluginRoot
    }
}

function Get-PluginVersion {
    param(
        [string]$BundledSourceRoot,
        [string]$PluginName
    )

    $manifestPath = Join-Path $BundledSourceRoot "plugins\$PluginName\.codex-plugin\plugin.json"
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw (T "插件清单不存在: $manifestPath" "Plugin manifest does not exist: $manifestPath")
    }

    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace($manifest.version)) {
        throw (T "插件版本为空: $manifestPath" "Plugin version is empty: $manifestPath")
    }

    return [string]$manifest.version
}

function Invoke-IfNeeded {
    param(
        [string]$DescriptionZh,
        [string]$DescriptionEn,
        [scriptblock]$Action
    )

    if ($DryRun) {
        Write-Host ('[DryRun] ' + (T $DescriptionZh $DescriptionEn))
        return
    }

    & $Action
}

function Move-ToBackupIfExists {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $backupPath = "$Path.backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Invoke-IfNeeded "备份 $Path -> $backupPath" "Back up $Path -> $backupPath" {
        Move-Item -LiteralPath $Path -Destination $backupPath
    }

    $script:BackupPaths.Add($backupPath)
    return $backupPath
}

function Copy-DirectoryContents {
    param(
        [string]$SourcePath,
        [string]$DestinationPath
    )

    Invoke-IfNeeded "创建目录 $DestinationPath" "Create directory $DestinationPath" {
        New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
    }

    $items = Get-ChildItem -LiteralPath $SourcePath -Force
    foreach ($item in $items) {
        Invoke-IfNeeded "复制 $($item.FullName) -> $DestinationPath" "Copy $($item.FullName) -> $DestinationPath" {
            Copy-Item -LiteralPath $item.FullName -Destination $DestinationPath -Recurse -Force
        }
    }
}

function Stop-ExtensionHostProcess {
    param([string]$CacheRoot)

    $processes = Get-Process -Name 'extension-host' -ErrorAction SilentlyContinue | Where-Object {
        $_.Path -and $_.Path.StartsWith($CacheRoot, [System.StringComparison]::OrdinalIgnoreCase)
    }

    if (-not $processes) {
        Write-Ok '未发现需要停止的 extension-host 进程。' 'No extension-host process needs to be stopped.'
        return
    }

    foreach ($process in $processes) {
        Invoke-IfNeeded "停止 extension-host PID=$($process.Id)" "Stop extension-host PID=$($process.Id)" {
            Stop-Process -Id $process.Id -Force
        }
    }
}

function Reset-TmpMarketplace {
    param(
        [string]$BundledSourceRoot,
        [string]$TmpMarketplaceRoot
    )

    $tmpParent = Split-Path -Path $TmpMarketplaceRoot -Parent
    Invoke-IfNeeded "创建目录 $tmpParent" "Create directory $tmpParent" {
        New-Item -ItemType Directory -Path $tmpParent -Force | Out-Null
    }

    Move-ToBackupIfExists -Path $TmpMarketplaceRoot | Out-Null
    Invoke-IfNeeded "复制 bundled marketplace 到 $TmpMarketplaceRoot" "Copy bundled marketplace to $TmpMarketplaceRoot" {
        Copy-Item -LiteralPath $BundledSourceRoot -Destination $tmpParent -Recurse -Force
    }
}

function Test-PluginCacheReady {
    param(
        [string]$PluginName,
        [string]$VersionDirectory
    )

    $required = [System.Collections.Generic.List[string]]::new()
    $required.Add((Join-Path $VersionDirectory '.codex-plugin\plugin.json'))

    switch ($PluginName) {
        'browser' {
            $required.Add((Join-Path $VersionDirectory 'scripts\browser-client.mjs'))
        }
        'chrome' {
            $required.Add((Join-Path $VersionDirectory 'scripts\browser-client.mjs'))
            $required.Add((Join-Path $VersionDirectory 'extension-host\windows\x64\extension-host.exe'))
        }
        'computer-use' {
            $required.Add((Join-Path $VersionDirectory 'scripts\computer-use-client.mjs'))
            $required.Add((Join-Path $VersionDirectory 'node_modules\@oai\sky\bin\windows\codex-computer-use.exe'))
        }
        'latex' {
            $required.Add((Join-Path $VersionDirectory 'bin\tectonic.exe'))
        }
    }

    $missing = @($required | Where-Object { -not (Test-Path -LiteralPath $_) })
    [PSCustomObject]@{
        Ready        = ($missing.Count -eq 0)
        MissingFiles = $missing
    }
}

function Ensure-LatestJunction {
    param(
        [string]$PluginCacheRoot,
        [string]$VersionDirectory
    )

    $latestPath = Join-Path $PluginCacheRoot 'latest'
    if (Test-Path -LiteralPath $latestPath) {
        Invoke-IfNeeded "删除旧 latest 链接 $latestPath" "Remove old latest link $latestPath" {
            Remove-Item -LiteralPath $latestPath -Recurse -Force
        }
    }

    Invoke-IfNeeded "创建 latest -> $VersionDirectory" "Create latest -> $VersionDirectory" {
        New-Item -ItemType Junction -Path $latestPath -Target $VersionDirectory | Out-Null
    }
}

function Sync-PluginCache {
    param(
        [string]$BundledSourceRoot,
        [string]$CacheMarketplaceRoot,
        [string[]]$PluginNames
    )

    $versions = @{}
    foreach ($pluginName in $PluginNames) {
        $pluginVersion = Get-PluginVersion -BundledSourceRoot $BundledSourceRoot -PluginName $pluginName
        $versions[$pluginName] = $pluginVersion

        $sourcePluginRoot = Join-Path $BundledSourceRoot "plugins\$pluginName"
        $pluginCacheRoot = Join-Path $CacheMarketplaceRoot $pluginName
        $versionDirectory = Join-Path $pluginCacheRoot $pluginVersion

        Invoke-IfNeeded "创建目录 $pluginCacheRoot" "Create directory $pluginCacheRoot" {
            New-Item -ItemType Directory -Path $pluginCacheRoot -Force | Out-Null
        }

        $shouldCopy = $true
        if (Test-Path -LiteralPath $versionDirectory) {
            $cacheState = Test-PluginCacheReady -PluginName $pluginName -VersionDirectory $versionDirectory
            if ($cacheState.Ready) {
                $shouldCopy = $false
                Write-Ok "缓存完整，跳过复制: $versionDirectory" "Cache is complete, skipping copy: $versionDirectory"
            }
            else {
                Write-WarnLine "缓存不完整，将备份后重建: $versionDirectory" "Cache is incomplete and will be backed up then rebuilt: $versionDirectory"
                foreach ($missingFile in $cacheState.MissingFiles) {
                    Write-InfoLine '缺失文件' 'Missing file' $missingFile
                }
                Move-ToBackupIfExists -Path $versionDirectory | Out-Null
            }
        }

        if ($shouldCopy) {
            Copy-DirectoryContents -SourcePath $sourcePluginRoot -DestinationPath $versionDirectory
        }

        Ensure-LatestJunction -PluginCacheRoot $pluginCacheRoot -VersionDirectory $versionDirectory
    }

    return $versions
}

function Find-LineIndex {
    param(
        [System.Collections.Generic.List[string]]$Lines,
        [string]$Pattern,
        [int]$StartIndex = 0,
        [int]$EndIndex = -1
    )

    if ($EndIndex -lt 0 -or $EndIndex -ge $Lines.Count) {
        $EndIndex = $Lines.Count - 1
    }

    for ($i = $StartIndex; $i -le $EndIndex; $i++) {
        if ($Lines[$i] -match $Pattern) {
            return $i
        }
    }

    return -1
}

function Ensure-NotifyLine {
    param(
        [System.Collections.Generic.List[string]]$Lines,
        [string]$NotifyPath
    )

    $literalNotifyPath = $NotifyPath.Replace("'", "''")
    $notifyLine = "notify = [ '$literalNotifyPath', 'turn-ended' ]"
    $notifyIndex = Find-LineIndex -Lines $Lines -Pattern '^notify\s*='
    if ($notifyIndex -ge 0) {
        $Lines[$notifyIndex] = $notifyLine
        return
    }

    $sandboxIndex = Find-LineIndex -Lines $Lines -Pattern '^sandbox_mode\s*='
    if ($sandboxIndex -ge 0) {
        $Lines.Insert($sandboxIndex + 1, '')
        $Lines.Insert($sandboxIndex + 1, $notifyLine)
        return
    }

    $Lines.Insert(0, '')
    $Lines.Insert(0, $notifyLine)
}

function Ensure-PluginEnabledSection {
    param(
        [System.Collections.Generic.List[string]]$Lines,
        [string]$PluginId
    )

    $header = "[plugins.`"$PluginId`"]"
    $headerIndex = Find-LineIndex -Lines $Lines -Pattern ([regex]::Escape($header))
    if ($headerIndex -lt 0) {
        if ($Lines.Count -gt 0 -and $Lines[$Lines.Count - 1] -ne '') {
            $Lines.Add('')
        }
        $Lines.Add($header)
        $Lines.Add('enabled = true')
        return
    }

    $nextSectionIndex = Find-LineIndex -Lines $Lines -Pattern '^\[' -StartIndex ($headerIndex + 1)
    if ($nextSectionIndex -lt 0) {
        $nextSectionIndex = $Lines.Count
    }

    $enabledIndex = Find-LineIndex -Lines $Lines -Pattern '^enabled\s*=' -StartIndex ($headerIndex + 1) -EndIndex ($nextSectionIndex - 1)
    if ($enabledIndex -ge 0) {
        $Lines[$enabledIndex] = 'enabled = true'
        return
    }

    $Lines.Insert($headerIndex + 1, 'enabled = true')
}

function Ensure-MarketplaceSection {
    param(
        [System.Collections.Generic.List[string]]$Lines,
        [string]$MarketplacePath
    )

    $header = '[marketplaces.openai-bundled]'
    $headerIndex = Find-LineIndex -Lines $Lines -Pattern ([regex]::Escape($header))
    if ($headerIndex -lt 0) {
        if ($Lines.Count -gt 0 -and $Lines[$Lines.Count - 1] -ne '') {
            $Lines.Add('')
        }
        $Lines.Add($header)
        $Lines.Add('source_type = "local"')
        $Lines.Add("source = '$MarketplacePath'")
        return
    }

    $nextSectionIndex = Find-LineIndex -Lines $Lines -Pattern '^\[' -StartIndex ($headerIndex + 1)
    if ($nextSectionIndex -lt 0) {
        $nextSectionIndex = $Lines.Count
    }

    $sourceTypeIndex = Find-LineIndex -Lines $Lines -Pattern '^source_type\s*=' -StartIndex ($headerIndex + 1) -EndIndex ($nextSectionIndex - 1)
    if ($sourceTypeIndex -ge 0) {
        $Lines[$sourceTypeIndex] = 'source_type = "local"'
    }
    else {
        $Lines.Insert($headerIndex + 1, 'source_type = "local"')
        $nextSectionIndex++
    }

    $sourceIndex = Find-LineIndex -Lines $Lines -Pattern '^source\s*=' -StartIndex ($headerIndex + 1) -EndIndex ($nextSectionIndex - 1)
    if ($sourceIndex -ge 0) {
        $Lines[$sourceIndex] = "source = '$MarketplacePath'"
    }
    else {
        $insertIndex = $headerIndex + 1
        if ($sourceTypeIndex -ge 0) {
            $insertIndex = $sourceTypeIndex + 1
        }
        $Lines.Insert($insertIndex, "source = '$MarketplacePath'")
    }
}

function Backup-ConfigFile {
    param([string]$ConfigPath)

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw (T "配置文件不存在: $ConfigPath" "Config file does not exist: $ConfigPath")
    }

    $backupPath = "$ConfigPath.backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Invoke-IfNeeded "备份配置文件 $ConfigPath -> $backupPath" "Back up config file $ConfigPath -> $backupPath" {
        Copy-Item -LiteralPath $ConfigPath -Destination $backupPath -Force
    }
    $script:BackupPaths.Add($backupPath)
}

function Update-ConfigToml {
    param(
        [string]$ConfigPath,
        [string]$NotifyPath,
        [string[]]$PluginIds,
        [string]$MarketplacePath
    )

    Backup-ConfigFile -ConfigPath $ConfigPath

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in (Get-Content -LiteralPath $ConfigPath)) {
        $lines.Add($line)
    }

    Ensure-NotifyLine -Lines $lines -NotifyPath $NotifyPath
    foreach ($pluginId in $PluginIds) {
        Ensure-PluginEnabledSection -Lines $lines -PluginId $pluginId
    }
    Ensure-MarketplaceSection -Lines $lines -MarketplacePath $MarketplacePath

    $newContent = ($lines -join [Environment]::NewLine) + [Environment]::NewLine
    Invoke-IfNeeded "写回配置 $ConfigPath" "Write config $ConfigPath" {
        Set-Content -LiteralPath $ConfigPath -Value $newContent -Encoding UTF8
    }
}

function Test-FinalRepairResult {
    param(
        [string]$TmpMarketplaceRoot,
        [string]$HelperPath,
        [string]$ConfigPath,
        [string[]]$PluginIds
    )

    $tmpMarketplaceJson = Join-Path $TmpMarketplaceRoot '.agents\plugins\marketplace.json'
    $configContent = ''
    if (Test-Path -LiteralPath $ConfigPath) {
        $configContent = Get-Content -LiteralPath $ConfigPath -Raw
    }

    $checks = [System.Collections.Generic.List[object]]::new()
    $checks.Add([PSCustomObject]@{ Name = 'TmpMarketplaceJson'; Passed = (Test-Path -LiteralPath $tmpMarketplaceJson); Detail = $tmpMarketplaceJson })
    $checks.Add([PSCustomObject]@{ Name = 'ComputerUseHelper'; Passed = (Test-Path -LiteralPath $HelperPath); Detail = $HelperPath })
    $checks.Add([PSCustomObject]@{ Name = 'NotifyPath'; Passed = ($configContent.IndexOf($HelperPath, [System.StringComparison]::OrdinalIgnoreCase) -ge 0); Detail = $HelperPath })

    foreach ($pluginId in $PluginIds) {
        $header = "[plugins.`"$pluginId`"]"
        $checks.Add([PSCustomObject]@{ Name = "PluginEnabled:$pluginId"; Passed = ($configContent.IndexOf($header, [System.StringComparison]::OrdinalIgnoreCase) -ge 0); Detail = $header })
    }

    return $checks
}

function Assert-FinalRepairResult {
    param([object[]]$Checks)

    if ($DryRun) {
        Write-Section '当前状态检查' 'Current state check'
        Write-WarnLine 'DryRun 只读取当前状态，不会把计划动作模拟成已完成结果。' 'DryRun reads the current state only; it does not simulate planned actions as completed.'
    }
    else {
        Write-Section '最终校验' 'Final validation'
    }

    foreach ($check in $Checks) {
        if ($check.Passed) {
            Write-Ok "$($check.Name): $($check.Detail)" "$($check.Name): $($check.Detail)"
        }
        else {
            if ($DryRun) {
                Write-WarnLine "$($check.Name) 当前未就绪: $($check.Detail)" "$($check.Name) is not ready now: $($check.Detail)"
            }
            else {
                Write-WarnLine "$($check.Name) 失败: $($check.Detail)" "$($check.Name) failed: $($check.Detail)"
            }
        }
    }

    if ($DryRun) {
        Write-WarnLine '正式运行会执行写入、备份、重建和最终硬校验；请确认计划后去掉 -DryRun。' 'A formal run performs writes, backups, rebuilds, and hard final validation; remove -DryRun after reviewing the plan.'
        return
    }

    $failed = @($Checks | Where-Object { -not $_.Passed })
    if ($failed.Count -gt 0) {
        throw (T "最终校验失败，共 $($failed.Count) 项未通过。请查看上方失败项和日志文件。" "Final validation failed. $($failed.Count) check(s) did not pass. Review the failed checks above and the log file.")
    }
}

function Show-Summary {
    Write-Section '结果摘要' 'Summary'
    if ($script:LogPath) {
        Write-InfoLine '日志文件' 'Log file' $script:LogPath
    }
    else {
        Write-InfoLine '日志文件' 'Log file' (T 'DryRun 模式未创建日志文件' 'No log file was created in DryRun mode')
    }

    if ($script:BackupPaths.Count -gt 0) {
        foreach ($backupPath in $script:BackupPaths) {
            if ($DryRun) {
                Write-InfoLine '计划备份路径' 'Planned backup path' $backupPath
            }
            else {
                Write-InfoLine '备份文件或目录' 'Backup file or directory' $backupPath
            }
        }
    }
    else {
        Write-InfoLine '备份文件或目录' 'Backup file or directory' (T '无' 'None')
    }

    if ($DryRun) {
        Write-WarnLine '当前是 DryRun，没有写入任何修复。' 'This was a DryRun. No repair changes were written.'
    }
    else {
        Write-Ok '修复流程已完成。请完全退出并重新打开 Codex Desktop。' 'Repair flow finished. Fully quit and reopen Codex Desktop.'
    }
}

try {
    Select-UiLanguage
    Write-Title
    Assert-PowerShell7

    $codexHomePath = [System.IO.Path]::GetFullPath($CodexHome)
    $configPath = Join-Path $codexHomePath 'config.toml'
    $tmpMarketplaceRoot = Join-Path $codexHomePath '.tmp\bundled-marketplaces\openai-bundled'
    $cacheMarketplaceRoot = Join-Path $codexHomePath 'plugins\cache\openai-bundled'
    $marketplaceConfigPath = Convert-ToExtendedWindowsPath -Path $tmpMarketplaceRoot
    $pluginNames = @('browser', 'chrome', 'computer-use', 'latex')
    $requiredPluginIds = @(
        'browser@openai-bundled',
        'chrome@openai-bundled',
        'computer-use@openai-bundled'
    )

    Start-RepairTranscript -CodexHomePath $codexHomePath
    Confirm-RepairPlan -CodexHomePath $codexHomePath -ConfigPath $configPath -TmpMarketplaceRoot $tmpMarketplaceRoot -CacheMarketplaceRoot $cacheMarketplaceRoot

    Write-Section '定位源目录' 'Locate source'
    $bundledSource = Get-LatestCodexBundledSource -PackageName $PackageName -SourceOverride $BundledSourceRoot
    Write-InfoLine 'App 包版本' 'App package version' ([string]$bundledSource.PackageVersion)
    Write-InfoLine 'Bundled 源目录' 'Bundled source directory' $bundledSource.PluginRoot

    Write-Section '执行修复' 'Run repair'
    Write-Step '停止可能锁住 marketplace 的 extension-host 进程。' 'Stop extension-host processes that may lock the marketplace.'
    Stop-ExtensionHostProcess -CacheRoot $cacheMarketplaceRoot

    Write-Step '重建 .tmp 下的 bundled marketplace。' 'Rebuild the bundled marketplace under .tmp.'
    Reset-TmpMarketplace -BundledSourceRoot $bundledSource.PluginRoot -TmpMarketplaceRoot $tmpMarketplaceRoot

    Write-Step '同步 bundled 插件缓存并重建 latest 链接。' 'Sync bundled plugin cache and recreate latest links.'
    $pluginVersions = Sync-PluginCache -BundledSourceRoot $bundledSource.PluginRoot -CacheMarketplaceRoot $cacheMarketplaceRoot -PluginNames $pluginNames

    $computerUseVersion = $pluginVersions['computer-use']
    $helperPath = Join-Path $cacheMarketplaceRoot "computer-use\$computerUseVersion\node_modules\@oai\sky\bin\windows\codex-computer-use.exe"
    Write-InfoLine 'Computer Use 插件版本' 'Computer Use plugin version' $computerUseVersion
    Write-InfoLine 'Computer Use helper' 'Computer Use helper' $helperPath

    Write-Step '备份并修正 config.toml。' 'Back up and update config.toml.'
    Update-ConfigToml -ConfigPath $configPath -NotifyPath $helperPath -PluginIds $requiredPluginIds -MarketplacePath $marketplaceConfigPath

    $checks = Test-FinalRepairResult -TmpMarketplaceRoot $tmpMarketplaceRoot -HelperPath $helperPath -ConfigPath $configPath -PluginIds $requiredPluginIds
    Assert-FinalRepairResult -Checks $checks
    Show-Summary
}
catch {
    Write-Host ''
    Write-Host ('[ERROR] ' + $_.Exception.Message)
    if ($script:LogPath) {
        Write-InfoLine '日志文件' 'Log file' $script:LogPath
    }
    if ($script:BackupPaths.Count -gt 0) {
        foreach ($backupPath in $script:BackupPaths) {
            Write-InfoLine '备份文件或目录' 'Backup file or directory' $backupPath
        }
    }
    exit 1
}
finally {
    Stop-RepairTranscript
}
