[CmdletBinding()]
param(
    [int]$PollSeconds = 2,
    [switch]$NoAutoDependencies,
    [switch]$NoAutoPySearch,
    [switch]$WithMonitoring,
    [switch]$DetachApp,
    [int]$MaxRuntimeSec = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$EnvFile = Join-Path $ProjectRoot '.env'
$LogDir = Join-Path $ProjectRoot 'logs'
$RunId = Get-Date -Format 'yyyyMMdd_HHmmss'
$AppOutLog = Join-Path $LogDir ("app.{0}.out.log" -f $RunId)
$AppErrLog = Join-Path $LogDir ("app.{0}.err.log" -f $RunId)
$PyOutLog = Join-Path $LogDir ("pysearch.{0}.out.log" -f $RunId)
$PyErrLog = Join-Path $LogDir ("pysearch.{0}.err.log" -f $RunId)

$script:LogCursor = @{}
$script:LastStatuses = @{}
$script:StartedAppProcess = $null
$script:StartedPySearchProcess = $null

function Write-Status {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'OK', 'WARN', 'ERR')]
        [string]$Level = 'INFO'
    )

    $color = switch ($Level) {
        'OK' { 'Green' }
        'WARN' { 'Yellow' }
        'ERR' { 'Red' }
        default { 'Cyan' }
    }

    Write-Host ("[{0:HH:mm:ss}] [{1}] {2}" -f (Get-Date), $Level, $Message) -ForegroundColor $color
}

function Ensure-LogDir {
    if (-not (Test-Path $LogDir)) {
        New-Item -Path $LogDir -ItemType Directory | Out-Null
    }
}

