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
$titleItem.Text = "ClassIsland 配置文件监控"
$titleItem.Enabled = $false
$contextMenu.Items.Add($titleItem) | Out-Null

# 添加分隔符
$contextMenu.Items.Add("-") | Out-Null

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

$lastOffset = Get-TimeOffsetFromSettingsJson -settingsJsonPath $settingsJsonPath

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
                    Write-MonitorLog -Message "TimeOffsetSeconds 已变化，正在调用 ClassIslandConnecter.ps1..." -Level "Info"
                    try {
                        & $connectorScriptPath
                        $exitCode = $LASTEXITCODE
                        if ($exitCode -ne 0) {
                            Write-MonitorLog -Message "ClassIslandConnecter.ps1 执行返回退出码: $exitCode" -Level "Warning"
                        }
                        else {
                            Write-MonitorLog -Message "当前时间偏移值为 $offsetDisplay `n已更改系统时间" -Level "Success"
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
    if ($notifyIcon) {
        $notifyIcon.Visible = $false
        $notifyIcon.Dispose()
    }
    Write-MonitorLog -Message "监控已停止。" -Level "Info"
}
