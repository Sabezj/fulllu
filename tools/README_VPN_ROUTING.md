# OpenWRT VPN Routing Fix Guide

## Problem
OpenWRT Pine Terra router not routing all LAN clients through VPN tunnel to VPS (89.125.92.10).

## Root Cause
Common issues:
1. Missing or incorrect default route through VPN interface
2. Firewall rules blocking VPN traffic
3. NAT not configured for VPN interface
4. VPN tunnel not established or unstable

## Quick Fix (If VPN Already Configured)

```bash
cd tools
chmod +x quick_fix_routing.sh
./quick_fix_routing.sh
```

This will:
- Detect your VPN interface (tun0, wg0, etc.)
- Fix routing table to use VPN as default
- Configure NAT and firewall rules
- Test connectivity

## Full Setup (If Starting Fresh)

### Option 1: WireGuard (Recommended)

```bash
cd tools
chmod +x setup_wireguard_tunnel.sh
./setup_wireguard_tunnel.sh
```

This will:
1. Install WireGuard on both OpenWRT and VPS
2. Generate encryption keys
3. Configure tunnel (10.0.0.1 ↔ 10.0.0.2)
4. Set up routing for all LAN clients
5. Test connectivity

### Option 2: Generic VPN Fix

```bash
cd tools
chmod +x fix_openwrt_vpn_routing.sh
./fix_openwrt_vpn_routing.sh
```

Works with existing OpenVPN, WireGuard, or other VPN setups.

## Diagnostics

```bash
cd tools
chmod +x diagnose_openwrt_routing.sh
./diagnose_openwrt_routing.sh
```

Shows:
- Network interfaces
- Routing table
- Active VPN tunnels
- Firewall configuration
- Current public IP

## Manual Steps (If Scripts Fail)

### 1. SSH into OpenWRT
```bash
ssh root@192.168.1.1
```

### 2. Check VPN Interface
```bash
ip link show | grep -E 'tun|wg|vpn'
# Note the interface name (e.g., wg0)
```

### 3. Set Default Route
```bash
ip route del default
ip route add default dev wg0  # Replace wg0 with your interface
```

### 4. Configure NAT
```bash
iptables -t nat -A POSTROUTING -o wg0 -j MASQUERADE
iptables -A FORWARD -i br-lan -o wg0 -j ACCEPT
```

### 5. Make Persistent
```bash
uci set network.@route[0].interface='wg0'
uci set network.@route[0].target='0.0.0.0'
uci set network.@route[0].netmask='0.0.0.0'
uci commit network
/etc/init.d/network reload
```

### 6. Test
```bash
curl ifconfig.me
# Should show: 89.125.92.10
```

## Verification

From any client device on your LAN:
```bash
curl ifconfig.me
```

Should return: `89.125.92.10` (your VPS IP)

## Troubleshooting

### VPN tunnel not connecting
```bash
# On OpenWRT
wg show  # For WireGuard
# or
systemctl status openvpn  # For OpenVPN

# Check VPS firewall
ssh root@89.125.92.10
ufw status
# Ensure port 51820 (WireGuard) or 1194 (OpenVPN) is open
```

### Clients still using ISP connection
```bash
# Check routing priority
ssh root@192.168.1.1
ip route show
# Default route should point to VPN interface

# Check firewall
iptables -L -n -v | grep FORWARD
```

### DNS not resolving
```bash
# Set DNS through VPN
ssh root@192.168.1.1
uci set network.wg0.dns='8.8.8.8 1.1.1.1'
uci commit network
/etc/init.d/network reload
```

## Configuration Files

- OpenWRT network config: `/etc/config/network`
- OpenWRT firewall config: `/etc/config/firewall`
- WireGuard config: `/etc/wireguard/wg0.conf`
- VPS WireGuard config: `/etc/wireguard/wg0.conf`

## Backup & Restore

### Backup current config
```bash
ssh root@192.168.1.1 'sysupgrade -b /tmp/backup.tar.gz'
scp root@192.168.1.1:/tmp/backup.tar.gz ./openwrt_backup_$(date +%Y%m%d).tar.gz
```

### Restore if needed
```bash
scp openwrt_backup_*.tar.gz root@192.168.1.1:/tmp/
ssh root@192.168.1.1 'sysupgrade -r /tmp/openwrt_backup_*.tar.gz'
```

## Security Notes

⚠️ **Important**: The VPS credentials in these scripts should be:
1. Changed immediately after setup
2. Stored in environment variables or secure vault
3. Never committed to version control

Update credentials:
```bash
# On VPS
passwd root  # Change root password
```

## Support

If issues persist:
1. Run `diagnose_openwrt_routing.sh` and save output
2. Check OpenWRT logs: `ssh root@192.168.1.1 'logread | tail -100'`
3. Check VPS logs: `ssh root@89.125.92.10 'journalctl -xe'`
