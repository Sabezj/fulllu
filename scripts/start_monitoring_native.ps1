[CmdletBinding()]
param(
    [int]$AppPort = 3000,
    [string]$AppHost = '127.0.0.1',
    [string]$PrometheusVersion = '3.11.3',
    [string]$AlertmanagerVersion = '0.32.1',
    [string]$GrafanaVersion = '13.0.1+security-01',
    [string]$GrafanaBuild = '25720641773'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$EnvFile = Join-Path $ProjectRoot '.env'
$MonitoringRoot = Join-Path $ProjectRoot 'ops\monitoring\runtime'
$DownloadsDir = Join-Path $MonitoringRoot 'downloads'
$ToolsDir = Join-Path $MonitoringRoot 'tools'
$PrometheusRuntimeDir = Join-Path $MonitoringRoot 'prometheus'
$AlertmanagerRuntimeDir = Join-Path $MonitoringRoot 'alertmanager'
$GrafanaRuntimeDir = Join-Path $MonitoringRoot 'grafana'
$LogDir = Join-Path $ProjectRoot 'logs'
$MonitoringLogDir = Join-Path $LogDir 'monitoring'

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

function Ensure-Dir {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

function Load-DotEnv {
    param([string]$Path)

    if (-not (Test-Path $Path)) { return }

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
            Set-Item -Path ("Env:{0}" -f $key) -Value $value
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

function Wait-ForHttp {
    param(
        [string]$Url,
        [int]$TimeoutSec = 45
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        try {
            $resp = Invoke-WebRequest -UseBasicParsing -Uri $Url -TimeoutSec 3
            if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 500) {
                return $true
            }
        }
        catch {}

        Start-Sleep -Milliseconds 600
    }

    return $false
}

function Normalize-ConfigPath {
    param([string]$Path)
    return ((Resolve-Path $Path).Path -replace '\\', '/')
}

function Invoke-ProxiedWebRequest {
    param(
        [string]$Url,
        [string]$OutFile
    )

    $oldHttp = $env:HTTP_PROXY
    $oldHttps = $env:HTTPS_PROXY
    $oldAll = $env:ALL_PROXY
    $oldNoProxy = $env:NO_PROXY
    $oldProgress = $global:ProgressPreference

    try {
        $env:HTTP_PROXY = 'http://127.0.0.1:9077'
        $env:HTTPS_PROXY = 'http://127.0.0.1:9077'
        $env:ALL_PROXY = 'socks5://127.0.0.1:9078'
        $env:NO_PROXY = '127.0.0.1,localhost'
        $global:ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $OutFile
    }
    finally {
        $env:HTTP_PROXY = $oldHttp
        $env:HTTPS_PROXY = $oldHttps
        $env:ALL_PROXY = $oldAll
        $env:NO_PROXY = $oldNoProxy
        $global:ProgressPreference = $oldProgress
    }
}

function Ensure-Downloaded {
    param(
        [string]$Url,
        [string]$Destination
    )

    if (Test-Path $Destination) {
        return
    }

    Write-Status "Downloading $(Split-Path $Destination -Leaf)"
    Invoke-ProxiedWebRequest -Url $Url -OutFile $Destination
}

function Ensure-ZipExtracted {
    param(
        [string]$ArchivePath,
        [string]$DestinationRoot,
        [string]$ExpectedDirName
    )

    $expectedDir = Join-Path $DestinationRoot $ExpectedDirName
    if (Test-Path $expectedDir) {
        return $expectedDir
    }

    Write-Status "Extracting $(Split-Path $ArchivePath -Leaf)"
    Expand-Archive -LiteralPath $ArchivePath -DestinationPath $DestinationRoot -Force
    return $expectedDir
}

function Ensure-TarGzExtracted {
    param(
        [string]$ArchivePath,
        [string]$DestinationRoot,
        [string]$ExpectedDirName
    )

    $expectedDir = Join-Path $DestinationRoot $ExpectedDirName
    if (Test-Path $expectedDir) {
        return $expectedDir
    }

    $tarExe = Get-Command tar.exe -ErrorAction SilentlyContinue
    if (-not $tarExe) {
        $tarExe = Get-Command tar -ErrorAction SilentlyContinue
    }
    if (-not $tarExe) {
        throw 'tar.exe is required to extract Grafana Windows binaries.'
    }

    Write-Status "Extracting $(Split-Path $ArchivePath -Leaf)"
    & $tarExe.Source -xf $ArchivePath -C $DestinationRoot
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to extract $ArchivePath"
    }

    return $expectedDir
}

function Copy-IfChanged {
    param(
        [string]$Source,
        [string]$Destination
    )

    if ((Test-Path $Destination) -and ((Get-FileHash $Source).Hash -eq (Get-FileHash $Destination).Hash)) {
        return
    }

    Copy-Item -Path $Source -Destination $Destination -Force
}

function Write-ContentIfChanged {
    param(
        [string]$Path,
        [string]$Content
    )

    if ((Test-Path $Path) -and ((Get-Content -Raw -Path $Path) -eq $Content)) {
        return
    }

    Set-Content -Path $Path -Value $Content -Encoding UTF8
}

function Ensure-MonitoringConfigs {
    param(
        [string]$GrafanaRootUrl,
        [string]$GrafanaAdminUser,
        [string]$GrafanaAdminPassword
    )

    Ensure-Dir $PrometheusRuntimeDir
    Ensure-Dir $AlertmanagerRuntimeDir
    Ensure-Dir $GrafanaRuntimeDir
    Ensure-Dir (Join-Path $PrometheusRuntimeDir 'data')
    Ensure-Dir (Join-Path $AlertmanagerRuntimeDir 'data')
    Ensure-Dir (Join-Path $GrafanaRuntimeDir 'data')
    Ensure-Dir (Join-Path $GrafanaRuntimeDir 'logs')
    Ensure-Dir (Join-Path $GrafanaRuntimeDir 'plugins')
    Ensure-Dir (Join-Path $GrafanaRuntimeDir 'dashboards')
    Ensure-Dir (Join-Path $GrafanaRuntimeDir 'provisioning')
    Ensure-Dir (Join-Path $GrafanaRuntimeDir 'provisioning\datasources')
    Ensure-Dir (Join-Path $GrafanaRuntimeDir 'provisioning\dashboards')

    $alertsSource = Join-Path $ProjectRoot 'ops\monitoring\prometheus\alerts.yml'
    $alertmanagerSource = Join-Path $ProjectRoot 'ops\monitoring\alertmanager\alertmanager.yml'
    $dashboardSourceDir = Join-Path $ProjectRoot 'ops\monitoring\grafana\dashboards'

    $alertsTarget = Join-Path $PrometheusRuntimeDir 'alerts.yml'
    $alertmanagerTarget = Join-Path $AlertmanagerRuntimeDir 'alertmanager.yml'

    Copy-IfChanged -Source $alertsSource -Destination $alertsTarget
    Copy-IfChanged -Source $alertmanagerSource -Destination $alertmanagerTarget
    Get-ChildItem -Path $dashboardSourceDir -Filter '*.json' -File | ForEach-Object {
        Copy-IfChanged -Source $_.FullName -Destination (Join-Path $GrafanaRuntimeDir "dashboards\$($_.Name)")
    }

    $prometheusConfig = @"
global:
  scrape_interval: 15s
  evaluation_interval: 15s

rule_files:
  - $(Normalize-ConfigPath $alertsTarget)

alerting:
  alertmanagers:
    - static_configs:
        - targets:
            - 127.0.0.1:9093

scrape_configs:
  - job_name: lawvoice-web
    metrics_path: /metrics
    static_configs:
      - targets:
          - $AppHost`:$AppPort

  - job_name: prometheus
    static_configs:
      - targets:
          - 127.0.0.1:9090

  - job_name: alertmanager
    static_configs:
      - targets:
          - 127.0.0.1:9093

  - job_name: grafana
    metrics_path: /metrics
    static_configs:
      - targets:
          - 127.0.0.1:3001
"@
    Write-ContentIfChanged -Path (Join-Path $PrometheusRuntimeDir 'prometheus.yml') -Content $prometheusConfig

    $datasourceConfig = @"
apiVersion: 1

datasources:
  - name: Prometheus
    uid: prometheus
    type: prometheus
    access: proxy
    url: http://127.0.0.1:9090
    isDefault: true
    editable: false
"@
    Write-ContentIfChanged -Path (Join-Path $GrafanaRuntimeDir 'provisioning\datasources\datasource.yml') -Content $datasourceConfig

    $dashboardConfig = @"
apiVersion: 1

providers:
  - name: LawVoice
    orgId: 1
    folder: LawVoice
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30
    allowUiUpdates: false
    options:
      path: $(Normalize-ConfigPath (Join-Path $GrafanaRuntimeDir 'dashboards'))
"@
    Write-ContentIfChanged -Path (Join-Path $GrafanaRuntimeDir 'provisioning\dashboards\dashboard.yml') -Content $dashboardConfig

    $grafanaConfig = @"
[server]
http_addr = 127.0.0.1
http_port = 3001
root_url = $GrafanaRootUrl

[security]
admin_user = $GrafanaAdminUser
admin_password = $GrafanaAdminPassword

[auth.anonymous]
enabled = false

[users]
allow_sign_up = false

[metrics]
enabled = true

[paths]
data = $(Normalize-ConfigPath (Join-Path $GrafanaRuntimeDir 'data'))
logs = $(Normalize-ConfigPath (Join-Path $GrafanaRuntimeDir 'logs'))
plugins = $(Normalize-ConfigPath (Join-Path $GrafanaRuntimeDir 'plugins'))
provisioning = $(Normalize-ConfigPath (Join-Path $GrafanaRuntimeDir 'provisioning'))
"@
    Write-ContentIfChanged -Path (Join-Path $GrafanaRuntimeDir 'custom.ini') -Content $grafanaConfig
}

function Start-ManagedProcess {
    param(
        [string]$Name,
        [string]$FilePath,
        [string[]]$ArgumentList,
        [string]$WorkingDirectory,
        [string]$HealthUrl,
        [string]$HostName,
        [int]$Port
    )

    if (Test-TcpPort -HostName $HostName -Port $Port) {
        Write-Status "$Name already listening on $HostName`:$Port" 'OK'
        return
    }

    $timeStamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $stdout = Join-Path $MonitoringLogDir ("{0}.{1}.out.log" -f $Name.ToLowerInvariant(), $timeStamp)
    $stderr = Join-Path $MonitoringLogDir ("{0}.{1}.err.log" -f $Name.ToLowerInvariant(), $timeStamp)

    Write-Status "Starting $Name on $HostName`:$Port"
    $process = Start-Process `
        -FilePath $FilePath `
        -ArgumentList $ArgumentList `
        -WorkingDirectory $WorkingDirectory `
        -WindowStyle Hidden `
        -PassThru `
        -RedirectStandardOutput $stdout `
        -RedirectStandardError $stderr

    if (-not (Wait-ForHttp -Url $HealthUrl -TimeoutSec 60)) {
        throw "$Name failed health check at $HealthUrl (logs: $stderr)"
    }

    Write-Status "$Name is up (PID $($process.Id))" 'OK'
}

Load-DotEnv -Path $EnvFile
Ensure-Dir $MonitoringRoot
Ensure-Dir $DownloadsDir
Ensure-Dir $ToolsDir
Ensure-Dir $LogDir
Ensure-Dir $MonitoringLogDir

$prometheusArchive = Join-Path $DownloadsDir ("prometheus-{0}.windows-amd64.zip" -f $PrometheusVersion)
$alertmanagerArchive = Join-Path $DownloadsDir ("alertmanager-{0}.windows-amd64.zip" -f $AlertmanagerVersion)
$grafanaArchive = Join-Path $DownloadsDir ("grafana_{0}_{1}_windows_amd64.tar.gz" -f $GrafanaVersion, $GrafanaBuild)

Ensure-Downloaded `
    -Url ("https://github.com/prometheus/prometheus/releases/download/v{0}/prometheus-{0}.windows-amd64.zip" -f $PrometheusVersion) `
    -Destination $prometheusArchive
Ensure-Downloaded `
    -Url ("https://github.com/prometheus/alertmanager/releases/download/v{0}/alertmanager-{0}.windows-amd64.zip" -f $AlertmanagerVersion) `
    -Destination $alertmanagerArchive
Ensure-Downloaded `
    -Url ("https://dl.grafana.com/grafana/release/{0}/grafana_{0}_{1}_windows_amd64.tar.gz" -f $GrafanaVersion, $GrafanaBuild) `
    -Destination $grafanaArchive

$prometheusHome = Ensure-ZipExtracted `
    -ArchivePath $prometheusArchive `
    -DestinationRoot $ToolsDir `
    -ExpectedDirName ("prometheus-{0}.windows-amd64" -f $PrometheusVersion)
$alertmanagerHome = Ensure-ZipExtracted `
    -ArchivePath $alertmanagerArchive `
    -DestinationRoot $ToolsDir `
    -ExpectedDirName ("alertmanager-{0}.windows-amd64" -f $AlertmanagerVersion)
$grafanaHome = Ensure-TarGzExtracted `
    -ArchivePath $grafanaArchive `
    -DestinationRoot $ToolsDir `
    -ExpectedDirName ("grafana-{0}" -f $GrafanaVersion)

$grafanaAdminUser = if ([string]::IsNullOrWhiteSpace($env:GRAFANA_ADMIN_USER)) { 'admin' } else { $env:GRAFANA_ADMIN_USER }
$grafanaAdminPassword = if ([string]::IsNullOrWhiteSpace($env:GRAFANA_ADMIN_PASSWORD)) { 'change-me' } else { $env:GRAFANA_ADMIN_PASSWORD }
$grafanaRootUrl = if ([string]::IsNullOrWhiteSpace($env:GRAFANA_ROOT_URL)) { 'http://127.0.0.1:3001' } else { $env:GRAFANA_ROOT_URL }

Ensure-MonitoringConfigs `
    -GrafanaRootUrl $grafanaRootUrl `
    -GrafanaAdminUser $grafanaAdminUser `
    -GrafanaAdminPassword $grafanaAdminPassword

Start-ManagedProcess `
    -Name 'Alertmanager' `
    -FilePath (Join-Path $alertmanagerHome 'alertmanager.exe') `
    -ArgumentList @(
        "--config.file=$(Join-Path $AlertmanagerRuntimeDir 'alertmanager.yml')",
        "--storage.path=$(Join-Path $AlertmanagerRuntimeDir 'data')",
        '--web.listen-address=127.0.0.1:9093'
    ) `
    -WorkingDirectory $alertmanagerHome `
    -HealthUrl 'http://127.0.0.1:9093/-/healthy' `
    -HostName '127.0.0.1' `
    -Port 9093

Start-ManagedProcess `
    -Name 'Prometheus' `
    -FilePath (Join-Path $prometheusHome 'prometheus.exe') `
    -ArgumentList @(
        "--config.file=$(Join-Path $PrometheusRuntimeDir 'prometheus.yml')",
        "--storage.tsdb.path=$(Join-Path $PrometheusRuntimeDir 'data')",
        '--web.listen-address=127.0.0.1:9090',
        '--web.enable-lifecycle'
    ) `
    -WorkingDirectory $prometheusHome `
    -HealthUrl 'http://127.0.0.1:9090/-/healthy' `
    -HostName '127.0.0.1' `
    -Port 9090

Start-ManagedProcess `
    -Name 'Grafana' `
    -FilePath (Join-Path $grafanaHome 'bin\grafana.exe') `
    -ArgumentList @(
        'server',
        '--homepath', $grafanaHome,
        '--config', (Join-Path $GrafanaRuntimeDir 'custom.ini')
    ) `
    -WorkingDirectory $grafanaHome `
    -HealthUrl 'http://127.0.0.1:3001/api/health' `
    -HostName '127.0.0.1' `
    -Port 3001

Write-Status 'Native monitoring stack is ready.' 'OK'
