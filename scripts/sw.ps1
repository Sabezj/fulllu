<#
    sw.ps1 — Windows service-runner
    Примеры:
      .\sw.ps1 -Action start
      .\sw.ps1 -Action stop    -Services Node,Worker
      .\sw.ps1 -Action restart
      .\sw.ps1 -Action status
#>

[CmdletBinding()]
param (
    [ValidateSet('start','stop','restart','status')]
    [string]  $Action   = 'start',

    [string[]]$Services = @('Redis','Node','Worker','FastAPI')
)

Set-StrictMode -Version Latest
$PSDefaultParameterValues['*:ErrorAction'] = 'Stop'

# — Пути и файлы
$ProjectRoot = 'G:\GitHub\vang'
$LogDir      = Join-Path $ProjectRoot 'logs'
$RunDir      = Join-Path $ProjectRoot 'run'
$PidFile     = Join-Path $RunDir  'services.json'

$RedisExe    = 'redis-server.exe'
$NpmExe      = 'C:\Program Files\nodejs\npm.cmd'
$NodeExe     = (Get-Command node -ErrorAction Ignore).Source
$VenvAct     = Join-Path $ProjectRoot 'venv\Scripts\Activate.ps1'
$FastApiPort = 4001

# — Логирование
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO','WARN','ERR')][string]$Level = 'INFO'
    )
    '{0:HH:mm:ss} [{1}] {2}' -f (Get-Date), $Level, $Message | Write-Host
}

# — Создать каталоги
function Ensure-Dirs {
    foreach ($d in @($LogDir, $RunDir)) {
        if (-not (Test-Path $d)) {
            New-Item -Path $d -ItemType Directory | Out-Null
        }
    }
}

# — Загрузить .env
function Load-DotEnv {
    $envFile = Join-Path $ProjectRoot '.env'
    if (Test-Path $envFile) {
        Get-Content $envFile | ForEach-Object {
            if ($_ -match '^(?<k>[A-Za-z_][A-Za-z0-9_]*)=(?<v>.*)$') {
                $key   = $Matches.k
                $value = $Matches.v.Trim('"')
                if (-not (Test-Path "Env:$key")) {
                    Set-Item -Path "Env:$key" -Value $value
                }
            }
        }
    }
}

# — Функции старта
function Start-Redis {
    Start-Process -FilePath $RedisExe `
        -ArgumentList '--port 6379 --save "" --appendonly no' `
        -RedirectStandardOutput (Join-Path $LogDir 'redis.log') `
        -RedirectStandardError  (Join-Path $LogDir 'redis.err.log') `
        -WindowStyle Hidden -PassThru |
        Select-Object -ExpandProperty Id
}
function Start-Node {
    Start-Process -FilePath $NpmExe `
        -ArgumentList "start --prefix `"$ProjectRoot`"" `
        -RedirectStandardOutput (Join-Path $LogDir 'node.log') `
        -RedirectStandardError  (Join-Path $LogDir 'node.err.log') `
        -WorkingDirectory $ProjectRoot `
        -WindowStyle Hidden -PassThru |
        Select-Object -ExpandProperty Id
}
function Start-Worker {
    Start-Process -FilePath $NodeExe `
        -ArgumentList 'embeddingsWorker.js' `
        -RedirectStandardOutput (Join-Path $LogDir 'worker.log') `
        -RedirectStandardError  (Join-Path $LogDir 'worker.err.log') `
        -WorkingDirectory $ProjectRoot `
        -WindowStyle Hidden -PassThru |
        Select-Object -ExpandProperty Id
}
function Start-API {
    $cmd = "& `"$VenvAct`"; uvicorn main:app --host 0.0.0.0 --port $FastApiPort"
    Start-Process -FilePath powershell `
        -ArgumentList '-NoProfile','-Command',$cmd `
        -RedirectStandardOutput (Join-Path $LogDir 'fastapi.log') `
        -RedirectStandardError  (Join-Path $LogDir 'fastapi.err.log') `
        -WorkingDirectory (Join-Path $ProjectRoot 'services\price-search') `
        -WindowStyle Hidden -PassThru |
        Select-Object -ExpandProperty Id
}

$StartMap = @{
    Redis   = { Start-Redis }
    Node    = { Start-Node }
    Worker  = { Start-Worker }
    FastAPI = { Start-API }
}

# — PID-утилиты
function Save-Pids {
    param([hashtable]$map)
    $map | ConvertTo-Json | Set-Content -Path $PidFile -Encoding UTF8
}
function Load-Pids {
    if (Test-Path $PidFile) {
        try {
            $json = Get-Content -Path $PidFile -Raw
            if ($json) {
                $obj = ConvertFrom-Json $json
                $ht  = @{}
                foreach ($p in $obj.PSObject.Properties) {
                    $ht[ $p.Name ] = $p.Value
                }
                return $ht
            }
        }
        catch {
            Write-Log "WARN: Не удалось разобрать services.json, будет пустой набор PID-ов." 'WARN'
        }
    }
    return @{}
}
function Stop-Pid {
    param([int]$id)
    if (Get-Process -Id $id -ErrorAction Ignore) {
        Stop-Process -Id $id -Force
    }
}

# — Основной блок
Ensure-Dirs
Load-DotEnv

$allPids = Load-Pids
$wanted  = @{}
foreach ($svc in $Services) { $wanted[$svc] = $true }

switch ($Action) {
    'status' {
        if (-not $allPids.Count) {
            Write-Log 'Нет запущенных служб.'
        }
        else {
            Write-Log 'Текущие PID-ы:'
            foreach ($svc in $allPids.Keys) {
                $procId = $allPids[$svc]
                $flag   = if (Get-Process -Id $procId -ErrorAction Ignore) { 'RUN' } else { 'DEAD' }
                Write-Host ("  {0,-8} {1,6} {2}" -f $svc, $procId, $flag)
            }
        }
    }

    'stop' {
        if (-not $allPids.Count) {
            Write-Log 'Нечего останавливать.'
        }
        else {
            foreach ($svc in $allPids.Keys.Clone()) {
                if ($wanted[$svc]) {
                    Stop-Pid $allPids[$svc]
                    $allPids.Remove($svc)
                    Write-Log "stopped $svc"
                }
            }
            Save-Pids $allPids
        }
    }

    'start' {
        foreach ($svc in $wanted.Keys) {
            if ($allPids.ContainsKey($svc)) {
                Write-Log "$svc уже запущен (PID $($allPids[$svc]))" 'WARN'
            }
            else {
                $procId = & $StartMap[$svc]
                $allPids[$svc] = $procId
                Write-Log "started $svc (PID $procId)"
            }
        }
        Save-Pids $allPids
    }

    'restart' {
        & $PSCommandPath -Action stop  -Services $Services
        & $PSCommandPath -Action start -Services $Services
    }
}

Write-Log 'Done.'
