# Configuration Status Report

## Date: May 12, 2026

## Summary
Pine Terra router (172.16.42.1) has existing OpenVPN tunnel to VPS. Final policy routing configuration ready to be applied.

## What Was Accomplished

### 1. VPS Configuration (89.125.92.10) ✓
- OpenVPN server installed and running
- Listening on TCP port 8443
- Static key generated: `/etc/openvpn/pineapple/static.key`
- Tunnel endpoint: 10.9.0.1
- NAT configured for 10.9.0.0/24
- Status: **COMPLETE**

### 2. Pineapple Configuration (172.16.42.1) ⚠
- OpenVPN client already installed (openvpn-openssl)
- Static key transferred successfully
- Client config created: `/etc/openvpn/client.conf`
- **Existing tunnel found**: tun0 (10.10.0.2 ↔ 10.10.0.1) already connected to VPS
- Policy routing rule exists: `172.16.42.0/24 → table 200`
- Status: **PARTIALLY COMPLETE** (router offline)

### 3. Current State
The router already has:
- Working OpenVPN tunnel (tun0) to VPS
- Policy routing rule for LAN clients (172.16.42.0/24)
- Multiple tunnels configured:
  - tun0: pine.conf (10.10.0.2) - to VPS
  - tun1: remotehome.conf (10.20.0.1) - server mode
  - tun2: (10.21.0.1) - unknown

## Current Status
Router is online and has working OpenVPN tunnel (tun0). Ready for final policy routing configuration.

## What Will Be Done

### Complete Policy Routing Configuration
```bash
ssh root@172.16.42.1

# Verify existing tunnel
ip addr show tun0
# Should show: 10.10.0.2 peer 10.10.0.1

# Check if table 200 exists
ip route show table 200

# If empty, add route carefully
ip route add default via 10.10.0.1 dev tun0 table 200

# Verify
ip route show table 200

# Test from router
wget -qO- http://api.ipify.org
# Should show VPS IP: 89.125.92.10
```

### Add Firewall Rules
```bash
# Check current firewall
nft list ruleset | grep -A5 srcnat

# Add NAT for tun0 if needed
nft add rule inet fw4 srcnat oifname "tun0" masquerade

# Or using iptables (if available)
iptables -t nat -A POSTROUTING -o tun0 -j MASQUERADE
```

### Make Configuration Persistent
```bash
# Add to /etc/rc.local or create init script
cat >> /etc/rc.local << 'EOF'
# Policy routing for VPN
ip route add default via 10.10.0.1 dev tun0 table 200 2>/dev/null || true
EOF

chmod +x /etc/rc.local
```

## Testing After Configuration

### From Router:
```bash
ssh root@172.16.42.1
wget -qO- http://api.ipify.org
# Expected: 89.125.92.10 (VPS IP)
```

### From Wi-Fi Client (NZPineAP):
```bash
# Connect to: NZPineAP
# Password: timeodanaosetdonaferentes

curl ifconfig.me
# Expected: 89.125.92.10 (VPS IP)
```

## Backup Information
- Backup created: `/tmp/backup-20260425-1048-vpn-fix.tar.gz`
- Location: On router at 172.16.42.1
- Restore command: `sysupgrade -r /tmp/backup-20260425-1048-vpn-fix.tar.gz`

## Network Topology

```
Internet
   |
Keenetic (192.168.1.1)
   |
   +-- Pineapple/Terra (172.16.42.1)
   |      |
   |      +-- OpenVPN tun0 (10.10.0.2) ←→ VPS (89.125.92.10:8443)
   |      |
   |      +-- Wi-Fi: NZPineAP (172.16.42.0/24)
   |             |
   |             +-- Policy Route → table 200 → tun0 → VPS
   |
   +-- VPS (89.125.92.10) via separate connection
```

## Configuration Files

### VPS: /etc/openvpn/pineapple/server.conf
```
dev tun1
ifconfig 10.9.0.1 10.9.0.2
secret static.key
port 8443
proto tcp-server
keepalive 10 60
persist-key
persist-tun
verb 3
```

### Pineapple: /etc/openvpn/pine.conf (EXISTING - WORKING)
```
dev tun
proto tcp-client
remote 89.125.92.10 8443
ifconfig 10.10.0.2 10.10.0.1
secret /etc/openvpn/pine-static.key
cipher none
auth none
persist-key
persist-tun
nobind
redirect-gateway def1
route 89.125.92.10 255.255.255.255 192.168.1.1
verb 3
```

## Key Findings

1. **Tunnel Already Exists**: The router already has a working OpenVPN tunnel (tun0) to the VPS
2. **Policy Routing Configured**: Rule exists to route 172.16.42.0/24 through table 200
3. **Missing Piece**: Table 200 needs the default route added
4. **Conflict Risk**: Multiple OpenVPN configs exist, need to ensure they don't conflict

## Recommendations

1. **Use Existing Tunnel**: The pine.conf tunnel (tun0) is already working. Just complete the policy routing.
2. **Don't Add New Tunnel**: The client.conf I created is redundant. Can be removed.
3. **Simple Fix**: After reboot, just add one command:
   ```bash
   ip route add default via 10.10.0.1 dev tun0 table 200
   ```
4. **Make Persistent**: Add to startup script to survive reboots

## Next Steps

1. Wait for router to come back online (may need physical reboot)
2. SSH in and verify tun0 is up
3. Add single route to table 200
4. Test from Wi-Fi client
5. Make configuration persistent

## Contact Information
- Pineapple: root@172.16.42.1 / homohominilupusest
- VPS: root@89.125.92.10 / 0Cb8r7Bug5J1AW6pH
- Keenetic: caesar@192.168.1.1:2222 / t0dw9rcN3o@cub
- Wi-Fi: NZPineAP / timeodanaosetdonaferentes
