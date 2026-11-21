<#
.SYNOPSIS
    在本机（Windows）通过 SSH 在编译主机上执行命令、上传或分块下载文件。

.DESCRIPTION
    从仓库根目录的 ssh.txt 读取 ip / username / passwd，使用 OpenSSH 的
    SSH_ASKPASS 机制完成密码认证，因此无需在 Windows 上安装 sshpass 或 plink。
    密码只从 ssh.txt 读取，不写死在脚本里。

    三种模式：
      Run      —— 远端执行命令（命令经临时 .sh 通过 bash -s 传入）
      Upload   —— 上传文件/目录（目录自动 scp -r）
      Download —— 分块下载（默认 512MB/块，断点续传，可校验 SHA256）

.EXAMPLE
    .\scripts\ssh-run.ps1 -Command "ls -la ~/alpindroid"

.EXAMPLE
    .\scripts\ssh-run.ps1 -Upload ".\alpine\alpine-minirootfs-3.23.8-aarch64.tar.gz" -RemoteDir "alpindroid/alpine"

.EXAMPLE
    # 分块下载并校验（中断后重复执行即续传）
    .\scripts\ssh-run.ps1 -Download "alpindroid/output/Alpindroid-ZeroW-v0.2.img" `
                          -LocalPath ".\output\Alpindroid-ZeroW-v0.2.img" `
                          -ExpectedSha256 "e14c90234581c2e3d8c027454b947214677f53d3ff5b8b113b928233344d3767"

.NOTES
    Run 模式的 -Command 内容会原样通过 stdin 交给远端 bash -s，可以写多行（here-string）。
    注意不要在命令文本里用 \n 这类反斜杠转义，本机外壳层会先解释它；需要换行请直接分行。
    远端 sudo 与登录密码相同，需要 root 时写：echo '<passwd>' | sudo -S -p '' <cmd>
    二进制数据（Download）全程走 cmd 重定向，PowerShell 不接触数据流，避免编码破坏。
#>
[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(ParameterSetName = 'Run', Mandatory = $true, Position = 0)]
    [string]$Command,

    [Parameter(ParameterSetName = 'Upload', Mandatory = $true)]
    [string]$Upload,

    [Parameter(ParameterSetName = 'Upload')]
    [string]$RemoteDir = 'alpindroid/work',

    [Parameter(ParameterSetName = 'Download', Mandatory = $true)]
    [string]$Download,

    [Parameter(ParameterSetName = 'Download', Mandatory = $true)]
    [string]$LocalPath,

    [Parameter(ParameterSetName = 'Download')]
    [int]$ChunkMB = 512,

    [Parameter(ParameterSetName = 'Download')]
    [string]$ExpectedSha256 = '',

    [string]$SshFile = (Join-Path (Split-Path -Parent $PSScriptRoot) 'ssh.txt'),

    [int]$ConnectTimeout = 15
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $SshFile)) { throw "找不到凭据文件: $SshFile" }

$cfg = @{}
foreach ($line in Get-Content -LiteralPath $SshFile) {
    if ($line -match '^\s*([^:#]+?)\s*[:=]\s*(.+?)\s*$') { $cfg[$Matches[1].Trim().ToLower()] = $Matches[2] }
}
if (-not $cfg['ip'])       { throw "ssh.txt 缺少 ip 字段: $SshFile" }
if (-not $cfg['username']) { throw "ssh.txt 缺少 username 字段: $SshFile" }
if (-not $cfg['passwd'])   { throw "ssh.txt 缺少 passwd 字段: $SshFile" }

# 生成一次性 askpass 脚本，ssh 会调用它取密码
$askpass = Join-Path $env:TEMP ("askpass_" + [guid]::NewGuid().ToString('N') + ".cmd")
Set-Content -LiteralPath $askpass -Encoding ASCII -Value ("@echo off`r`necho " + $cfg['passwd'])
$env:SSH_ASKPASS = $askpass
$env:SSH_ASKPASS_REQUIRE = 'force'
$env:DISPLAY = 'localhost:0'

$target = "$($cfg['username'])@$($cfg['ip'])"
$sshOpts = @('-o', 'StrictHostKeyChecking=accept-new', '-o', "ConnectTimeout=$ConnectTimeout",
             '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=8')

# 管道给原生 ssh.exe 的编码：UTF-8 且不带 BOM
$prevOutputEncoding = $OutputEncoding
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)

