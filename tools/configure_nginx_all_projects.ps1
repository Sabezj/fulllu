# Настройка Nginx для всех 3 проектов
# Создаёт единую конфигурацию с SSL и проксированием

$ErrorActionPreference = "Stop"

$VPS_IP = "89.125.92.10"
$VPS_USER = "root"
$SSH_KEY = "$env:USERPROFILE\.ssh\id_rsa_deploy"

$SSH_EXE = Join-Path $env:WINDIR "System32\OpenSSH\ssh.exe"
if (!(Test-Path $SSH_EXE)) { $SSH_EXE = "ssh" }

function SSH-Exec {
    param([string]$Command)
    & $SSH_EXE -i $SSH_KEY -o StrictHostKeyChecking=no $VPS_USER@$VPS_IP $Command
}

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  НАСТРОЙКА NGINX ДЛЯ 3 ПРОЕКТОВ" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# ----------------------------------------------------------------------------
# ШАГ 1: Проверка текущей конфигурации
# ----------------------------------------------------------------------------
Write-Host "Шаг 1: Проверка текущей конфигурации Nginx..." -ForegroundColor Yellow

# Проверяем существующие конфиги
$domains = @("allaw-urist.ru", "sed-lex-story.ru", "sed-lex-voice.ru")

foreach ($domain in $domains) {
    $configExists = SSH-Exec "test -f /etc/nginx/sites-available/$domain && echo 'yes' || echo 'no'"
    if ($configExists -eq "yes") {
        Write-Host "✓ $domain - конфиг найден" -ForegroundColor Green
    } else {
        Write-Host "✗ $domain - конфиг не найден" -ForegroundColor Red
    }
}

# Проверяем сертификаты
Write-Host "`nПроверка SSL сертификатов..." -ForegroundColor Yellow
foreach ($domain in $domains) {
    $certExists = SSH-Exec "test -f /opt/certs/$domain/fullchain.pem && test -f /opt/certs/$domain/privkey.pem && echo 'yes' || echo 'no'"
    if ($certExists -eq "yes") {
        Write-Host "✓ $domain - сертификаты найдены" -ForegroundColor Green
    } else {
        Write-Host "✗ $domain - сертификаты не найдены" -ForegroundColor Red
    }
}

# ----------------------------------------------------------------------------
# ШАГ 2: Создание конфигурации Nginx
# ----------------------------------------------------------------------------
Write-Host "`nШаг 2: Создание конфигурации Nginx..." -ForegroundColor Yellow

# Конфиг для allaw-urist.ru (порт 3000)
$allawConfig = @"
# allaw-urist.ru - голосовой консультант по правовым вопросам
server {
    listen 80;
    server_name allaw-urist.ru www.allaw-urist.ru;
    return 301 https://`$host`$request_uri;
}

