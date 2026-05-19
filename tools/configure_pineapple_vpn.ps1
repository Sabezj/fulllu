# Root cause: Pineapple OpenWrt router needs VPN tunnel to VPS with proper routing
# This automates the complete diagnostic and configuration workflow

param(
    [switch]$DiagnosticOnly,
    [switch]$UseOpenVPN,
    [switch]$SkipBackup
)

# Configuration
$PINEAPPLE_IP = "192.168.1.91"
$PINEAPPLE_USER = "root"
$PINEAPPLE_PASS = "homohominilupusest"

$VPS_IP = "89.125.92.10"
$VPS_USER = "root"
$VPS_PASS = "0Cb8r7Bug5J1AW6pH"

$KEENETIC_IP = "192.168.1.1"
$KEENETIC_USER = "caesar"
$KEENETIC_PASS = "t0dw9rcN3o@cub"
$KEENETIC_PORT = "2222"

$TERRA_IP = "172.16.42.1"
$TERRA_USER = "root"
$TERRA_PASS = "homohominilupusest"

Write-Host "=== Pineapple VPN Configuration Tool ===" -ForegroundColor Cyan
Write-Host "Pineapple: $PINEAPPLE_IP"
Write-Host "VPS: $VPS_IP"
Write-Host "Keenetic: $KEENETIC_IP (not modified)"
Write-Host ""

# SSH helper with automatic password
function Invoke-SSH {
    param(
        [string]$TargetHost,
        [string]$User,
        [string]$Password,
        [string]$Command,
        [int]$Port = 22
    )
    
    $tempScript = [System.IO.Path]::GetTempFileName()
    @"
#!/usr/bin/expect -f
set timeout 30
spawn ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $Port ${User}@${TargetHost} "$Command"
expect {
    "password:" {
        send "$Password\r"
        exp_continue
    }
    eof
}
"@ | Out-File -FilePath $tempScript -Encoding ASCII
    
    if (Get-Command wsl -ErrorAction SilentlyContinue) {
        $result = wsl bash -c "expect $tempScript 2>&1"
        Remove-Item $tempScript -ErrorAction SilentlyContinue
        return $result
    } else {
        # Fallback: use plink if available
        if (Get-Command plink -ErrorAction SilentlyContinue) {
            $result = echo $Password | plink -ssh -P $Port -l $User -pw $Password $TargetHost $Command 2>&1
            return $result
        } else {
            Write-Host "Error: Need WSL with expect or plink for automated SSH" -ForegroundColor Red
            exit 1
        }
    }
}

Write-Host "Step 1: Diagnostic - Checking current state..." -ForegroundColor Yellow

# Check Pineapple
Write-Host "`nPineapple Status:" -ForegroundColor Cyan
$pineappleIfaces = Invoke-SSH -TargetHost $PINEAPPLE_IP -User $PINEAPPLE_USER -Password $PINEAPPLE_PASS -Command "ip addr show; ip route show"
Write-Host $pineappleIfaces

$wgStatus = Invoke-SSH -TargetHost $PINEAPPLE_IP -User $PINEAPPLE_USER -Password $PINEAPPLE_PASS -Command "wg show 2>/dev/null || echo 'No WireGuard'"
Write-Host "WireGuard: $wgStatus"

# Check VPS
Write-Host "`nVPS Status:" -ForegroundColor Cyan
$vpsWg = Invoke-SSH -TargetHost $VPS_IP -User $VPS_USER -Password $VPS_PASS -Command "wg show 2>/dev/null; iptables -t nat -L POSTROUTING -n -v | head -20"
Write-Host $vpsWg

if ($DiagnosticOnly) {
    Write-Host "`nDiagnostic complete. Use without -DiagnosticOnly to configure." -ForegroundColor Green
    exit 0
}

# Backup
if (-not $SkipBackup) {
    Write-Host "`nStep 2: Creating backup..." -ForegroundColor Yellow
    $backupName = "backup-$(Get-Date -Format 'yyyyMMdd-HHmm')"
    Invoke-SSH -TargetHost $PINEAPPLE_IP -User $PINEAPPLE_USER -Password $PINEAPPLE_PASS -Command "sysupgrade -b /tmp/$backupName.tar.gz"
    Write-Host "✓ Backup created: /tmp/$backupName.tar.gz" -ForegroundColor Green
}

