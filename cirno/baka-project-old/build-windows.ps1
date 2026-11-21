# 在 Windows PowerShell 执行： .\build-windows.ps1
# 需要 Python 3 和 Pillow；第一次运行前请执行：py -m pip install Pillow
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
if (-not (Test-Path 'cirno.gif')) {
    throw 'no gif'
}
py .\bake_cirno.py --size 40x20 --fps 10
if ($LASTEXITCODE -ne 0) { throw 'fail' }
py .\build_assets.py --size 40x20
if ($LASTEXITCODE -ne 0) { throw 'fail2' }
Write-Host 'ok'