function Get-CommandPath {
    param([string]$Name)

    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Load-DotEnv {
    param([string]$Path)

    $loaded = @{}
    if (-not (Test-Path $Path)) {
        Write-Status ".env not found at $Path (using current environment only)" 'WARN'
        return $loaded
    }

    foreach ($lineRaw in Get-Content -Path $Path) {
        $line = $lineRaw.Trim()
        if (-not $line -or $line.StartsWith('#')) { continue }

        if ($line -match '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
            $key = $Matches[1]
            $value = $Matches[2].Trim()

            if (($value.StartsWith('"') -and $value.EndsWith('"')) -or
                ($value.StartsWith("'") -and $value.EndsWith("'"))) {
                $value = $value.Substring(1, $value.Length - 2)
            }

            $loaded[$key] = $value
            Set-Item -Path ("Env:{0}" -f $key) -Value $value
        }
    }

    return $loaded
}

function To-Bool {
    param(
        [AllowNull()][string]$Value,
        [bool]$Default = $false
    )

    if ([string]::IsNullOrWhiteSpace($Value)) { return $Default }
    switch ($Value.Trim().ToLowerInvariant()) {
        '1' { return $true }
        'true' { return $true }
        'yes' { return $true }
        'on' { return $true }
        '0' { return $false }
        'false' { return $false }
        'no' { return $false }
        'off' { return $false }
        default { return $Default }
    }
}

function Parse-Endpoint {
    param(
        [string]$Raw,
        [string]$DefaultHost,
        [int]$DefaultPort,
        [string]$DefaultScheme = 'http'
    )

    $value = $Raw
    if ([string]::IsNullOrWhiteSpace($value)) {
        $value = "{0}://{1}:{2}" -f $DefaultScheme, $DefaultHost, $DefaultPort
    }

    try {
        $uri = [uri]$value
        if (-not $uri.Host) { throw "URI host is empty" }
        $port = if ($uri.Port -gt 0) { $uri.Port } else { $DefaultPort }
        return [pscustomobject]@{
            Raw = $value
            Host = $uri.Host
            Port = $port
            Scheme = $uri.Scheme
            IsValid = $true
        }
    }
    catch {
        return [pscustomobject]@{
            Raw = $value
            Host = $DefaultHost
            Port = $DefaultPort
            Scheme = $DefaultScheme
            IsValid = $false
        }
    }
}

function Test-TcpPort {
    param(
        [string]$HostName,
        [int]$Port,
        [int]$TimeoutMs = 1500
    )

    try {
        $client = [System.Net.Sockets.TcpClient]::new()
        $async = $client.BeginConnect($HostName, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) {
            $client.Dispose()
            return $false
        }
        $client.EndConnect($async)
        $client.Dispose()
        return $true
    }
    catch {
        return $false
    }
}

function Test-HttpHealth {
    param(
        [string]$Url,
        [int]$TimeoutSec = 2
    )

    try {
        $resp = Invoke-WebRequest -Uri $Url -TimeoutSec $TimeoutSec -UseBasicParsing
        return $resp.StatusCode -ge 200 -and $resp.StatusCode -lt 500
    }
    catch {
        return $false
    }
}

function Test-PySearchHealth {
    param(
        [string]$BaseUrl,
        [int]$TimeoutSec = 2
    )

    $base = $BaseUrl.TrimEnd('/')
    $urls = @("$base/health", "$base/healthz")
    foreach ($url in $urls) {
        if (Test-HttpHealth -Url $url -TimeoutSec $TimeoutSec) {
            return $true
        }
    }
    return $false
}

function Is-LoopbackHost {
    param([string]$HostName)
    if ([string]::IsNullOrWhiteSpace($HostName)) { return $false }
    $h = $HostName.ToLowerInvariant()
    return $h -in @('127.0.0.1', 'localhost', '::1', '0.0.0.0')
}

function Ensure-DockerDependencies {
    param(
        [bool]$NeedDb,
        [bool]$NeedRedis,
        [int]$DbPort = 5432,
        [int]$RedisPort = 6379
    )

    $services = @()
    if ($NeedDb) { $services += 'db' }
    if ($NeedRedis) { $services += 'redis' }
    if ($services.Count -eq 0) { return }

    $dockerCmd = Get-Command docker -ErrorAction SilentlyContinue
    if (-not $dockerCmd) {
        Write-Status "Docker is not available, cannot auto-start db/redis." 'WARN'
        return
    }

    $dockerDaemonUp = $false
    try {
        & docker info *> $null
        if ($LASTEXITCODE -eq 0) { $dockerDaemonUp = $true }
    } catch {}
    if (-not $dockerDaemonUp) {
        Write-Status "Docker daemon is not running. Start Docker Desktop first." 'WARN'
        return
    }

    $hasCompose = $false
    try {
        & docker compose version *> $null
        if ($LASTEXITCODE -eq 0) { $hasCompose = $true }
    } catch {}

    if ($hasCompose) {
        Write-Status "Starting dependencies with docker compose: $($services -join ', ')"
        Push-Location $ProjectRoot
        try {
            & docker compose up -d @services | Out-Host
        }
        finally {
            Pop-Location
        }
        return
    }

    Write-Status "docker compose is unavailable. Fallback to docker run/start." 'WARN'

    function Ensure-ContainerRunning {
        param(
            [string]$Name,
            [string]$Image,
            [string[]]$RunArgs
        )

        $exists = (& docker ps -a --filter "name=^/${Name}$" --format "{{.ID}}") -join ''
        if ($exists) {
            $running = (& docker inspect -f "{{.State.Running}}" $Name) -join ''
            if ($running -eq 'true') {
                Write-Status "Container '$Name' already running." 'OK'
                return
            }

            Write-Status "Starting existing container '$Name'..."
            & docker start $Name | Out-Host
            return
        }

        Write-Status "Creating container '$Name' from '$Image'..."
        & docker run -d --name $Name @RunArgs $Image | Out-Host
    }

    if ($NeedDb) {
        Ensure-ContainerRunning -Name 'lawvoice-db' -Image 'postgres:16' -RunArgs @(
            '-p', ("{0}:5432" -f $DbPort),
            '-e', 'POSTGRES_USER=postgres',
            '-e', 'POSTGRES_PASSWORD=pass',
            '-e', 'POSTGRES_DB=db',
            '-v', 'lawvoice_pgdata:/var/lib/postgresql/data'
        )
    }

    if ($NeedRedis) {
        Ensure-ContainerRunning -Name 'lawvoice-redis' -Image 'redis:7' -RunArgs @(
            '-p', ("{0}:6379" -f $RedisPort)
        )
    }
}

function Ensure-MonitoringStack {
    param([int]$AppPort)

    $dockerCmd = Get-Command docker -ErrorAction SilentlyContinue
    if (-not $dockerCmd) {
        Write-Status "Docker is not available. Falling back to native monitoring stack." 'WARN'
        $nativeScript = Join-Path $PSScriptRoot 'start_monitoring_native.ps1'
        if (-not (Test-Path $nativeScript)) {
            Write-Status "Native monitoring helper not found: $nativeScript" 'ERR'
            return
        }
        & $nativeScript -AppPort $AppPort
        return
    }

    $dockerDaemonUp = $false
    try {
        & docker info *> $null
        if ($LASTEXITCODE -eq 0) { $dockerDaemonUp = $true }
    } catch {}
    if (-not $dockerDaemonUp) {
        Write-Status "Docker daemon is not running. Falling back to native monitoring stack." 'WARN'
        $nativeScript = Join-Path $PSScriptRoot 'start_monitoring_native.ps1'
        if (-not (Test-Path $nativeScript)) {
            Write-Status "Native monitoring helper not found: $nativeScript" 'ERR'
            return
        }
        & $nativeScript -AppPort $AppPort
        return
    }

    $hasCompose = $false
    try {
        & docker compose version *> $null
        if ($LASTEXITCODE -eq 0) { $hasCompose = $true }
    } catch {}

    if (-not $hasCompose) {
        Write-Status "docker compose is unavailable. Falling back to native monitoring stack." 'WARN'
        $nativeScript = Join-Path $PSScriptRoot 'start_monitoring_native.ps1'
        if (-not (Test-Path $nativeScript)) {
            Write-Status "Native monitoring helper not found: $nativeScript" 'ERR'
            return
        }
        & $nativeScript -AppPort $AppPort
        return
    }

    Write-Status "Starting monitoring stack: prometheus, alertmanager, grafana"
    Push-Location $ProjectRoot
    try {
        & docker compose up -d prometheus alertmanager grafana | Out-Host
    }
    finally {
        Pop-Location
    }
}

function Wait-ForCondition {
    param(
        [scriptblock]$Check,
        [int]$TimeoutSec = 40,
        [int]$StepMs = 600
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (& $Check) { return $true }
        Start-Sleep -Milliseconds $StepMs
    }
    return $false
}

function Try-StartRedisFromPath {
    param(
        [string]$HostName,
        [int]$Port
    )

    if (-not (Is-LoopbackHost $HostName)) { return $false }

    $candidates = @('redis-server.exe', 'redis-server', 'redis')
    foreach ($name in $candidates) {
        $exe = Get-CommandPath -Name $name
        if (-not $exe) { continue }

        Write-Status "Trying local Redis from PATH using '$name' on port $Port..."
        try {
            $proc = Start-Process `
                -FilePath $exe `
                -ArgumentList @('--port', "$Port") `
                -PassThru `
                -WindowStyle Hidden

            $isUp = Wait-ForCondition -TimeoutSec 8 -StepMs 300 -Check {
                Test-TcpPort -HostName $HostName -Port $Port
            }
            if ($isUp) {
                Write-Status "Local Redis started via '$name' (PID $($proc.Id))." 'OK'
                return $true
            }

            if (-not $proc.HasExited) {
                Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            }
        }
        catch {
            Write-Status "Failed starting '$name': $($_.Exception.Message)" 'WARN'
        }
    }

    return $false
}

function Start-PySearch {
    param(
        [string]$DatabaseUrl,
        [string]$RedisUrl
    )

    $pyScript = Join-Path $ProjectRoot 'services\pysearch\start_py_search.ps1'
    $pyWorkDir = Join-Path $ProjectRoot 'services\pysearch'
    if (-not (Test-Path $pyScript)) {
        Write-Status "PySearch script not found: $pyScript" 'WARN'
        return $null
    }

    $psExe = Get-CommandPath -Name 'pwsh'
    if (-not $psExe) {
        $psExe = Get-CommandPath -Name 'powershell'
    }
    if (-not $psExe) {
        Write-Status "pwsh/powershell not found, cannot start PySearch." 'ERR'
        return $null
    }

    $pyDirCandidates = @()
    if ($env:PYSEARCH_VENV_DIR) { $pyDirCandidates += $env:PYSEARCH_VENV_DIR }
    $pyDirCandidates += '.\pysearch_venv'
    $pyDirCandidates += '.\.venv'

    $selectedPyDir = $null
    foreach ($candidate in $pyDirCandidates) {
        $candidateActivate = Join-Path (Join-Path $pyWorkDir $candidate) 'Scripts\Activate.ps1'
        if (Test-Path $candidateActivate) {
            $selectedPyDir = $candidate
            break
        }
    }

    if (-not $selectedPyDir) {
        $selectedPyDir = '.\pysearch_venv'
        $selectedPyDirAbs = Join-Path $pyWorkDir $selectedPyDir
        Write-Status "PySearch venv not found. Trying to create: $selectedPyDirAbs"

        $created = $false
        $pythonCmds = @(
            @{ Name = 'python'; Args = @('-m', 'venv', $selectedPyDir) },
            @{ Name = 'python3'; Args = @('-m', 'venv', $selectedPyDir) },
            @{ Name = 'py'; Args = @('-3', '-m', 'venv', $selectedPyDir) }
        )

        foreach ($cmd in $pythonCmds) {
            $exe = Get-CommandPath -Name $cmd.Name
            if (-not $exe) { continue }
            try {
                Write-Status "Creating PySearch venv via '$($cmd.Name)'..."
                $p = Start-Process -FilePath $exe -ArgumentList $cmd.Args -WorkingDirectory $pyWorkDir -PassThru -Wait
                if ($p.ExitCode -eq 0) {
                    $activate = Join-Path $selectedPyDirAbs 'Scripts\Activate.ps1'
                    if (Test-Path $activate) {
                        $created = $true
                        break
                    }
                }
            }
            catch {
                Write-Status "Venv create failed with '$($cmd.Name)': $($_.Exception.Message)" 'WARN'
            }
        }

        if (-not $created) {
            Write-Status "Unable to create PySearch venv automatically. Set PYSEARCH_VENV_DIR and retry." 'ERR'
            return $null
        }
    }

    Write-Status "Starting PySearch (FastAPI) in background using venv '$selectedPyDir'..."
    $oldDb = $env:DATABASE_URL
    $oldRedis = $env:REDIS_URL
    $env:DATABASE_URL = $DatabaseUrl
    $env:REDIS_URL = $RedisUrl

    $proc = Start-Process `
        -FilePath $psExe `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $pyScript, '-PyDir', $selectedPyDir) `
        -WorkingDirectory $pyWorkDir `
        -PassThru `
        -RedirectStandardOutput $PyOutLog `
        -RedirectStandardError $PyErrLog

    $env:DATABASE_URL = $oldDb
    $env:REDIS_URL = $oldRedis
    return $proc
}

