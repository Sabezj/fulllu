#!/bin/bash
# Setup WireGuard on VPS for Keenetic router connection
# Root cause: VPS needs WireGuard server configured to accept Keenetic client

set -e

VPS_IP="89.125.92.10"
VPS_USER="root"
VPS_PASS="0Cb8r7Bug5J1AW6pH"

# Keenetic WireGuard public key (from show interface output)
KEENETIC_PUBLIC_KEY="e6ejlpvpSJxWv/EPFo0dKR3dNl2oZUhpBKjScQJJclg="

echo "=== VPS WireGuard Server Setup ==="
echo "VPS: $VPS_IP"
echo ""

echo "Step 1: Installing WireGuard on VPS..."
sshpass -p "$VPS_PASS" ssh -o StrictHostKeyChecking=no $VPS_USER@$VPS_IP << 'VPS_SETUP'
# Update and install WireGuard
apt-get update
apt-get install -y wireguard wireguard-tools

# Enable IP forwarding
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.conf
sysctl -p

echo "✓ WireGuard installed"
VPS_SETUP

echo ""
echo "Step 2: Generating WireGuard keys on VPS..."
sshpass -p "$VPS_PASS" ssh $VPS_USER@$VPS_IP << 'VPS_KEYS'
cd /etc/wireguard
if [ ! -f privatekey ]; then
    umask 077
    wg genkey | tee privatekey | wg pubkey > publickey
    echo "✓ Keys generated"
else
    echo "✓ Keys already exist"
fi

echo ""
echo "VPS Public Key:"
cat publickey
echo ""
echo "VPS Private Key:"
cat privatekey
VPS_KEYS

echo ""
echo "Step 3: Retrieving keys..."
VPS_PRIVATE=$(sshpass -p "$VPS_PASS" ssh $VPS_USER@$VPS_IP "cat /etc/wireguard/privatekey")
VPS_PUBLIC=$(sshpass -p "$VPS_PASS" ssh $VPS_USER@$VPS_IP "cat /etc/wireguard/publickey")

echo "VPS Public Key: $VPS_PUBLIC"
echo "Keenetic Public Key: $KEENETIC_PUBLIC_KEY"

echo ""
echo "Step 4: Creating WireGuard configuration..."
sshpass -p "$VPS_PASS" ssh $VPS_USER@$VPS_IP bash << VPSCONFIG
cat > /etc/wireguard/wg0.conf << 'WGCONF'
[Interface]
Address = 10.0.0.1/24
ListenPort = 51820
PrivateKey = $VPS_PRIVATE

# PostUp rules for NAT and forwarding
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT
PostUp = iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostUp = iptables -t nat -A POSTROUTING -o ens3 -j MASQUERADE
PostUp = iptables -t nat -A POSTROUTING -o venet0 -j MASQUERADE

# PostDown rules
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -o ens3 -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -o venet0 -j MASQUERADE

[Peer]
# Keenetic Router
PublicKey = $KEENETIC_PUBLIC_KEY
AllowedIPs = 10.0.0.2/32, 192.168.1.0/24
PersistentKeepalive = 25
WGCONF

echo "✓ Configuration created"
VPSCONFIG

echo ""
echo "Step 5: Starting WireGuard..."
sshpass -p "$VPS_PASS" ssh $VPS_USER@$VPS_IP << 'VPSSTART'
# Stop if running
wg-quick down wg0 2>/dev/null || true

# Start WireGuard
wg-quick up wg0

# Enable on boot
systemctl enable wg-quick@wg0

echo "✓ WireGuard started"
echo ""
echo "WireGuard Status:"
wg show
VPSSTART

echo ""
echo "Step 6: Configuring firewall..."
sshpass -p "$VPS_PASS" ssh $VPS_USER@$VPS_IP << 'VPSFIREWALL'
# Allow WireGuard port
if command -v ufw &> /dev/null; then
    ufw allow 51820/udp
    ufw reload
    echo "✓ UFW configured"
elif command -v firewall-cmd &> /dev/null; then
    firewall-cmd --permanent --add-port=51820/udp
    firewall-cmd --reload
    echo "✓ Firewalld configured"
else
    # Direct iptables
    iptables -A INPUT -p udp --dport 51820 -j ACCEPT
    echo "✓ iptables configured"
fi
VPSFIREWALL

echo ""
echo "=== VPS Configuration Complete ==="
echo ""
echo "VPS WireGuard Public Key: $VPS_PUBLIC"
echo "VPS WireGuard IP: 10.0.0.1"
echo "Keenetic should connect to: ${VPS_IP}:51820"
echo ""
echo "Next: Configure Keenetic router with this VPS public key"
echo "Keenetic WireGuard IP should be: 10.0.0.2"
