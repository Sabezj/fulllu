# Complete Pine Terra VPN routing configuration
# Root cause: Existing OpenVPN tunnel (tun0) needs policy routing completed
# The router already has tun0 (10.10.0.2 <-> 10.10.0.1) connected to VPS

<# $env:USERPROFILE\x5c.ssh\x5cid_rsa_deploy.pub" }Generating public/private rsa k

ey pair.                            

root password from vps is p77PC6WoW8G5uBqdc3

connection could be establishhed with following ssh key



$env:USERPROFILE\x5c.ssh\x5cid_rsa_deploy.pub" }Generating public/private rsa k

ey pair.                                                                        Your identification has been saved in C:\Users\xsanf\.ssh\id_rsa_deploy

Your public key has been saved in C:\Users\xsanf\.ssh\id_rsa_deploy.pub

The key fingerprint is:

SHA256:fjXBELKgPoxY82yjp2D4OXveiopbtRnZS8JsIMxyDJU kiro-deploy

The key's randomart image is:

+---[RSA 4096]----+

|....  . . o.     |

|ooE  . . o o     |

|oo* .   .   o    |

|.= @ o       .   |

|. . ^ o S   o    |

|.  = O o   . .   |

|o.o + . . .      |

|o+.=..   .       |

|+o*=o..          |

+----[SHA256]-----+

ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDpX/UW+jxrmMLvSTBCeJqA85CsIwT/ifIbVhITsudQ

EqTZCiGlkAClMDVBo/e40H+Tmoq/LOIVHzjV6Ve0qBg0mIyEgkNQc9n/R2wtG3PY6dPWDoQA70u9uOXeswdlPucKNaMro9FJFuzNGX2bncUbPvSdWZi77rY8bIAliI74sMUyMtiaN+Zra6OBrmmvvEYrAHR9dN3nkEu4MYH+mpdHbVNAjQ3qNPo2i9JSpT2Lbt0XYHjjP609bB2CqMx4LNVUJURd5aIqQyl04Dpf9mDsfjDwBi1hLOpOvjJ2rzSXqKicDEJxEuuiQBVTSd+axomw2U5BwRytIaYKz5Ulsi3KLcjsfYCrVkDQq0btynwWBOxWkGdyRoiXc0NBrysdnXJ4ibAkcHGgMoYsiJmWBWQv86lvI9HOpA9GQYHFkT2DGrUD2bwyRXF1OfdaG4NDVc/xsQ1ognGRLAAoKj+deQkYVxNZ2EXIBnomTKqPG73jdKYBaJ/Ai+5/f7vivJw0w5I0P38ePuYTlOSTOtN80HBtQ7IzlF7OxsjcKUQOONHJlcTaDopBWLHP47ywkRSg7sPDx0mgRUjoc1h60THaVdkCeessY7oSqQnRFC6PODOiO73p7oU/XT4AwGuk/483c1nFKuk3I1qCQ1tl7g/QSjiYAmIv8nwS0d9cGEcJL8jdnQ== kiro-deploy 



 #>


$TERRA_IP = "172.16.42.1"
$TERRA_USER = "root"
$TERRA_PASS = "homohominilupusest"
$VPS_IP = "89.125.92.10"

Write-Host "=== Pine Terra VPN Routing - Final Configuration ===" -ForegroundColor Cyan
Write-Host "Terra Router: $TERRA_IP"
Write-Host "VPS: $VPS_IP"
Write-Host ""

# Check if we have SSH available
$sshAvailable = $false
if (Get-Command ssh -ErrorAction SilentlyContinue) {
    $sshAvailable = $true
    Write-Host "✓ Using native SSH" -ForegroundColor Green
} else {
    Write-Host "⚠ SSH not available - will generate manual commands" -ForegroundColor Yellow
}

# Step 1: Verify connectivity
Write-Host ""
Write-Host "Step 1: Verifying Terra router is online..." -ForegroundColor Yellow
if (!(Test-Connection -ComputerName $TERRA_IP -Count 2 -Quiet)) {
    Write-Host "❌ Cannot reach Terra at $TERRA_IP" -ForegroundColor Red
    Write-Host "Please ensure:"
    Write-Host "  1. Router is powered on"
    Write-Host "  2. Connected to Keenetic network"
    Write-Host "  3. IP address is correct"
    exit 1
}
Write-Host "✓ Terra is reachable" -ForegroundColor Green