function Write-LastLogTail {
    param(
        [string]$Path,
        [string]$Prefix,
        [int]$Lines = 12,
        [string]$Color = 'DarkYellow'
    )

    if (-not (Test-Path $Path)) { return }
    $tail = @(Get-Content -Path $Path -Tail $Lines)
    if ($tail.Length -eq 0) { return }

    Write-Status "Last $Lines lines from ${Prefix}:"
    foreach ($line in $tail) {
        Write-Host ("[{0:HH:mm:ss}] [{1}] {2}" -f (Get-Date), $Prefix, $line) -ForegroundColor $Color
    }
}

function Start-App {
    $npmExe = Get-CommandPath -Name 'npm.cmd'
    if (-not $npmExe) {
        $npmExe = Get-CommandPath -Name 'npm'
    }
    if (-not $npmExe) {
        throw "npm is not available in PATH."
    }

    Write-Status "Starting app with 'npm start'..."
    return Start-Process `
        -FilePath $npmExe `
        -ArgumentList @('start') `
        -WorkingDirectory $ProjectRoot `
        -PassThru `
        -RedirectStandardOutput $AppOutLog `
        -RedirectStandardError $AppErrLog
}

function Write-NewLogLines {
    param(
        [string]$Path,
        [string]$Prefix,
        [string]$Color = 'Gray'
    )

    if (-not (Test-Path $Path)) { return }
    if (-not $script:LogCursor.ContainsKey($Path)) {
        $script:LogCursor[$Path] = 0
    }

    $lines = @(Get-Content -Path $Path)
    $cursor = [int]$script:LogCursor[$Path]
    $lineCount = $lines.Length
    if ($cursor -gt $lineCount) { $cursor = 0 }

    for ($i = $cursor; $i -lt $lineCount; $i++) {
        Write-Host ("[{0:HH:mm:ss}] [{1}] {2}" -f (Get-Date), $Prefix, $lines[$i]) -ForegroundColor $Color
    }

    $script:LogCursor[$Path] = $lineCount
}

