# ClassIslandUniversalTime-PowerShell (CIUT-PS)
CIUT-PS 可以读取 ClassIsland 的配置文件并将 Windows 时间设为偏移后的时间，支持 ClassIsland 1.x 与 2.x。当前仅支持 Windows。

> [!WARNING]
> 本项目使用 vibe-coding 方式编写，若您对该方式存在固有的排斥感，请忽略此项目。

~~真感觉 vibe 成依托石山了，维护困难……~~

## 快速上手：
1. 安装 [PowerShell 7](https://github.com/PowerShell/powershell/releases)。
2. 转到 [Releases](https://github.com/EmerMine/ClassIslandUniversalTime-PowerShell/releases/) 下载压缩包并解压到一个合适的目录下。
3. 新建管理员终端，工作目录设置为当前脚本所在目录。
4. 运行 `pwsh.exe .\UniversalTime.ps1 -TestCompensation -GUI` 测试补偿值（补偿值因设备而异）。
5. 运行 `pwsh.exe .\ClassIslandConfigMonitor.ps1` 开启 ClassIsland 配置文件监测（在通知区域内退出）并将 Windows 时间设置为 ClassIsland 偏移后的时间。
6. （推荐）在 ClassIsland 自动化内设置启动 ClassIsland 时自动运行 `pwsh.exe path\to\ClassIslandConfigMonitor.ps1` 同步偏移后的时间。

> [!IMPORTANT]
> 当 ClassIsland 安装了 `ClasslslandHide` 插件时，`ClassIslandConnector.ps1` 无法识别并定位 ClassIsland 主程序，会导致无法获取 ClassIsland 配置文件。第一次运行请关闭 `ClassIslandHide` 插件或手动在 `ClassIslandUniversalTime.json` 内新建 `SettingsJsonPath` 设置项并指定 ClassIsland 配置文件。eg: `"SettingsJsonPath": "D:\\Program_Files\\ClassIsland\\data\\Settings.json"` 。

## `UniversalTime.ps1` 使用方法

### 语法

```powershell
# 偏移模式（默认）：设置系统时间 = UTC 时间 + 指定延迟 + 补偿值（会关闭 Windows Time 时间自动同步服务）
.\UniversalTime.ps1 [[-DelaySeconds] <double>] [-NtpServer <string>] [-CompensationSeconds <double>]

# 测试模式：关闭自动同步 > 设置精确时间 > 打开 time.is > 收集补偿值 > 保存配置 > 恢复同步
.\UniversalTime.ps1 -TestCompensation [-NtpServer <string>] [-GUI]

# 还原模式：还原系统时间，并启用 Windows Time 时间自动同步服务
.\UniversalTime.ps1 -Restore
```

### 参数

| 参数名                | 参数集                 | 类型     | 必需   | 默认值                                  | 别名     | 描述                                                                                                                |
| --------------------- | ---------------------- | -------- | ------ | --------------------------------------- | -------- | ------------------------------------------------------------------------------------------------------------------- |
| `DelaySeconds`        | Default                | `double` | 否     | 0                                       | `Delay`  | 延迟时间（秒），可为小数。最终时间 = UTC 时间 + 指定延迟 + 补偿值。                                                     |
| `NtpServer`           | Default, Test, Restore | `string` | 否     | 从配置文件读取；若无则 `ntp.aliyun.com` | `Server` | NTP 服务器地址。优先使用命令行值。                                                                        |
| `CompensationSeconds` | Default                | `double` | 否     | 从配置文件读取；若无则 0      | `Comp`   | 固定补偿值（秒），用于修正系统固有偏差。正数表示系统时间偏快，负数表示偏慢。                                        |
| `TestCompensation`    | Test                   | `switch` | **是** | -                                       | -        | 启用测试模式。该模式下脚本会关闭自动同步、设置精确时间、打开 time.is 网页、提示用户输入补偿值，保存配置后恢复同步。 |
| `GUI`                 | Test                   | `switch` | 否     | -                          | -        | 使用图形对话框（用于触屏）输入偏移值。                              |
| `Restore`             | Restore                | `switch` | **是** | -                                       | -        | 还原系统时间，并启用 Windows Time 时间自动同步服务                                                     |


### 示例

```powershell
# 使用默认配置，延迟 5 秒
.\UniversalTime.ps1 -DelaySeconds 5

# 测试模式（图形界面）
.\UniversalTime.ps1 -TestCompensation -GUI

# 还原系统时间并开启自动同步
.\UniversalTime.ps1 -Restore

# 临时指定服务器和补偿值
.\UniversalTime.ps1 -NtpServer time.windows.com -CompensationSeconds 0.2 -DelaySeconds 1
```