if (!$sshAvailable) {
    Write-Host ""
    Write-Host "=== Manual Configuration Required ===" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "SSH is not available. Please execute these commands manually:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "1. Open PuTTY or another SSH client" -ForegroundColor Cyan
    Write-Host "2. Connect to: $TERRA_USER@$TERRA_IP" -ForegroundColor Cyan
    Write-Host "3. Password: $TERRA_PASS" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "4. Execute the following commands:" -ForegroundColor Cyan
    Write-Host ""
    
    $manualScript = @'
# Create backup
sysupgrade -b /tmp/backup-$(date +%Y%m%d-%H%M%S)-final-fix.tar.gz

# Ensure routing table exists
grep -q "^200 vpn" /etc/iproute2/rt_tables || echo "200 vpn" >> /etc/iproute2/rt_tables

# Remove existing rules
ip rule del from 172.16.42.0/24 table 200 2>/dev/null || true
ip route flush table 200 2>/dev/null || true

# Wait for tun0
for i in {1..10}; do
    if ip addr show tun0 2>/dev/null | grep -q "inet 10.10.0.2"; then
        echo "✓ tun0 is up"
        break
    fi
    echo "Waiting for tun0... ($i/10)"
    sleep 2
done

# Add policy routing
ip rule add from 172.16.42.0/24 table 200 priority 100
ip route add default via 10.10.0.1 dev tun0 table 200

# Configure NAT
iptables -t nat -D POSTROUTING -o tun0 -j MASQUERADE 2>/dev/null || true
iptables -t nat -A POSTROUTING -o tun0 -j MASQUERADE
iptables -D FORWARD -i br-lan -o tun0 -j ACCEPT 2>/dev/null || true
iptables -A FORWARD -i br-lan -o tun0 -j ACCEPT
iptables -D FORWARD -i tun0 -o br-lan -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
iptables -A FORWARD -i tun0 -o br-lan -m state --state RELATED,ESTABLISHED -j ACCEPT

# Disable IPv6
uci set network.lan.ipv6='0' 2>/dev/null || true
uci set dhcp.lan.ra='disabled' 2>/dev/null || true
uci set dhcp.lan.dhcpv6='disabled' 2>/dev/null || true
uci commit

# Create startup script
cat > /etc/init.d/vpn_routing << 'EOF'
#!/bin/sh /etc/rc.common

START=99
STOP=10

start() {
    sleep 10
    for i in {1..30}; do
        if ip addr show tun0 2>/dev/null | grep -q "inet 10.10.0.2"; then
            break
        fi
        sleep 2
    done
    grep -q "^200 vpn" /etc/iproute2/rt_tables || echo "200 vpn" >> /etc/iproute2/rt_tables
    ip rule del from 172.16.42.0/24 table 200 2>/dev/null || true
    ip rule add from 172.16.42.0/24 table 200 priority 100
    ip route flush table 200 2>/dev/null || true
    ip route add default via 10.10.0.1 dev tun0 table 200
    iptables -t nat -D POSTROUTING -o tun0 -j MASQUERADE 2>/dev/null || true
    iptables -t nat -A POSTROUTING -o tun0 -j MASQUERADE
    iptables -D FORWARD -i br-lan -o tun0 -j ACCEPT 2>/dev/null || true
    iptables -A FORWARD -i br-lan -o tun0 -j ACCEPT
    iptables -D FORWARD -i tun0 -o br-lan -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
    iptables -A FORWARD -i tun0 -o br-lan -m state --state RELATED,ESTABLISHED -j ACCEPT
    logger -t vpn_routing "VPN routing configured"
}

stop() {
    ip rule del from 172.16.42.0/24 table 200 2>/dev/null || true
    ip route flush table 200 2>/dev/null || true
    logger -t vpn_routing "VPN routing removed"
}
EOF

chmod +x /etc/init.d/vpn_routing
/etc/init.d/vpn_routing enable

# Verify
echo ""
echo "=== Verification ==="
ip rule show | grep "172.16.42.0/24"
ip route show table 200
iptables -t nat -L POSTROUTING -n -v | grep tun0

echo ""
echo "✓ Configuration complete"
'@
    
    Write-Host $manualScript -ForegroundColor White
    Write-Host ""
    Write-Host "5. After execution, test from a Wi-Fi client:" -ForegroundColor Cyan
    Write-Host "   curl ifconfig.me" -ForegroundColor White
    Write-Host "   Should show: $VPS_IP" -ForegroundColor White
    Write-Host ""
    
    # Save to file for easy copy
    $manualScript | Out-File -FilePath "tools\manual_terra_config.sh" -Encoding UTF8
    Write-Host "✓ Commands saved to: tools\manual_terra_config.sh" -ForegroundColor Green
    Write-Host ""
    exit 0
}

# Step 2: Check current state
Write-Host ""
Write-Host "Step 2: Checking current configuration..." -ForegroundColor Yellow
$checkScript = @'
echo "=== Network Interfaces ==="
ip addr show | grep -E "^[0-9]+:|inet "

