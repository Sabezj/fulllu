# Deployment Guide: allaw-urist.ru

Complete guide for deploying the allaw-urist voice agent application to VPS.

## Overview

- **Domain**: allaw-urist.ru
- **VPS IP**: 89.125.92.10
- **VPS User**: root
- **Project Directory**: /opt/sed-lex-voice
- **Dev Root**: F:\GitHub\vangZ_strict_patched_plus_voice_assistant\

## Architecture

```
Local Dev (Windows)          VPS (Linux)
─────────────────────       ─────────────────────
Source files         ──────> /opt/sed-lex-voice/releases/YYYYMMDD_HHMMSS/
                             │
                             ├── Build frontend on VPS (with correct domain)
                             ├── Install dependencies
                             └── Symlink to 'current'
                                  │
                                  ├── PM2 manages Node.js process
                                  ├── Nginx reverse proxy (port 80/443 → 3000)
                                  └── SSL via Let's Encrypt
```

## Prerequisites

### Local Machine (Windows)
- SSH key at `%USERPROFILE%\.ssh\id_rsa_deploy`
- PowerShell with execution policy allowing scripts
- Optional: rsync for faster transfers (via WSL or Git Bash)

### VPS (Linux)
- Ubuntu/Debian-based system
- Root access via SSH
- Node.js 20+, PM2, Nginx, PostgreSQL, Redis, Certbot

## Step 1: VPS Initial Setup (One-Time)

Run this script on the VPS to install all required software:

```bash
# Copy the setup script to VPS
scp -i %USERPROFILE%\.ssh\id_rsa_deploy tools/vps_setup_allaw_urist.sh root@89.125.92.10:/tmp/

# SSH to VPS and run setup
ssh -i %USERPROFILE%\.ssh\id_rsa_deploy root@89.125.92.10
chmod +x /tmp/vps_setup_allaw_urist.sh
/tmp/vps_setup_allaw_urist.sh
```

This installs:
- Node.js 20
- PM2 (process manager)
- Nginx (web server)
- Certbot (SSL certificates)
- PostgreSQL (database)
- Redis (caching)

## Step 2: Configure Database

After VPS setup, configure the PostgreSQL database:

```bash
# SSH to VPS
ssh -i %USERPROFILE%\.ssh\id_rsa_deploy root@89.125.92.10

# Set a secure password for the database user
sudo -u postgres psql
ALTER USER allaw_user WITH PASSWORD 'your_secure_password_here';
\q

# Test connection
psql -U allaw_user -d allaw_urist -h localhost
```

## Step 3: Deploy Application

From your local Windows machine, run the canonical deployment script:

```powershell
cd F:\GitHub\vangZ_strict_patched_plus_voice_assistant
.\tools\redeploy_allaw_urist.ps1
```

### What the deployment script does:

1. **Verifies SSH connection** to VPS
2. **Creates deployment package** from dev root (recursively includes the current app, services, monitoring, tests, docs, and configs)
3. **Backs up current release** on VPS
4. **Creates new release directory** with timestamp
5. **Uploads files** to VPS (via rsync or scp)
6. **Installs dependencies** on VPS (including devDependencies for build)
7. **Builds frontend on VPS** with production domain (avoids CORS issues)
8. **Removes devDependencies** after build
9. **Configures .env** with production settings
10. **Updates symlink** to new release
11. **Configures PM2** to run the application
12. **Sets up Nginx** reverse proxy
13. **Verifies deployment** and shows status

## Step 4: Configure Environment Variables

After first deployment, configure the .env file on VPS:

```bash
ssh -i %USERPROFILE%\.ssh\id_rsa_deploy root@89.125.92.10
nano /opt/sed-lex-voice/releases/current/.env
```

**Required variables:**
```bash
# OpenAI API
OPENAI_API_KEY=sk-proj-...

# Security
ADMIN_API_KEY=generate_random_string_here
ADMIN_SESSION_SECRET=generate_another_random_string_here

# Database (use the password you set in Step 2)
DATABASE_URL=postgres://allaw_user:your_secure_password_here@localhost:5432/allaw_urist

# CORS (already configured by deployment script)
ALLOWED_ORIGINS=https://allaw-urist.ru,https://www.allaw-urist.ru,http://allaw-urist.ru,http://www.allaw-urist.ru

# Production settings (already configured)
NODE_ENV=production
ENABLE_HTTPS=false
SSL_DOMAIN=allaw-urist.ru
```

After editing, restart the application:
```bash
pm2 restart allaw-urist.ru
```

## Step 5: Setup SSL Certificate

Configure HTTPS with Let's Encrypt:

```bash
ssh -i %USERPROFILE%\.ssh\id_rsa_deploy root@89.125.92.10

# Request SSL certificate (interactive)
certbot --nginx -d allaw-urist.ru -d www.allaw-urist.ru

# Certbot will:
# 1. Verify domain ownership
# 2. Issue certificate
# 3. Update Nginx config automatically
# 4. Setup auto-renewal

# Test auto-renewal
certbot renew --dry-run
```

