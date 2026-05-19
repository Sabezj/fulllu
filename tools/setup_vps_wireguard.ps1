# Setup WireGuard on VPS for Keenetic router connection
# Root cause: VPS needs WireGuard server configured to accept Keenetic client

$VPS_IP = "89.125.92.10"
$VPS_USER = "root"
$VPS_PASS = "0Cb8r7Bug5J1AW6pH"

# Keenetic WireGuard public key (from show interface output)
$KEENETIC_PUBLIC_KEY = "e6ejlpvpSJxWv/EPFo0dKR3dNl2oZUhpBKjScQJJclg="

Write-Host "=== VPS WireGuard Server Setup ===" -ForegroundColor Cyan
Write-Host "VPS: $VPS_IP"
Write-Host ""

# Function to run SSH commands with password
function Invoke-SSHCommand {
    param(
        [string]$Command,
        [string]$TargetHost = $VPS_IP,
        [string]$User = $VPS_USER,
        [string]$Password = $VPS_PASS
    )
    
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "ssh"
    $psi.Arguments = "-o StrictHostKeyChecking=no ${User}@${TargetHost} `"$Command`""
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    $process.Start() | Out-Null
    
    # Send password if prompted
    Start-Sleep -Milliseconds 500
    $process.StandardInput.WriteLine($Password)
    $process.StandardInput.Close()
    
    $output = $process.StandardOutput.ReadToEnd()
    $error = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    
    if ($error -and $error -notmatch "password:" -and $error -notmatch "Warning:") {
        Write-Host "Error: $error" -ForegroundColor Red
    }
    
    return $output
}

Write-Host "Step 1: Installing WireGuard on VPS..." -ForegroundColor Yellow
$installCmd = @"
apt-get update && apt-get install -y wireguard wireguard-tools
echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
echo 'net.ipv6.conf.all.forwarding=1' >> /etc/sysctl.conf
sysctl -p
echo 'WireGuard installed'
"@

$result = Invoke-SSHCommand -Command $installCmd
Write-Host $result
Write-Host "✓ WireGuard installation complete" -ForegroundColor Green

Write-Host "`nStep 2: Generating WireGuard keys on VPS..." -ForegroundColor Yellow
$keysCmd = @"
cd /etc/wireguard
if [ ! -f privatekey ]; then
    umask 077
    wg genkey | tee privatekey | wg pubkey > publickey
    echo 'Keys generated'
else
    echo 'Keys already exist'
fi
cat publickey
echo '---'
cat privatekey
"@

$keysResult = Invoke-SSHCommand -Command $keysCmd
Write-Host $keysResult

# Parse keys from output
$lines = $keysResult -split "`n"
$vpsPublicKey = ""
$vpsPrivateKey = ""
$foundSeparator = $false

foreach ($line in $lines) {
    if ($line -match "^[A-Za-z0-9+/]{43}=$") {
        if (-not $foundSeparator) {
            $vpsPublicKey = $line.Trim()
        } else {
            $vpsPrivateKey = $line.Trim()
        }
    }
    if ($line -match "---") {
        $foundSeparator = $true
    }
}

Write-Host "`nVPS Public Key: $vpsPublicKey" -ForegroundColor Green
Write-Host "Keenetic Public Key: $KEENETIC_PUBLIC_KEY" -ForegroundColor Green

Write-Host "`nStep 3: Creating WireGuard configuration..." -ForegroundColor Yellow
$configCmd = @"
cat > /etc/wireguard/wg0.conf << 'WGCONF'
[Interface]
Address = 10.0.0.1/24
ListenPort = 51820
PrivateKey = $vpsPrivateKey

# PostUp rules for NAT and forwarding
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT
PostUp = iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostUp = iptables -t nat -A POSTROUTING -o ens3 -j MASQUERADE
PostUp = iptables -t nat -A POSTROUTING -o venet0 -j MASQUERADE

# PostDown rules
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -o ens3 -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -o venet0 -j MASQUERADE

[Peer]
# Keenetic Router
PublicKey = $KEENETIC_PUBLIC_KEY
AllowedIPs = 10.0.0.2/32, 192.168.1.0/24
PersistentKeepalive = 25
WGCONF
echo 'Configuration created'
"@

$configResult = Invoke-SSHCommand -Command $configCmd
Write-Host $configResult
Write-Host "✓ Configuration created" -ForegroundColor Green

Write-Host "`nStep 4: Starting WireGuard..." -ForegroundColor Yellow
$startCmd = @"
wg-quick down wg0 2>/dev/null || true
wg-quick up wg0
systemctl enable wg-quick@wg0
echo 'WireGuard started'
wg show
"@

$startResult = Invoke-SSHCommand -Command $startCmd
Write-Host $startResult
Write-Host "✓ WireGuard started" -ForegroundColor Green

Write-Host "`nStep 5: Configuring firewall..." -ForegroundColor Yellow
$firewallCmd = @"
if command -v ufw &> /dev/null; then
    ufw allow 51820/udp
    ufw reload
    echo 'UFW configured'
elif command -v firewall-cmd &> /dev/null; then
    firewall-cmd --permanent --add-port=51820/udp
    firewall-cmd --reload
    echo 'Firewalld configured'
else
    iptables -A INPUT -p udp --dport 51820 -j ACCEPT
    echo 'iptables configured'
fi
"@

$firewallResult = Invoke-SSHCommand -Command $firewallCmd
Write-Host $firewallResult
Write-Host "✓ Firewall configured" -ForegroundColor Green

Write-Host "`n=== VPS Configuration Complete ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "VPS WireGuard Public Key: $vpsPublicKey" -ForegroundColor Yellow
Write-Host "VPS WireGuard IP: 10.0.0.1"
Write-Host "VPS Endpoint: ${VPS_IP}:51820"
Write-Host ""
Write-Host "Keenetic Configuration Needed:" -ForegroundColor Yellow
Write-Host "1. Open https://192.168.1.1 in browser"
Write-Host "2. Go to: Internet > WireGuard > Wireguard1"
Write-Host "3. Set Peer Public Key: $vpsPublicKey"
Write-Host "4. Set Endpoint: ${VPS_IP}:51820"
Write-Host "5. Set Allowed IPs: 0.0.0.0/0"
Write-Host "6. Set Local IP: 10.0.0.2/24"
Write-Host "7. Enable interface"
Write-Host ""
Write-Host "Then add routing:" -ForegroundColor Yellow
Write-Host "Go to: Routing > Add route: 0.0.0.0/0 via Wireguard1 metric 10"
Write-Host ""

# Save configuration to file
$configInfo = @"
VPS WireGuard Configuration
============================
VPS IP: $VPS_IP
VPS Public Key: $vpsPublicKey
VPS WireGuard IP: 10.0.0.1
Listen Port: 51820

Keenetic Configuration:
- Public Key: $KEENETIC_PUBLIC_KEY
- WireGuard IP: 10.0.0.2
- Endpoint: ${VPS_IP}:51820
- Allowed IPs: 0.0.0.0/0
"@

$configInfo | Out-File -FilePath "tools/wireguard_config.txt" -Encoding UTF8
Write-Host "Configuration saved to: tools/wireguard_config.txt" -ForegroundColor Green