echo ""
echo "=== Tunnel Status ==="
if ip addr show tun0 2>/dev/null; then
    echo "✓ tun0 exists"
else
    echo "❌ tun0 not found"
fi

echo ""
echo "=== Current Routes ==="
ip route show

echo ""
echo "=== Policy Routing Rules ==="
ip rule show

echo ""
echo "=== Policy Routing Table 200 ==="
ip route show table 200 || echo "(empty)"

echo ""
echo "=== OpenVPN Status ==="
ps | grep openvpn | grep -v grep || echo "OpenVPN not running"

echo ""
echo "=== Current External IP ==="
wget -qO- --timeout=5 http://api.ipify.org 2>/dev/null || echo "Cannot reach internet"
'@

plink -batch -pw $TERRA_PASS $TERRA_USER@$TERRA_IP $checkScript

# Step 3: Create backup
Write-Host ""
Write-Host "Step 3: Creating backup..." -ForegroundColor Yellow
$BACKUP_NAME = "backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')-final-fix"
plink -batch -pw $TERRA_PASS $TERRA_USER@$TERRA_IP "sysupgrade -b /tmp/$BACKUP_NAME.tar.gz && echo '✓ Backup: /tmp/$BACKUP_NAME.tar.gz'"

# Step 4: Apply routing configuration
Write-Host ""
Write-Host "Step 4: Configuring policy routing..." -ForegroundColor Yellow
$configScript = @'
# Ensure routing table 200 exists
if ! grep -q "^200" /etc/iproute2/rt_tables; then
    echo "200 vpn" >> /etc/iproute2/rt_tables
fi

# Remove any existing rules/routes for table 200
ip rule del from 172.16.42.0/24 table 200 2>/dev/null || true
ip route flush table 200 2>/dev/null || true

# Wait for tun0 to be up
for i in {1..10}; do
    if ip addr show tun0 2>/dev/null | grep -q "inet 10.10.0.2"; then
        echo "✓ tun0 is up with IP 10.10.0.2"
        break
    fi
    echo "Waiting for tun0... ($i/10)"
    sleep 2
done

# Verify tun0 is up
if ! ip addr show tun0 2>/dev/null | grep -q "inet 10.10.0.2"; then
    echo "❌ tun0 is not up. Checking OpenVPN..."
    
    # Check if OpenVPN is running
    if ! ps | grep -v grep | grep -q openvpn; then
        echo "Starting OpenVPN..."
        /etc/init.d/openvpn start
        sleep 5
    fi
    
    # Check again
    if ! ip addr show tun0 2>/dev/null | grep -q "inet 10.10.0.2"; then
        echo "❌ Failed to bring up tun0"
        exit 1
    fi
fi

# Add policy routing rule
echo "Adding policy routing rule..."
ip rule add from 172.16.42.0/24 table 200 priority 100

# Add default route to table 200 (carefully to avoid routing loop)
echo "Adding default route to table 200..."
# First, ensure we have a route to VPS via main table
if ! ip route show | grep -q "89.125.92.10"; then
    # Add route to VPS via Keenetic gateway
    KEENETIC_GW=$(ip route show default | grep -oP 'via \K[0-9.]+' | head -1)
    if [ -n "$KEENETIC_GW" ]; then
        ip route add 89.125.92.10 via $KEENETIC_GW 2>/dev/null || true
    fi
fi

# Now add default route to table 200
ip route add default via 10.10.0.1 dev tun0 table 200

echo "✓ Policy routing configured"

# Configure firewall/NAT
echo "Configuring firewall..."
iptables -t nat -D POSTROUTING -o tun0 -j MASQUERADE 2>/dev/null || true
iptables -t nat -A POSTROUTING -o tun0 -j MASQUERADE

iptables -D FORWARD -i br-lan -o tun0 -j ACCEPT 2>/dev/null || true
iptables -A FORWARD -i br-lan -o tun0 -j ACCEPT

iptables -D FORWARD -i tun0 -o br-lan -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
iptables -A FORWARD -i tun0 -o br-lan -m state --state RELATED,ESTABLISHED -j ACCEPT

echo "✓ Firewall configured"

# Disable IPv6 to prevent leaks
echo "Disabling IPv6..."
uci set network.lan.ipv6='0' 2>/dev/null || true
uci set dhcp.lan.ra='disabled' 2>/dev/null || true
uci set dhcp.lan.dhcpv6='disabled' 2>/dev/null || true
uci commit

echo "✓ IPv6 disabled"
'@

plink -batch -pw $TERRA_PASS $TERRA_USER@$TERRA_IP $configScript