## Step 6: Initialize Database Schema

Run database migrations:

```bash
ssh -i %USERPROFILE%\.ssh\id_rsa_deploy root@89.125.92.10
cd /opt/sed-lex-voice/releases/current

# Run SQL scripts
psql -U allaw_user -d allaw_urist -h localhost -f scripts/create_agent_profiles.sql
psql -U allaw_user -d allaw_urist -h localhost -f scripts/create_orders_table.sql
```

## Step 7: Verify Deployment

### Check application status:
```bash
pm2 list
pm2 logs allaw-urist.ru --lines 50
```

### Check Nginx:
```bash
systemctl status nginx
nginx -t
```

### Test the application:
```bash
# HTTP (should redirect to HTTPS after SSL setup)
curl http://allaw-urist.ru

# HTTPS
curl https://allaw-urist.ru
curl https://www.allaw-urist.ru

# API health check
curl https://allaw-urist.ru/api/health
curl https://www.allaw-urist.ru/api/health

# Monitoring
curl -I https://allaw-urist.ru/grafana/
curl -I https://allaw-urist.ru/proteus/
```

### Check from browser:
- https://allaw-urist.ru
- https://www.allaw-urist.ru
- Open browser console (F12) and check for CORS errors

## Troubleshooting

### CORS Errors
**Symptom**: Browser console shows "blocked by CORS policy"

**Fix**:
1. Check ALLOWED_ORIGINS in .env includes your domain with https://
2. Restart application: `pm2 restart allaw-urist.ru`
3. Clear browser cache

### Application Won't Start
**Check logs**:
```bash
pm2 logs allaw-urist.ru --lines 100
```

**Common issues**:
- Missing environment variables (check .env)
- Database connection failed (check DATABASE_URL)
- Port 3000 already in use (check with `lsof -i :3000`)

### Nginx 502 Bad Gateway
**Cause**: Application not running or not listening on port 3000

**Fix**:
```bash
pm2 restart allaw-urist.ru
pm2 logs allaw-urist.ru
```

### SSL Certificate Issues
**Renew manually**:
```bash
certbot renew
systemctl reload nginx
```

## Rollback Procedure

If deployment fails, rollback to previous version:

```bash
ssh -i %USERPROFILE%\.ssh\id_rsa_deploy root@89.125.92.10
cd /opt/sed-lex-voice/releases

# List available backups
ls -la ../backups/

# Rollback to specific backup
rm current
ln -s ../backups/backup_YYYYMMDD_HHMMSS current

# Restart application
pm2 restart allaw-urist.ru
```

## Monitoring

### PM2 Monitoring
```bash
pm2 monit                    # Real-time monitoring
pm2 logs allaw-urist.ru      # View logs
pm2 restart allaw-urist.ru   # Restart app
pm2 stop allaw-urist.ru      # Stop app
pm2 start allaw-urist.ru     # Start app
```

### System Resources
```bash
htop                         # CPU/Memory usage
df -h                        # Disk usage
free -h                      # Memory usage
```

### Application Logs
```bash
# Application logs
tail -f /opt/sed-lex-voice/releases/current/logs/app.log

# Nginx access logs
tail -f /var/log/nginx/access.log

# Nginx error logs
tail -f /var/log/nginx/error.log
```

## Maintenance

### Update Application
Simply run the deployment script again:
```powershell
.\tools\redeploy_allaw_urist.ps1
```

### Clean Old Releases
Keep only last 5 releases to save disk space:
```bash
cd /opt/sed-lex-voice/releases
ls -t | tail -n +6 | xargs rm -rf
```

### Database Backup
```bash
# Create backup
pg_dump -U allaw_user -d allaw_urist -h localhost > backup_$(date +%Y%m%d).sql

# Restore backup
psql -U allaw_user -d allaw_urist -h localhost < backup_20260513.sql
```

## Security Checklist

- [ ] SSH key authentication enabled (no password login)
- [ ] Firewall configured (UFW: allow 22, 80, 443)
- [ ] SSL certificate installed and auto-renewal working
- [ ] Strong passwords for database and admin accounts
- [ ] ADMIN_API_KEY and ADMIN_SESSION_SECRET are random strings
- [ ] NODE_ENV=production in .env
- [ ] CORS properly configured with ALLOWED_ORIGINS
- [ ] Regular backups scheduled

## Performance Optimization

### Enable Gzip in Nginx
Edit `/etc/nginx/sites-available/allaw-urist.ru`:
```nginx
gzip on;
gzip_types text/plain text/css application/json application/javascript text/xml application/xml;
gzip_min_length 1000;
```

### PM2 Cluster Mode (if needed)
Edit `ecosystem.config.cjs`:
```javascript
instances: 'max',  // Use all CPU cores
exec_mode: 'cluster'
```

### Redis Caching
Already configured in the application. Monitor with:
```bash
redis-cli
> INFO stats
> MONITOR
```

## Support

For issues or questions:
1. Check logs: `pm2 logs allaw-urist.ru`
2. Review this guide
3. Check application documentation in `/docs`
