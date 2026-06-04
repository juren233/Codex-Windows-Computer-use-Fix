[CmdletBinding()]
param(
    [switch]$DryRun,
    [string]$CodexHome = (Join-Path $env:USERPROFILE '.codex'),
    [string]$PackageName = 'OpenAI.Codex',
    [string]$BundledSourceRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step {
    param([string]$Message)
    Write-Host "[*] $Message"
}

function Write-WarnLine {
    param([string]$Message)
    Write-Warning $Message
}

function Assert-PowerShell7 {
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        throw "必须使用 PowerShell 7 运行此脚本。当前版本: $($PSVersionTable.PSVersion)"
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

function Get-LatestCodexBundledSource {
    param(
        [string]$PackageName,
        [string]$BundledSourceRoot
    )

    if (-not [string]::IsNullOrWhiteSpace($BundledSourceRoot)) {
        if (-not (Test-Path -LiteralPath $BundledSourceRoot)) {
            throw "指定的 bundled 插件源目录不存在: $BundledSourceRoot"
        }

        return [PSCustomObject]@{
            PackageVersion = 'custom'
            PluginRoot     = $BundledSourceRoot
        }
    }

    $pkg = Get-AppxPackage -Name $PackageName | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $pkg) {
        throw "未找到 $PackageName 的 Appx 安装信息。"
    }

    $pluginRoot = Join-Path $pkg.InstallLocation 'app\resources\plugins\openai-bundled'
    if (-not (Test-Path -LiteralPath $pluginRoot)) {
        throw "未找到 Codex Desktop 的 bundled 插件源目录: $pluginRoot"
    }

    [PSCustomObject]@{
        PackageVersion = [version]$pkg.Version
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
        throw "插件清单不存在: $manifestPath"
    }

    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace($manifest.version)) {
        throw "插件版本为空: $manifestPath"
    }

    return [string]$manifest.version
}

function Invoke-IfNeeded {
    param(
        [string]$Description,
        [scriptblock]$Action
    )

    if ($DryRun) {
        Write-Host "[DryRun] $Description"
        return
    }

    & $Action
}

function Stop-ExtensionHostProcess {
    param([string]$CacheRoot)

    $processes = Get-Process -Name 'extension-host' -ErrorAction SilentlyContinue | Where-Object {
        $_.Path -and $_.Path.StartsWith($CacheRoot, [System.StringComparison]::OrdinalIgnoreCase)
    }

    if (-not $processes) {
        Write-Step '未发现需要停止的 extension-host 进程。'
        return
    }

    foreach ($process in $processes) {
        Invoke-IfNeeded -Description "停止 extension-host PID=$($process.Id)" -Action {
            Stop-Process -Id $process.Id -Force
        }
    }
}

function Move-ToBackupIfExists {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $backupPath = "$Path.backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Invoke-IfNeeded -Description "备份 $Path -> $backupPath" -Action {
        Move-Item -LiteralPath $Path -Destination $backupPath
    }
    return $backupPath
}

function Copy-DirectoryContents {
    param(
        [string]$SourcePath,
        [string]$DestinationPath
    )

    Invoke-IfNeeded -Description "创建目录 $DestinationPath" -Action {
        New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
    }

    $items = Get-ChildItem -LiteralPath $SourcePath -Force
    foreach ($item in $items) {
        Invoke-IfNeeded -Description "复制 $($item.FullName) -> $DestinationPath" -Action {
            Copy-Item -LiteralPath $item.FullName -Destination $DestinationPath -Recurse -Force
        }
    }
}

function Reset-TmpMarketplace {
    param(
        [string]$BundledSourceRoot,
        [string]$TmpMarketplaceRoot
    )

    $tmpParent = Split-Path -Path $TmpMarketplaceRoot -Parent
    Invoke-IfNeeded -Description "创建目录 $tmpParent" -Action {
        New-Item -ItemType Directory -Path $tmpParent -Force | Out-Null
    }

    Move-ToBackupIfExists -Path $TmpMarketplaceRoot | Out-Null
    Invoke-IfNeeded -Description "复制 bundled marketplace 到 $TmpMarketplaceRoot" -Action {
        Copy-Item -LiteralPath $BundledSourceRoot -Destination $tmpParent -Recurse -Force
    }
}

