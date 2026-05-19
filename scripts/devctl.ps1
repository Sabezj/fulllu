<#
    sw.ps1 — Windows service-runner
    Примеры:
        .\sw.ps1 -Action start            # все сервисы
        .\sw.ps1 -Action stop  -Services Node,Worker
        .\sw.ps1 -Action restart          # всё
        .\sw.ps1 -Action status
#>

[CmdletBinding()]
param (
    [ValidateSet('start','stop','restart','status')]
    [string]$Action = 'start',

    # Имёна сервисов из набора: Redis | Node | Worker | FastAPI
    [ValidateSet('Redis','Node','Worker','FastAPI')]
    [string[]]$Services = @('Redis','Node','Worker','FastAPI')
)

# --------------------------------------------------------------------
#  Параметры проекта
# --------------------------------------------------------------------
Set-StrictMode -Version Latest
$PSDefaultParameterValues['*:ErrorAction'] = 'Stop'

$ProjectRoot = "G:\GitHub\vang"
$LogDir      = Join-Path $ProjectRoot 'logs'
$EnvFile     = Join-Path $ProjectRoot '.env'

# Бинарники
$RedisExe    = "redis-server.exe"  # в PATH
$NpmExe      = "C:\Program Files\nodejs\npm.cmd"
$NodeExe     = (Get-Command node -EA SilentlyContinue).Source
$PythonExe   = Join-Path $ProjectRoot 'venv\Scripts\python.exe'

# Entrypoints / Порты
$NodeScript   = Join-Path $ProjectRoot 'index.js'               # при необходимости поменяй
$WorkerScript = Join-Path $ProjectRoot 'embeddingsWorker.js'
$NodePort     = 3000
$FastApiDir   = Join-Path $ProjectRoot 'services\price-search'
$FastApiPort  = 4001

# --------------------------------------------------------------------
function Write-Log([string]$msg,[ValidateSet('INFO','WARN','ERR')][string]$lvl='INFO'){
    "{0:HH:mm:ss} [{1}] {2}" -f (Get-Date),$lvl,$msg | Write-Host
}
function Ensure-Dirs {
    foreach($d in @($LogDir)){ if(-not (Test-Path $d)){ New-Item $d -ItemType Directory | Out-Null } }
}
function Load-DotEnv {
    if(Test-Path $EnvFile){
        Get-Content $EnvFile | ForEach-Object {
            if($_ -match '^(?<k>[A-Za-z_][A-Za-z0-9_]*)=(?<v>.*)$'){
                $k = $Matches.k
                $v = $Matches.v.Trim('"')
                if(-not (Test-Path ("Env:{0}" -f $k))){
                    Set-Item -Path ("Env:{0}" -f $k) -Value $v
                }
            }
        }
    }
}

# -------------------- помощники статуса/поиска -----------------------
function Get-ProcsByPort([int]$Port){
    # Возвращает процессы, слушающие заданный порт
    $conns = Get-NetTCPConnection -LocalPort $Port -State Listen -EA SilentlyContinue
    if(-not $conns){ return @() }
    $pids = $conns | Select-Object -ExpandProperty OwningProcess -Unique
    foreach($pid in $pids){
        $p = Get-Process -Id $pid -EA SilentlyContinue
        if($p){ $p }
    }
}

function Get-ProcsByCmd([string]$name,[string]$needle){
    # Ищем по имени процесса и фрагменту командной строки
    Get-CimInstance Win32_Process |
      Where-Object {
        $_.Name -ieq $name -and
        $_.CommandLine -match [Regex]::Escape($needle)
      }
}

function ProcIds($procObjs){
    foreach($p in $procObjs){
        if($p -is [System.Diagnostics.Process]){ $p.Id }
        elseif($p.PSObject.Properties.Name -contains 'ProcessId'){ $p.ProcessId }
        elseif($p.PSObject.Properties.Name -contains 'Id'){ $p.Id }
    }
}