function Publish-StatusChanges {
    param([hashtable]$Checks)

    foreach ($name in $Checks.Keys) {
        $isUp = & $Checks[$name]
        $state = if ($isUp) { 'UP' } else { 'DOWN' }

        if ((-not $script:LastStatuses.ContainsKey($name)) -or $script:LastStatuses[$name] -ne $state) {
            $level = if ($isUp) { 'OK' } else { 'WARN' }
            Write-Status "$name -> $state" $level
        }

        $script:LastStatuses[$name] = $state
    }
}

Ensure-LogDir
$null = Load-DotEnv -Path $EnvFile

$port = 3000
if ($env:PORT -and ($env:PORT -as [int])) { $port = [int]$env:PORT }

$dbEndpoint = Parse-Endpoint -Raw $env:DATABASE_URL -DefaultHost '127.0.0.1' -DefaultPort 5432 -DefaultScheme 'postgres'
$redisEndpoint = Parse-Endpoint -Raw $env:REDIS_URL -DefaultHost '127.0.0.1' -DefaultPort 6379 -DefaultScheme 'redis'
$searchEndpoint = Parse-Endpoint -Raw $env:SEARCH_API -DefaultHost '127.0.0.1' -DefaultPort 5051 -DefaultScheme 'http'
$usePySearch = To-Bool -Value $env:USE_PY_SEARCH -Default $false

