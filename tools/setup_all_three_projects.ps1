# Мастер-скрипт настройки всех 3 проектов голосового ассистента
# 1. allaw-urist.ru - голосовой консультант по правовым вопросам
# 2. sed-lex-story.ru - генератор правовых квестов
# 3. sed-lex-voice.ru - система приёма заявок при неизвестном потоке

$ErrorActionPreference = "Stop"

# ============================================================================
# КОНФИГУРАЦИЯ
# ============================================================================
$VPS_IP = "89.125.92.10"
$VPS_USER = "root"
$SSH_KEY = "$env:USERPROFILE\.ssh\id_rsa_deploy"

# SSH executable
$SSH_EXE = Join-Path $env:WINDIR "System32\OpenSSH\ssh.exe"
if (!(Test-Path $SSH_EXE)) { $SSH_EXE = "ssh" }

function SSH-Exec {
    param([string]$Command)
    & $SSH_EXE -i $SSH_KEY -o StrictHostKeyChecking=no $VPS_USER@$VPS_IP $Command
}

function Log-Step {
    param([string]$Message, [string]$Color = "Yellow")
    Write-Host "`n$Message" -ForegroundColor $Color
}

function Log-Success {
    param([string]$Message)
    Write-Host "✓ $Message" -ForegroundColor Green
}

function Log-Error {
    param([string]$Message)
    Write-Host "✗ $Message" -ForegroundColor Red
}

# ============================================================================
# ОСНОВНОЙ СКРИПТ
# ============================================================================
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Настройка 3 проектов голосового ассистента" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "1. allaw-urist.ru - голосовой консультант" -ForegroundColor Gray
Write-Host "2. sed-lex-story.ru - генератор правовых квестов" -ForegroundColor Gray
Write-Host "3. sed-lex-voice.ru - система приёма заявок" -ForegroundColor Gray
Write-Host ""

# ----------------------------------------------------------------------------
# ШАГ 1: Проверка сертификатов
# ----------------------------------------------------------------------------
Log-Step "Шаг 1: Проверка SSL сертификатов..."

$domains = @("allaw-urist.ru", "sed-lex-story.ru", "sed-lex-voice.ru")

foreach ($domain in $domains) {
    $certExists = SSH-Exec "test -f /opt/certs/$domain/fullchain.pem && test -f /opt/certs/$domain/privkey.pem && echo 'yes' || echo 'no'"
    
    if ($certExists -eq "yes") {
        Log-Success "$domain - сертификаты найдены"
        
        # Проверяем срок действия
        $certInfo = SSH-Exec "openssl x509 -in /opt/certs/$domain/fullchain.pem -noout -dates 2>/dev/null || echo 'Ошибка чтения'"
        Write-Host "  $certInfo" -ForegroundColor Gray
    } else {
        Log-Error "$domain - сертификаты не найдены"
        Write-Host "  Ожидаемые файлы:" -ForegroundColor Gray
        Write-Host "    /opt/certs/$domain/fullchain.pem" -ForegroundColor Gray
        Write-Host "    /opt/certs/$domain/privkey.pem" -ForegroundColor Gray
    }
}

# ----------------------------------------------------------------------------
# ШАГ 2: Проверка Nginx конфигурации
# ----------------------------------------------------------------------------
Log-Step "Шаг 2: Проверка Nginx конфигурации..."

foreach ($domain in $domains) {
    $configExists = SSH-Exec "test -f /etc/nginx/sites-available/$domain && echo 'yes' || echo 'no'"
    
    if ($configExists -eq "yes") {
        Log-Success "$domain - Nginx конфиг найден"
        
        # Проверяем порт
        $portCheck = SSH-Exec "grep 'proxy_pass' /etc/nginx/sites-available/$domain | head -1"
        Write-Host "  Прокси: $portCheck" -ForegroundColor Gray
        
        # Проверяем SSL
        $sslCheck = SSH-Exec "grep 'ssl_certificate' /etc/nginx/sites-available/$domain | head -1"
        if ($sslCheck) {
            Log-Success "$domain - SSL настроен"
        } else {
            Log-Error "$domain - SSL не настроен"
        }
    } else {
        Log-Error "$domain - Nginx конфиг не найден"
    }
}

# ----------------------------------------------------------------------------
# ШАГ 3: Проверка работы приложений
# ----------------------------------------------------------------------------
Log-Step "Шаг 3: Проверка работы приложений..."

# 1. allaw-urist.ru (уже работает)
Log-Step "1. allaw-urist.ru - голосовой консультант" -Color "Cyan"
$allawStatus = SSH-Exec "pm2 list | grep 'allaw-urist.ru' | grep 'online' && echo 'online' || echo 'offline'"
if ($allawStatus -eq "online") {
    Log-Success "Приложение работает"
    $allawPort = SSH-Exec "netstat -tlnp | grep :3000 && echo 'listening' || echo 'not listening'"
    if ($allawPort -eq "listening") {
        Log-Success "Порт 3000 слушает"
    }
} else {
    Log-Error "Приложение не работает"
}