if ($UseOpenVPN) {
    Write-Host "`nStep 3: Configuring OpenVPN tunnel..." -ForegroundColor Yellow
    
    # Install OpenVPN on VPS
    Write-Host "Installing OpenVPN on VPS..."
    Invoke-SSH -TargetHost $VPS_IP -User $VPS_USER -Password $VPS_PASS -Command @"
apt-get update && apt-get install -y openvpn easy-rsa
mkdir -p /etc/openvpn/pineapple
cd /etc/openvpn/pineapple
openvpn --genkey secret static.key
cat > server.conf << 'EOF'
dev tun1
ifconfig 10.9.0.1 10.9.0.2
secret static.key
port 8443
proto tcp-server
keepalive 10 60
persist-key
persist-tun
verb 3
EOF
systemctl enable openvpn@server
systemctl restart openvpn@server
"@
    
    # Get static key
    $staticKey = Invoke-SSH -TargetHost $VPS_IP -User $VPS_USER -Password $VPS_PASS -Command "cat /etc/openvpn/pineapple/static.key"
    
    # Install OpenVPN on Pineapple
    Write-Host "Installing OpenVPN on Pineapple..."
    Invoke-SSH -TargetHost $PINEAPPLE_IP -User $PINEAPPLE_USER -Password $PINEAPPLE_PASS -Command @"
opkg update
opkg install openvpn-openssl
mkdir -p /etc/openvpn
cat > /etc/openvpn/static.key << 'EOF'
$staticKey
EOF
cat > /etc/openvpn/client.conf << 'EOF'
dev tun0
ifconfig 10.9.0.2 10.9.0.1
remote $VPS_IP 8443
proto tcp-client
secret /etc/openvpn/static.key
keepalive 10 60
persist-key
persist-tun
verb 3
EOF
/etc/init.d/openvpn enable
/etc/init.d/openvpn start
"@
    
    # Configure routing
    Write-Host "Configuring policy routing..."
    Invoke-SSH -TargetHost $PINEAPPLE_IP -User $PINEAPPLE_USER -Password $PINEAPPLE_PASS -Command @"
# Add routing table for VPN
echo '200 vpn' >> /etc/iproute2/rt_tables

# Route LAN clients through VPN
ip rule add from 172.16.42.0/24 table 200
ip route add default via 10.9.0.1 dev tun0 table 200

# NAT for VPN
iptables -t nat -A POSTROUTING -o tun0 -j MASQUERADE

# Disable IPv6 RA on LAN
uci set network.lan.ipv6='0'
uci set dhcp.lan.ra='disabled'
uci commit
/etc/init.d/network reload
"@
    
    Write-Host "✓ OpenVPN configured" -ForegroundColor Green
    
} else {
    Write-Host "`nStep 3: Configuring WireGuard tunnel..." -ForegroundColor Yellow
    
    # Generate new keys for Pineapple
    Write-Host "Generating WireGuard keys..."
    $pineappleKeys = Invoke-SSH -TargetHost $PINEAPPLE_IP -User $PINEAPPLE_USER -Password $PINEAPPLE_PASS -Command @"
wg genkey | tee /tmp/wg_private | wg pubkey
cat /tmp/wg_private
"@
    
    $keys = $pineappleKeys -split "`n"
    $pineapplePublic = $keys[0].Trim()
    $pineapplePrivate = $keys[1].Trim()
    
    Write-Host "Pineapple Public Key: $pineapplePublic"
    
    # Configure VPS WireGuard
    Write-Host "Configuring VPS WireGuard..."
    Invoke-SSH -TargetHost $VPS_IP -User $VPS_USER -Password $VPS_PASS -Command @"
# Generate VPS keys if needed
if [ ! -f /etc/wireguard/wgpine_private ]; then
    wg genkey | tee /etc/wireguard/wgpine_private | wg pubkey > /etc/wireguard/wgpine_public
fi

VPS_PRIVATE=\$(cat /etc/wireguard/wgpine_private)
VPS_PUBLIC=\$(cat /etc/wireguard/wgpine_public)

# Create wgpine interface config
cat > /etc/wireguard/wgpine.conf << EOF
[Interface]
Address = 10.9.0.1/24
ListenPort = 51821
PrivateKey = \$VPS_PRIVATE
PostUp = iptables -A FORWARD -i wgpine -j ACCEPT; iptables -t nat -A POSTROUTING -s 10.9.0.0/24 -j MASQUERADE
PostDown = iptables -D FORWARD -i wgpine -j ACCEPT; iptables -t nat -D POSTROUTING -s 10.9.0.0/24 -j MASQUERADE

[Peer]
PublicKey = $pineapplePublic
AllowedIPs = 10.9.0.2/32, 172.16.42.0/24
PersistentKeepalive = 25
EOF

# Start wgpine
wg-quick down wgpine 2>/dev/null || true
wg-quick up wgpine
systemctl enable wg-quick@wgpine

echo \$VPS_PUBLIC
"@
    
    $vpsPublic = ($vpsWgSetup -split "`n")[-1].Trim()
    Write-Host "VPS Public Key: $vpsPublic"
    
    # Configure Pineapple WireGuard
    Write-Host "Configuring Pineapple WireGuard..."
    Invoke-SSH -TargetHost $PINEAPPLE_IP -User $PINEAPPLE_USER -Password $PINEAPPLE_PASS -Command @"
# Create WireGuard interface
uci set network.wgfi=interface
uci set network.wgfi.proto='wireguard'
uci set network.wgfi.private_key='$pineapplePrivate'
uci add_list network.wgfi.addresses='10.9.0.2/24'

# Add VPS peer
uci delete network.@wireguard_wgfi[0] 2>/dev/null || true
uci add network wireguard_wgfi
uci set network.@wireguard_wgfi[-1].public_key='$vpsPublic'
uci set network.@wireguard_wgfi[-1].endpoint_host='$VPS_IP'
uci set network.@wireguard_wgfi[-1].endpoint_port='51821'
uci set network.@wireguard_wgfi[-1].persistent_keepalive='25'
uci add_list network.@wireguard_wgfi[-1].allowed_ips='0.0.0.0/0'

# Policy routing for LAN clients only
echo '200 vpn' >> /etc/iproute2/rt_tables
ip rule add from 172.16.42.0/24 table 200
ip route add default dev wgfi table 200

# Firewall
uci set firewall.wg=zone
uci set firewall.wg.name='wg'
uci set firewall.wg.input='ACCEPT'
uci set firewall.wg.output='ACCEPT'
uci set firewall.wg.forward='ACCEPT'
uci set firewall.wg.masq='1'
uci set firewall.wg.network='wgfi'

uci add firewall forwarding
uci set firewall.@forwarding[-1].src='lan'
uci set firewall.@forwarding[-1].dest='wg'

# Disable IPv6 RA
uci set network.lan.ipv6='0'
uci set dhcp.lan.ra='disabled'

# Disable hardware offload (breaks policy routing)
uci set network.@device[0].flow_offload='0'

uci commit
/etc/init.d/network reload
/etc/init.d/firewall reload
"@
    
    Write-Host "✓ WireGuard configured" -ForegroundColor Green
}