# -------------------- стартовые функции -------------------------------
function Start-Redis {
    Start-Process -FilePath $RedisExe -ArgumentList '--port 6379 --save "" --appendonly no' `
        -RedirectStandardOutput (Join-Path $LogDir 'redis.log') `
        -RedirectStandardError  (Join-Path $LogDir 'redis.err.log') `
        -WindowStyle Hidden -PassThru | Select-Object -ExpandProperty Id
}
function Start-Node {
    if(Test-Path $NpmExe){
        # если у тебя npm-скрипт — оставляем
        Start-Process -FilePath $NpmExe -ArgumentList "start --prefix `"$ProjectRoot`"" `
            -RedirectStandardOutput (Join-Path $LogDir 'node.log') `
            -RedirectStandardError  (Join-Path $LogDir 'node.err.log') `
            -WorkingDirectory $ProjectRoot -WindowStyle Hidden -PassThru | Select-Object -ExpandProperty Id
    } else {
        # fallback: напрямую node index.js
        Start-Process -FilePath $NodeExe -ArgumentList "`"$NodeScript`"" `
            -RedirectStandardOutput (Join-Path $LogDir 'node.log') `
            -RedirectStandardError  (Join-Path $LogDir 'node.err.log') `
            -WorkingDirectory $ProjectRoot -WindowStyle Hidden -PassThru | Select-Object -ExpandProperty Id
    }
}
function Start-Worker {
    Start-Process -FilePath $NodeExe -ArgumentList "`"$WorkerScript`"" `
        -RedirectStandardOutput (Join-Path $LogDir 'worker.log') `
        -RedirectStandardError  (Join-Path $LogDir 'worker.err.log') `
        -WorkingDirectory $ProjectRoot -WindowStyle Hidden -PassThru | Select-Object -ExpandProperty Id
}
function Start-API {
    # Запускаем uvicorn через python -m uvicorn — PID будет у python.exe
    $args = "-m uvicorn main:app --host 0.0.0.0 --port $FastApiPort"
    Start-Process -FilePath $PythonExe -ArgumentList $args `
        -RedirectStandardOutput (Join-Path $LogDir 'fastapi.log') `
        -RedirectStandardError  (Join-Path $LogDir 'fastapi.err.log') `
        -WorkingDirectory $FastApiDir -WindowStyle Hidden -PassThru | Select-Object -ExpandProperty Id
}

$StartMap = @{
    Redis   = { Start-Redis }
    Node    = { Start-Node }
    Worker  = { Start-Worker }
    FastAPI = { Start-API }
}

# -------------------- определение статуса -----------------------------
function Find-ServiceProcs([string]$svc){
    switch($svc){
        'Redis'  { Get-Process -Name 'redis-server' -EA SilentlyContinue }
        'Node'   { Get-ProcsByPort -Port $NodePort }
        'Worker' { Get-ProcsByCmd  -name 'node.exe' -needle $WorkerScript }
        'FastAPI'{
            $ps = Get-ProcsByPort -Port $FastApiPort
            if(-not $ps -or $ps.Count -eq 0){
                # fallback: по командной строке
                Get-ProcsByCmd -name 'python.exe' -needle 'uvicorn main:app'
            } else { $ps }
        }
        default { @() }
    }
}

# -------------------- стоп/килл по сервису ---------------------------
function Stop-ServiceByName([string]$svc){
    $found = Find-ServiceProcs $svc
    if($found){
        foreach($pid in ProcIds $found){
            try{
                Stop-Process -Id $pid -Force -EA Stop
                Write-Log "stopped $svc (PID $pid)"
            }catch{
                Write-Log "не удалось остановить $svc (PID $pid): $($_.Exception.Message)" 'ERR'
            }
        }
    }else{
        Write-Log "nothing to stop: $svc" 'WARN'
    }
}

# -------------------- MAIN -------------------------------------------
Ensure-Dirs; Load-DotEnv

switch ($Action) {

  'status' {
      foreach($svc in $Services){
          $found = Find-ServiceProcs $svc
          if($found){
              $ids = (ProcIds $found) -join ','
              Write-Log "$($svc): RUN  (PID: $ids)"
          } else {
              Write-Log "$($svc): DEAD"
          }
      }
  }

  'stop' {
      foreach($svc in $Services){ Stop-ServiceByName $svc }
  }

  'start' {
      foreach($svc in $Services){
          $found = Find-ServiceProcs $svc
          if($found){
              $ids = (ProcIds $found) -join ','
              Write-Log "$svc уже запущен (PID: $ids)" 'WARN'
          } else {
              $procId = & $StartMap[$svc]
              Write-Log "started $svc  (PID $procId)"
          }
      }
  }

  'restart' {
      & $PSCommandPath -Action stop  -Services $Services
      & $PSCommandPath -Action start -Services $Services
  }
}

Write-Log 'Done.'