function Ensure-LatestJunction {
    param(
        [string]$PluginCacheRoot,
        [string]$VersionDirectory
    )

    $latestPath = Join-Path $PluginCacheRoot 'latest'
    if (Test-Path -LiteralPath $latestPath) {
        Invoke-IfNeeded -Description "删除旧 latest 链接 $latestPath" -Action {
            Remove-Item -LiteralPath $latestPath -Recurse -Force
        }
    }

    Invoke-IfNeeded -Description "创建 latest -> $VersionDirectory" -Action {
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

        Invoke-IfNeeded -Description "创建目录 $pluginCacheRoot" -Action {
            New-Item -ItemType Directory -Path $pluginCacheRoot -Force | Out-Null
        }

        if (-not (Test-Path -LiteralPath $versionDirectory)) {
            Copy-DirectoryContents -SourcePath $sourcePluginRoot -DestinationPath $versionDirectory
        }
        else {
            Write-Step "缓存已存在，跳过复制: $versionDirectory"
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

    $notifyLine = "notify = [ `"$NotifyPath`", `"turn-ended`" ]"
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

function Update-ConfigToml {
    param(
        [string]$ConfigPath,
        [string]$NotifyPath,
        [string[]]$PluginIds,
        [string]$MarketplacePath
    )

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
    Invoke-IfNeeded -Description "写回配置 $ConfigPath" -Action {
        Set-Content -LiteralPath $ConfigPath -Value $newContent -Encoding UTF8
    }
}

function Test-RepairResult {
    param(
        [string]$TmpMarketplaceRoot,
        [string]$HelperPath,
        [string]$ConfigPath
    )

    $tmpMarketplaceJson = Join-Path $TmpMarketplaceRoot '.agents\plugins\marketplace.json'
    $notifyLine = (Get-Content -LiteralPath $ConfigPath | Where-Object { $_ -match '^notify\s*=' } | Select-Object -First 1)

    [PSCustomObject]@{
        TmpMarketplaceReady = Test-Path -LiteralPath $tmpMarketplaceJson
        HelperReady         = Test-Path -LiteralPath $HelperPath
        NotifyLine          = $notifyLine
    }
}

Assert-PowerShell7

$codexHome = [System.IO.Path]::GetFullPath($CodexHome)
$configPath = Join-Path $codexHome 'config.toml'
$tmpMarketplaceRoot = Join-Path $codexHome '.tmp\bundled-marketplaces\openai-bundled'
$cacheMarketplaceRoot = Join-Path $codexHome 'plugins\cache\openai-bundled'
$marketplaceConfigPath = Convert-ToExtendedWindowsPath -Path $tmpMarketplaceRoot
$pluginNames = @('browser', 'chrome', 'computer-use', 'latex')
$requiredPluginIds = @(
    'browser@openai-bundled',
    'chrome@openai-bundled',
    'computer-use@openai-bundled'
)

Write-Step '定位 Codex Desktop bundled 插件源目录。'
$bundledSource = Get-LatestCodexBundledSource -PackageName $PackageName -BundledSourceRoot $BundledSourceRoot
Write-Step "使用 App 包版本: $($bundledSource.PackageVersion)"

Write-Step '停止可能锁住 marketplace 的 extension-host 进程。'
Stop-ExtensionHostProcess -CacheRoot $cacheMarketplaceRoot

Write-Step '重建 .tmp 下的 bundled marketplace。'
Reset-TmpMarketplace -BundledSourceRoot $bundledSource.PluginRoot -TmpMarketplaceRoot $tmpMarketplaceRoot

Write-Step '同步 bundled 插件缓存并重建 latest 链接。'
$pluginVersions = Sync-PluginCache -BundledSourceRoot $bundledSource.PluginRoot -CacheMarketplaceRoot $cacheMarketplaceRoot -PluginNames $pluginNames

$computerUseVersion = $pluginVersions['computer-use']
$helperPath = Join-Path $cacheMarketplaceRoot "computer-use\$computerUseVersion\node_modules\@oai\sky\bin\windows\codex-computer-use.exe"
Write-Step "使用 Computer Use 插件版本: $computerUseVersion"

Write-Step '修正 config.toml 中的 helper 路径、插件启用项和 marketplace 源。'
Update-ConfigToml -ConfigPath $configPath -NotifyPath $helperPath -PluginIds $requiredPluginIds -MarketplacePath $marketplaceConfigPath

Write-Step '执行只读结果校验。'
$result = Test-RepairResult -TmpMarketplaceRoot $tmpMarketplaceRoot -HelperPath $helperPath -ConfigPath $configPath
$result | Format-List | Out-String -Width 220 | Write-Host

if ($DryRun) {
    Write-WarnLine '当前是 DryRun，未实际修改任何文件。'
}
else {
    Write-WarnLine '修复已落地。请完全退出并重新打开 Codex Desktop，然后再检查 Computer Use 是否恢复。'
}
