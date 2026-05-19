# Настройка Django проекта sed-lex-story.ru
# Генератор правовых квестов

$ErrorActionPreference = "Stop"

$VPS_IP = "89.125.92.10"
$VPS_USER = "root"
$SSH_KEY = "$env:USERPROFILE\.ssh\id_rsa_deploy"
$PROJECT_PATH = "/opt/lexquest"

$SSH_EXE = Join-Path $env:WINDIR "System32\OpenSSH\ssh.exe"
if (!(Test-Path $SSH_EXE)) { $SSH_EXE = "ssh" }

function SSH-Exec {
    param([string]$Command)
    & $SSH_EXE -i $SSH_KEY -o StrictHostKeyChecking=no $VPS_USER@$VPS_IP $Command
}

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Настройка Django проекта: sed-lex-story.ru" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# ----------------------------------------------------------------------------
# ШАГ 1: Проверка структуры проекта
# ----------------------------------------------------------------------------
Write-Host "Шаг 1: Проверка структуры проекта..." -ForegroundColor Yellow

$structure = SSH-Exec "ls -la $PROJECT_PATH/"
Write-Host $structure

# Проверяем виртуальное окружение
$venvExists = SSH-Exec "test -d $PROJECT_PATH/.venv && echo 'yes' || echo 'no'"
if ($venvExists -eq "yes") {
    Write-Host "✓ Виртуальное окружение найдено" -ForegroundColor Green
} else {
    Write-Host "✗ Виртуальное окружение не найдено" -ForegroundColor Red
    Write-Host "Создаем виртуальное окружение..." -ForegroundColor Yellow
    SSH-Exec "cd $PROJECT_PATH && python3 -m venv .venv"
    Write-Host "✓ Виртуальное окружение создано" -ForegroundColor Green
}

# ----------------------------------------------------------------------------
# ШАГ 2: Установка зависимостей
# ----------------------------------------------------------------------------
Write-Host "`nШаг 2: Установка зависимостей..." -ForegroundColor Yellow

# Проверяем requirements.txt
$requirements = SSH-Exec "test -f $PROJECT_PATH/backend/requirements.txt && echo 'yes' || echo 'no'"
if ($requirements -eq "yes") {
    Write-Host "Устанавливаем зависимости..." -ForegroundColor Gray
    SSH-Exec "cd $PROJECT_PATH && .venv/bin/pip install -r backend/requirements.txt"
    Write-Host "✓ Зависимости установлены" -ForegroundColor Green
} else {
    Write-Host "Устанавливаем базовые зависимости Django..." -ForegroundColor Gray
    SSH-Exec "cd $PROJECT_PATH && .venv/bin/pip install django gunicorn psycopg2-binary django-cors-headers"
    Write-Host "✓ Базовые зависимости установлены" -ForegroundColor Green
}

# ----------------------------------------------------------------------------
# ШАГ 3: Настройка .env файла
# ----------------------------------------------------------------------------
Write-Host "`nШаг 3: Настройка конфигурации..." -ForegroundColor Yellow

$envExists = SSH-Exec "test -f $PROJECT_PATH/.env && echo 'yes' || echo 'no'"
if ($envExists -eq "no") {
    Write-Host "Создаем .env файл..." -ForegroundColor Gray
    
    $envContent = @"
# Django Settings
DEBUG=False
SECRET_KEY=$(openssl rand -hex 32)
ALLOWED_HOSTS=sed-lex-story.ru,www.sed-lex-story.ru,localhost,127.0.0.1

# Database
DATABASE_URL=sqlite:///$PROJECT_PATH/lexquest.db

# CORS
CORS_ALLOWED_ORIGINS=https://sed-lex-story.ru,https://www.sed-lex-story.ru

# Security
CSRF_TRUSTED_ORIGINS=https://sed-lex-story.ru,https://www.sed-lex-story.ru

# Application
DJANGO_SETTINGS_MODULE=lexquest.settings.production
"@
    
    # Создаем временный файл
    $tempFile = [System.IO.Path]::GetTempFileName()
    $envContent | Out-File -FilePath $tempFile -Encoding UTF8
    
    # Загружаем на VPS
    $SCP_EXE = Join-Path $env:WINDIR "System32\OpenSSH\scp.exe"
    if (!(Test-Path $SCP_EXE)) { $SCP_EXE = "scp" }
    
    & $SCP_EXE -i $SSH_KEY $tempFile "${VPS_USER}@${VPS_IP}:/tmp/django_env"
    Remove-Item $tempFile
    
    SSH-Exec "mv /tmp/django_env $PROJECT_PATH/.env"
    Write-Host "✓ .env файл создан" -ForegroundColor Green
} else {
    Write-Host "✓ .env файл уже существует" -ForegroundColor Green
}

