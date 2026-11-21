# Windows 原生编译 baka.exe。支持 MSYS2 UCRT64 GCC 或 Visual Studio cl.exe。
# PowerShell 用法： .\build-windows.ps1 [-Size 40x20] [-Fps 10] [-SkipBake] [-RequireAnimation]
param(
    [string]$Size = '40x20',
    [double]$Fps = 10,
    [switch]$SkipBake,
    [switch]$RequireAnimation,
    [ValidateSet('auto', 'gcc', 'cl')]
    [string]$Compiler = 'auto'
)
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

function Invoke-Python([string[]]$ArgsToPass) {
    $py = Get-Command py -ErrorAction SilentlyContinue
    if ($py) {
        & $py.Source @ArgsToPass
    } else {
        $python = Get-Command python -ErrorAction SilentlyContinue
        if (-not $python) { throw 'nopy3' }
        & $python.Source @ArgsToPass
    }
    if ($LASTEXITCODE -ne 0) { throw "pyerror:$LASTEXITCODE" }
}

$gif = Test-Path (Join-Path $PSScriptRoot 'cirno.gif')
$didBake = $false
if ($gif -and -not $SkipBake) {
    Write-Host 'cirno.gif，baking' -ForegroundColor Cyan
    Invoke-Python -ArgsToPass @('.\bake_cirno.py', '--size', $Size, '--fps', "$Fps")
    $didBake = $true
}

$modes = @('mono', 'braille-mono', 'ascii', 'braille', 'normal')
$missing = @($modes | Where-Object { -not (Test-Path "baked/$_-$Size.cirno") })
if ($RequireAnimation -and $missing.Count -ne 0) {
    throw ('cirno?' + ($missing -join ', ') + 'i need cirno!')
}

# 有素材时重新生成 assets.h；没有 GIF 也没有动画缓存时，允许用内置静态素材先测试。
$hasAnyBake = (@($modes | Where-Object { Test-Path "baked/$_-$Size.cirno" })).Count -gt 0
if ($didBake -or $hasAnyBake -or -not (Test-Path 'assets.h')) {
    $assetArgs = @('.\build_assets.py', '--size', $Size)
    if ($missing.Count -ne 0) { $assetArgs += '--allow-missing' }
    Invoke-Python -ArgsToPass $assetArgs
} else {
    Write-Host 'no cirno!!!!!!!!!!' -ForegroundColor Yellow
}

# 优先使用 GCC；兼容 Windows PowerShell 直接定位 MSYS2 UCRT64 里的 gcc.exe。
$gccPath = $null
foreach ($candidate in @('C:\msys64\ucrt64\bin\gcc.exe', 'C:\msys2\ucrt64\bin\gcc.exe')) {
    if (Test-Path $candidate) { $gccPath = $candidate; break }
}
if (-not $gccPath) {
    $gccCommand = Get-Command gcc -ErrorAction SilentlyContinue
    if ($gccCommand) { $gccPath = $gccCommand.Source }
}
$clCommand = Get-Command cl -ErrorAction SilentlyContinue
$clPath = if ($clCommand) { $clCommand.Source } else { $null }

if ($Compiler -eq 'gcc' -and -not $gccPath) { throw 'no gcc' }
if ($Compiler -eq 'cl' -and -not $clPath) { throw 'no cl' }
if ($Compiler -eq 'auto') {
    if ($gccPath) { $Compiler = 'gcc' }
    elseif ($clPath) { $Compiler = 'cl' }
    else {
        throw 'no gcc!!!!!'
    }
}

Write-Host "baka baka gogogo" -ForegroundColor Cyan
if ($Compiler -eq 'gcc') {
    & $gccPath -Os -std=c11 -Wall -Wextra -static -s -o baka.exe baka.c -lm
} else {
    & $clPath /nologo /O2 /utf-8 /std:c11 /Fe:baka.exe baka.c
}
if ($LASTEXITCODE -ne 0) { throw "gcc error:$LASTEXITCODE" }
if (-not (Test-Path 'baka.exe')) { throw 'no baka.exe!' }
Write-Host 'ok:baka.exe' -ForegroundColor Green
Write-Host 'run test:.\baka.exe  /  .\baka.exe baka  /  .\baka.exe --list'
if ($missing.Count -ne 0) {
    Write-Host 'no animate' -ForegroundColor Yellow
}