try {
    if ($PSCmdlet.ParameterSetName -eq 'Upload') {
        $localPath = (Resolve-Path -LiteralPath $Upload).Path
        $name = Split-Path -Leaf $localPath
        $isDir = (Get-Item -LiteralPath $localPath).PSIsContainer
        $null | ssh @sshOpts $target "mkdir -p '$RemoteDir'"
        $scpArgs = @()
        if ($isDir) { $scpArgs += '-r' }
        $scpArgs += $sshOpts
        $scpArgs += $localPath
        $scpArgs += "${target}:${RemoteDir}"
        $null | scp @scpArgs
        if ($LASTEXITCODE -ne 0) { throw "scp 失败，退出码 $LASTEXITCODE" }
        Write-Output "uploaded: $localPath -> ${target}:${RemoteDir}/$name"
    }
    elseif ($PSCmdlet.ParameterSetName -eq 'Download') {
        $MB = 1MB
        $chunk = [int64]$ChunkMB * $MB

        # 远端大小
        $remoteSizeText = ($null | ssh @sshOpts $target "stat -c %s '$Download'") -join ''
        $remoteSize = [int64]$remoteSizeText.Trim()
        if ($remoteSize -le 0) { throw "远端文件大小异常: $remoteSizeText" }

        # 支持绝对路径与相对路径（相对路径按当前目录解析）
        if ([System.IO.Path]::IsPathRooted($LocalPath)) {
            $full = [System.IO.Path]::GetFullPath($LocalPath)
        }
        else {
            $full = [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $LocalPath))
        }
        $dir = Split-Path -Parent $full
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

        # 已有部分按块边界对齐后续传
        $have = 0
        if (Test-Path -LiteralPath $full) { $have = (Get-Item -LiteralPath $full).Length }
        if ($have -gt $remoteSize) { $have = 0; Remove-Item -LiteralPath $full -Force }
        $doneBytes = [int64]([math]::Floor($have / $chunk) * $chunk)
        if ($doneBytes -ne $have) {
            $fs = [System.IO.File]::Open($full, 'Open', 'Write')
            $fs.SetLength($doneBytes)
            $fs.Close()
        }
        if ($doneBytes -gt 0) {
            Write-Output ("resume: 已有 {0:N0} / {1:N0} 字节，从 {2} MB 处继续" -f $doneBytes, $remoteSize, ($doneBytes / $MB))
        }
        else {
            Write-Output ("start: 共 {0:N0} 字节，按 {1} MB 分块" -f $remoteSize, $ChunkMB)
            if (Test-Path -LiteralPath $full) { Remove-Item -LiteralPath $full -Force }
        }

        $idx = 0
        while ($doneBytes -lt $remoteSize) {
            $idx++
            $skipMB = [int64]($doneBytes / $MB)
            $remain = $remoteSize - $doneBytes
            $isLast = ($remain -le $chunk)
            if ($isLast) { $ddArgs = "bs=1M skip=$skipMB" }
            else         { $ddArgs = "bs=1M skip=$skipMB count=$ChunkMB" }

            # 首块用 > 创建，其余用 >> 追加；均走 cmd，二进制安全
            $redir = if ($idx -eq 1 -and $doneBytes -eq 0) { '>' } else { '>>' }
            # $Download 必须用双引号展开，再接成单引号包裹的远端命令
            $ddRemote = "dd if='$Download' $ddArgs 2>/dev/null"
            $sshLine = 'ssh ' + ($sshOpts -join ' ') + ' ' + $target + ' "' + $ddRemote + '"'
            $cmdLine = $sshLine + ' ' + $redir + ' "' + $full + '"'

            Write-Output ("chunk {0}: {1}" -f $idx, $ddArgs)
            & cmd.exe /c $cmdLine
            if ($LASTEXITCODE -ne 0) { throw "第 $idx 块下载失败（退出码 $LASTEXITCODE），重跑本命令可续传" }

            $doneBytes = (Get-Item -LiteralPath $full).Length
            Write-Output ("  progress: {0:N1} / {1:N1} MB ({2:P1})" -f ($doneBytes/$MB), ($remoteSize/$MB), ($doneBytes/$remoteSize))
            if ($doneBytes -ge $remoteSize) { break }
        }

        $finalSize = (Get-Item -LiteralPath $full).Length
        if ($finalSize -ne $remoteSize) { throw "大小不符：本地 $finalSize / 远端 $remoteSize" }
        Write-Output ("done: {0}  {1:N0} 字节" -f $full, $finalSize)

        if ($ExpectedSha256) {
            Write-Output "校验 SHA256 ..."
            $h = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLower()
            if ($h -ne $ExpectedSha256.ToLower()) { throw "SHA256 不符！本地 $h / 期望 $ExpectedSha256" }
            Write-Output "SHA256 OK: $h"
        }
    }
    else {
        # 命令写入临时 .sh（LF 换行、无 BOM），用 cmd 的 < 重定向喂给远端 bash -s，
        # 避免 PowerShell 管道给原生进程加 CRLF
        $shFile = Join-Path $env:TEMP ("remote_" + [guid]::NewGuid().ToString('N') + ".sh")
        $lf = (($Command -replace "`r`n", "`n") -replace "`r", "`n").TrimEnd("`n")
        [System.IO.File]::WriteAllText($shFile, $lf + "`n", [System.Text.UTF8Encoding]::new($false))
        try {
            $cmdLine = 'ssh ' + ($sshOpts -join ' ') + ' ' + $target + ' bash -s < "' + $shFile + '"'
            & cmd.exe /c $cmdLine
            if ($LASTEXITCODE -ne 0) { throw "远端命令退出码 $LASTEXITCODE" }
        }
        finally {
            Remove-Item -LiteralPath $shFile -Force -ErrorAction SilentlyContinue
        }
    }
}
finally {
    Remove-Item -LiteralPath $askpass -Force -ErrorAction SilentlyContinue
    $OutputEncoding = $prevOutputEncoding
}