Write-Status "Project root: $ProjectRoot"
Write-Status "PORT=$port | USE_PY_SEARCH=$usePySearch"
Write-Status "DB: $($dbEndpoint.Host):$($dbEndpoint.Port) | Redis: $($redisEndpoint.Host):$($redisEndpoint.Port)"
Write-Status "Run logs: $RunId"
if ($usePySearch) {
    Write-Status "PySearch API: $($searchEndpoint.Raw)"
}

$dbUp = Test-TcpPort -HostName $dbEndpoint.Host -Port $dbEndpoint.Port
$redisUp = Test-TcpPort -HostName $redisEndpoint.Host -Port $redisEndpoint.Port

if (-not $NoAutoDependencies) {
    $needDbAuto = (-not $dbUp) -and (Is-LoopbackHost $dbEndpoint.Host)
    $needRedisAuto = (-not $redisUp) -and (Is-LoopbackHost $redisEndpoint.Host)

    if ($needRedisAuto) {
        $redisUp = Try-StartRedisFromPath -HostName $redisEndpoint.Host -Port $redisEndpoint.Port
        if ($redisUp) { $needRedisAuto = $false }
    }

    if ($needDbAuto -or $needRedisAuto) {
        Ensure-DockerDependencies `
            -NeedDb $needDbAuto `
            -NeedRedis $needRedisAuto `
            -DbPort $dbEndpoint.Port `
            -RedisPort $redisEndpoint.Port

        $dbUp = Wait-ForCondition -TimeoutSec 45 -Check { Test-TcpPort -HostName $dbEndpoint.Host -Port $dbEndpoint.Port }
        $redisUp = Wait-ForCondition -TimeoutSec 30 -Check { Test-TcpPort -HostName $redisEndpoint.Host -Port $redisEndpoint.Port }
    }
}

if (-not $dbUp) { Write-Status "PostgreSQL is not reachable at $($dbEndpoint.Host):$($dbEndpoint.Port)" 'WARN' }
if (-not $redisUp) { Write-Status "Redis is not reachable at $($redisEndpoint.Host):$($redisEndpoint.Port)" 'WARN' }

if ($WithMonitoring) {
    Ensure-MonitoringStack -AppPort $port
}

