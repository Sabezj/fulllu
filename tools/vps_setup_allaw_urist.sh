#!/bin/bash
# VPS setup script for allaw-urist.ru
# Run this ONCE on the VPS to prepare the environment
# Root cause: VPS needs Node.js, PM2, Nginx, Certbot, and PostgreSQL

set -e

DOMAIN="allaw-urist.ru"
PROJECT_DIR="/opt/sed-lex-voice"
NODE_VERSION="20"

echo "=== Setting up VPS for $DOMAIN ==="
echo ""

# Update system
echo "Step 1: Updating system packages..."
apt-get update
apt-get upgrade -y

# Install Node.js
echo ""
echo "Step 2: Installing Node.js $NODE_VERSION..."
if ! command -v node &> /dev/null; then
    curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | bash -
    apt-get install -y nodejs
fi
node --version
npm --version

# Install PM2
echo ""
echo "Step 3: Installing PM2..."
if ! command -v pm2 &> /dev/null; then
    npm install -g pm2@latest
    pm2 startup systemd -u root --hp /root
fi
pm2 --version

# Install Nginx
echo ""
echo "Step 4: Installing Nginx..."
if ! command -v nginx &> /dev/null; then
    apt-get install -y nginx
    systemctl enable nginx
    systemctl start nginx
fi
nginx -v

# Install Certbot
echo ""
echo "Step 5: Installing Certbot..."
if ! command -v certbot &> /dev/null; then
    apt-get install -y certbot python3-certbot-nginx
fi
certbot --version

mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh << 'HOOK'
#!/bin/sh
systemctl reload nginx
HOOK
chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh

# Install PostgreSQL
echo ""
echo "Step 6: Installing PostgreSQL..."
if ! command -v psql &> /dev/null; then
    apt-get install -y postgresql postgresql-contrib
    systemctl enable postgresql
    systemctl start postgresql
fi
psql --version

# Install Redis
echo ""
echo "Step 7: Installing Redis..."
if ! command -v redis-cli &> /dev/null; then
    apt-get install -y redis-server
    systemctl enable redis-server
    systemctl start redis-server
fi
redis-cli --version

# Create project directory structure
echo ""
echo "Step 8: Creating project directories..."
mkdir -p $PROJECT_DIR/{releases,backups}
echo "✓ Created $PROJECT_DIR structure"

# Setup PostgreSQL database
echo ""
echo "Step 9: Setting up PostgreSQL database..."
sudo -u postgres psql << EOF
-- Create database if not exists
SELECT 'CREATE DATABASE allaw_urist' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'allaw_urist')\gexec

-- Create user if not exists
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_user WHERE usename = 'allaw_user') THEN
    CREATE USER allaw_user WITH PASSWORD 'change_this_password';
  END IF;
END
\$\$;

-- Grant privileges
GRANT ALL PRIVILEGES ON DATABASE allaw_urist TO allaw_user;

-- Enable pgvector extension
\c allaw_urist
CREATE EXTENSION IF NOT EXISTS vector;
EOF

echo "✓ PostgreSQL database 'allaw_urist' created"
echo "⚠ IMPORTANT: Change the database password!"
echo "  sudo -u postgres psql"
echo "  ALTER USER allaw_user WITH PASSWORD 'your_secure_password';"

# Configure firewall
echo ""
echo "Step 10: Configuring firewall..."
if command -v ufw &> /dev/null; then
    ufw allow 22/tcp
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw --force enable
    echo "✓ Firewall configured"
else
    echo "⚠ UFW not installed, skipping firewall setup"
fi

# Setup log rotation
echo ""
echo "Step 11: Setting up log rotation..."
cat > /etc/logrotate.d/allaw-urist << 'LOGROTATE'
/opt/sed-lex-voice/releases/current/logs/*.log {
    daily
    rotate 14
    compress
    delaycompress
    notifempty
    missingok
    copytruncate
}
LOGROTATE
echo "✓ Log rotation configured"

echo ""
echo "=== VPS Setup Complete ==="
echo ""
echo "Next steps:"
echo "1. Deploy the application using redeploy_allaw_urist.ps1 from your local machine"
echo "2. Configure .env file at $PROJECT_DIR/releases/current/.env"
echo "3. Setup SSL: certbot --nginx -d $DOMAIN -d www.$DOMAIN"
echo "   Verify renewal: certbot renew --dry-run"
echo "4. Update database password in .env"
echo ""
echo "Useful commands:"
echo "  pm2 list                    # List running processes"
echo "  pm2 logs allaw-urist.ru     # View application logs"
echo "  pm2 restart allaw-urist.ru  # Restart application"
echo "  nginx -t                    # Test Nginx config"
echo "  systemctl status nginx      # Check Nginx status"
echo ""