# 2. sed-lex-story.ru (проверяем Django проект)
Log-Step "2. sed-lex-story.ru - генератор правовых квестов" -Color "Cyan"
$lexquestPath = "/opt/lexquest"

# Проверяем структуру проекта
$backendExists = SSH-Exec "test -d $lexquestPath/backend && echo 'yes' || echo 'no'"
$frontendExists = SSH-Exec "test -d $lexquestPath/frontend && echo 'yes' || echo 'no'"

if ($backendExists -eq "yes") {
    Log-Success "Backend найден"
    
    # Проверяем Django
    $djangoCheck = SSH-Exec "cd $lexquestPath/backend && python -c 'import django; print(django.__version__)' 2>/dev/null || echo 'Django не найден'"
    Write-Host "  Django: $djangoCheck" -ForegroundColor Gray
    
    # Проверяем .env
    $envCheck = SSH-Exec "test -f $lexquestPath/.env && echo 'yes' || echo 'no'"
    if ($envCheck -eq "yes") {
        Log-Success "Конфигурация .env найдена"
    }
} else {
    Log-Error "Backend не найден"
}

if ($frontendExists -eq "yes") {
    Log-Success "Frontend найден"
} else {
    Log-Error "Frontend не найден"
}

# 3. sed-lex-voice.ru (проверяем текущий проект)
Log-Step "3. sed-lex-voice.ru - система приёма заявок" -Color "Cyan"
$sedlexPath = "/opt/sed-lex-voice"

# Проверяем текущий релиз
$currentLink = SSH-Exec "readlink $sedlexPath/current 2>/dev/null || echo 'Нет symlink'"
Write-Host "  Текущий релиз: $currentLink" -ForegroundColor Gray

# Проверяем Node.js проект
$packageExists = SSH-Exec "test -f $sedlexPath/current/package.json && echo 'yes' || echo 'no'"
if ($packageExists -eq "yes") {
    Log-Success "Node.js проект найден"
    
    # Проверяем PM2
    $sedlexStatus = SSH-Exec "pm2 list | grep 'sed-lex-voice' | grep 'online' && echo 'online' || echo 'offline'"
    if ($sedlexStatus -eq "online") {
        Log-Success "Приложение работает в PM2"
    } else {
        Log-Error "Приложение не работает в PM2"
    }
} else {
    Log-Error "Node.js проект не найден"
}

# ----------------------------------------------------------------------------
# ШАГ 4: Создание/обновление Nginx конфигураций
# ----------------------------------------------------------------------------
Log-Step "Шаг 4: Настройка Nginx для всех проектов..."

foreach ($domain in $domains) {
    Log-Step "Настройка $domain..." -Color "Gray"
    
    # Определяем порт для каждого проекта
    $port = switch ($domain) {
        "allaw-urist.ru" { "3000" }
        "sed-lex-story.ru" { "8000" }  # Django обычно на 8000
        "sed-lex-voice.ru" { "3001" }  # Другой порт для второго Node.js
    }
    
    # Создаем Nginx конфиг
    $nginxConfig = @"
# HTTP -> HTTPS редирект
server {
    listen 80;
    server_name $domain www.$domain;
    return 301 https://`$host`$request_uri;
}

# HTTPS сервер
server {
    listen 443 ssl http2;
    server_name $domain www.$domain;

    # SSL сертификаты
    ssl_certificate /opt/certs/$domain/fullchain.pem;
    ssl_certificate_key /opt/certs/$domain/privkey.pem;

    # SSL настройки
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    # Прокси на приложение
    location / {
        proxy_pass http://localhost:$port;
        proxy_http_version 1.1;
        proxy_set_header Upgrade `$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host `$host;
        proxy_cache_bypass `$http_upgrade;
        proxy_set_header X-Real-IP `$remote_addr;
        proxy_set_header X-Forwarded-For `$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto `$scheme;
        
        # Таймауты для голосового ассистента
        proxy_connect_timeout 300s;
        proxy_send_timeout 300s;
        proxy_read_timeout 300s;
    }

    # Статические файлы (для Django)
    location /static/ {
        alias /opt/lexquest/backend/static/;
        expires 1y;
        add_header Cache-Control "public, immutable";
    }

    location /media/ {
        alias /opt/lexquest/backend/media/;
        expires 1y;
        add_header Cache-Control "public, immutable";
    }
}
"@
    
    # Сохраняем конфиг
    $tempFile = [System.IO.Path]::GetTempFileName()
    $nginxConfig | Out-File -FilePath $tempFile -Encoding UTF8
    
    # Загружаем на VPS
    $SCP_EXE = Join-Path $env:WINDIR "System32\OpenSSH\scp.exe"
    if (!(Test-Path $SCP_EXE)) { $SCP_EXE = "scp" }
    
    & $SCP_EXE -i $SSH_KEY $tempFile "${VPS_USER}@${VPS_IP}:/tmp/nginx_$domain"
    Remove-Item $tempFile
    
    # Устанавливаем конфиг
    SSH-Exec "mv /tmp/nginx_$domain /etc/nginx/sites-available/$domain" | Out-Null
    SSH-Exec "ln -sf /etc/nginx/sites-available/$domain /etc/nginx/sites-enabled/$domain" | Out-Null
    
    Log-Success "Nginx конфиг создан для $domain (порт: $port)"
}

