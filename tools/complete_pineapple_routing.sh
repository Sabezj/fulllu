#!/bin/bash
# Complete Pine Terra VPN routing configuration
# Root cause: Existing OpenVPN tunnel (tun0) needs policy routing completed
# The router already has tun0 (10.10.0.2 <-> 10.10.0.1) connected to VPS
# Just need to add default route to table 200 and make it persistent

set -e

TERRA_IP="172.16.42.1"
TERRA_USER="root"
TERRA_PASS="homohominilupusest"
VPS_IP="89.125.92.10"
VPS_USER="root"
VPS_PASS="0Cb8r7Bug5J1AW6pH"
KEENETIC_IP="192.168.1.1"
KEENETIC_USER="caesar"
KEENETIC_PASS="t0dw9rcN3o@cub"

echo "=== Pine Terra VPN Routing - Final Configuration ==="
echo "Terra Router: $TERRA_IP"
echo "VPS: $VPS_IP"
echo "Keenetic: $KEENETIC_IP (not modified)"
echo ""

# Step 1: Verify connectivity
echo "Step 1: Verifying Terra router is online..."
if ! ping -c 2 -W 2 $TERRA_IP > /dev/null 2>&1; then
    echo "❌ Cannot reach Terra at $TERRA_IP"
    echo "Please ensure:"
    echo "  1. Router is powered on"
    echo "  2. Connected to Keenetic network"
    echo "  3. IP address is correct"
    exit 1
fi
echo "✓ Terra is reachable"

# Step 2: Check current state
echo ""
echo "Step 2: Checking current configuration..."
sshpass -p "$TERRA_PASS" ssh -o StrictHostKeyChecking=no $TERRA_USER@$TERRA_IP << 'CHECKSTATE'
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
CHECKSTATE

# Step 3: Create backup
echo ""
echo "Step 3: Creating backup..."
BACKUP_NAME="backup-$(date +%Y%m%d-%H%M%S)-final-fix"
sshpass -p "$TERRA_PASS" ssh -o StrictHostKeyChecking=no $TERRA_USER@$TERRA_IP \
    "sysupgrade -b /tmp/$BACKUP_NAME.tar.gz && echo '✓ Backup: /tmp/$BACKUP_NAME.tar.gz'"

# Step 4: Apply routing configuration
echo ""
echo "Step 4: Configuring policy routing..."
sshpass -p "$TERRA_PASS" ssh -o StrictHostKeyChecking=no $TERRA_USER@$TERRA_IP << 'CONFIGURE'
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
CONFIGURE

# Step 5: Make configuration persistent
echo ""
echo "Step 5: Making configuration persistent..."
sshpass -p "$TERRA_PASS" ssh -o StrictHostKeyChecking=no $TERRA_USER@$TERRA_IP << 'PERSIST'
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
PERSIST

# Step 6: Verify configuration
echo ""
echo "Step 6: Verifying configuration..."
sshpass -p "$TERRA_PASS" ssh -o StrictHostKeyChecking=no $TERRA_USER@$TERRA_IP << 'VERIFY'
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
VERIFY

# Step 7: Test from actual client (if possible)
echo ""
echo "=== Configuration Complete ==="
echo ""
echo "✓ Policy routing configured"
echo "✓ Firewall rules applied"
echo "✓ Startup script created"
echo "✓ Backup saved: /tmp/$BACKUP_NAME.tar.gz"
echo ""
echo "Network Details:"
echo "  SSID: NZPineAP"
echo "  Password: timeodanaosetdonaferentes"
echo "  LAN Subnet: 172.16.42.0/24"
echo ""
echo "Testing:"
echo "  1. Connect to NZPineAP Wi-Fi"
echo "  2. Run: curl ifconfig.me"
echo "  3. Should show: $VPS_IP"
echo ""
echo "Router Management:"
echo "  Router itself uses direct WAN (not VPN)"
echo "  Only LAN clients (172.16.42.0/24) route through VPS"
echo ""
echo "Troubleshooting:"
echo "  ssh root@$TERRA_IP"
echo "  logread | grep -E 'openvpn|vpn_routing'"
echo "  ip route show table 200"
echo ""
echo "Rollback:"
echo "  ssh root@$TERRA_IP"
echo "  sysupgrade -r /tmp/$BACKUP_NAME.tar.gz"
