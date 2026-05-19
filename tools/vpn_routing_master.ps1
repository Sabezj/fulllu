# Master script for OpenWRT VPN routing management (PowerShell)
# Windows-compatible version

$OPENWRT_IP = "192.168.1.1"
$VPS_IP = "89.125.92.10"
$VPS_USER = "root"
$VPS_PASS = "0Cb8r7Bug5J1AW6pH"

function Show-Menu {
    Clear-Host
    Write-Host "╔════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║     OpenWRT VPN Routing Management                     ║" -ForegroundColor Cyan
    Write-Host "║     VPS: $VPS_IP | Router: $OPENWRT_IP           ║" -ForegroundColor Cyan
    Write-Host "╚════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "1) Quick Diagnostics - Check current status"
    Write-Host "2) Quick Fix - Repair VPN routing (if tunnel exists)"
    Write-Host "3) Full WireGuard Setup - Complete installation"
    Write-Host "4) Backup Configuration"
    Write-Host "5) Test Connectivity"
    Write-Host "6) View Logs"
    Write-Host "7) Exit"
    Write-Host ""
    $choice = Read-Host "Select option [1-7]"
    return $choice
}

function Test-SSHConnection {
    param([string]$Host)
    Write-Host "Testing SSH connection to $Host..." -ForegroundColor Yellow
    try {
        $result = ssh -o ConnectTimeout=5 root@$Host "echo 'Connected'"
        if ($result -eq "Connected") {
            Write-Host "✓ SSH connection successful" -ForegroundColor Green
            return $true
        }
    } catch {
        Write-Host "✗ SSH connection failed" -ForegroundColor Red
        return $false
    }
}

function Run-Diagnostics {
    Write-Host "`n=== Running Diagnostics ===" -ForegroundColor Cyan
    
    Write-Host "`n1. Network Interfaces:" -ForegroundColor Yellow
    ssh root@$OPENWRT_IP "ip addr show | grep -E '^[0-9]+:|inet '"
    
    Write-Host "`n2. Routing Table:" -ForegroundColor Yellow
    ssh root@$OPENWRT_IP "ip route show"
    
    Write-Host "`n3. Active VPN Tunnels:" -ForegroundColor Yellow
    ssh root@$OPENWRT_IP "ip link show | grep -E 'tun|wg|vpn' || echo 'No VPN interface found'"
    
    Write-Host "`n4. WireGuard Status:" -ForegroundColor Yellow
    ssh root@$OPENWRT_IP "wg show 2>/dev/null || echo 'WireGuard not active'"
    
    Write-Host "`n5. Current Public IP:" -ForegroundColor Yellow
    $currentIP = ssh root@$OPENWRT_IP "curl -s --max-time 5 ifconfig.me"
    Write-Host "Current IP: $currentIP"
    
    if ($currentIP -eq $VPS_IP) {
        Write-Host "✓ Routing through VPS correctly!" -ForegroundColor Green
    } else {
        Write-Host "✗ NOT routing through VPS (expected: $VPS_IP)" -ForegroundColor Red
    }
    
    Write-Host "`n6. VPS Connectivity:" -ForegroundColor Yellow
    ssh root@$OPENWRT_IP "ping -c 3 $VPS_IP"
    
    Read-Host "`nPress Enter to continue"
}