# Удаляем дефолтный сайт
SSH-Exec "rm -f /etc/nginx/sites-enabled/default" | Out-Null

# Тестируем и перезагружаем Nginx
Log-Step "Тестирование Nginx конфигурации..."
$nginxTest = SSH-Exec "nginx -t 2>&1"
if ($nginxTest -match "successful") {
    SSH-Exec "systemctl reload nginx" | Out-Null
    Log-Success "Nginx перезагружен"
} else {
    Log-Error "Ошибка теста Nginx"
    Write-Host $nginxTest
}

# ----------------------------------------------------------------------------
# ШАГ 5: Настройка PM2 для всех проектов
# ----------------------------------------------------------------------------
Log-Step "Шаг 5: Настройка PM2 процессов..."

# 1. allaw-urist.ru (уже есть)
Log-Step "1. allaw-urist.ru" -Color "Gray"
$allawRunning = SSH-Exec "pm2 list | grep -q 'allaw-urist.ru' && echo 'yes' || echo 'no'"
if ($allawRunning -eq "no") {
    SSH-Exec "cd /opt/sed-lex-voice/current && pm2 start ecosystem.config.cjs --env production" | Out-Null
    Log-Success "PM2 процесс создан"
} else {
    Log-Success "PM2 процесс уже работает"
}

# 2. sed-lex-voice.ru (создаем если нет)
Log-Step "2. sed-lex-voice.ru" -Color "Gray"
$sedlexRunning = SSH-Exec "pm2 list | grep -q 'sed-lex-voice' && echo 'yes' || echo 'no'"

if ($sedlexRunning -eq "no") {
    # Создаем ecosystem config для sed-lex-voice
    $ecosystemConfig = @"
module.exports = {
  apps: [
    {
      name: 'sed-lex-voice.ru',
      script: './server.js',
      cwd: '/opt/sed-lex-voice/current',
      instances: 1,
      exec_mode: 'fork',
      autorestart: true,
      watch: false,
      max_memory_restart: '768M',
      env: {
        NODE_ENV: 'production',
        PORT: 3001
      }
    }
  ]
};
"@
    
    $tempFile = [System.IO.Path]::GetTempFileName()
    $ecosystemConfig | Out-File -FilePath $tempFile -Encoding UTF8
    & $SCP_EXE -i $SSH_KEY $tempFile "${VPS_USER}@${VPS_IP}:/opt/sed-lex-voice/current/ecosystem_sedlex.cjs"
    Remove-Item $tempFile
    
    SSH-Exec "cd /opt/sed-lex-voice/current && pm2 start ecosystem_sedlex.cjs --env production" | Out-Null
    Log-Success "PM2 процесс создан для sed-lex-voice"
} else {
    Log-Success "PM2 процесс уже работает"
}

# 3. sed-lex-story.ru (Django + Gunicorn)
Log-Step "3. sed-lex-story.ru (Django)" -Color "Gray"
$djangoRunning = SSH-Exec "pm2 list | grep -q 'sed-lex-story' && echo 'yes' || echo 'no'"

if ($djangoRunning -eq "no") {
    # Создаем PM2 конфиг для Django
    $djangoPm2Config = @"
module.exports = {
  apps: [
    {
      name: 'sed-lex-story.ru',
      script: 'gunicorn',
      args: 'lexquest.wsgi:application --bind 0.0.0.0:8000 --workers 3',
      cwd: '/opt/lexquest/backend',
      interpreter: '/opt/lexquest/.venv/bin/python',
      instances: 1,
      exec_mode: 'fork',
      autorestart: true,
      watch: false,
      max_memory_restart: '1G',
      env: {
        DJANGO_SETTINGS_MODULE: 'lexquest.settings.production',
        PYTHONPATH: '/opt/lexquest/backend'
      }
    }
  ]
};
"@
    
    $tempFile = [System.IO.Path]::GetTempFileName()
    $djangoPm2Config | Out-File -FilePath $tempFile -Encoding UTF8
    & $SCP_EXE -i $SSH_KEY $tempFile "${VPS_USER}@${VPS_IP}:/opt/lexquest/backend/ecosystem_django.cjs"
    Remove-Item $tempFile
    
    SSH-Exec "cd /opt/lexquest/backend && pm2 start ecosystem_django.cjs" | Out-Null
    Log-Success "PM2 процесс создан для Django"
} else {
    Log-Success "PM2 процесс уже работает"
}