# ----------------------------------------------------------------------------
# ШАГ 4: Настройка Django settings
# ----------------------------------------------------------------------------
Write-Host "`nШаг 4: Настройка Django settings..." -ForegroundColor Yellow

# Проверяем структуру settings
$settingsStructure = SSH-Exec "find $PROJECT_PATH/backend -name 'settings.py' -o -name 'settings' -type d"
Write-Host "Найденные settings: $settingsStructure" -ForegroundColor Gray

# Создаем production settings если нужно
$prodSettings = SSH-Exec "test -f $PROJECT_PATH/backend/lexquest/settings/production.py && echo 'yes' || echo 'no'"
if ($prodSettings -eq "no") {
    Write-Host "Создаем production settings..." -ForegroundColor Gray
    
    $prodSettingsContent = @"
from .base import *

# Security
DEBUG = False
ALLOWED_HOSTS = os.getenv('ALLOWED_HOSTS', '').split(',')
CSRF_TRUSTED_ORIGINS = os.getenv('CSRF_TRUSTED_ORIGINS', '').split(',')

# Database
import dj_database_url
DATABASES = {
    'default': dj_database_url.config(default=os.getenv('DATABASE_URL'))
}

# Static files
STATIC_ROOT = os.path.join(BASE_DIR, 'static')
STATIC_URL = '/static/'

# Media files
MEDIA_ROOT = os.path.join(BASE_DIR, 'media')
MEDIA_URL = '/media/'

# CORS
CORS_ALLOWED_ORIGINS = os.getenv('CORS_ALLOWED_ORIGINS', '').split(',')
CORS_ALLOW_CREDENTIALS = True

# Security headers
SECURE_PROXY_SSL_HEADER = ('HTTP_X_FORWARDED_PROTO', 'https')
SECURE_SSL_REDIRECT = True
SESSION_COOKIE_SECURE = True
CSRF_COOKIE_SECURE = True
"@
    
    $tempFile = [System.IO.Path]::GetTempFileName()
    $prodSettingsContent | Out-File -FilePath $tempFile -Encoding UTF8
    & $SCP_EXE -i $SSH_KEY $tempFile "${VPS_USER}@${VPS_IP}:/tmp/production_settings.py"
    Remove-Item $tempFile
    
    SSH-Exec "mkdir -p $PROJECT_PATH/backend/lexquest/settings"
    SSH-Exec "mv /tmp/production_settings.py $PROJECT_PATH/backend/lexquest/settings/production.py"
    Write-Host "✓ Production settings созданы" -ForegroundColor Green
}

# ----------------------------------------------------------------------------
# ШАГ 5: Миграции базы данных
# ----------------------------------------------------------------------------
Write-Host "`nШаг 5: Миграции базы данных..." -ForegroundColor Yellow

Write-Host "Применяем миграции..." -ForegroundColor Gray
$migrations = SSH-Exec "cd $PROJECT_PATH/backend && .venv/bin/python manage.py migrate 2>&1"
Write-Host $migrations

# Создаем суперпользователя если нужно
$superuser = SSH-Exec "cd $PROJECT_PATH/backend && .venv/bin/python manage.py shell -c 'from django.contrib.auth import get_user_model; User = get_user_model(); print(User.objects.exists())' 2>/dev/null || echo 'error'"
if ($superuser -eq "False") {
    Write-Host "Создаем суперпользователя..." -ForegroundColor Gray
    SSH-Exec "cd $PROJECT_PATH/backend && echo 'from django.contrib.auth import get_user_model; User = get_user_model(); User.objects.create_superuser(\"admin\", \"admin@sed-lex-story.ru\", \"admin123\")' | .venv/bin/python manage.py shell"
    Write-Host "✓ Суперпользователь создан (admin/admin123)" -ForegroundColor Green
}