function Quick-Fix {
    Write-Host "`n=== Quick VPN Routing Fix ===" -ForegroundColor Cyan
    
    Write-Host "Detecting VPN interface..."
    $tunnelIF = ssh root@$OPENWRT_IP "ip link show | grep -oE '(tun|wg|vpn)[0-9]+' | head -1"
    
    if ([string]::IsNullOrEmpty($tunnelIF)) {
        Write-Host "✗ No VPN tunnel interface found!" -ForegroundColor Red
        Write-Host "Please run Full WireGuard Setup first (option 3)" -ForegroundColor Yellow
        Read-Host "Press Enter to continue"
        return
    }
    
    Write-Host "✓ Found tunnel: $tunnelIF" -ForegroundColor Green
    Write-Host "`nApplying routing fixes..."
    
    $fixScript = @"
# Enable IP forwarding
echo 1 > /proc/sys/net/ipv4/ip_forward

# Set default route through VPN
ip route del default 2>/dev/null || true
ip route add default dev $tunnelIF

# Configure NAT
iptables -t nat -D POSTROUTING -o $tunnelIF -j MASQUERADE 2>/dev/null || true
iptables -t nat -A POSTROUTING -o $tunnelIF -j MASQUERADE

# Allow forwarding
iptables -D FORWARD -i br-lan -o $tunnelIF -j ACCEPT 2>/dev/null || true
iptables -A FORWARD -i br-lan -o $tunnelIF -j ACCEPT
iptables -D FORWARD -i $tunnelIF -o br-lan -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
iptables -A FORWARD -i $tunnelIF -o br-lan -m state --state RELATED,ESTABLISHED -j ACCEPT

# Update firewall config
uci set firewall.@zone[1].network='wan $tunnelIF'
uci commit firewall
/etc/init.d/firewall reload

echo 'Fixes applied'
"@
    
    ssh root@$OPENWRT_IP $fixScript
    
    Write-Host "`nTesting connectivity..."
    $newIP = ssh root@$OPENWRT_IP "curl -s --max-time 10 ifconfig.me"
    Write-Host "Current public IP: $newIP"
    
    if ($newIP -eq $VPS_IP) {
        Write-Host "✓ Routing is working! All clients now route through VPN" -ForegroundColor Green
    } else {
        Write-Host "⚠ Still having issues. Run diagnostics for details" -ForegroundColor Yellow
    }
    
    Read-Host "`nPress Enter to continue"
}

function Full-WireGuardSetup {
    Write-Host "`n=== Full WireGuard Setup ===" -ForegroundColor Cyan
    Write-Host "⚠️  This will:" -ForegroundColor Yellow
    Write-Host "   - Install WireGuard on OpenWRT and VPS"
    Write-Host "   - Generate encryption keys"
    Write-Host "   - Configure routing for all clients"
    Write-Host ""
    
    $confirm = Read-Host "Continue? (yes/no)"
    if ($confirm -ne "yes") {
        Write-Host "Cancelled"
        Read-Host "Press Enter to continue"
        return
    }
    
    Write-Host "`nStep 1: Installing WireGuard on OpenWRT..."
    ssh root@$OPENWRT_IP @"
opkg update
opkg install wireguard-tools luci-proto-wireguard kmod-wireguard
umask 077
wg genkey | tee /etc/wireguard/privatekey | wg pubkey > /etc/wireguard/publickey
"@
    
    Write-Host "✓ WireGuard installed on OpenWRT" -ForegroundColor Green
    
    Write-Host "`nStep 2: Installing WireGuard on VPS..."
    ssh root@$VPS_IP @"
apt-get update
apt-get install -y wireguard
if [ ! -f /etc/wireguard/privatekey ]; then
    umask 077
    wg genkey | tee /etc/wireguard/privatekey | wg pubkey > /etc/wireguard/publickey
fi
"@
    
    Write-Host "✓ WireGuard installed on VPS" -ForegroundColor Green
    
    Write-Host "`nStep 3: Retrieving keys..."
    $openwrtPrivate = ssh root@$OPENWRT_IP "cat /etc/wireguard/privatekey"
    $openwrtPublic = ssh root@$OPENWRT_IP "cat /etc/wireguard/publickey"
    $vpsPrivate = ssh root@$VPS_IP "cat /etc/wireguard/privatekey"
    $vpsPublic = ssh root@$VPS_IP "cat /etc/wireguard/publickey"
    
    Write-Host "✓ Keys generated" -ForegroundColor Green
    
    Write-Host "`nStep 4: Configuring VPS..."
    $vpsConfig = @"
[Interface]
Address = 10.0.0.1/24
ListenPort = 51820
PrivateKey = $vpsPrivate
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

[Peer]
PublicKey = $openwrtPublic
AllowedIPs = 10.0.0.2/32, 192.168.1.0/24
PersistentKeepalive = 25
"@
    
    $vpsConfig | ssh root@$VPS_IP "cat > /etc/wireguard/wg0.conf"
    ssh root@$VPS_IP @"
echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
sysctl -p
systemctl enable wg-quick@wg0
systemctl restart wg-quick@wg0
"@
    
    Write-Host "✓ VPS configured" -ForegroundColor Green
    
    Write-Host "`nStep 5: Configuring OpenWRT..."
    ssh root@$OPENWRT_IP @"
uci set network.wg0=interface
uci set network.wg0.proto='wireguard'
uci set network.wg0.private_key='$openwrtPrivate'
uci set network.wg0.listen_port='51820'
uci add_list network.wg0.addresses='10.0.0.2/24'

uci add network wireguard_wg0
uci set network.@wireguard_wg0[-1].public_key='$vpsPublic'
uci set network.@wireguard_wg0[-1].endpoint_host='$VPS_IP'
uci set network.@wireguard_wg0[-1].endpoint_port='51820'
uci set network.@wireguard_wg0[-1].route_allowed_ips='1'
uci set network.@wireguard_wg0[-1].persistent_keepalive='25'
uci add_list network.@wireguard_wg0[-1].allowed_ips='0.0.0.0/0'

uci set firewall.wg=zone
uci set firewall.wg.name='wg'
uci set firewall.wg.input='ACCEPT'
uci set firewall.wg.output='ACCEPT'
uci set firewall.wg.forward='ACCEPT'
uci set firewall.wg.masq='1'
uci set firewall.wg.network='wg0'

uci add firewall forwarding
uci set firewall.@forwarding[-1].src='lan'
uci set firewall.@forwarding[-1].dest='wg'

uci commit network
uci commit firewall
/etc/init.d/network reload
/etc/init.d/firewall reload
"@
    
    Write-Host "✓ OpenWRT configured" -ForegroundColor Green
    
    Write-Host "`nStep 6: Testing tunnel..."
    Start-Sleep -Seconds 5
    ssh root@$OPENWRT_IP "ping -c 3 10.0.0.1"
    
    Write-Host "`nStep 7: Verifying public IP..."
    $finalIP = ssh root@$OPENWRT_IP "curl -s ifconfig.me"
    Write-Host "Public IP: $finalIP"
    
    if ($finalIP -eq $VPS_IP) {
        Write-Host "`n✓ SUCCESS! All clients now route through VPS" -ForegroundColor Green
    } else {
        Write-Host "`n⚠ Setup complete but routing may need adjustment" -ForegroundColor Yellow
    }
    
    Read-Host "`nPress Enter to continue"
}

