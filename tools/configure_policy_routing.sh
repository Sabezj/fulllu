#!/bin/sh
# Configure policy routing via UCI (OpenWrt's config system)
# This is the proper way that survives reboots and doesn't break connections

echo "=== Configuring Policy Routing via UCI ==="

# Check if table 200 is defined
grep -q "200 vpn" /etc/iproute2/rt_tables || echo "200 vpn" >> /etc/iproute2/rt_tables

# Configure via UCI network config
uci -q delete network.vpn_route
uci set network.vpn_route=route
uci set network.vpn_route.interface='tun0'
uci set network.vpn_route.target='0.0.0.0'
uci set network.vpn_route.netmask='0.0.0.0'
uci set network.vpn_route.table='200'

# Configure firewall for NAT
uci -q delete firewall.vpn_nat
uci set firewall.vpn_nat=rule
uci set firewall.vpn_nat.name='VPN NAT'
uci set firewall.vpn_nat.src='lan'
uci set firewall.vpn_nat.dest='*'
uci set firewall.vpn_nat.target='ACCEPT'

# Commit changes
uci commit network
uci commit firewall

echo "✓ UCI configuration saved"
echo ""
echo "Applying configuration (this will restart network)..."
echo "Your SSH session may disconnect briefly."
echo ""

# Apply in background to allow SSH to finish
(
  sleep 3
  /etc/init.d/network reload
  sleep 5
  
  # Add NAT rule via nftables
  nft list table inet fw4 2>/dev/null | grep -q 'oifname "tun0"' || {
    nft add rule inet fw4 srcnat oifname "tun0" masquerade 2>/dev/null
  }
  
  # Verify
  ip route show table 200 > /tmp/route_status.txt
  wget -qO- --timeout=10 http://api.ipify.org > /tmp/external_ip.txt 2>&1
  
  echo "Configuration applied. Results in /tmp/external_ip.txt"
) &

echo "Configuration scheduled. Check results in 10 seconds."