# Сохраняем PM2 конфигурацию
SSH-Exec "pm2 save" | Out-Null
Log-Success "PM2 конфигурация сохранена"

# ----------------------------------------------------------------------------
# ШАГ 6: Настройка баз данных
# ----------------------------------------------------------------------------
Log-Step "Шаг 6: Настройка баз данных..."

# 1. PostgreSQL для allaw-urist.ru (уже есть)
Log-Step "1. База данных allaw-urist.ru" -Color "Gray"
$dbExists = SSH-Exec "sudo -u postgres psql -tAc `"SELECT 1 FROM pg_database WHERE datname='allaw_urist'`""
if ($dbExists -ne "1") {
    SSH-Exec "sudo -u postgres psql -c `"CREATE DATABASE allaw_urist;`"" | Out-Null
    SSH-Exec "sudo -u postgres psql -c `"CREATE USER allaw_user WITH PASSWORD 'allaw_temp_password_123';`"" | Out-Null
    SSH-Exec "sudo -u postgres psql -c `"GRANT ALL PRIVILEGES ON DATABASE allaw_urist TO allaw_user;`"" | Out-Null
    Log-Success "База данных создана"
} else {
    Log-Success "База данных существует"
}

# 2. SQLite для sed-lex-story.ru (уже есть lexquest.db)
Log-Step "2. База данных sed-lex-story.ru" -Color "Gray"
$sqliteExists = SSH-Exec "test -f /opt/lexquest/lexquest.db && echo 'yes' || echo 'no'"
if ($sqliteExists -eq "yes") {
    Log-Success "SQLite база найдена"
    
    # Проверяем миграции Django
    $migrations = SSH-Exec "cd /opt/lexquest/backend && /opt/lexquest/.venv/bin/python manage.py showmigrations 2>/dev/null | head -5 || echo 'Ошибка миграций'"
    Write-Host "  Миграции: $migrations" -ForegroundColor Gray
} else {
    Log-Error "SQLite база не найдена"
}

# ----------------------------------------------------------------------------
# ШАГ 7: Финальная проверка
# ----------------------------------------------------------------------------
Log-Step "Шаг 7: Финальная проверка..."

Write-Host "`n=== Статус PM2 процессов ===" -ForegroundColor Cyan
SSH-Exec "pm2 list"

Write-Host "`n=== Статус портов ===" -ForegroundColor Cyan
SSH-Exec "netstat -tlnp | grep -E ':3000|:3001|:8000'"

Write-Host "`n=== Проверка доменов ===" -ForegroundColor Cyan
foreach ($domain in $domains) {
    Write-Host "`nПроверка $domain..." -ForegroundColor Yellow
    $curlResult = SSH-Exec "curl -s -o /dev/null -w 'HTTP: %{http_code}, Время: %{time_total}s\n' https://$domain || echo 'Ошибка подключения'"
    Write-Host "  $curlResult" -ForegroundColor Gray
}

# ============================================================================
# ИТОГ
# ============================================================================
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  НАСТРОЙКА ЗАВЕРШЕНА" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Проекты доступны по адресам:" -ForegroundColor Yellow
Write-Host "  1. https://allaw-urist.ru - голосовой консультант" -ForegroundColor Green
Write-Host "  2. https://sed-lex-story.ru - генератор правовых квестов" -ForegroundColor Green
Write-Host "  3. https://sed-lex-voice.ru - система приёма заявок" -ForegroundColor Green
Write-Host ""
Write-Host "Управление:" -ForegroundColor Yellow
Write-Host "  pm2 list                    # Все процессы" -ForegroundColor Gray
Write-Host "  pm2 logs [имя]              # Логи процесса" -ForegroundColor Gray
Write-Host "  systemctl status nginx      # Статус Nginx" -ForegroundColor Gray
Write-Host "  nginx -t                    # Проверка конфига Nginx" -ForegroundColor Gray
Write-Host ""
Write-Host "Следующие шаги:" -ForegroundColor Yellow
Write-Host "  1. Настроить .env файлы для каждого проекта" -ForegroundColor Gray
Write-Host "  2. Запустить миграции Django для sed-lex-story" -ForegroundColor Gray
Write-Host "  3. Настроить фронтенд для sed-lex-story" -ForegroundColor Gray
Write-Host "  4. Обновить пароли БД" -ForegroundColor Gray
Write-Host ""
