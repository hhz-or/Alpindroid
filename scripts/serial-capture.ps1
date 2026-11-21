# 串口捕获脚本（Windows）
# 用法:
#   .\serial-capture.ps1                      # 自动找第一个 COM 口
#   .\serial-capture.ps1 -PortName COM3       # 指定端口
#   .\serial-capture.ps1 -Baud 115200         # 指定波特率（默认 115200）
#
# 特性：
#   - 等待串口设备出现（最多 -WaitSec 秒）
#   - 以 115200 8N1、无流控打开，DTR/RTS 保持关闭（避免板子被复位）
#   - 边读边打印到屏幕，同时追加写入日志文件
#   - 日志文件名带时间戳，便于区分多次开机

[CmdletBinding()]
param(
    [string]$PortName = '',
    [int]$Baud = 115200,
    [int]$WaitSec = 300,
    [string]$OutDir = (Join-Path (Split-Path -Parent $PSScriptRoot) 'work')
)

$ErrorActionPreference = 'Stop'

# 1. 等端口出现
if (-not $PortName) {
    Write-Host "等待串口设备出现（最多 $WaitSec 秒）..." -ForegroundColor Yellow
    $deadline = (Get-Date).AddSeconds($WaitSec)
    while ((Get-Date) -lt $deadline) {
        $ports = [System.IO.Ports.SerialPort]::GetPortNames()
        if ($ports.Count -gt 0) {
            $PortName = $ports[0]
            Write-Host "发现串口: $($ports -join ', ')  使用 $PortName" -ForegroundColor Green
            break
        }
        Start-Sleep -Seconds 2
    }
    if (-not $PortName) {
        Write-Host "超时：未发现任何 COM 口。" -ForegroundColor Red
        Write-Host "请检查：1) USB 端是否插好  2) 是否需要 CH340/CP210x 驱动  3) 设备管理器是否有未知设备" -ForegroundColor Red
        exit 1
    }
}

# 2. 准备日志
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logPath = Join-Path $OutDir "serial-$stamp.log"

Write-Host "端口: $PortName  波特率: $Baud 8N1  日志: $logPath" -ForegroundColor Cyan
Write-Host ("=" * 70)
Write-Host "现在可以给板子上电了（按 Ctrl+C 结束捕获）" -ForegroundColor Yellow
Write-Host ("=" * 70)

# 3. 打开串口
$sp = New-Object System.IO.Ports.SerialPort
$sp.PortName = $PortName
$sp.BaudRate = $Baud
$sp.Parity = [System.IO.Ports.Parity]::None
$sp.DataBits = 8
$sp.StopBits = [System.IO.Ports.StopBits]::One
$sp.Handshake = [System.IO.Ports.Handshake]::None
$sp.ReadTimeout = 200
$sp.WriteTimeout = 200
$sp.DtrEnable = $false     # 不要拉 DTR，避免触发板子复位
$sp.RtsEnable = $false
$sp.Encoding = [System.Text.Encoding]::UTF8

try {
    $sp.Open()
} catch {
    Write-Host "打开 $PortName 失败: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

$sw = [System.IO.StreamWriter]::new($logPath, $true, [System.Text.Encoding]::UTF8)
$sw.AutoFlush = $true
$totalBytes = 0

try {
    while ($true) {
        try {
            $chunk = $sp.ReadExisting()
        } catch [System.TimeoutException] {
            $chunk = ''
        } catch {
            break
        }

        if ($chunk -and $chunk.Length -gt 0) {
            $totalBytes += $chunk.Length
            Write-Host -NoNewline $chunk
            $sw.Write($chunk)
        }
        else {
            Start-Sleep -Milliseconds 50
        }
    }
}
finally {
    try { $sp.Close() } catch {}
    try { $sw.Close() } catch {}
    Write-Host ""
    Write-Host ("=" * 70)
    Write-Host "捕获结束，共 $totalBytes 字符，日志保存在: $logPath" -ForegroundColor Cyan
}
