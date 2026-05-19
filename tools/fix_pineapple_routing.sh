#!/bin/bash
# Complete Pineapple VPN routing fix
# Root cause: Policy routing + WireGuard conflicts, switching to OpenVPN TCP

set -e

PINEAPPLE="172.16.42.1"
VPS="89.125.92.10"
KEENETIC="192.168.1.1"

echo "=== Pineapple VPN Routing Fix ==="
echo "Pineapple: $PINEAPPLE"
echo "VPS: $VPS"
echo "Keenetic: $KEENETIC (read-only)"
echo ""

# Step 1: Diagnostics
echo "Step 1: Diagnostics..."
echo "Checking Pineapple..."
ssh root@$PINEAPPLE "ip addr show; ip route show; wg show 2>/dev/null || echo 'No WG'"

echo ""
echo "Checking VPS..."
ssh root@$VPS "wg show; iptables -t nat -L POSTROUTING -n | head -10"

# Step 2: Backup
echo ""
echo "Step 2: Creating backup..."
BACKUP="backup-$(date +%Y%m%d-%H%M)-vpn-fix"
ssh root@$PINEAPPLE "sysupgrade -b /tmp/$BACKUP.tar.gz"
echo "✓ Backup: /tmp/$BACKUP.tar.gz"

# Step 3: Install OpenVPN on VPS
echo ""
echo "Step 3: Configuring VPS OpenVPN..."
ssh root@$VPS << 'VPSCONFIG'
apt-get update && apt-get install -y openvpn
mkdir -p /etc/openvpn/pineapple
cd /etc/openvpn/pineapple

# Generate static key
openvpn --genkey secret static.key

# Server config
cat > server.conf << 'EOF'
dev tun1
ifconfig 10.9.0.1 10.9.0.2
secret static.key
port 8443
proto tcp-server
keepalive 10 60
persist-key
persist-tun
comp-lzo
verb 3
EOF

# Enable and start
systemctl enable openvpn@server
systemctl restart openvpn@server

# Firewall
iptables -A INPUT -p tcp --dport 8443 -j ACCEPT
iptables -A FORWARD -i tun1 -j ACCEPT
iptables -t nat -A POSTROUTING -s 10.9.0.0/24 -j MASQUERADE

echo "✓ VPS OpenVPN configured"
VPSCONFIG

# Get static key
echo ""
echo "Retrieving static key..."
ssh root@$VPS "cat /etc/openvpn/pineapple/static.key" > /tmp/openvpn_static.key

# Step 4: Configure Pineapple
echo ""
echo "Step 4: Configuring Pineapple..."
scp /tmp/openvpn_static.key root@$PINEAPPLE:/tmp/

ssh root@$PINEAPPLE << 'PINECONFIG'
# Install OpenVPN
opkg update
opkg install openvpn-openssl

# Disable WireGuard
uci set network.wgfi.auto='0'
uci commit network
ifdown wgfi

# Create OpenVPN config
mkdir -p /etc/openvpn
mv /tmp/openvpn_static.key /etc/openvpn/

cat > /etc/openvpn/client.conf << EOF
dev tun0
ifconfig 10.9.0.2 10.9.0.1
remote 89.125.92.10 8443
proto tcp-client
secret /etc/openvpn/static.key
keepalive 10 60
persist-key
persist-tun
comp-lzo
verb 3
EOF

# Enable OpenVPN
/etc/init.d/openvpn enable
/etc/init.d/openvpn start

# Wait for tunnel
sleep 5

# Policy routing for LAN clients
echo '200 vpn' >> /etc/iproute2/rt_tables 2>/dev/null || true
ip rule del from 172.16.42.0/24 table 200 2>/dev/null || true
ip rule add from 172.16.42.0/24 table 200
ip route flush table 200
ip route add default via 10.9.0.1 dev tun0 table 200

# Firewall for tun0
iptables -t nat -D POSTROUTING -o tun0 -j MASQUERADE 2>/dev/null || true
iptables -t nat -A POSTROUTING -o tun0 -j MASQUERADE
iptables -D FORWARD -i br-lan -o tun0 -j ACCEPT 2>/dev/null || true
iptables -A FORWARD -i br-lan -o tun0 -j ACCEPT

# Disable IPv6 RA
uci set network.lan.ipv6='0'
uci set dhcp.lan.ra='disabled'
uci set dhcp.lan.dhcpv6='disabled'

# Disable hardware offload
uci set network.@device[0].flow_offload='0' 2>/dev/null || true

uci commit
/etc/init.d/network reload

echo "✓ Pineapple configured"
PINECONFIG

# Step 5: Test
echo ""
echo "Step 5: Testing..."
sleep 3

ssh root@$PINEAPPLE << 'TEST'
echo "=== Tunnel Status ==="
ip addr show tun0

echo ""
echo "=== Routes ==="
ip route show table 200

echo ""
echo "=== External IP ==="
wget -qO- http://api.ipify.org
echo ""

echo ""
echo "=== DNS Test ==="
nslookup google.com 8.8.8.8
TEST

echo ""
echo "=== Configuration Complete ==="
echo ""
echo "Network: NZPineAP"
echo "Password: timeodanaosetdonaferentes"
echo "Clients on 172.16.42.0/24 route through $VPS"
echo ""
echo "Test from client:"
echo "  curl ifconfig.me"
echo "  Should show: $VPS"
echo ""
echo "Rollback:"
echo "  ssh root@$PINEAPPLE 'sysupgrade -r /tmp/$BACKUP.tar.gz'"