if ($usePySearch) {
    $searchBaseUrl = "{0}://{1}:{2}" -f $searchEndpoint.Scheme, $searchEndpoint.Host, $searchEndpoint.Port
    $pyUp = Test-PySearchHealth -BaseUrl $searchBaseUrl

    if (-not $pyUp -and -not $NoAutoPySearch -and (Is-LoopbackHost $searchEndpoint.Host)) {
        $script:StartedPySearchProcess = Start-PySearch -DatabaseUrl $env:DATABASE_URL -RedisUrl $env:REDIS_URL
        $pyUp = Wait-ForCondition -TimeoutSec 60 -Check { Test-PySearchHealth -BaseUrl $searchBaseUrl }
    }

    if (-not $pyUp) {
        Write-Status "PySearch is not reachable: $searchBaseUrl (/health or /healthz)" 'WARN'
        Write-LastLogTail -Path $PyErrLog -Prefix 'PY:ERR'
        Write-LastLogTail -Path $PyOutLog -Prefix 'PY'
    }
}

$existingAppConn = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
if ($existingAppConn) {
    Write-Status "Port $port already in use (PID $($existingAppConn.OwningProcess)). Skip app start." 'WARN'
}
else {
    $script:StartedAppProcess = Start-App
}

$checks = @{
    'PostgreSQL' = { Test-TcpPort -HostName $dbEndpoint.Host -Port $dbEndpoint.Port }
    'Redis' = { Test-TcpPort -HostName $redisEndpoint.Host -Port $redisEndpoint.Port }
    "App:$port" = { Test-TcpPort -HostName '127.0.0.1' -Port $port }
}

if ($usePySearch) {
    $searchBaseUrl = "{0}://{1}:{2}" -f $searchEndpoint.Scheme, $searchEndpoint.Host, $searchEndpoint.Port
    $checks['PySearch'] = { Test-PySearchHealth -BaseUrl $searchBaseUrl }
}

if ($WithMonitoring) {
    $checks['Alertmanager'] = { Test-HttpHealth -Url 'http://127.0.0.1:9093/-/healthy' -TimeoutSec 2 }
    $checks['Prometheus'] = { Test-HttpHealth -Url 'http://127.0.0.1:9090/-/healthy' -TimeoutSec 2 }
    $checks['Grafana'] = { Test-HttpHealth -Url 'http://127.0.0.1:3001/api/health' -TimeoutSec 2 }
}

Write-Status "Status monitor started. Press Ctrl+C to stop." 'OK'
$startedAt = Get-Date

try {
    while ($true) {
        if ($MaxRuntimeSec -gt 0) {
            $elapsed = ((Get-Date) - $startedAt).TotalSeconds
            if ($elapsed -ge $MaxRuntimeSec) {
                Write-Status "MaxRuntimeSec=$MaxRuntimeSec reached, stopping monitor."
                break
            }
        }

        Publish-StatusChanges -Checks $checks

        Write-NewLogLines -Path $AppOutLog -Prefix 'APP' -Color 'Gray'
        Write-NewLogLines -Path $AppErrLog -Prefix 'APP:ERR' -Color 'Red'
        Write-NewLogLines -Path $PyOutLog -Prefix 'PY' -Color 'DarkGray'
        Write-NewLogLines -Path $PyErrLog -Prefix 'PY:ERR' -Color 'DarkYellow'

        if ($script:StartedAppProcess) {
            $script:StartedAppProcess.Refresh()
            if ($script:StartedAppProcess.HasExited) {
                Write-Status "App exited with code $($script:StartedAppProcess.ExitCode)" 'ERR'
                break
            }
        }

        Start-Sleep -Seconds $PollSeconds
    }
}
finally {
    if ($script:StartedPySearchProcess -and -not $DetachApp) {
        try {
            $script:StartedPySearchProcess.Refresh()
            if (-not $script:StartedPySearchProcess.HasExited) {
                Write-Status "Stopping PySearch (PID $($script:StartedPySearchProcess.Id))"
                Stop-Process -Id $script:StartedPySearchProcess.Id -Force -ErrorAction SilentlyContinue
            }
        } catch {}
    }

    if ($script:StartedAppProcess -and -not $DetachApp) {
        $script:StartedAppProcess.Refresh()
        if (-not $script:StartedAppProcess.HasExited) {
            Write-Status "Stopping app (PID $($script:StartedAppProcess.Id))"
            Stop-Process -Id $script:StartedAppProcess.Id -Force -ErrorAction SilentlyContinue
        }
    }
}
