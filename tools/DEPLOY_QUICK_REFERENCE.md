# Quick Reference: allaw-urist.ru Deployment

## Deploy Application
```powershell
# From local Windows machine
cd F:\GitHub\vangZ_strict_patched_plus_voice_assistant
.\tools\redeploy_allaw_urist.ps1
```

## SSH to VPS
```powershell
ssh -i %USERPROFILE%\.ssh\id_rsa_deploy root@89.125.92.10
```

## Common PM2 Commands
```bash
pm2 list                      # List all processes
pm2 logs allaw-urist.ru       # View logs
pm2 restart allaw-urist.ru    # Restart app
pm2 stop allaw-urist.ru       # Stop app
pm2 start allaw-urist.ru      # Start app
pm2 monit                     # Real-time monitoring
pm2 save                      # Save process list
```

## Edit Configuration
```bash
nano /opt/sed-lex-voice/releases/current/.env
pm2 restart allaw-urist.ru    # After changes
```

## Check Status
```bash
# Application
pm2 status
curl https://allaw-urist.ru/api/health
curl https://www.allaw-urist.ru/api/health

# Nginx
systemctl status nginx
nginx -t

# Monitoring
curl -I https://allaw-urist.ru/grafana/
curl -I https://allaw-urist.ru/proteus/

# Database
psql -U allaw_user -d allaw_urist -h localhost -c "SELECT version();"

# Redis
redis-cli ping
```

## View Logs
```bash
# Application
pm2 logs allaw-urist.ru --lines 100
tail -f /opt/sed-lex-voice/releases/current/logs/app.log

# Nginx
tail -f /var/log/nginx/access.log
tail -f /var/log/nginx/error.log

# System
journalctl -u nginx -f
```

## Rollback
```bash
cd /opt/sed-lex-voice/releases
ls -la ../backups/                              # List backups
rm current
ln -s ../backups/backup_YYYYMMDD_HHMMSS current # Replace timestamp
pm2 restart allaw-urist.ru
```

## SSL Certificate
```bash
# Renew certificate
certbot renew
systemctl reload nginx

# Test auto-renewal
certbot renew --dry-run

# Check expiry
certbot certificates
```

## Database Operations
```bash
# Connect to database
psql -U allaw_user -d allaw_urist -h localhost

# Backup
pg_dump -U allaw_user -d allaw_urist -h localhost > backup_$(date +%Y%m%d).sql

# Restore
psql -U allaw_user -d allaw_urist -h localhost < backup_20260513.sql

# Run migration
psql -U allaw_user -d allaw_urist -h localhost -f scripts/migration.sql
```

## Troubleshooting

### App won't start
```bash
pm2 logs allaw-urist.ru --lines 200
pm2 restart allaw-urist.ru
```

### CORS errors
```bash
# Check ALLOWED_ORIGINS in .env
grep ALLOWED_ORIGINS /opt/sed-lex-voice/releases/current/.env
# Should include: https://allaw-urist.ru,https://www.allaw-urist.ru
pm2 restart allaw-urist.ru
```

### 502 Bad Gateway
```bash
# Check if app is running
pm2 list
# Check if listening on port 3000
lsof -i :3000
# Restart
pm2 restart allaw-urist.ru
```

### High memory usage
```bash
pm2 restart allaw-urist.ru
pm2 monit
```

## Maintenance

### Clean old releases (keep last 5)
```bash
cd /opt/sed-lex-voice/releases
ls -t | tail -n +6 | xargs rm -rf
```

### Clean old backups (keep last 10)
```bash
cd /opt/sed-lex-voice/backups
ls -t | tail -n +11 | xargs rm -rf
```

### Update system packages
```bash
apt update
apt upgrade -y
reboot  # If kernel updated
```

## Emergency Contacts

- **VPS IP**: 89.125.92.10
- **Domain**: allaw-urist.ru
- **Project Dir**: /opt/sed-lex-voice
- **SSH Key**: %USERPROFILE%\.ssh\id_rsa_deploy
