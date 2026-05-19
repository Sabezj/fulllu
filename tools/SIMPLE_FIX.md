# Simple One-Command Fix

## The Problem
Adding the route directly breaks your SSH connection because you're connected through that same network.

## The Solution
Run this single command that does everything in the background:

```bash
(sleep 2; ip route add default via 10.10.0.1 dev tun0 table 200; ip route show table 200 > /tmp/route.txt; wget -qO /tmp/ip.txt http://api.ipify.org; echo "ip route add default via 10.10.0.1 dev tun0 table 200 2>/dev/null || true" >> /etc/rc.local; chmod +x /etc/rc.local) & echo "Scheduled. Wait 5 seconds then: cat /tmp/ip.txt"
```

## What It Does
1. Waits 2 seconds (lets SSH finish)
2. Adds the route to table 200
3. Saves route status to /tmp/route.txt
4. Tests external IP and saves to /tmp/ip.txt
5. Makes it persistent in /etc/rc.local
6. Runs in background so SSH stays connected

## After Running
Wait 5 seconds, then check:
```bash
cat /tmp/ip.txt
```

Should show: `89.125.92.10`

## Verify It's Working
```bash
# Check the route
ip route show table 200

# Check from router
wget -qO- http://api.ipify.org
```

## Test from Wi-Fi Client
Connect to NZPineAP and run:
```bash
curl ifconfig.me
```

Should show: `89.125.92.10`

## If It Doesn't Work

### Check tunnel status:
```bash
ip addr show tun0
# Should show: 10.10.0.2 peer 10.10.0.1
```

### Check OpenVPN:
```bash
/etc/init.d/openvpn status
logread | grep openvpn | tail -20
```

### Restart OpenVPN if needed:
```bash
/etc/init.d/openvpn restart
sleep 5
ip addr show tun0
```

### Then add route again:
```bash
ip route add default via 10.10.0.1 dev tun0 table 200
```

## Alternative: Use UCI (Proper OpenWrt Way)

If the simple fix doesn't work, use the UCI method:

```bash
# Add to routing table
grep -q "200 vpn" /etc/iproute2/rt_tables || echo "200 vpn" >> /etc/iproute2/rt_tables

# Configure route via UCI
uci set network.vpn_route=route
uci set network.vpn_route.interface='tun0'
uci set network.vpn_route.target='0.0.0.0'
uci set network.vpn_route.netmask='0.0.0.0'
uci set network.vpn_route.table='200'
uci commit network

# Apply (will briefly disconnect)
/etc/init.d/network reload
```

## Rollback If Needed
```bash
sysupgrade -r /tmp/backup-20260425-1048-vpn-fix.tar.gz
```