server {
    listen 443 ssl http2;
    server_name allaw-urist.ru www.allaw-urist.ru;

    # SSL сертификаты
    ssl_certificate /opt/certs/allaw-urist.ru/fullchain.pem;
    ssl_certificate_key /opt/certs/allaw-urist.ru/privkey.pem;

    # SSL настройки
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-RSA-AES256-GCM-SHA512:DHE-RSA-AES256-GCM-SHA512:ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    # Прокси на Node.js приложение
    location / {
        proxy_pass http://localhost:3000;
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

    # Статические файлы
    location /static/ {
        alias /opt/sed-lex-voice/current/public/;
        expires 1y;
        add_header Cache-Control "public, immutable";
    }

    # Здоровье приложения
    location /health {
        proxy_pass http://localhost:3000/health;
        access_log off;
    }
}
"@

# Конфиг для sed-lex-story.ru (порт 8000 - Django)
$storyConfig = @"
# sed-lex-story.ru - генератор правовых квестов
server {
    listen 80;
    server_name sed-lex-story.ru www.sed-lex-story.ru;
    return 301 https://`$host`$request_uri;
}

server {
    listen 443 ssl http2;
    server_name sed-lex-story.ru www.sed-lex-story.ru;

    # SSL сертификаты
    ssl_certificate /opt/certs/sed-lex-story.ru/fullchain.pem;
    ssl_certificate_key /opt/certs/sed-lex-story.ru/privkey.pem;

    # SSL настройки
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-RSA-AES256-GCM-SHA512:DHE-RSA-AES256-GCM-SHA512:ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    # Прокси на Django приложение
    location / {
        proxy_pass http://localhost:8000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade `$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host `$host;
        proxy_cache_bypass `$http_upgrade;
        proxy_set_header X-Real-IP `$remote_addr;
        proxy_set_header X-Forwarded-For `$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto `$scheme;
        
        # Для WebSocket если нужно
        proxy_set_header X-Forwarded-Host `$server_name;
    }

    # Статические файлы Django
    location /static/ {
        alias /opt/lexquest/backend/static/;
        expires 1y;
        add_header Cache-Control "public, immutable";
        access_log off;
    }

    # Медиа файлы Django
    location /media/ {
        alias /opt/lexquest/backend/media/;
        expires 1y;
        add_header Cache-Control "public, immutable";
        access_log off;
    }

    # Админка Django
    location /admin {
        proxy_pass http://localhost:8000/admin;
    }

    # Здоровье приложения
    location /health {
        proxy_pass http://localhost:8000/health;
        access_log off;
    }
}
"@

# Конфиг для sed-lex-voice.ru (порт 3001)
$voiceConfig = @"
# sed-lex-voice.ru - система приёма заявок при неизвестном потоке
server {
    listen 80;
    server_name sed-lex-voice.ru www.sed-lex-voice.ru;
    return 301 https://`$host`$request_uri;
}

server {
    listen 443 ssl http2;
    server_name sed-lex-voice.ru www.sed-lex-voice.ru;

    # SSL сертификаты
    ssl_certificate /opt/certs/sed-lex-voice.ru/fullchain.pem;
    ssl_certificate_key /opt/certs/sed-lex-voice.ru/privkey.pem;

    # SSL настройки
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-RSA-AES256-GCM-SHA512:DHE-RSA-AES256-GCM-SHA512:ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    # Прокси на Node.js приложение
    location / {
        proxy_pass http://localhost:3001;
        proxy_http_version 1.1;
        proxy_set_header Upgrade `$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host `$host;
        proxy_cache_bypass `$http_upgrade;
        proxy_set_header X-Real-IP `$remote_addr;
        proxy_set_header X-Forwarded-For `$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto `$scheme;
        
        # Таймауты для обработки заявок
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }

    # API для приёма заявок
    location /api/ {
        proxy_pass http://localhost:3001/api/;
        
        # Дополнительные заголовки для API
        add_header Access-Control-Allow-Origin *;
        add_header Access-Control-Allow-Methods 'GET, POST, OPTIONS';
        add_header Access-Control-Allow-Headers 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range';
        
        # Обработка preflight запросов
        if (`$request_method = 'OPTIONS') {
            add_header Access-Control-Allow-Origin *;
            add_header Access-Control-Allow-Methods 'GET, POST, OPTIONS';
            add_header Access-Control-Allow-Headers 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range';
            add_header Access-Control-Max-Age 1728000;
            add_header Content-Type 'text/plain; charset=utf-8';
            add_header Content-Length 0;
            return 204;
        }
    }

    # Здоровье приложения
    location /health {
        proxy_pass http://localhost:3001/health;
        access_log off;
    }
}
"@

# ----------------------------------------------------------------------------
# ШАГ 3: Запись конфигураций на сервер
# ----------------------------------------------------------------------------
Write-Host "`nШаг 3: Запись конфигураций на сервер..." -ForegroundColor Yellow

$SCP_EXE = Join-Path $env:WINDIR "System32\OpenSSH\scp.exe"
if (!(Test-Path $SCP_EXE)) { $SCP_EXE = "scp" }

# Создаем и загружаем конфиги
$configs = @{
    "allaw-urist.ru" = $allawConfig
    "sed-lex-story.ru" = $storyConfig
    "sed-lex-voice.ru" = $voiceConfig
}

foreach ($domain in $configs.Keys) {
    Write-Host "Создаем конфиг для $domain..." -ForegroundColor Gray
    
    $tempFile = [System.IO.Path]::GetTempFileName()
    $configs[$domain] | Out-File -FilePath $tempFile -Encoding UTF8
    
    # Загружаем на сервер
    & $SCP_EXE -i $SSH_KEY $tempFile "${VPS_USER}@${VPS_IP}:/tmp/nginx_$domain"
    Remove-Item $tempFile
    
    # Перемещаем в правильное место
    SSH-Exec "mv /tmp/nginx_$domain /etc/nginx/sites-available/$domain"
    SSH-Exec "ln -sf /etc/nginx/sites-available/$domain /etc/nginx/sites-enabled/$domain"
    
    Write-Host "✓ Конфиг для $domain создан" -ForegroundColor Green
}

# Удаляем дефолтный сайт
SSH-Exec "rm -f /etc/nginx/sites-enabled/default" | Out-Null
Write-Host "✓ Дефолтный сайт удалён" -ForegroundColor Green

# ----------------------------------------------------------------------------
# ШАГ 4: Тестирование и перезагрузка Nginx
# ----------------------------------------------------------------------------
Write-Host "`nШаг 4: Тестирование конфигурации Nginx..." -ForegroundColor Yellow

