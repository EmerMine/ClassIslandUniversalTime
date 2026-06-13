#!/usr/bin/env pwsh
<#
.SYNOPSIS
    监控 ClassIsland 配置文件中的 TimeOffsetSeconds 变化，变化时自动调用 ClassIslandConnecter.ps1。
.DESCRIPTION
    本脚本需要 PowerShell 7 或更高版本。
    工作流程：
    1. 从 ClassIslandUniversalTime.json 读取 ClassIsland Settings.json 路径。
    2. 若路径不存在或无效，则运行 ClassIslandConnecter.ps1 生成配置路径，然后重新读取。
    3. 使用 FileSystemWatcher 监控 ClassIsland Settings.json 文件。
    4. 当检测到 TimeOffsetSeconds 值变化时，调用 ClassIslandConnecter.ps1。
    5. 首次启动时也会立即调用一次 ClassIslandConnecter.ps1。
.PARAMETER ConfigPath
    指定 ClassIslandUniversalTime.json 路径（可选）。
.EXAMPLE
    .\ClassIslandConfigMonitor.ps1
    以默认配置启动监控。
.NOTES
    本脚本需要管理员权限运行（FileSystemWatcher 和 ClassIslandConnecter.ps1 需要）。
    请确保 ClassIslandConnecter.ps1 与本脚本放在同一目录下。
#>

[CmdletBinding()]
param(
    [string]$ConfigPath
)

# ---------- 检查是否已获得管理员权限 ----------
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$isAdmin = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    # 需要提升权限，重新启动脚本
    $scriptPath = $MyInvocation.MyCommand.Path
    $arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`""
    
    try {
        Start-Process -FilePath "pwsh.exe" -Verb RunAs -ArgumentList $arguments -WorkingDirectory $PWD -Wait:$false
    }
    catch {
        Start-Process -FilePath "pwsh.exe" -ArgumentList $arguments -WorkingDirectory $PWD
    }
    exit 0
}

# ---------- 路径配置 ----------
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ConfigPath) {
    $ConfigPath = Join-Path $scriptDir "ClassIslandUniversalTime.json"
}
$connectorScriptPath = Join-Path $scriptDir "ClassIslandConnecter.ps1"

# 脚本版本信息
$scriptVersion = "1.2.0"

# ---------- 加载 WinForms 和 DPI 设置 ----------
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# 设置高 DPI 支持
try {
    # .NET Framework 4.7+ 支持的高 DPI 模式
    $dpiMode = [System.Windows.Forms.HighDpiMode]::PerMonitorV2
    [System.Windows.Forms.Application]::SetHighDpiMode($dpiMode)
}
catch {
    # .NET Framework 4.6.x 及以下版本忽略
}

[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

# ---------- 设置系统托盘图标 ----------
$iconPath = Join-Path $scriptDir "icon.ico"
$notifyIcon = New-Object System.Windows.Forms.NotifyIcon
if (Test-Path $iconPath) {
    $notifyIcon.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($iconPath)
}
else {
    $notifyIcon.Icon = [System.Drawing.SystemIcons]::Application
}
$notifyIcon.Text = "ClassIsland 配置文件监控"
$notifyIcon.Visible = $true

# 创建右键菜单
$contextMenu = New-Object System.Windows.Forms.ContextMenuStrip

# 设置菜单高 DPI 支持
try {
    $contextMenu.AutoScaleDimensions = New-Object System.Drawing.SizeF(96, 96)
    $contextMenu.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
}
catch {
    # 忽略不支持的属性
}

# 添加标题菜单项（无法选中）
$titleItem = New-Object System.Windows.Forms.ToolStripMenuItem
$titleItem.Text = "ClassIsland 配置文件监控 v$scriptVersion"
$titleItem.Enabled = $false
$contextMenu.Items.Add($titleItem) | Out-Null

# 添加分隔符
$contextMenu.Items.Add("-") | Out-Null

# 添加"识别到的 ClassIsland 版本"菜单项（不可选择）
$versionInfoItem = New-Object System.Windows.Forms.ToolStripMenuItem
$versionInfoItem.Text = "识别到的 ClassIsland 版本: 未知"
$versionInfoItem.Enabled = $false
$contextMenu.Items.Add($versionInfoItem) | Out-Null

# 添加"当前 ClassIsland 内偏移时间"菜单项（不可选择）
$offsetInfoItem = New-Object System.Windows.Forms.ToolStripMenuItem
$offsetInfoItem.Text = "当前 ClassIsland 内偏移时间: 未知"
$offsetInfoItem.Enabled = $false
$contextMenu.Items.Add($offsetInfoItem) | Out-Null

# 添加分隔符
$contextMenu.Items.Add("-") | Out-Null

# 添加"ClassIsland 退出后自动退出程序"菜单项
$autoExitItem = New-Object System.Windows.Forms.ToolStripMenuItem
$autoExitItem.Text = "ClassIsland 退出后自动退出程序"
$autoExitItem.CheckOnClick = $true
$autoExitItem.Add_Click({
    $script:autoExitOnClassIslandExit = $autoExitItem.Checked
    Save-Settings
})
$contextMenu.Items.Add($autoExitItem) | Out-Null

# 添加"退出程序后恢复系统时间"菜单项
$restoreTimeItem = New-Object System.Windows.Forms.ToolStripMenuItem
$restoreTimeItem.Text = "退出程序后恢复系统时间"
$restoreTimeItem.CheckOnClick = $true
$restoreTimeItem.Add_Click({
    $script:restoreTimeOnExit = $restoreTimeItem.Checked
    Save-Settings
})
$contextMenu.Items.Add($restoreTimeItem) | Out-Null

# 添加分隔符
$contextMenu.Items.Add("-") | Out-Null

# 添加"关于"菜单项
$aboutItem = New-Object System.Windows.Forms.ToolStripMenuItem
$aboutItem.Text = "关于"
$aboutItem.Add_Click({
        $aboutMessage = "版本: $scriptVersion`nhttps://github.com/EmerMine/ClassIslandUniversalTime-PowerShell"
    Write-MonitorLog -Message $aboutMessage -Level "Success"
})
$contextMenu.Items.Add($aboutItem) | Out-Null

