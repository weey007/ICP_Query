# ICP_Query 服务管理脚本(后台运行)
# 用法:
#   .\start.ps1                    # 清残留并后台启动,日志写入 service.log
#   .\start.ps1 -Action stop       # 停止服务
#   .\start.ps1 -Action restart    # 重启
#   .\start.ps1 -Action status     # 查看状态
#   .\start.ps1 -Action log        # 查看最近日志(-Follow 持续跟踪)
#   .\start.ps1 -Action fg         # 前台运行(调试用,Ctrl+C 两次退出)
param(
    [ValidateSet('start', 'stop', 'restart', 'status', 'log', 'fg')]
    [string]$Action = 'start',
    [int]$Port = 0,
    [switch]$Follow
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $root
$logFile = Join-Path $root 'service.log'
$pidFile = Join-Path $root 'service.pid'

function Resolve-Port {
    if ($Port -gt 0) { return $Port }
    $cfg = Get-Content (Join-Path $root 'config.yml') -Raw
    if ($cfg -match '(?ms)^system:.*?^\s*port:\s*(\d+)') { return [int]$Matches[1] }
    return 16181
}

function Get-StaleProcesses {
    Get-CimInstance Win32_Process -Filter "Name='python.exe'" |
        Where-Object { $_.CommandLine -match 'icpApi\.py' }
}

function Stop-ServiceProcesses {
    # 1) PID 文件中的后台包装进程
    if (Test-Path $pidFile) {
        $oldPid = Get-Content $pidFile -ErrorAction SilentlyContinue
        if ($oldPid) {
            $p = Get-CimInstance Win32_Process -Filter "ProcessId=$oldPid" -ErrorAction SilentlyContinue
            if ($p) {
                Write-Host "==> stop background wrapper, PID $oldPid"
                Stop-Process -Id $oldPid -Force
            }
        }
        Remove-Item $pidFile -ErrorAction SilentlyContinue
    }
    # 2) 命令行包含 icpApi.py 的 python 进程
    foreach ($p in Get-StaleProcesses) {
        Write-Host "==> kill stale instance (icpApi.py), PID $($p.ProcessId)"
        Stop-Process -Id $p.ProcessId -Force
    }
    # 3) 兜底:杀掉仍占用端口的 python/uv 进程
    $port = Resolve-Port
    $listeners = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
    foreach ($l in $listeners) {
        $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$($l.OwningProcess)" -ErrorAction SilentlyContinue
        if ($proc.Name -in 'python.exe', 'uv.exe') {
            Write-Host "==> kill port holder '$($proc.Name)', PID $($proc.ProcessId)"
            Stop-Process -Id $proc.ProcessId -Force
        } elseif ($proc) {
            Write-Warning "port $port is held by '$($proc.Name)' (PID $($proc.ProcessId)), not python/uv - skipped"
        }
    }
}

function Start-Background {
    $port = Resolve-Port
    Write-Host "==> service port: $port"
    Stop-ServiceProcesses
    # 用隐藏窗口的 pwsh 包一层,让服务拥有独立控制台,Terminal 关闭不影响;
    $inner = "[Console]::OutputEncoding = [System.Text.Encoding]::UTF8; uv run python src/python/icpApi.py *> '$logFile'"
    $wrapper = Start-Process -FilePath 'pwsh' -ArgumentList '-NoProfile', '-Command', $inner `
        -WorkingDirectory $root -WindowStyle Hidden -PassThru
    Set-Content -Path $pidFile -Value $wrapper.Id
    Start-Sleep -Seconds 3
    $listening = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
    if ($listening) {
        Write-Host "==> service started in background (wrapper PID $($wrapper.Id))"
        Write-Host "==> web ui: http://127.0.0.1:$port"
        Write-Host "==> log: .\start.ps1 -Action log   stop: .\start.ps1 -Action stop"
    } else {
        Write-Warning "service is not listening yet, check log: .\start.ps1 -Action log"
    }
}

switch ($Action) {
    'start' { Start-Background }
    'stop' {
        Stop-ServiceProcesses
        Write-Host "==> stopped"
    }
    'restart' {
        & $PSCommandPath -Action stop -Port $Port
        & $PSCommandPath -Action start -Port $Port
    }
    'status' {
        $port = Resolve-Port
        if (Test-Path $pidFile) {
            $wpid = Get-Content $pidFile
            $p = Get-CimInstance Win32_Process -Filter "ProcessId=$wpid" -ErrorAction SilentlyContinue
            if ($p) {
                Write-Host "==> wrapper PID $wpid : running"
            } else {
                Write-Host "==> wrapper PID $wpid : dead (stale pid file)"
            }
        } else {
            Write-Host "==> no pid file (never started in background)"
        }
        $lst = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
        if ($lst) {
            Write-Host "==> port $port : LISTENING (PID $($lst[0].OwningProcess))"
        } else {
            Write-Host "==> port $port : not listening"
        }
        Write-Host "==> icpApi.py python processes: $(@(Get-StaleProcesses).Count)"
    }
    'log' {
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        if (-not (Test-Path $logFile)) {
            Write-Warning "no log file at $logFile - start the service first"
            return
        }
        if ($Follow) {
            Get-Content -Path $logFile -Tail 50 -Wait
        } else {
            Get-Content -Path $logFile -Tail 50
        }
    }
    'fg' {
        $port = Resolve-Port
        Write-Host "==> service port: $port"
        Stop-ServiceProcesses
        Write-Host "==> starting in foreground: uv run python src/python/icpApi.py"
        & uv run python src/python/icpApi.py
    }
}