$nginxTest = SSH-Exec "nginx -t 2>&1"
Write-Host "Результат теста:" -ForegroundColor Gray
Write-Host $nginxTest

if ($nginxTest -match "successful") {
    Write-Host "✓ Конфигурация Nginx корректна" -ForegroundColor Green
    
    # Перезагружаем Nginx
    Write-Host "`nПерезагрузка Nginx..." -ForegroundColor Yellow
    SSH-Exec "systemctl reload nginx"
    Write-Host "✓ Nginx перезагружен" -ForegroundColor Green
} else {
    Write-Host "✗ Ошибка в конфигурации Nginx" -ForegroundColor Red
    exit 1
}

# ----------------------------------------------------------------------------
# ШАГ 5: Проверка доступности
# ----------------------------------------------------------------------------
Write-Host "`nШаг 5: Проверка доступности проектов..." -ForegroundColor Yellow

Start-Sleep -Seconds 3

foreach ($domain in $domains) {
    Write-Host "`nПроверка $domain..." -ForegroundColor Gray
    
    # Проверяем HTTP редирект
    $httpCheck = SSH-Exec "curl -s -o /dev/null -w '%{http_code} %{redirect_url}' http://$domain --max-time 5 || echo 'ERROR'"
    Write-Host "  HTTP: $httpCheck" -ForegroundColor $(if ($httpCheck -match "301") { "Green" } else { "Yellow" })
    
    # Проверяем HTTPS
    $httpsCheck = SSH-Exec "curl -s -o /dev/null -w '%{http_code}' https://$domain --max-time 10 || echo 'ERROR'"
    Write-Host "  HTTPS: $httpsCheck" -ForegroundColor $(if ($httpsCheck -eq "200") { "Green" } elseif ($httpsCheck -eq "502" -or $httpsCheck -eq "503") { "Red" } else { "Yellow" })
    
    # Проверяем SSL сертификат
    $sslCheck = SSH-Exec "openssl s_client -connect $domain:443 -servername $domain < /dev/null 2>/dev/null | openssl x509 -noout -dates 2>/dev/null | head -2 || echo 'SSL ERROR'"
    Write-Host "  SSL: $sslCheck" -ForegroundColor Gray
}

# ----------------------------------------------------------------------------
# ШАГ 6: Проверка портов
# ----------------------------------------------------------------------------
Write-Host "`nШаг 6: Проверка открытых портов..." -ForegroundColor Yellow

$portsCheck = SSH-Exec "netstat -tlnp | grep -E ':3000|:3001|:8000'"
Write-Host "Открытые порты:" -ForegroundColor Gray
Write-Host $portsCheck

# ----------------------------------------------------------------------------
# ИТОГ
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  NGINX НАСТРОЕН ДЛЯ ВСЕХ 3 ПРОЕКТОВ" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Конфигурация создана:" -ForegroundColor Yellow
Write-Host "  /etc/nginx/sites-available/allaw-urist.ru" -ForegroundColor Gray
Write-Host "  /etc/nginx/sites-available/sed-lex-story.ru" -ForegroundColor Gray
Write-Host "  /etc/nginx/sites-available/sed-lex-voice.ru" -ForegroundColor Gray
Write-Host ""
Write-Host "Порты:" -ForegroundColor Yellow
Write-Host "  allaw-urist.ru    → localhost:3000" -ForegroundColor Gray
Write-Host "  sed-lex-story.ru  → localhost:8000" -ForegroundColor Gray
Write-Host "  sed-lex-voice.ru  → localhost:3001" -ForegroundColor Gray
Write-Host ""
Write-Host "Доступны по адресам:" -ForegroundColor Yellow
Write-Host "  https://allaw-urist.ru" -ForegroundColor Green
Write-Host "  https://sed-lex-story.ru" -ForegroundColor Green
Write-Host "  https://sed-lex-voice.ru" -ForegroundColor Green
Write-Host ""
Write-Host "Управление:" -ForegroundColor Yellow
Write-Host "  nginx -t                          # Проверка конфига" -ForegroundColor Gray
Write-Host "  systemctl reload nginx            # Перезагрузка" -ForegroundColor Gray
Write-Host "  systemctl status nginx            # Статус" -ForegroundColor Gray
Write-Host "  tail -f /var/log/nginx/error.log  # Логи ошибок" -ForegroundColor Gray
Write-Host ""
Write-Host "Следующие шаги:" -ForegroundColor Yellow
Write-Host "  1. Убедиться что приложения запущены на правильных портах" -ForegroundColor Gray
Write-Host "  2. Проверить логи приложений если есть ошибки 502" -ForegroundColor Gray
Write-Host "  3. Настроить мониторинг и алерты" -ForegroundColor Gray
Write-Host "  4. Настроить бэкапы конфигов" -ForegroundColor Gray
Write-Host ""