# 添加退出菜单项
$exitItem = New-Object System.Windows.Forms.ToolStripMenuItem
$exitItem.Text = "退出"
$exitItem.Add_Click({
    $script:running = $false
})
$contextMenu.Items.Add($exitItem) | Out-Null
$notifyIcon.ContextMenuStrip = $contextMenu

# 气泡消息队列（避免频繁弹出）
$balloonQueue = New-Object System.Collections.Queue
$lastBalloonTime = [DateTime]::MinValue
$balloonCooldownMs = 2000

# 设置项（从配置文件读取）
$autoExitOnClassIslandExit = $false
$restoreTimeOnExit = $false

# ClassIsland 运行状态跟踪
$classIslandWasRunning = $false
$classIslandExePath = $null
$classIslandVersion = $null

function Load-Settings {
    $config = Read-CiConfig
    if ($config) {
        if ($config.AutoExitOnClassIslandExit -eq $true) {
            $script:autoExitOnClassIslandExit = $true
        }
        if ($config.RestoreTimeOnExit -eq $true) {
            $script:restoreTimeOnExit = $true
        }
    }
}

function Save-Settings {
    $config = Read-CiConfig
    if (-not $config) {
        $config = @{}
    }
    # 创建新的配置对象，确保所有字段都被正确保存
    $newConfig = [PSCustomObject]@{
        Debug = if ($config.Debug -eq $null) { $false } else { $config.Debug }
        SettingsJsonPath = $config.SettingsJsonPath
        NtpServer = if ($config.NtpServer -eq $null) { "ntp.aliyun.com" } else { $config.NtpServer }
        CompensationSeconds = if ($config.CompensationSeconds -eq $null) { 0.0 } else { $config.CompensationSeconds }
        AutoExitOnClassIslandExit = $script:autoExitOnClassIslandExit
        RestoreTimeOnExit = $script:restoreTimeOnExit
    }
    $newConfig | ConvertTo-Json -Depth 10 | Set-Content $ConfigPath -Encoding UTF8
}

function Get-ClassIslandExePath {
    param([string]$settingsJsonPath)
    if (-not $settingsJsonPath) { return $null }
    try {
        $settingsDir = Split-Path -Parent $settingsJsonPath
        $classIslandDir = Split-Path -Parent $settingsDir
        $exePath = Join-Path $classIslandDir "ClassIsland.exe"
        if (Test-Path $exePath) {
            return $exePath
        }
    }
    catch { }
    return $null
}

function Get-ClassIslandVersion {
    param([string]$exePath)
    if (-not $exePath -or -not (Test-Path $exePath)) { return $null }
    try {
        $versionInfo = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($exePath)
        return $versionInfo.FileVersion
    }
    catch { }
    return $null
}

