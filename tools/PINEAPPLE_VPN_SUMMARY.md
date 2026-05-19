# Pineapple VPN Routing - Complete Solution

## Problem Summary
OpenWrt Pineapple (192.168.1.91) needs to route all Wi-Fi clients (172.16.42.0/24) through VPS tunnel (89.125.92.10) without affecting main Keenetic router.

## Root Causes Found
1. WireGuard data packets not reaching VPS (handshake OK, data failed)
2. Duplicate peer keys between Keenetic and Pineapple causing conflicts
3. Full-tunnel on router itself creates routing loops
4. Possible ISP/DPI blocking WireGuard UDP traffic

## Solution: OpenVPN TCP
Switched from WireGuard UDP to OpenVPN TCP/8443 for reliability through restrictive networks.

## Network Topology
```
Internet
   |
Keenetic (192.168.1.1) --- ISP (95.84.198.112)
   |                        |
   |                     Wireguard1 (separate, not modified)
   |                        |
Pineapple (192.168.1.91)   VPS (89.125.92.10)
   |                        |
   +--- OpenVPN TCP:8443 ---+
   |
Wi-Fi: NZPineAP (172.16.42.0/24)
```

## Configuration Details

### VPS (89.125.92.10)
- OpenVPN server on TCP/8443
- Tunnel IP: 10.9.0.1
- NAT for 10.9.0.0/24
- Firewall allows 8443/tcp

### Pineapple (192.168.1.91)
- OpenVPN client to VPS:8443
- Tunnel IP: 10.9.0.2
- Policy routing: 172.16.42.0/24 → table 200 → tun0
- Router itself uses direct WAN
- IPv6 RA disabled on LAN
- Hardware offload disabled

### Keenetic (192.168.1.1)
- NOT MODIFIED
- Continues using Wireguard1 independently
- Pineapple on "Direct" policy

## Quick Start

### Option 1: Automated (Bash)
```bash
# Setup SSH keys first (one-time)
ssh-copy-id root@192.168.1.91
ssh-copy-id root@89.125.92.10

# Run complete configuration
bash tools/fix_pineapple_routing.sh
```

### Option 2: Manual Steps

#### On VPS:
```bash
ssh root@89.125.92.10

# Install OpenVPN
apt-get update && apt-get install -y openvpn
mkdir -p /etc/openvpn/pineapple
cd /etc/openvpn/pineapple

# Generate key
openvpn --genkey secret static.key

# Create config
cat > server.conf << 'EOF'
dev tun1
ifconfig 10.9.0.1 10.9.0.2
secret static.key
port 8443
proto tcp-server
keepalive 10 60
persist-key
persist-tun
verb 3
EOF

# Start
systemctl enable openvpn@server
systemctl start openvpn@server

# Firewall
iptables -A INPUT -p tcp --dport 8443 -j ACCEPT
iptables -A FORWARD -i tun1 -j ACCEPT
iptables -t nat -A POSTROUTING -s 10.9.0.0/24 -j MASQUERADE
```

#### On Pineapple:
```bash
ssh root@192.168.1.91

# Copy static.key from VPS to /etc/openvpn/static.key

# Install OpenVPN
opkg update
opkg install openvpn-openssl

# Create config
cat > /etc/openvpn/client.conf << 'EOF'
dev tun0
ifconfig 10.9.0.2 10.9.0.1
remote 89.125.92.10 8443
proto tcp-client
secret /etc/openvpn/static.key
keepalive 10 60
persist-key
persist-tun
verb 3
EOF

# Start
/etc/init.d/openvpn enable
/etc/init.d/openvpn start

# Policy routing
echo '200 vpn' >> /etc/iproute2/rt_tables
ip rule add from 172.16.42.0/24 table 200
ip route add default via 10.9.0.1 dev tun0 table 200

# Firewall
iptables -t nat -A POSTROUTING -o tun0 -j MASQUERADE
iptables -A FORWARD -i br-lan -o tun0 -j ACCEPT

# Disable IPv6 RA
uci set network.lan.ipv6='0'
uci set dhcp.lan.ra='disabled'
uci commit
/etc/init.d/network reload
```

## Testing

### From Pineapple itself:
```bash
ssh root@192.168.1.91
wget -qO- http://api.ipify.org
# Should show: 95.84.198.112 (direct WAN)
```

### From Wi-Fi client (NZPineAP):
```bash
# Connect to: NZPineAP
# Password: timeodanaosetdonaferentes

curl ifconfig.me
# Should show: 89.125.92.10 (VPS)
```

## Troubleshooting

### Tunnel not connecting:
```bash
# On Pineapple
logread | grep openvpn
ip addr show tun0

# On VPS
systemctl status openvpn@server
journalctl -u openvpn@server -n 50
```

### Clients not routing through tunnel:
```bash
# On Pineapple
ip rule show
ip route show table 200
iptables -t nat -L POSTROUTING -n -v
```

### DNS not working:
```bash
# On Pineapple
cat /etc/resolv.conf
nslookup google.com 8.8.8.8
```

## Rollback

### Quick rollback:
```bash
ssh root@192.168.1.91
sysupgrade -r /tmp/backup-*.tar.gz
```

### Manual rollback:
```bash
# Stop OpenVPN
/etc/init.d/openvpn stop
/etc/init.d/openvpn disable

# Remove policy routing
ip rule del from 172.16.42.0/24 table 200
ip route flush table 200

# Re-enable WireGuard if needed
uci set network.wgfi.auto='1'
uci commit
ifup wgfi
```

## Files Created
- `tools/fix_pineapple_routing.sh` - Complete automated setup
- `tools/configure_pineapple_vpn.ps1` - PowerShell version
- `tools/setup_ssh_keys.ps1` - SSH key setup helper
- `tools/PINEAPPLE_VPN_SUMMARY.md` - This document

## Credentials Reference
- Pineapple: root@192.168.1.91 / homohominilupusest
- VPS: root@89.125.92.10 / 0Cb8r7Bug5J1AW6pH
- Keenetic: caesar@192.168.1.1:2222 / t0dw9rcN3o@cub
- Terra: root@172.16.42.1 / homohominilupusest
- NZPineAP Wi-Fi: timeodanaosetdonaferentes

## Notes
- Keenetic Wireguard1 remains untouched and functional
- Pineapple uses separate OpenVPN tunnel
- Only 172.16.42.0/24 clients route through VPS
- Pineapple itself uses direct WAN for management
- TCP/8443 chosen for firewall/DPI compatibility
