#!/bin/bash
# WireGuard VPN tunnel setup for OpenWRT Pine Terra
# Routes all client traffic through VPS at 89.125.92.10

set -e

VPS_IP="89.125.92.10"
VPS_USER="root"
VPS_PASS="0Cb8r7Bug5J1AW6pH"
OPENWRT_IP="192.168.1.1"

echo "=== WireGuard VPN Tunnel Setup ==="
echo ""

# Install sshpass if not available
if ! command -v sshpass &> /dev/null; then
    echo "Installing sshpass..."
    # For Windows/WSL, you may need to install manually
    echo "Please install sshpass or enter passwords manually"
fi

echo "Step 1: Installing WireGuard on OpenWRT..."
ssh root@$OPENWRT_IP << 'OPENWRT_SETUP'
opkg update
opkg install wireguard-tools luci-proto-wireguard kmod-wireguard

# Generate WireGuard keys for OpenWRT
umask 077
wg genkey | tee /etc/wireguard/privatekey | wg pubkey > /etc/wireguard/publickey

PRIVATE_KEY=$(cat /etc/wireguard/privatekey)
PUBLIC_KEY=$(cat /etc/wireguard/publickey)

echo "OpenWRT WireGuard keys generated:"
echo "Private: $PRIVATE_KEY"
echo "Public: $PUBLIC_KEY"
echo ""
echo "Save these keys!"
OPENWRT_SETUP

echo ""
echo "Step 2: Setting up WireGuard on VPS..."
sshpass -p "$VPS_PASS" ssh root@$VPS_IP << 'VPS_SETUP'
# Install WireGuard on VPS
apt-get update
apt-get install -y wireguard

# Generate VPS keys if not exist
if [ ! -f /etc/wireguard/privatekey ]; then
    umask 077
    wg genkey | tee /etc/wireguard/privatekey | wg pubkey > /etc/wireguard/publickey
fi

VPS_PRIVATE=$(cat /etc/wireguard/privatekey)
VPS_PUBLIC=$(cat /etc/wireguard/publickey)

echo "VPS WireGuard keys:"
echo "Private: $VPS_PRIVATE"
echo "Public: $VPS_PUBLIC"

# Create WireGuard configuration
cat > /etc/wireguard/wg0.conf << 'WGCONF'
[Interface]
Address = 10.0.0.1/24
ListenPort = 51820
PrivateKey = VPS_PRIVATE_KEY_PLACEHOLDER
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

[Peer]
# OpenWRT Pine Terra
PublicKey = OPENWRT_PUBLIC_KEY_PLACEHOLDER
AllowedIPs = 10.0.0.2/32, 192.168.1.0/24
PersistentKeepalive = 25
WGCONF

# Enable IP forwarding
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -p

# Start WireGuard
systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0

echo "✓ VPS WireGuard configured"
VPS_SETUP

echo ""
echo "Step 3: Retrieving keys for cross-configuration..."
OPENWRT_PUBLIC=$(ssh root@$OPENWRT_IP "cat /etc/wireguard/publickey")
VPS_PUBLIC=$(sshpass -p "$VPS_PASS" ssh root@$VPS_IP "cat /etc/wireguard/publickey")
VPS_PRIVATE=$(sshpass -p "$VPS_PASS" ssh root@$VPS_IP "cat /etc/wireguard/privatekey")
OPENWRT_PRIVATE=$(ssh root@$OPENWRT_IP "cat /etc/wireguard/privatekey")

echo "Keys retrieved successfully"

echo ""
echo "Step 4: Configuring OpenWRT WireGuard interface..."
ssh root@$OPENWRT_IP << OPENWRT_CONFIG
# Configure WireGuard interface via UCI
uci set network.wg0=interface
uci set network.wg0.proto='wireguard'
uci set network.wg0.private_key='$OPENWRT_PRIVATE'
uci set network.wg0.listen_port='51820'
uci add_list network.wg0.addresses='10.0.0.2/24'

# Add VPS as peer
uci add network wireguard_wg0
uci set network.@wireguard_wg0[-1].public_key='$VPS_PUBLIC'
uci set network.@wireguard_wg0[-1].endpoint_host='$VPS_IP'
uci set network.@wireguard_wg0[-1].endpoint_port='51820'
uci set network.@wireguard_wg0[-1].route_allowed_ips='1'
uci set network.@wireguard_wg0[-1].persistent_keepalive='25'
uci add_list network.@wireguard_wg0[-1].allowed_ips='0.0.0.0/0'

# Configure firewall
uci set firewall.wg=zone
uci set firewall.wg.name='wg'
uci set firewall.wg.input='ACCEPT'
uci set firewall.wg.output='ACCEPT'
uci set firewall.wg.forward='ACCEPT'
uci set firewall.wg.masq='1'
uci set firewall.wg.network='wg0'

# Allow forwarding from LAN to WG
uci add firewall forwarding
uci set firewall.@forwarding[-1].src='lan'
uci set firewall.@forwarding[-1].dest='wg'

# Commit and reload
uci commit network
uci commit firewall
/etc/init.d/network reload
/etc/init.d/firewall reload

echo "✓ OpenWRT configured"
OPENWRT_CONFIG

echo ""
echo "Step 5: Updating VPS peer configuration..."
sshpass -p "$VPS_PASS" ssh root@$VPS_IP << VPS_UPDATE
sed -i "s/VPS_PRIVATE_KEY_PLACEHOLDER/$VPS_PRIVATE/g" /etc/wireguard/wg0.conf
sed -i "s/OPENWRT_PUBLIC_KEY_PLACEHOLDER/$OPENWRT_PUBLIC/g" /etc/wireguard/wg0.conf
wg-quick down wg0 2>/dev/null || true
wg-quick up wg0
VPS_UPDATE

echo ""
echo "Step 6: Testing tunnel connectivity..."
sleep 5
ssh root@$OPENWRT_IP "ping -c 3 10.0.0.1"

echo ""
echo "Step 7: Verifying routing..."
ssh root@$OPENWRT_IP "curl --interface wg0 ifconfig.me"

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Tunnel established:"
echo "  OpenWRT: 10.0.0.2"
echo "  VPS: 10.0.0.1"
echo ""
echo "All LAN clients (192.168.1.0/24) now route through VPS"
echo ""
echo "Test from client: curl ifconfig.me"
echo "Should show: $VPS_IP"