function Compare-Version {
    param([string]$version1, [string]$version2)
    try {
        $v1Parts = $version1.Split('.')
        $v2Parts = $version2.Split('.')
        for ($i = 0; $i -lt [Math]::Max($v1Parts.Length, $v2Parts.Length); $i++) {
            $v1 = if ($i -lt $v1Parts.Length) { [int]$v1Parts[$i] } else { 0 }
            $v2 = if ($i -lt $v2Parts.Length) { [int]$v2Parts[$i] } else { 0 }
            if ($v1 -gt $v2) { return 1 }
            if ($v1 -lt $v2) { return -1 }
        }
        return 0
    }
    catch { return 0 }
}

function Test-ClassIslandRunning {
    param([string]$exePath, [string]$version)
    if (-not $exePath) { return $false }
    try {
        $classIslandDir = Split-Path -Parent $exePath
        # 版本 >= 2.0.0.0 检测 ClassIsland.Desktop.exe
        if ($version -and (Compare-Version -version1 $version -version2 "2.0.0.0") -ge 0) {
            $desktopExe = Join-Path $classIslandDir "ClassIsland.Desktop.exe"
            $processName = "ClassIsland.Desktop"
        }
        else {
            $processName = "ClassIsland"
        }
        $process = Get-Process -Name $processName -ErrorAction SilentlyContinue
        return ($null -ne $process)
    }
    catch { }
    return $false
}

function Restore-SystemTime {
    Write-MonitorLog -Message "正在恢复系统时间..." -Level "Info"
    try {
        # 调用 UniversalTime.ps1 -Restore 还原时间
        $universalScriptPath = Join-Path $scriptDir "UniversalTime.ps1"
        if (Test-Path $universalScriptPath) {
            & $universalScriptPath -Restore
            $exitCode = $LASTEXITCODE
            if ($exitCode -eq 0) {
                Write-MonitorLog -Message "已恢复系统时间" -Level "Success"
            }
            else {
                Write-MonitorLog -Message "恢复系统时间失败，退出码: $exitCode" -Level "Error"
            }
        }
        else {
            Write-MonitorLog -Message "未找到 UniversalTime.ps1，无法恢复系统时间" -Level "Error"
        }
    }
    catch {
        Write-MonitorLog -Message "恢复系统时间时发生错误: $_" -Level "Error"
    }
}

function Write-MonitorLog {
    param([string]$Message, [string]$Level = "Info")
    # 控制台输出（仅调试用）
    if ($Level -eq "Error") {
        Write-Host $Message -ForegroundColor Red
    }
    elseif ($Level -eq "Warning") {
        Write-Host $Message -ForegroundColor Yellow
    }
    elseif ($Level -eq "Success") {
        Write-Host $Message -ForegroundColor Green
    }
    else {
        Write-Host $Message -ForegroundColor Cyan
    }
    # 仅在警告/错误/成功级别时添加到气泡队列
    if ($Level -eq "Error" -or $Level -eq "Warning" -or $Level -eq "Success") {
        $balloonQueue.Enqueue($Message)
    }
}

function Process-BalloonQueue {
    if ($balloonQueue.Count -eq 0) {
        return
    }
    $now = Get-Date
    if (($now - $lastBalloonTime).TotalMilliseconds -lt $balloonCooldownMs) {
        return
    }
    $msg = $balloonQueue.Dequeue()
    try {
        $notifyIcon.ShowBalloonTip(3000, "ClassIsland 配置文件监控", $msg, "Info")
        $script:lastBalloonTime = Get-Date
    }
    catch { }
}

function Read-CiConfig {
    if (Test-Path $ConfigPath) {
        try {
            return Get-Content $ConfigPath -Raw | ConvertFrom-Json
        }
        catch {
            Write-MonitorLog -Message "读取配置文件失败: $_" -Level "Error"
            return $null
        }
    }
    return $null
}

# ---------- 读取 ClassIsland Settings.json ----------
function Get-TimeOffsetFromSettingsJson {
    param([string]$settingsJsonPath)
    if (-not (Test-Path $settingsJsonPath)) {
        return $null
    }
    try {
        $settings = Get-Content $settingsJsonPath -Raw | ConvertFrom-Json
        $offset = $settings.TimeOffsetSeconds
        if ($null -ne $offset) {
            $offsetNum = 0.0
            if ([double]::TryParse($offset, [ref]$offsetNum)) {
                return $offsetNum
            }
        }
    }
    catch { }
    return $null
}

