$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$canonicalScript = Join-Path $scriptDir 'redeploy_allaw_urist.ps1'

if (!(Test-Path $canonicalScript)) {
    throw "Canonical deploy script not found: $canonicalScript"
}

Write-Host "Delegating to $canonicalScript" -ForegroundColor Yellow
& $canonicalScript @args
exit $LASTEXITCODE
