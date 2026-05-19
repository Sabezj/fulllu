# Simple local runner for voice agent application
# This tool provides a minimal way to run the application locally
# with graceful fallbacks for missing dependencies

[CmdletBinding()]
param(
    [switch]$SkipDependencies,
    [switch]$SkipPySearch,
    [int]$Port = 3000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$EnvFile = Join-Path $ProjectRoot '.env'

function Write-Status {
    param(
        [string]$Message,
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

function Test-TcpPort {
    param(
        [string]$HostName = '127.0.0.1',
        [int]$Port,
        [int]$TimeoutMs = 1000
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

function Load-Environment {
    # Load .env file if it exists
    if (Test-Path $EnvFile) {
        Write-Status "Loading environment from $EnvFile"
        Get-Content $EnvFile | ForEach-Object {
            $line = $_.Trim()
            if ($line -and -not $line.StartsWith('#')) {
                if ($line -match '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
                    $key = $Matches[1]
                    $value = $Matches[2].Trim()
                    
                    # Remove quotes if present
                    if (($value.StartsWith('"') -and $value.EndsWith('"')) -or
                        ($value.StartsWith("'") -and $value.EndsWith("'"))) {
                        $value = $value.Substring(1, $value.Length - 2)
                    }
                    
                    Set-Item -Path "Env:$key" -Value $value
                }
            }
        }
    }
    
    # Override PORT if specified
    if ($Port -ne 3000) {
        Set-Item -Path "Env:PORT" -Value $Port
        Write-Status "Using port: $Port"
    }
}

function Check-Dependencies {
    Write-Status "Checking application dependencies..."
    
    # Check Node.js/npm
    try {
        $nodeVersion = node --version
        $npmVersion = npm --version
        Write-Status "Node.js: $nodeVersion, npm: $npmVersion" 'OK'
    }
    catch {
        Write-Status "Node.js/npm not found. Please install Node.js first." 'ERR'
        return $false
    }
    
    # Check if port is available
    if (Test-TcpPort -Port $Port) {
        Write-Status "Port $Port is already in use" 'WARN'
        Write-Status "Try a different port with: -Port 3001" 'WARN'
        return $false
    }
    
    return $true
}

function Check-OptionalDependencies {
    if ($SkipDependencies) {
        Write-Status "Skipping dependency checks (user requested)" 'WARN'
        return
    }
    
    # Check PostgreSQL
    $dbPort = 5432
    if ($env:DATABASE_URL -match 'localhost:(\d+)' -or $env:DATABASE_URL -match '127.0.0.1:(\d+)') {
        $dbPort = [int]$Matches[1]
    }
    
    if (Test-TcpPort -Port $dbPort) {
        Write-Status "PostgreSQL detected on port $dbPort" 'OK'
    }
    else {
        Write-Status "PostgreSQL not found on port $dbPort" 'WARN'
        Write-Status "Some features may not work without database" 'WARN'
    }
    
    # Check Redis
    $redisPort = 6379
    if ($env:REDIS_URL -match 'localhost:(\d+)' -or $env:REDIS_URL -match '127.0.0.1:(\d+)') {
        $redisPort = [int]$Matches[1]
    }
    
    if (Test-TcpPort -Port $redisPort) {
        Write-Status "Redis detected on port $redisPort" 'OK'
    }
    else {
        Write-Status "Redis not found on port $redisPort" 'WARN'
        Write-Status "Some features may not work without Redis" 'WARN'
    }
    
    # Check Python search if enabled
    if ($env:USE_PY_SEARCH -eq 'true' -and -not $SkipPySearch) {
        $searchPort = 5051
        if ($env:SEARCH_API -match ':(\d+)') {
            $searchPort = [int]$Matches[1]
        }
        
        if (Test-TcpPort -Port $searchPort) {
            Write-Status "Python search service detected on port $searchPort" 'OK'
        }
        else {
            Write-Status "Python search service not found on port $searchPort" 'WARN'
            Write-Status "Search features may not work" 'WARN'
        }
    }
}

function Start-Application {
    Write-Status "Starting application..."
    Write-Status "Application will be available at: http://localhost:$Port"
    Write-Status "Press Ctrl+C to stop the application"
    
    try {
        # Change to project directory and start
        Push-Location $ProjectRoot
        npm start
    }
    catch {
        Write-Status "Application failed to start: $($_.Exception.Message)" 'ERR'
        return $false
    }
    finally {
        Pop-Location
    }
    
    return $true
}

# Main execution
Write-Status "Starting local application runner"
Write-Status "Project root: $ProjectRoot"

# Load environment
Load-Environment

# Check dependencies
if (-not (Check-Dependencies)) {
    Write-Status "Dependency check failed. Exiting." 'ERR'
    exit 1
}

# Check optional dependencies
Check-OptionalDependencies

# Start the application
Start-Application