# ---------- 确保有有效的 Settings.json 路径 ----------
function Ensure-SettingsPath {
    $config = Read-CiConfig
    $settingsPath = $null

    if ($config -and $config.SettingsJsonPath) {
        $settingsPath = $config.SettingsJsonPath
        if (Test-Path $settingsPath) {
            $offset = Get-TimeOffsetFromSettingsJson -settingsJsonPath $settingsPath
            if ($null -ne $offset) {
                Write-MonitorLog -Message "从配置文件中读取到 Settings.json 路径: $settingsPath" -Level "Info"
                return $settingsPath
            }
        }
    }

    Write-MonitorLog -Message "配置文件中没有有效的 Settings.json 路径，正在运行 ClassIslandConnecter.ps1..." -Level "Warning"
    $connectorScriptPath = Join-Path $scriptDir "ClassIslandConnecter.ps1"
    if (-not (Test-Path $connectorScriptPath)) {
        Write-MonitorLog -Message "错误: 未找到 ClassIslandConnecter.ps1 脚本" -Level "Error"
        return $null
    }

    try {
        & $connectorScriptPath
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            Write-MonitorLog -Message "ClassIslandConnecter.ps1 执行返回退出码: $exitCode" -Level "Warning"
        }
    }
    catch {
        Write-MonitorLog -Message "执行 ClassIslandConnecter.ps1 时发生错误: $_" -Level "Error"
        return $null
    }

    Start-Sleep -Seconds 5
    $config = Read-CiConfig
    if ($config -and $config.SettingsJsonPath -and (Test-Path $config.SettingsJsonPath)) {
        Write-MonitorLog -Message "通过 ClassIslandConnecter.ps1 获取到 Settings.json 路径: $($config.SettingsJsonPath)" -Level "Success"
        return $config.SettingsJsonPath
    }

    Write-MonitorLog -Message "无法获取有效的 Settings.json 路径" -Level "Error"
    return $null
}

# ---------- 主逻辑：获取初始路径 ----------
$settingsJsonPath = Ensure-SettingsPath
if (-not $settingsJsonPath) {
    Write-MonitorLog -Message "错误: 未能获取有效的 ClassIsland Settings.json 路径，脚本退出。" -Level "Error"
    $notifyIcon.Visible = $false
    $notifyIcon.Dispose()
    exit 1
}

# 加载设置
Load-Settings

# 更新菜单项勾选状态
$autoExitItem.Checked = $autoExitOnClassIslandExit
$restoreTimeItem.Checked = $restoreTimeOnExit

# 初始化 ClassIsland 运行状态检测
$classIslandExePath = Get-ClassIslandExePath -settingsJsonPath $settingsJsonPath
if ($classIslandExePath) {
    $classIslandVersion = Get-ClassIslandVersion -exePath $classIslandExePath
    $classIslandWasRunning = Test-ClassIslandRunning -exePath $classIslandExePath -version $classIslandVersion
    if ($classIslandWasRunning) {
        Write-MonitorLog -Message "检测到 ClassIsland 正在运行" -Level "Info"
    }
    # 更新版本信息菜单项
    if ($classIslandVersion) {
        $versionInfoItem.Text = "识别到的 ClassIsland 版本: $classIslandVersion"
    }
}

$lastOffset = Get-TimeOffsetFromSettingsJson -settingsJsonPath $settingsJsonPath

# 更新偏移时间菜单项
if ($null -ne $lastOffset) {
    $offsetInfoItem.Text = "当前 ClassIsland 内偏移时间: $lastOffset 秒"
}

# Write-MonitorLog -Message "首次运行 ClassIslandConnecter.ps1..." -Level "Info"
try {
    & $connectorScriptPath
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        Write-MonitorLog -Message "ClassIslandConnecter.ps1 首次执行返回退出码: $exitCode" -Level "Warning"
    }
}
catch {
    Write-MonitorLog -Message "执行 ClassIslandConnecter.ps1 时发生错误: $_" -Level "Error"
}

$lastOffset = Get-TimeOffsetFromSettingsJson -settingsJsonPath $settingsJsonPath

# ---------- 设置文件监控 ----------
Write-MonitorLog -Message "开始监控文件变化: $settingsJsonPath" -Level "Info"

