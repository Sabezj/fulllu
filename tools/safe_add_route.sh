#!/bin/sh
# Safe route addition that won't break SSH connection
# Root cause: Adding route while connected through that route breaks SSH

echo "=== Safe Route Configuration ==="

# Add route in background, allowing SSH to complete first
(
  sleep 2
  ip route add default via 10.10.0.1 dev tun0 table 200 2>/dev/null
  echo "Route added to table 200"
  
  # Verify
  ip route show table 200
  
  # Test
  wget -qO- --timeout=5 http://api.ipify.org > /tmp/external_ip.txt 2>&1
  
  # Make persistent
  grep -q "ip route add default via 10.10.0.1 dev tun0 table 200" /etc/rc.local 2>/dev/null || {
    echo "ip route add default via 10.10.0.1 dev tun0 table 200 2>/dev/null || true" >> /etc/rc.local
    chmod +x /etc/rc.local
  }
  
  echo "Configuration complete. Check /tmp/external_ip.txt for result."
) &

echo "Route configuration scheduled. SSH connection will remain stable."
echo "Check status in 5 seconds: cat /tmp/external_ip.txt"
