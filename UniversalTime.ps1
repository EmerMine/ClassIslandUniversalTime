<#
.SYNOPSIS
    从 NTP 服务器获取精确时间，可将系统时间设为“精确时间 + 延迟 + 补偿值”，或还原为现实时间。
    提供测试模式，先关闭自动同步、由脚本设置精确时间，打开 time.is 辅助用户判断偏差，并将用户输入的补偿值及当前 NTP 服务器保存到配置文件。
.DESCRIPTION
    该脚本通过原始 NTP 协议向服务器请求时间，并自动修正网络传输延迟。
    - 偏移模式（默认）：设置系统时间 = 精确 UTC + DelaySeconds + CompensationSeconds，并关闭 Windows 自动同步。
    - 测试模式：关闭 Windows Time 服务 → 脚本设置精确 UTC → 打开 time.is → 提示用户输入偏移值（正快负慢）→ 保存到配置文件 → 恢复自动同步。
    - 还原模式：将系统时间还原为精确 UTC，并启用 Windows 自动同步。
    所有模式均需管理员权限。
.PARAMETER DelaySeconds
    延迟时间（秒），可为小数。最终时间 = 精确时间 + 延迟 + 补偿。默认 0。
.PARAMETER NtpServer
    NTP 服务器地址。若未提供，则从配置文件读取；若无配置文件则使用 ntp.aliyun.com。
.PARAMETER CompensationSeconds
    补偿值（秒），用于修正固定偏差。若未提供，则从配置文件读取；若无配置文件则默认为 0（并输出警告）。仅偏移模式可用。
.PARAMETER TestCompensation
    测试补偿值模式：关闭自动同步，脚本设置精确时间，打开 time.is，等待用户输入偏移值，保存配置后恢复同步。
    与偏移/还原模式互斥。
.PARAMETER GUI
    仅与测试模式搭配使用。使用图形对话框输入偏移值（支持十分位步进、键盘限制）。不使用则默认使用控制台 Read-Host。
.PARAMETER Restore
    还原模式：将系统时间还原为精确 UTC 时间，并启用 Windows 自动同步。与偏移/测试模式互斥。
.EXAMPLE
    .\Set-DelayedNtpTime.ps1 -DelaySeconds 5
    若配置文件存在则自动读取补偿值和 NTP 服务器，将系统时间设为精确 UTC+5+补偿 秒，关闭自动同步。
    若配置文件不存在，补偿值按 0 处理，并输出警告提示用户运行测试模式。
.EXAMPLE
    .\Set-DelayedNtpTime.ps1 -TestCompensation -GUI
    测试模式（GUI）：关闭同步，设置精确时间，打开 time.is，弹出图形对话框输入偏移值，保存配置后恢复同步。
.EXAMPLE
    .\Set-DelayedNtpTime.ps1 -Restore
    还原系统时间为精确 UTC，并开启自动同步。
.NOTES
    必须使用管理员权限运行。
#>

[CmdletBinding(DefaultParameterSetName = 'Default')]
param(
    [Parameter(ParameterSetName = 'Default', Position = 0)]
    [Alias("Delay")]
    [double]$DelaySeconds = 0,

    [Parameter(ParameterSetName = 'Default')]
    [Parameter(ParameterSetName = 'Test')]
    [Parameter(ParameterSetName = 'Restore')]
    [Alias("Server")]
    [string]$NtpServer,

    [Parameter(ParameterSetName = 'Default')]
    [Alias("Comp")]
    [double]$CompensationSeconds,

    [Parameter(ParameterSetName = 'Test', Mandatory = $true)]
    [switch]$TestCompensation,

    [Parameter(ParameterSetName = 'Test')]
    [switch]$GUI,

    [Parameter(ParameterSetName = 'Restore', Mandatory = $true)]
    [switch]$Restore
)

# ---------- 配置文件路径 ----------
$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$configPath = Join-Path $scriptDirectory "ClassIslandUniversalTime.json"

# ---------- 配置文件读写函数 ----------
function Read-Config {
    if (Test-Path $configPath) {
        try {
            $config = Get-Content $configPath -Raw | ConvertFrom-Json
            return $config
        }
        catch {
            Write-Host "警告: 读取配置文件失败，将使用默认值。错误: $_" -ForegroundColor Yellow
        }
    }
    return $null
}

