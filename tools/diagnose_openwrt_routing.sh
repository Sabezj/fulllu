#!/bin/bash
# Diagnostic script for OpenWRT routing issues
# Checks why clients aren't routing through VPN tunnel

OPENWRT_IP="192.168.1.1"
VPS_IP="89.125.92.10"

echo "=== OpenWRT Routing Diagnostics ==="
echo ""

echo "1. Network Interfaces:"
ssh root@$OPENWRT_IP "ip addr show" | grep -E "^[0-9]+:|inet "
echo ""

echo "2. Routing Table:"
ssh root@$OPENWRT_IP "ip route show"
echo ""

echo "3. Active VPN Tunnels:"
ssh root@$OPENWRT_IP "ip link show | grep -E 'tun|wg|vpn'"
echo ""

echo "4. WireGuard Status (if installed):"
ssh root@$OPENWRT_IP "wg show 2>/dev/null || echo 'WireGuard not active'"
echo ""

echo "5. Firewall Zones:"
ssh root@$OPENWRT_IP "uci show firewall | grep -E 'zone|forwarding'"
echo ""

echo "6. NAT Rules:"
ssh root@$OPENWRT_IP "iptables -t nat -L -n -v | head -30"
echo ""

echo "7. Default Gateway:"
ssh root@$OPENWRT_IP "ip route | grep default"
echo ""

echo "8. DNS Configuration:"
ssh root@$OPENWRT_IP "cat /etc/resolv.conf"
echo ""

echo "9. Testing VPS Connectivity:"
ssh root@$OPENWRT_IP "ping -c 3 $VPS_IP"
echo ""

echo "10. Current Public IP (from OpenWRT):"
ssh root@$OPENWRT_IP "curl -s --max-time 5 ifconfig.me || echo 'Failed to get IP'"
echo ""

echo "=== Diagnostic Complete ==="
echo ""
echo "Expected: Public IP should be $VPS_IP"
echo "If different, VPN tunnel is not routing traffic"