# Step 5: Make configuration persistent
Write-Host ""
Write-Host "Step 5: Making configuration persistent..." -ForegroundColor Yellow
$persistScript = @'
# Create startup script
cat > /etc/init.d/vpn_routing << 'EOF'
#!/bin/sh /etc/rc.common

START=99
STOP=10

start() {
    # Wait for network to be ready
    sleep 10
    
    # Wait for tun0
    for i in {1..30}; do
        if ip addr show tun0 2>/dev/null | grep -q "inet 10.10.0.2"; then
            break
        fi
        sleep 2
    done
    
    # Ensure routing table exists
    grep -q "^200 vpn" /etc/iproute2/rt_tables || echo "200 vpn" >> /etc/iproute2/rt_tables
    
    # Add policy routing
    ip rule del from 172.16.42.0/24 table 200 2>/dev/null || true
    ip rule add from 172.16.42.0/24 table 200 priority 100
    
    # Add default route
    ip route flush table 200 2>/dev/null || true
    ip route add default via 10.10.0.1 dev tun0 table 200
    
    # NAT
    iptables -t nat -D POSTROUTING -o tun0 -j MASQUERADE 2>/dev/null || true
    iptables -t nat -A POSTROUTING -o tun0 -j MASQUERADE
    
    # Forward
    iptables -D FORWARD -i br-lan -o tun0 -j ACCEPT 2>/dev/null || true
    iptables -A FORWARD -i br-lan -o tun0 -j ACCEPT
    iptables -D FORWARD -i tun0 -o br-lan -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
    iptables -A FORWARD -i tun0 -o br-lan -m state --state RELATED,ESTABLISHED -j ACCEPT
    
    logger -t vpn_routing "VPN routing configured"
}

stop() {
    ip rule del from 172.16.42.0/24 table 200 2>/dev/null || true
    ip route flush table 200 2>/dev/null || true
    logger -t vpn_routing "VPN routing removed"
}
EOF

chmod +x /etc/init.d/vpn_routing
/etc/init.d/vpn_routing enable

echo "✓ Startup script created and enabled"
'@

plink -batch -pw $TERRA_PASS $TERRA_USER@$TERRA_IP $persistScript

# Step 6: Verify configuration
Write-Host ""
Write-Host "Step 6: Verifying configuration..." -ForegroundColor Yellow
$verifyScript = @'
echo "=== Policy Routing Rules ==="
ip rule show | grep "172.16.42.0/24"

echo ""
echo "=== Policy Routing Table 200 ==="
ip route show table 200

echo ""
echo "=== NAT Rules ==="
iptables -t nat -L POSTROUTING -n -v | grep tun0

echo ""
echo "=== Router External IP (should be ISP) ==="
wget -qO- --timeout=5 --bind-address=172.16.42.1 http://api.ipify.org 2>/dev/null || echo "Cannot determine"

echo ""
echo "=== Test from LAN perspective (should be VPS) ==="
# Simulate what a LAN client would see
ip route get 8.8.8.8 from 172.16.42.100 | head -1
'@

plink -batch -pw $TERRA_PASS $TERRA_USER@$TERRA_IP $verifyScript

# Summary
Write-Host ""
Write-Host "=== Configuration Complete ===" -ForegroundColor Green
Write-Host ""
Write-Host "✓ Policy routing configured" -ForegroundColor Green
Write-Host "✓ Firewall rules applied" -ForegroundColor Green
Write-Host "✓ Startup script created" -ForegroundColor Green
Write-Host "✓ Backup saved: /tmp/$BACKUP_NAME.tar.gz" -ForegroundColor Green
Write-Host ""
Write-Host "Network Details:"
Write-Host "  SSID: NZPineAP"
Write-Host "  Password: timeodanaosetdonaferentes"
Write-Host "  LAN Subnet: 172.16.42.0/24"
Write-Host ""
Write-Host "Testing:"
Write-Host "  1. Connect to NZPineAP Wi-Fi"
Write-Host "  2. Run: curl ifconfig.me"
Write-Host "  3. Should show: $VPS_IP"
Write-Host ""
Write-Host "Router Management:"
Write-Host "  Router itself uses direct WAN (not VPN)"
Write-Host "  Only LAN clients (172.16.42.0/24) route through VPS"
Write-Host ""
Write-Host "Troubleshooting:"
Write-Host "  plink -pw $TERRA_PASS root@$TERRA_IP 'logread | grep -E \"openvpn|vpn_routing\"'"
Write-Host "  plink -pw $TERRA_PASS root@$TERRA_IP 'ip route show table 200'"
Write-Host ""
Write-Host "Rollback:"
Write-Host "  plink -pw $TERRA_PASS root@$TERRA_IP 'sysupgrade -r /tmp/$BACKUP_NAME.tar.gz'"