function Write-Config {
    param([double]$compValue, [string]$ntpServer)
    # 读取现有配置中的所有字段
    $existingConfig = $null
    if (Test-Path $configPath) {
        try {
            $existingConfig = Get-Content $configPath -Raw | ConvertFrom-Json
        }
        catch { }
    }
    $config = @{
        Debug                      = if ($existingConfig -and $null -ne $existingConfig.Debug) { $existingConfig.Debug } else { $false }
        SettingsJsonPath           = if ($existingConfig -and $existingConfig.SettingsJsonPath) { $existingConfig.SettingsJsonPath } else { $null }
        CompensationSeconds        = $compValue
        NtpServer                  = $ntpServer
        AutoExitOnClassIslandExit  = if ($existingConfig -and $existingConfig.AutoExitOnClassIslandExit -eq $true) { $true } else { $false }
        RestoreTimeOnExit          = if ($existingConfig -and $existingConfig.RestoreTimeOnExit -eq $true) { $true } else { $false }
    }
    $config | ConvertTo-Json | Set-Content $configPath
    Write-Host "配置已保存到: $configPath (补偿值=$compValue, NTP服务器=$ntpServer)" -ForegroundColor Green
}

# ---------- 管理员权限检查 ----------
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "错误: 此脚本需要管理员权限。请以管理员身份重启 PowerShell 并再次运行。" -ForegroundColor Red
    exit 1
}

# ---------- 辅助函数（修复退出码污染） ----------
function Disable-TimeSync {
    Write-Host "正在关闭 Windows 自动时间同步..." -ForegroundColor Yellow
    cmd /c "w32tm /config /syncfromflags:NO /update" 2>&1 | Out-Null
    $null = $LASTEXITCODE   # 清除退出码
    cmd /c "net stop w32time" 2>&1 | Out-Null
    $null = $LASTEXITCODE
    Write-Host "自动时间同步已关闭。" -ForegroundColor Green
}