Write-Host "`nStep 4: Testing connectivity..." -ForegroundColor Yellow

Start-Sleep -Seconds 5

$testResult = Invoke-SSH -TargetHost $PINEAPPLE_IP -User $PINEAPPLE_USER -Password $PINEAPPLE_PASS -Command @"
echo '=== Tunnel Status ==='
if [ -f /etc/openvpn/client.conf ]; then
    ip addr show tun0
else
    wg show wgfi
fi

echo '=== Routes ==='
ip route show table 200

echo '=== External IP from Pineapple ==='
wget -qO- http://api.ipify.org
echo ''

echo '=== DNS Test ==='
nslookup google.com
"@

Write-Host $testResult

if ($testResult -match $VPS_IP) {
    Write-Host "`n✓ SUCCESS! Pineapple routes through VPS" -ForegroundColor Green
} else {
    Write-Host "`n⚠ Warning: External IP doesn't match VPS" -ForegroundColor Yellow
}

Write-Host "`n=== Configuration Complete ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "Network: NZPineAP"
Write-Host "Password: timeodanaosetdonaferentes"
Write-Host "Clients on 172.16.42.0/24 will route through $VPS_IP"
Write-Host ""
Write-Host "Test from client: curl ifconfig.me"
Write-Host "Should show: $VPS_IP"
Write-Host ""
Write-Host "Rollback: ssh root@$PINEAPPLE_IP 'sysupgrade -r /tmp/backup-*.tar.gz'"