$watcher = New-Object System.IO.FileSystemWatcher
$watcher.Path = Split-Path -Parent $settingsJsonPath
$watcher.Filter = Split-Path -Leaf $settingsJsonPath
$watcher.EnableRaisingEvents = $false
$watcher.NotifyFilter = [System.IO.NotifyFilters]::LastWrite -bor [System.IO.NotifyFilters]::Size

$stableDelayMs = 500
$classIslandCheckIntervalMs = 3000  # ClassIsland 运行状态检测间隔
$lastClassIslandCheck = [DateTime]::MinValue
$running = $true
$fileChanged = $false

$job = Register-ObjectEvent -InputObject $watcher -EventName Changed -Action {
    $global:fileChanged = $true
} -ErrorAction SilentlyContinue

$watcher.EnableRaisingEvents = $true

# 合并启动通知为一条
$offsetDisplay = if ($null -ne $lastOffset) { $lastOffset } else { "未设置" }
Write-MonitorLog -Message "程序正在监控配置文件……`n初始时间偏移值为 $offsetDisplay" -Level "Success"

try {
    while ($running) {
        # 处理气泡队列
        Process-BalloonQueue
        
        # 处理 UI 事件（关键：保持菜单响应）
        [System.Windows.Forms.Application]::DoEvents()
        
        # 检测 ClassIsland 是否退出（仅在启动时 ClassIsland 正在运行且设置项开启时检测）
        if ($autoExitOnClassIslandExit -and $classIslandWasRunning) {
            $now = Get-Date
            if (($now - $lastClassIslandCheck).TotalMilliseconds -ge $classIslandCheckIntervalMs) {
                $script:lastClassIslandCheck = $now
                $isRunning = Test-ClassIslandRunning -exePath $classIslandExePath -version $classIslandVersion
                if (-not $isRunning) {
                    Write-MonitorLog -Message "检测到 ClassIsland 已退出，脚本将自动退出" -Level "Success"
                    $script:running = $false
                    break
                }
            }
        }
        
        # 检查文件变化
        if ($global:fileChanged) {
            Start-Sleep -Milliseconds $stableDelayMs
            $global:fileChanged = $false

            $currentOffset = Get-TimeOffsetFromSettingsJson -settingsJsonPath $settingsJsonPath
            if ($null -ne $currentOffset) {
                $changed = $false
                if ($null -eq $lastOffset) {
                    $changed = $true
                    Write-MonitorLog -Message "检测到 TimeOffsetSeconds: $currentOffset（之前为 null）" -Level "Info"
                }
                elseif ([Math]::Abs($currentOffset - $lastOffset) -gt 0.0001) {
                    $changed = $true
                    Write-MonitorLog -Message "检测到 TimeOffsetSeconds 变化: $lastOffset -> $currentOffset" -Level "Info"
                }

                if ($changed) {
                    $lastOffset = $currentOffset
                    # 更新偏移时间菜单项
                    $offsetInfoItem.Text = "当前 ClassIsland 内偏移时间: $currentOffset 秒"
                    Write-MonitorLog -Message "TimeOffsetSeconds 已变化，正在调用 ClassIslandConnecter.ps1..." -Level "Info"
                    try {
                        & $connectorScriptPath
                        $exitCode = $LASTEXITCODE
                        if ($exitCode -ne 0) {
                            Write-MonitorLog -Message "ClassIslandConnecter.ps1 执行返回退出码: $exitCode" -Level "Warning"
                        }
                        else {
                            Write-MonitorLog -Message "当前时间偏移值为 $currentOffset `n已更改系统时间" -Level "Success"
                        }
                    }
                    catch {
                        Write-MonitorLog -Message "执行 ClassIslandConnecter.ps1 时发生错误: $_" -Level "Error"
                    }
                }
            }
        }

        Start-Sleep -Milliseconds 100
    }
}
finally {
    $running = $false
    $watcher.EnableRaisingEvents = $false
    $watcher.Dispose()
    if ($job) {
        Unregister-Event -SubscriptionId $job.Id -ErrorAction SilentlyContinue
    }

    # 删除托盘图标
    if ($notifyIcon) {
        $notifyIcon.Visible = $false
        $notifyIcon.Dispose()
    }
    
    # 恢复系统时间（如果设置）
    if ($restoreTimeOnExit) {
        Restore-SystemTime
    }
    
    Write-MonitorLog -Message "监控已停止。" -Level "Info"
}