function Enable-TimeSync {
    param([string]$Server)
    Write-Host "正在启用 Windows 自动时间同步..." -ForegroundColor Yellow
    cmd /c "w32tm /config /syncfromflags:manual /manualpeerlist:`"$Server`" /update" 2>&1 | Out-Null
    $null = $LASTEXITCODE
    cmd /c "sc config w32time start= auto" 2>&1 | Out-Null
    $null = $LASTEXITCODE
    cmd /c "net start w32time" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        cmd /c "sc start w32time" 2>&1 | Out-Null
        $null = $LASTEXITCODE
    }
    cmd /c "w32tm /resync" 2>&1 | Out-Null
    $null = $LASTEXITCODE
    Write-Host "自动时间同步已启用并与 $Server 同步。" -ForegroundColor Green
}

# ---------- 处理 NTP 服务器参数优先级 ----------
$effectiveNtpServer = $null
if ($PSBoundParameters.ContainsKey('NtpServer') -and $NtpServer) {
    $effectiveNtpServer = $NtpServer
    Write-Host "使用命令行指定的 NTP 服务器: $effectiveNtpServer" -ForegroundColor Cyan
}
else {
    $config = Read-Config
    if ($config -and $config.NtpServer) {
        $effectiveNtpServer = $config.NtpServer
        Write-Host "从配置文件读取 NTP 服务器: $effectiveNtpServer" -ForegroundColor Cyan
    }
    else {
        $effectiveNtpServer = "ntp.aliyun.com"
        Write-Host "使用默认 NTP 服务器: $effectiveNtpServer" -ForegroundColor Cyan
    }
}
$NtpServer = $effectiveNtpServer

# ---------- 处理补偿值参数优先级（仅默认模式需要）----------
if ($PSCmdlet.ParameterSetName -eq 'Default') {
    if (-not $PSBoundParameters.ContainsKey('CompensationSeconds')) {
        $config = Read-Config
        if ($config -and ($config.CompensationSeconds -ne $null)) {
            $CompensationSeconds = $config.CompensationSeconds
            Write-Host "从配置文件读取补偿值: $CompensationSeconds 秒" -ForegroundColor Cyan
        }
        else {
            $CompensationSeconds = 0.0
            Write-Host "警告: 未提供补偿值且无配置文件，补偿值将按 0 处理。建议运行 -TestCompensation 模式测量并保存补偿值。" -ForegroundColor Yellow
        }
    }
    else {
        Write-Host "使用命令行指定的补偿值: $CompensationSeconds 秒" -ForegroundColor Cyan
    }
}

# ---------- 所有模式在 NTP 请求前统一关闭时间服务 ----------
if ($PSCmdlet.ParameterSetName -ne 'Test') {
    Disable-TimeSync
}
else {
    Write-Host "测试模式：准备关闭时间服务..." -ForegroundColor Cyan
    Disable-TimeSync
}

# ---------- 定义 NTP 工具函数 ----------
function Convert-NtpTimestampToDateTime([byte[]]$bytes, [int]$startIndex) {
    $seconds = [System.BitConverter]::ToUInt32(@($bytes[$startIndex + 3], $bytes[$startIndex + 2], $bytes[$startIndex + 1], $bytes[$startIndex + 0]), 0)
    $fraction = [System.BitConverter]::ToUInt32(@($bytes[$startIndex + 7], $bytes[$startIndex + 6], $bytes[$startIndex + 5], $bytes[$startIndex + 4]), 0)
    $totalSeconds = $seconds + ($fraction / 4294967296.0)
    return [DateTime]::new(1900, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc).AddSeconds($totalSeconds)
}

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class Win32Time {
    [StructLayout(LayoutKind.Sequential)]
    public struct SYSTEMTIME {
        public ushort Year;
        public ushort Month;
        public ushort DayOfWeek;
        public ushort Day;
        public ushort Hour;
        public ushort Minute;
        public ushort Second;
        public ushort Milliseconds;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool SetSystemTime(ref SYSTEMTIME st);
}
"@

# ---------- 获取精确 NTP 时间 ----------
Write-Host "正在向 NTP 服务器 $NtpServer 请求时间..." -ForegroundColor Cyan

$ntpData = New-Object byte[] 48
$ntpData[0] = 0x1B

$client = New-Object System.Net.Sockets.UdpClient
$client.Client.ReceiveTimeout = 5000
$client.Client.SendTimeout = 3000

try {
    $client.Connect($NtpServer, 123)
    $t1 = [DateTime]::UtcNow
    $null = $client.Send($ntpData, $ntpData.Length)   # 抑制输出 "48"
    $remoteEndPoint = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
    $response = $client.Receive([ref]$remoteEndPoint)
    $t4 = [DateTime]::UtcNow
}
catch {
    Write-Host "错误: 无法从 NTP 服务器获取时间。$_" -ForegroundColor Red
    exit 2
}
finally {
    $client.Close()
}

# ---------- 解析并计算时间 ----------
$t3 = Convert-NtpTimestampToDateTime $response 40
$roundTrip = ($t4 - $t1).TotalMilliseconds
$halfRtt = [TimeSpan]::FromTicks(($t4 - $t1).Ticks / 2)
$preciseUtc = $t3 + $halfRtt

# 确定目标时间
if ($PSCmdlet.ParameterSetName -eq 'Default') {
    $targetUtc = $preciseUtc.AddSeconds($DelaySeconds + $CompensationSeconds)
}
else {
    $targetUtc = $preciseUtc
}

# ---------- 输出详情 ----------
Write-Host ("T1 (发送时间 UTC)      : " + $t1.ToString("yyyy-MM-dd HH:mm:ss.fff")) -ForegroundColor Gray
Write-Host ("T4 (接收时间 UTC)      : " + $t4.ToString("yyyy-MM-dd HH:mm:ss.fff")) -ForegroundColor Gray
Write-Host ("T3 (服务器发送时间 UTC): " + $t3.ToString("yyyy-MM-dd HH:mm:ss.fff")) -ForegroundColor Gray
Write-Host "----------------------------------------" -ForegroundColor Gray
Write-Host ("网络往返延迟 (RTT)     : $roundTrip ms") -ForegroundColor Yellow
Write-Host ("修正后精确 UTC 时间    : " + $preciseUtc.ToString("yyyy-MM-dd HH:mm:ss.fff")) -ForegroundColor Green

if ($PSCmdlet.ParameterSetName -eq 'Default') {
    Write-Host ("用户指定延迟           : $DelaySeconds 秒") -ForegroundColor Yellow
    Write-Host ("补偿值                 : $CompensationSeconds 秒") -ForegroundColor Yellow
    Write-Host ("目标系统 UTC 时间      : " + $targetUtc.ToString("yyyy-MM-dd HH:mm:ss.fff")) -ForegroundColor Magenta
}

# ---------- 设置系统时间 ----------
if ($PSCmdlet.ParameterSetName -eq 'Restore') {
    Write-Host "还原模式：正在将系统时间设为精确 UTC 时间..." -ForegroundColor Cyan
}
if ($PSCmdlet.ParameterSetName -eq 'Test') {
    Write-Host "测试模式：正在将系统时间设为精确 UTC 时间..." -ForegroundColor Cyan
}

$st = New-Object Win32Time+SYSTEMTIME
$st.Year = $targetUtc.Year
$st.Month = $targetUtc.Month
$st.Day = $targetUtc.Day
$st.DayOfWeek = 0
$st.Hour = $targetUtc.Hour
$st.Minute = $targetUtc.Minute
$st.Second = $targetUtc.Second
$st.Milliseconds = $targetUtc.Millisecond

$result = [Win32Time]::SetSystemTime([ref]$st)
if ($result) {
    Write-Host "成功! 系统时间已设置为: $($targetUtc.ToString('yyyy-MM-dd HH:mm:ss.fff')) UTC" -ForegroundColor Green
    Write-Host "对应本地时间: $( [System.TimeZoneInfo]::ConvertTimeFromUtc($targetUtc, [System.TimeZoneInfo]::Local).ToString('yyyy-MM-dd HH:mm:ss.fff') )" -ForegroundColor Green
}
else {
    Write-Host "错误: 设置系统时间失败。请检查权限或系统策略。" -ForegroundColor Red
    exit 3
}

# ---------- 测试模式：收集偏移值，保存配置 ----------
if ($PSCmdlet.ParameterSetName -eq 'Test') {
    $currentUtc = [DateTime]::UtcNow
    $testOffset = ($currentUtc - $preciseUtc).TotalSeconds
    $testDirection = if ($testOffset -gt 0) { "快" } else { "慢" }
    Write-Host ("当前系统 UTC 时间      : " + $currentUtc.ToString("yyyy-MM-dd HH:mm:ss.fff")) -ForegroundColor Cyan
    Write-Host ("与精确时间的偏差       : $([Math]::Round([Math]::Abs($testOffset), 3)) 秒 ($testDirection)") -ForegroundColor Magenta
    Write-Host "----------------------------------------" -ForegroundColor Gray
    Write-Host "正在打开 https://time.is 请查看网页顶端系统时间快/慢提示。" -ForegroundColor Yellow
    Start-Process "https://time.is"
    Write-Host ""
    Write-Host "Windows Time 服务已关闭，系统时间已由脚本设置为精确时间。" -ForegroundColor Cyan
    Write-Host "请根据网页显示的偏差，输入补偿值（正数表示系统时间比真实时间快，负数表示慢）。" -ForegroundColor Cyan
    Write-Host "例如：网页显示『你的系统时间快 0.3 秒』则输入 +0.3 或 0.3；显示『慢 0.2 秒』则输入 -0.2"
    
    $compValue = $null

    if ($GUI) {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        [System.Windows.Forms.Application]::SetHighDpiMode('PerMonitorV2')
        [System.Windows.Forms.Application]::EnableVisualStyles()

        $form = New-Object System.Windows.Forms.Form
        $form.Text = "输入补偿值"
        $form.Size = New-Object System.Drawing.Size(460, 190)
        $form.StartPosition = "CenterScreen"
        $form.FormBorderStyle = "FixedDialog"
        $form.MaximizeBox = $false
        $form.MinimizeBox = $false
        $form.BackColor = [System.Drawing.Color]::FromArgb(240, 242, 245)
        $form.TopMost = $true
        $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi

        $defaultFont = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Regular)
        $form.Font = $defaultFont

        $label = New-Object System.Windows.Forms.Label
        $label.Text = "查看网页顶端提示并设置补偿值，快正慢负"
        $label.Location = New-Object System.Drawing.Point(20, 15)
        $label.Size = New-Object System.Drawing.Size(385, 24)
        $form.Controls.Add($label)

        $textBox = New-Object System.Windows.Forms.TextBox
        $textBox.Location = New-Object System.Drawing.Point(20, 45)
        $textBox.Size = New-Object System.Drawing.Size(170, 30)
        $textBox.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Regular)
        $textBox.Text = "0.0"
        $textBox.TextAlign = "Right"
        $form.Controls.Add($textBox)

        function Set-FormattedValue {
            param([double]$value)
            $rounded = [Math]::Round($value, 1)
            $textBox.Text = $rounded.ToString("0.0")
        }
        function Update-TextBoxValue {
            $current = $textBox.Text
            $valid = [double]::TryParse($current, [ref]$null)
            if ($valid) {
                $num = [double]$current
                Set-FormattedValue -value $num
            }
            else {
                Set-FormattedValue -value 0.0
            }
        }
        $textBox.Add_Leave({ Update-TextBoxValue })
        $textBox.Add_KeyPress({
                param($sender, $e)
                $keyChar = $e.KeyChar
                $currentText = $textBox.Text
                $cursorPos = $textBox.SelectionStart
                if ([char]::IsControl($keyChar)) { return }
                if ($keyChar -notmatch '[\d\-\.]') {
                    $e.Handled = $true; return
                }
                if ($keyChar -eq '-') {
                    if ($currentText.Contains('-') -or $cursorPos -ne 0) {
                        $e.Handled = $true
                    }
                    return
                }
                if ($keyChar -eq '.') {
                    if ($currentText.Contains('.')) {
                        $e.Handled = $true
                    }
                    return
                }
                $dotIndex = $currentText.IndexOf('.')
                if ($dotIndex -ge 0 -and $cursorPos -gt $dotIndex) {
                    $afterDot = $currentText.Substring($dotIndex + 1).Length
                    if ($afterDot -ge 1 -and $cursorPos -ge $dotIndex + 2) {
                        $e.Handled = $true
                    }
                }
            })

        $btnUp = New-Object System.Windows.Forms.Button
        $btnUp.Text = "▲"
        $btnUp.Size = New-Object System.Drawing.Size(35, 30)
        $btnUp.Location = New-Object System.Drawing.Point(195, 45)
        $btnUp.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
        $btnUp.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $btnUp.BackColor = [System.Drawing.Color]::FromArgb(248, 249, 250)
        $btnUp.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(200, 200, 200)
        $btnUp.UseVisualStyleBackColor = $false
        $btnUp.Cursor = [System.Windows.Forms.Cursors]::Hand
        $btnDown = New-Object System.Windows.Forms.Button
        $btnDown.Text = "▼"
        $btnDown.Size = New-Object System.Drawing.Size(35, 30)
        $btnDown.Location = New-Object System.Drawing.Point(235, 45)
        $btnDown.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
        $btnDown.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $btnDown.BackColor = [System.Drawing.Color]::FromArgb(248, 249, 250)
        $btnDown.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(200, 200, 200)
        $btnDown.UseVisualStyleBackColor = $false
        $btnDown.Cursor = [System.Windows.Forms.Cursors]::Hand
        $btnUp.Add_Click({
                $currentValue = [double]$textBox.Text
                $newValue = $currentValue + 0.1
                Set-FormattedValue -value $newValue
            })
        $btnDown.Add_Click({
                $currentValue = [double]$textBox.Text
                $newValue = $currentValue - 0.1
                Set-FormattedValue -value $newValue
            })
        $form.Controls.Add($btnUp)
        $form.Controls.Add($btnDown)

        $btnOk = New-Object System.Windows.Forms.Button
        $btnOk.Text = "确定"
        $btnOk.Size = New-Object System.Drawing.Size(75, 32)
        $btnOk.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
        $btnOk.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 212)
        $btnOk.ForeColor = [System.Drawing.Color]::White
        $btnOk.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $btnOk.FlatAppearance.BorderSize = 0
        $btnOk.UseVisualStyleBackColor = $false
        $btnOk.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $btnOk.Location = New-Object System.Drawing.Point(340, 110)
        $form.Controls.Add($btnOk)
        $form.AcceptButton = $btnOk

        $form.Add_FormClosing({
                param($sender, $e)
                if ($sender.DialogResult -eq [System.Windows.Forms.DialogResult]::None) {
                    $sender.DialogResult = [System.Windows.Forms.DialogResult]::OK
                }
            })

        $dialogResult = $form.ShowDialog()
        $compValue = [double]$textBox.Text
        $form.Dispose()
    }
    else {
        Write-Host "提示：直接按回车将设置补偿值为 0。" -ForegroundColor Cyan
        $valid = $false
        while (-not $valid) {
            $input = Read-Host "请输入偏移值"
            if ([string]::IsNullOrWhiteSpace($input)) {
                $compValue = 0.0
                $valid = $true
                Write-Host "已设置为 0" -ForegroundColor Yellow
            }
            elseif ([double]::TryParse($input, [ref]$compValue)) {
                $valid = $true
            }
            else {
                Write-Host "输入无效，请输入一个数字（例如 0.5 或 -0.3），或直接回车设为 0" -ForegroundColor Red
            }
        }
    }

    Write-Config -compValue $compValue -ntpServer $NtpServer
    Enable-TimeSync -Server $NtpServer
    Write-Host "测试模式结束，自动同步已恢复。" -ForegroundColor Green
    exit 0   # 明确成功退出
}

# ---------- 还原模式：启用自动同步 ----------
if ($PSCmdlet.ParameterSetName -eq 'Restore') {
    Enable-TimeSync -Server $NtpServer
    exit 0
}

# ---------- 默认模式：保持时间服务关闭 ----------
if ($PSCmdlet.ParameterSetName -eq 'Default') {
    Write-Host "偏移模式执行完成，Windows 自动时间同步已保持关闭状态。" -ForegroundColor Green
    exit 0
}