function Backup-Config {
    Write-Host "`n=== Backing up OpenWRT Configuration ===" -ForegroundColor Cyan
    $backupFile = "openwrt_backup_$(Get-Date -Format 'yyyyMMdd_HHmmss').tar.gz"
    
    ssh root@$OPENWRT_IP "sysupgrade -b /tmp/backup.tar.gz"
    scp root@${OPENWRT_IP}:/tmp/backup.tar.gz $backupFile
    
    Write-Host "✓ Backup saved: $backupFile" -ForegroundColor Green
    Read-Host "Press Enter to continue"
}

function Test-Connectivity {
    Write-Host "`n=== Testing Connectivity ===" -ForegroundColor Cyan
    
    Write-Host "`n1. OpenWRT to VPS:"
    ssh root@$OPENWRT_IP "ping -c 3 $VPS_IP"
    
    Write-Host "`n2. OpenWRT public IP:"
    $ip = ssh root@$OPENWRT_IP "curl -s ifconfig.me"
    Write-Host "IP: $ip"
    
    if ($ip -eq $VPS_IP) {
        Write-Host "✓ Routing through VPS" -ForegroundColor Green
    } else {
        Write-Host "✗ NOT routing through VPS" -ForegroundColor Red
    }
    
    Write-Host "`n3. WireGuard tunnel status:"
    ssh root@$OPENWRT_IP "wg show"
    
    Read-Host "`nPress Enter to continue"
}

function View-Logs {
    Write-Host "`n=== Recent Logs ===" -ForegroundColor Cyan
    Write-Host "`nOpenWRT logs:"
    ssh root@$OPENWRT_IP "logread | tail -50"
    Read-Host "`nPress Enter to continue"
}

# Main loop
while ($true) {
    $choice = Show-Menu
    
    switch ($choice) {
        "1" { Run-Diagnostics }
        "2" { Quick-Fix }
        "3" { Full-WireGuardSetup }
        "4" { Backup-Config }
        "5" { Test-Connectivity }
        "6" { View-Logs }
        "7" { 
            Write-Host "Goodbye!" -ForegroundColor Cyan
            exit 
        }
        default {
            Write-Host "Invalid option" -ForegroundColor Red
            Start-Sleep -Seconds 2
        }
    }
}