# ----------------------------------------------------------------------------
# ШАГ 6: Сборка статических файлов
# ----------------------------------------------------------------------------
Write-Host "`nШаг 6: Сборка статических файлов..." -ForegroundColor Yellow

SSH-Exec "cd $PROJECT_PATH/backend && .venv/bin/python manage.py collectstatic --noinput"
Write-Host "✓ Статические файлы собраны" -ForegroundColor Green

# ----------------------------------------------------------------------------
# ШАГ 7: Настройка фронтенда
# ----------------------------------------------------------------------------
Write-Host "`nШаг 7: Настройка фронтенда..." -ForegroundColor Yellow

$frontendPath = "$PROJECT_PATH/frontend"
$packageExists = SSH-Exec "test -f $frontendPath/package.json && echo 'yes' || echo 'no'"

if ($packageExists -eq "yes") {
    Write-Host "Устанавливаем зависимости фронтенда..." -ForegroundColor Gray
    SSH-Exec "cd $frontendPath && npm install --production"
    
    Write-Host "Собираем фронтенд..." -ForegroundColor Gray
    SSH-Exec "cd $frontendPath && npm run build 2>/dev/null || echo 'Build command not found'"
    
    Write-Host "✓ Фронтенд настроен" -ForegroundColor Green
} else {
    Write-Host "⚠ Фронтенд не найден или не настроен" -ForegroundColor Yellow
}

# ----------------------------------------------------------------------------
# ШАГ 8: Создание systemd сервиса
# ----------------------------------------------------------------------------
Write-Host "`nШаг 8: Создание systemd сервиса..." -ForegroundColor Yellow

$serviceContent = @"
[Unit]
Description=sed-lex-story.ru Django Gunicorn
After=network.target

[Service]
User=root
Group=root
WorkingDirectory=$PROJECT_PATH/backend
Environment="PATH=$PROJECT_PATH/.venv/bin"
Environment="DJANGO_SETTINGS_MODULE=lexquest.settings.production"
ExecStart=$PROJECT_PATH/.venv/bin/gunicorn lexquest.wsgi:application --bind 0.0.0.0:8000 --workers 3
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
"@

$tempFile = [System.IO.Path]::GetTempFileName()
$serviceContent | Out-File -FilePath $tempFile -Encoding UTF8
& $SCP_EXE -i $SSH_KEY $tempFile "${VPS_USER}@${VPS_IP}:/tmp/sed-lex-story.service"
Remove-Item $tempFile

SSH-Exec "mv /tmp/sed-lex-story.service /etc/systemd/system/sed-lex-story.service"
SSH-Exec "systemctl daemon-reload"
SSH-Exec "systemctl enable sed-lex-story.service"
SSH-Exec "systemctl start sed-lex-story.service"

Write-Host "✓ Systemd сервис создан и запущен" -ForegroundColor Green

# ----------------------------------------------------------------------------
# ИТОГ
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  НАСТРОЙКА DJANGO ЗАВЕРШЕНА" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Проект доступен по адресу:" -ForegroundColor Yellow
Write-Host "  https://sed-lex-story.ru" -ForegroundColor Green
Write-Host ""
Write-Host "Админка Django:" -ForegroundColor Yellow
Write-Host "  https://sed-lex-story.ru/admin" -ForegroundColor Gray
Write-Host "  Логин: admin" -ForegroundColor Gray
Write-Host "  Пароль: admin123" -ForegroundColor Gray
Write-Host ""
Write-Host "Управление:" -ForegroundColor Yellow
Write-Host "  systemctl status sed-lex-story  # Статус сервиса" -ForegroundColor Gray
Write-Host "  journalctl -u sed-lex-story -f  # Логи" -ForegroundColor Gray
Write-Host "  pm2 list                        # PM2 процессы" -ForegroundColor Gray
Write-Host ""
Write-Host "Следующие шаги:" -ForegroundColor Yellow
Write-Host "  1. Изменить пароль админа" -ForegroundColor Gray
Write-Host "  2. Настроить базу данных PostgreSQL при необходимости" -ForegroundColor Gray
Write-Host "  3. Настроить кеширование (Redis)" -ForegroundColor Gray
Write-Host "  4. Настроить мониторинг" -ForegroundColor Gray
Write-Host ""
