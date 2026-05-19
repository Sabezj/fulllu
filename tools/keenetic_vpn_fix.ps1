# Keenetic Router VPN Routing Fix
# Root cause: Keenetic router has WireGuard configured but not routing all traffic through VPN
# This script configures the router to route all LAN clients through the VPS tunnel

$KEENETIC_IP = "192.168.1.1"
$KEENETIC_PORT = "2222"
$KEENETIC_USER = "caesar"
$KEENETIC_PASS = "t0dw9rcN3o@cub"

$VPS_IP = "89.125.92.10"
$VPS_USER = "root"
$VPS_PASS = "0Cb8r7Bug5J1AW6pH"

Write-Host "=== Keenetic VPN Routing Configuration ===" -ForegroundColor Cyan
Write-Host ""

# Function to run commands on Keenetic
function Invoke-KeeneticCommand {
    param([string]$Command)
    
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "ssh"
    $psi.Arguments = "-p $KEENETIC_PORT ${KEENETIC_USER}@${KEENETIC_IP} `"$Command`""
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    $process.Start() | Out-Null
    
    # Send password
    $process.StandardInput.WriteLine($KEENETIC_PASS)
    $process.StandardInput.Close()
    
    $output = $process.StandardOutput.ReadToEnd()
    $error = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    
    if ($error -and $error -notmatch "password:") {
        Write-Host "Error: $error" -ForegroundColor Red
    }
    
    return $output
}

Write-Host "Step 1: Checking current WireGuard status..." -ForegroundColor Yellow
$wgStatus = Invoke-KeeneticCommand "show interface Wireguard1"
Write-Host $wgStatus

if ($wgStatus -match "link: down") {
    Write-Host "`n⚠ WireGuard interface is DOWN" -ForegroundColor Yellow
    Write-Host "Checking WireGuard peer configuration..."
    
    $wgPeer = Invoke-KeeneticCommand "show wireguard peer"
    Write-Host $wgPeer
}

Write-Host "`nStep 2: Checking routing table..." -ForegroundColor Yellow
$routes = Invoke-KeeneticCommand "show ip route"
Write-Host $routes

Write-Host "`nStep 3: Checking current public IP..." -ForegroundColor Yellow
$currentIP = Invoke-KeeneticCommand "show ip http-client"
Write-Host "Current IP detection method may vary..."

Write-Host "`nStep 4: Configuring WireGuard tunnel to VPS..." -ForegroundColor Yellow
Write-Host "VPS IP: $VPS_IP"

# Check if we need to configure WireGuard peer
Write-Host "`nConfiguring WireGuard peer for VPS..."
$configCommands = @"
configure
interface Wireguard1
  peer endpoint $VPS_IP port 51820
  peer allowed-ip 0.0.0.0/0
  peer persistent-keepalive 25
  up
  no shutdown
exit
ip route 0.0.0.0/0 Wireguard1 auto 10
commit
"@

Write-Host "Commands to apply:"
Write-Host $configCommands -ForegroundColor Gray

Write-Host "`nApplying configuration..." -ForegroundColor Yellow
# Note: Keenetic uses a web-based API for configuration
# SSH access is limited to show commands
Write-Host "⚠ Keenetic routers require web UI or API for configuration changes" -ForegroundColor Yellow
Write-Host ""
Write-Host "Manual steps required:" -ForegroundColor Cyan
Write-Host "1. Open browser: https://$KEENETIC_IP" 
Write-Host "2. Login with credentials"
Write-Host "3. Go to: Internet > WireGuard"
Write-Host "4. Configure peer:"
Write-Host "   - Endpoint: ${VPS_IP}:51820"
Write-Host "   - Allowed IPs: 0.0.0.0/0"
Write-Host "   - Persistent Keepalive: 25"
Write-Host "5. Go to: Routing > Static routes"
Write-Host "6. Add route: 0.0.0.0/0 via Wireguard1"
Write-Host ""

Write-Host "Alternatively, using Keenetic CLI (if available)..." -ForegroundColor Yellow

Read-Host "Press Enter to continue with automated API configuration"

Write-Host "`nStep 5: Using Keenetic HTTP API..." -ForegroundColor Yellow

# Keenetic uses HTTP API for configuration
$apiUrl = "http://$KEENETIC_IP/rci/"
$auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${KEENETIC_USER}:${KEENETIC_PASS}"))

try {
    # Get current WireGuard config
    $headers = @{
        "Authorization" = "Basic $auth"
        "Content-Type" = "application/json"
    }
    
    $wgConfig = Invoke-RestMethod -Uri $apiUrl -Method Post -Headers $headers -Body '{"show":{"interface":"Wireguard1"}}' -ErrorAction Stop
    Write-Host "Current WireGuard config retrieved" -ForegroundColor Green
    Write-Host ($wgConfig | ConvertTo-Json -Depth 10)
    
    # Configure WireGuard peer
    Write-Host "`nConfiguring WireGuard peer..." -ForegroundColor Yellow
    $peerConfig = @{
        "interface" = @{
            "Wireguard1" = @{
                "peer" = @{
                    "endpoint" = "${VPS_IP}:51820"
                    "allowed-ip" = @("0.0.0.0/0")
                    "persistent-keepalive" = 25
                }
                "up" = $true
            }
        }
    } | ConvertTo-Json -Depth 10
    
    $result = Invoke-RestMethod -Uri $apiUrl -Method Post -Headers $headers -Body $peerConfig -ErrorAction Stop
    Write-Host "✓ WireGuard peer configured" -ForegroundColor Green
    
    # Add default route through WireGuard
    Write-Host "`nAdding default route through WireGuard..." -ForegroundColor Yellow
    $routeConfig = @{
        "ip" = @{
            "route" = @{
                "0.0.0.0/0" = @{
                    "interface" = "Wireguard1"
                    "auto" = $true
                    "metric" = 10
                }
            }
        }
    } | ConvertTo-Json -Depth 10
    
    $result = Invoke-RestMethod -Uri $apiUrl -Method Post -Headers $headers -Body $routeConfig -ErrorAction Stop
    Write-Host "✓ Default route added" -ForegroundColor Green
    
} catch {
    Write-Host "✗ API configuration failed: $_" -ForegroundColor Red
    Write-Host "Falling back to manual configuration instructions..." -ForegroundColor Yellow
}

Write-Host "`n=== Configuration Summary ===" -ForegroundColor Cyan
Write-Host "Router: Keenetic Viva at $KEENETIC_IP"
Write-Host "VPS: $VPS_IP"
Write-Host "WireGuard Interface: Wireguard1"
Write-Host ""
Write-Host "Next steps:"
Write-Host "1. Verify WireGuard tunnel is UP"
Write-Host "2. Test from a client: curl ifconfig.me"
Write-Host "3. Should show: $VPS_IP"
Write-Host ""

Read-Host "Press Enter to test connectivity"

Write-Host "`nTesting connectivity..." -ForegroundColor Yellow
$finalStatus = Invoke-KeeneticCommand "show interface Wireguard1"
Write-Host $finalStatus

if ($finalStatus -match "link: up") {
    Write-Host "`n✓ WireGuard tunnel is UP!" -ForegroundColor Green
} else {
    Write-Host "`n⚠ WireGuard tunnel is still DOWN" -ForegroundColor Yellow
    Write-Host "Check VPS WireGuard configuration"
}
