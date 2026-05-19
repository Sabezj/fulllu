# Execute VPN Routing Fix - Quick Guide

## Problem
Pine Terra router (172.16.42.1) has OpenVPN tunnel to VPS but not routing all LAN clients through it.

## Solution
Complete the policy routing configuration to route all 172.16.42.0/24 clients through VPS tunnel.

## Execute Now

### Option 1: PowerShell (Recommended for Windows)
```powershell
cd F:\GitHub\allow\awllow-uristv\opt\sed-lex-voice
.\tools\complete_pineapple_routing.ps1
```

### Option 2: Bash (if using WSL or Git Bash)
```bash
cd /f/GitHub/allow/awllow-uristv/opt/sed-lex-voice
chmod +x tools/complete_pineapple_routing.sh
./tools/complete_pineapple_routing.sh
```

### Option 3: Manual SSH Commands
If scripts fail, execute manually:

```bash
# Connect to router
ssh root@172.16.42.1
# Password: homohominilupusest

# Verify tun0 is up
ip addr show tun0
# Should show: inet 10.10.0.2 peer 10.10.0.1

# Add routing table name
echo "200 vpn" >> /etc/iproute2/rt_tables

# Add policy routing rule
ip rule add from 172.16.42.0/24 table 200 priority 100

# Add default route to table 200
ip route add default via 10.10.0.1 dev tun0 table 200

# Configure NAT
iptables -t nat -A POSTROUTING -o tun0 -j MASQUERADE
iptables -A FORWARD -i br-lan -o tun0 -j ACCEPT
iptables -A FORWARD -i tun0 -o br-lan -m state --state RELATED,ESTABLISHED -j ACCEPT

# Verify
ip route show table 200
# Should show: default via 10.10.0.1 dev tun0

# Test from LAN perspective
ip route get 8.8.8.8 from 172.16.42.100
# Should route through tun0
```

## What the Fix Does

1. **Verifies** tun0 tunnel is up (10.10.0.2 ↔ 10.10.0.1)
2. **Creates** policy routing table 200
3. **Adds** rule: traffic from 172.16.42.0/24 → table 200
4. **Routes** table 200 default → tun0 → VPS
5. **Configures** NAT for tun0
6. **Makes persistent** via startup script
7. **Creates backup** before changes

## Expected Result

- **Router itself**: Uses direct WAN (not VPN) for management
- **LAN clients** (172.16.42.0/24): Route through VPS tunnel
- **Wi-Fi SSID**: NZPineAP
- **Wi-Fi Password**: timeodanaosetdonaferentes

## Testing

### From Wi-Fi Client:
```bash
# Connect to NZPineAP
curl ifconfig.me
# Should show: 89.125.92.10 (VPS IP)
```

### From Router:
```bash
ssh root@172.16.42.1
wget -qO- http://api.ipify.org
# Should show: ISP IP (not VPS)
```

## Troubleshooting

### If tunnel is down:
```bash
ssh root@172.16.42.1
/etc/init.d/openvpn restart
sleep 5
ip addr show tun0
```

### If clients not routing through VPN:
```bash
ssh root@172.16.42.1
ip rule show | grep 172.16.42
ip route show table 200
iptables -t nat -L POSTROUTING -n -v | grep tun0
```

### Check logs:
```bash
ssh root@172.16.42.1
logread | grep -E 'openvpn|vpn_routing'
```

## Rollback

If something goes wrong:
```bash
ssh root@172.16.42.1
ls -lt /tmp/backup-*.tar.gz | head -1
# Note the backup filename
sysupgrade -r /tmp/backup-YYYYMMDD-HHMMSS-final-fix.tar.gz
```

## Network Topology After Fix

```
Internet
   |
Keenetic (192.168.1.1)
   |
   +-- Pine Terra (172.16.42.1) [Direct WAN for management]
          |
          +-- OpenVPN tun0 (10.10.0.2) ←→ VPS (89.125.92.10)
          |
          +-- Wi-Fi: NZPineAP (172.16.42.0/24)
                 |
                 +-- All clients → table 200 → tun0 → VPS
```

## Credentials Reference

- **Pine Terra**: root@172.16.42.1 / homohominilupusest
- **VPS**: root@89.125.92.10 / 0Cb8r7Bug5J1AW6pH
- **Keenetic**: caesar@192.168.1.1:2222 / t0dw9rcN3o@cub
- **NZPineAP Wi-Fi**: timeodanaosetdonaferentes

## Time Estimate

- Automated script: 2-3 minutes
- Manual execution: 5-10 minutes

## Safety

- Backup created before any changes
- Router management access preserved (direct WAN)
- Only LAN clients affected
- Rollback available if needed
