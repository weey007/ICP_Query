# ICP_Query 启动脚本
# 用法:
#   .\start.ps1              # 从 config.yml 读取端口
#   .\start.ps1 -Port 8080   # 手动指定端口
param(
    [int]$Port = 0
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $root

# ---- 解析端口 ----
if ($Port -le 0) {
    $cfg = Get-Content (Join-Path $root 'config.yml') -Raw
    if ($cfg -match '(?ms)^system:.*?^\s*port:\s*(\d+)') {
        $Port = [int]$Matches[1]
    } else {
        $Port = 16181
    }
}
Write-Host "==> service port: $Port"

# ---- 清理 1: 命令行包含 icpApi.py 的 python 进程 ----
$stale = Get-CimInstance Win32_Process -Filter "Name='python.exe'" |
    Where-Object { $_.CommandLine -match 'icpApi\.py' }
foreach ($p in $stale) {
    Write-Host "==> kill stale instance (icpApi.py), PID $($p.ProcessId)"
    Stop-Process -Id $p.ProcessId -Force
}

# ---- 清理 2: 兜底,杀掉仍占用端口的 python/uv 进程 ----
$listeners = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
foreach ($l in $listeners) {
    $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$($l.OwningProcess)"
    if ($proc.Name -in 'python.exe', 'uv.exe') {
        Write-Host "==> kill port holder '$($proc.Name)', PID $($proc.ProcessId)"
        Stop-Process -Id $proc.ProcessId -Force
    } elseif ($proc) {
        Write-Warning "port $Port is held by '$($proc.Name)' (PID $($proc.ProcessId)), not python/uv - skipped, may fail to bind"
    }
}

# ---- 启动服务 ----
Write-Host "==> starting: uv run python src/python/icpApi.py"
& uv run python src/python/icpApi.py
