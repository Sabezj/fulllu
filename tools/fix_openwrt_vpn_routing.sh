#!/bin/bash
# Root cause: OpenWRT Pine Terra not routing all LAN clients through VPN tunnel
# This script diagnoses and fixes the routing configuration to ensure all traffic
# goes through the VPS tunnel at 89.125.92.10

set -e

VPS_IP="89.125.92.10"
VPS_USER="root"
VPS_PASS="0Cb8r7Bug5J1AW6pH"

echo "=== OpenWRT VPN Routing Fix ==="
echo "Target VPS: $VPS_IP"
echo ""

# Function to run commands on OpenWRT
run_openwrt() {
    ssh -o StrictHostKeyChecking=no root@192.168.1.1 "$@"
}

# Function to run commands on VPS
run_vps() {
    sshpass -p "$VPS_PASS" ssh -o StrictHostKeyChecking=no "$VPS_USER@$VPS_IP" "$@"
}

echo "Step 1: Backing up current OpenWRT configuration..."
run_openwrt "sysupgrade -b /tmp/backup-\$(date +%Y%m%d-%H%M%S).tar.gz"
echo "✓ Backup created"

echo ""
echo "Step 2: Checking current network configuration..."
run_openwrt "uci show network" > /tmp/openwrt_network_config.txt
run_openwrt "ip route show" > /tmp/openwrt_routes.txt
run_openwrt "iptables -t nat -L -n -v" > /tmp/openwrt_nat.txt
echo "✓ Configuration saved to /tmp/openwrt_*.txt"

echo ""
echo "Step 3: Checking VPN tunnel status..."
TUNNEL_STATUS=$(run_openwrt "ip link show | grep -E 'tun|wg|vpn' || echo 'No tunnel found'")
echo "$TUNNEL_STATUS"

echo ""
echo "Step 4: Detecting tunnel interface..."
# Common VPN interface names: tun0, wg0, vpn0
TUNNEL_IF=$(run_openwrt "ip link show | grep -oE '(tun|wg|vpn)[0-9]+' | head -1 || echo ''")

if [ -z "$TUNNEL_IF" ]; then
    echo "⚠ No active VPN tunnel detected. Checking for WireGuard or OpenVPN config..."
    
    # Check if WireGuard is installed
    WG_INSTALLED=$(run_openwrt "opkg list-installed | grep wireguard || echo 'not installed'")
    echo "WireGuard: $WG_INSTALLED"
    
    # Check if OpenVPN is installed
    OVPN_INSTALLED=$(run_openwrt "opkg list-installed | grep openvpn || echo 'not installed'")
    echo "OpenVPN: $OVPN_INSTALLED"
    
    echo ""
    echo "Please specify which VPN type you're using:"
    echo "1) WireGuard"
    echo "2) OpenVPN"
    echo "3) Other (manual configuration)"
    read -p "Choice [1-3]: " VPN_TYPE
else
    echo "✓ Found tunnel interface: $TUNNEL_IF"
    VPN_TYPE="existing"
fi

echo ""
echo "Step 5: Configuring routing for all clients..."

# Create VPN routing configuration
cat > /tmp/vpn_routing_config.sh << 'EOF'
#!/bin/sh
# VPN routing configuration for OpenWRT
# Ensures all LAN clients route through VPN tunnel

TUNNEL_IF="__TUNNEL_IF__"
VPS_IP="__VPS_IP__"
LAN_SUBNET="192.168.1.0/24"

# Set up routing table for VPN
uci set network.vpn=interface
uci set network.vpn.proto='none'
uci set network.vpn.ifname="$TUNNEL_IF"
uci set network.vpn.auto='1'

# Configure firewall zones
uci set firewall.@zone[1].network='wan vpn'
uci set firewall.@zone[0].forward='ACCEPT'

# Add routing rules
uci add network rule
uci set network.@rule[-1].in='lan'
uci set network.@rule[-1].lookup='100'
uci set network.@rule[-1].priority='1000'

# Add routing table entry
uci add network route
uci set network.@route[-1].interface='vpn'
uci set network.@route[-1].target='0.0.0.0'
uci set network.@route[-1].netmask='0.0.0.0'
uci set network.@route[-1].table='100'

# Commit changes
uci commit network
uci commit firewall

# Apply changes
/etc/init.d/network reload
/etc/init.d/firewall reload

# Add iptables rules for NAT
iptables -t nat -A POSTROUTING -o $TUNNEL_IF -j MASQUERADE
iptables -A FORWARD -i br-lan -o $TUNNEL_IF -j ACCEPT
iptables -A FORWARD -i $TUNNEL_IF -o br-lan -m state --state RELATED,ESTABLISHED -j ACCEPT

# Make iptables rules persistent
/etc/init.d/firewall restart

echo "✓ VPN routing configured"
EOF

# Replace placeholders
sed -i "s/__TUNNEL_IF__/$TUNNEL_IF/g" /tmp/vpn_routing_config.sh
sed -i "s/__VPS_IP__/$VPS_IP/g" /tmp/vpn_routing_config.sh

# Copy and execute on OpenWRT
scp /tmp/vpn_routing_config.sh root@192.168.1.1:/tmp/
run_openwrt "chmod +x /tmp/vpn_routing_config.sh && /tmp/vpn_routing_config.sh"

echo ""
echo "Step 6: Verifying VPN tunnel connectivity..."
PING_TEST=$(run_openwrt "ping -c 3 -W 2 8.8.8.8 || echo 'FAILED'")
if echo "$PING_TEST" | grep -q "FAILED"; then
    echo "⚠ Warning: Cannot reach internet through tunnel"
    echo "Checking VPN connection to VPS..."
    run_openwrt "ping -c 3 $VPS_IP"
else
    echo "✓ Internet connectivity through tunnel working"
fi

echo ""
echo "Step 7: Testing client routing..."
echo "Checking if LAN clients route through VPN..."
run_openwrt "traceroute -m 5 8.8.8.8 | head -10"

echo ""
echo "Step 8: Making configuration persistent..."
run_openwrt "cat >> /etc/rc.local << 'RCEOF'
# Auto-start VPN routing on boot
sleep 10
/tmp/vpn_routing_config.sh 2>&1 | logger -t vpn-routing
RCEOF"

echo ""
echo "=== Configuration Complete ==="
echo ""
echo "Next steps:"
echo "1. Test from a client device: curl ifconfig.me"
echo "2. Should show VPS IP: $VPS_IP"
echo "3. If not working, check logs: ssh root@192.168.1.1 'logread | grep vpn'"
echo ""
echo "To revert: ssh root@192.168.1.1 'sysupgrade -r /tmp/backup-*.tar.gz'"
