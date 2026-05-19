#!/bin/bash
# Quick fix for OpenWRT routing through VPN tunnel
# Root cause: Missing default route or firewall rules blocking VPN traffic

set -e

OPENWRT_IP="192.168.1.1"

echo "=== Quick VPN Routing Fix ==="
echo ""

echo "Detecting VPN interface..."
TUNNEL_IF=$(ssh root@$OPENWRT_IP "ip link show | grep -oE '(tun|wg|vpn)[0-9]+' | head -1")

if [ -z "$TUNNEL_IF" ]; then
    echo "❌ No VPN tunnel interface found!"
    echo "Please run setup_wireguard_tunnel.sh first"
    exit 1
fi

echo "✓ Found tunnel: $TUNNEL_IF"
echo ""

echo "Applying routing fixes..."
ssh root@$OPENWRT_IP << FIXES
# Fix 1: Ensure IP forwarding is enabled
echo 1 > /proc/sys/net/ipv4/ip_forward

# Fix 2: Add default route through VPN
ip route del default 2>/dev/null || true
ip route add default dev $TUNNEL_IF

# Fix 3: Add NAT masquerading for VPN
iptables -t nat -D POSTROUTING -o $TUNNEL_IF -j MASQUERADE 2>/dev/null || true
iptables -t nat -A POSTROUTING -o $TUNNEL_IF -j MASQUERADE

# Fix 4: Allow forwarding from LAN to VPN
iptables -D FORWARD -i br-lan -o $TUNNEL_IF -j ACCEPT 2>/dev/null || true
iptables -A FORWARD -i br-lan -o $TUNNEL_IF -j ACCEPT

# Fix 5: Allow return traffic
iptables -D FORWARD -i $TUNNEL_IF -o br-lan -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
iptables -A FORWARD -i $TUNNEL_IF -o br-lan -m state --state RELATED,ESTABLISHED -j ACCEPT

# Fix 6: Ensure firewall allows VPN zone
uci set firewall.@zone[1].network='wan $TUNNEL_IF' 2>/dev/null || true
uci commit firewall
/etc/init.d/firewall reload

echo "✓ Routing fixes applied"
FIXES

echo ""
echo "Testing connectivity..."
RESULT=$(ssh root@$OPENWRT_IP "curl -s --max-time 10 ifconfig.me")
echo "Current public IP: $RESULT"
echo ""

if [ -n "$RESULT" ]; then
    echo "✓ Routing is working!"
    echo "All clients should now route through VPN"
else
    echo "⚠ Still having issues. Run diagnose_openwrt_routing.sh for details"
fi
