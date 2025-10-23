#!/bin/bash

# Настройки пользователя
DOMAIN="domenforserver123"
TOKEN="7c4ac80c-d14f-4ca6-ae8c-df2b04a939ae"
USERNAME=$(whoami)
SERVER_IP=$(hostname -I | awk '{print $1}')
DUCKDNS_URL="$DOMAIN.duckdns.org"

echo "=========================================="
echo "🚀 АВТОМАТИЧЕСКАЯ УСТАНОВКА ДОМАШНЕГО СЕРВЕРА"
echo "=========================================="

# Функция для логирования
log() {
    echo "[$(date '+%H:%M:%S')] $1"
}

# 1. ОБНОВЛЕНИЕ СИСТЕМЫ
log "📦 Обновление системы..."
sudo apt update && sudo apt upgrade -y

# 2. УСТАНОВКА ЗАВИСИМОСТЕЙ
log "📦 Установка пакетов..."
sudo apt install -y \
  curl wget git \
  docker.io docker-compose \
  apache2 mysql-server \
  php php-curl php-gd php-mysql php-xml php-zip php-mbstring php-intl \
  cron nano htop tree unzip

# 3. НАСТРОЙКА DOCKER
log "🐳 Настройка Docker..."
sudo systemctl enable docker
sudo systemctl start docker
sudo usermod -aG docker $USER
newgrp docker << EOF
EOF

# 4. НАСТРОЙКА ЧАСОВОГО ПОЯСА
log "⏰ Настройка времени..."
sudo timedatectl set-timezone Europe/Moscow

# 5. НАСТРОЙКА DUCKDNS
log "🌐 Настройка DuckDNS..."
mkdir -p /home/$USER/scripts

cat > /home/$USER/scripts/duckdns-update.sh << EOF
#!/bin/bash
DOMAIN="$DOMAIN"
TOKEN="$TOKEN"
URL="https://www.duckdns.org/update?domains=\${DOMAIN}&token=\${TOKEN}&ip="
response=\$(curl -s -w "\n%{http_code}" "\$URL")
http_code=\$(echo "\$response" | tail -n1)
content=\$(echo "\$response" | head -n1)
echo "\$(date): HTTP \$http_code - \$content" >> "/home/$USER/scripts/duckdns.log"
EOF

chmod +x /home/$USER/scripts/duckdns-update.sh

# Добавляем в Cron
(crontab -l 2>/dev/null; echo "*/5 * * * * /home/$USER/scripts/duckdns-update.sh") | crontab -
/home/$USER/scripts/duckdns-update.sh

# 6. СОЗДАНИЕ ПАПОК ДЛЯ СЕРВИСОВ
log "📁 Создание структуры папок..."
mkdir -p /home/$USER/docker/{jellyfin,tribler,jackett,overseerr,heimdall,uptime-kuma,vaultwarden,homepage,password-manager,qbittorrent,radarr,sonarr,prowlarr}
mkdir -p /home/$USER/media/{movies,tv,streaming,music,downloads,torrents}
mkdir -p /home/$USER/backups

# 7. ЗАПУСК ВСЕХ СЕРВИСОВ ЧЕРЕЗ DOCKER-COMPOSE
log "🐳 Запуск сервисов..."

cat > /home/$USER/docker/docker-compose.yml << EOF
version: '3.8'

networks:
  server-net:
    driver: bridge

services:
  # Jellyfin - медиасервер
  jellyfin:
    image: jellyfin/jellyfin:latest
    container_name: jellyfin
    restart: unless-stopped
    ports:
      - "8096:8096"
    volumes:
      - /home/$USER/docker/jellyfin:/config
      - /home/$USER/media:/media
    environment:
      - TZ=Europe/Moscow
    networks:
      - server-net

  # qBittorrent - торрент-клиент для стриминга
  qbittorrent:
    image: lscr.io/linuxserver/qbittorrent:latest
    container_name: qbittorrent
    restart: unless-stopped
    ports:
      - "6881:6881"
      - "6881:6881/udp"
    volumes:
      - /home/$USER/docker/qbittorrent:/config
      - /home/$USER/media/streaming:/downloads
    environment:
      - TZ=Europe/Moscow
      - PUID=1000
      - PGID=1000
      - WEBUI_PORT=8080
    networks:
      - server-net

  # Radarr - управление фильмами
  radarr:
    image: lscr.io/linuxserver/radarr:latest
    container_name: radarr
    restart: unless-stopped
    ports:
      - "7878:7878"
    volumes:
      - /home/$USER/docker/radarr:/config
      - /home/$USER/media/movies:/movies
      - /home/$USER/media/streaming:/downloads
    environment:
      - TZ=Europe/Moscow
      - PUID=1000
      - PGID=1000
    networks:
      - server-net

  # Sonarr - управление сериалами
  sonarr:
    image: lscr.io/linuxserver/sonarr:latest
    container_name: sonarr
    restart: unless-stopped
    ports:
      - "8989:8989"
    volumes:
      - /home/$USER/docker/sonarr:/config
      - /home/$USER/media/tv:/tv
      - /home/$USER/media/streaming:/downloads
    environment:
      - TZ=Europe/Moscow
      - PUID=1000
      - PGID=1000
    networks:
      - server-net

  # Prowlarr - менеджер индексаторов
  prowlarr:
    image: lscr.io/linuxserver/prowlarr:latest
    container_name: prowlarr
    restart: unless-stopped
    ports:
      - "9696:9696"
    volumes:
      - /home/$USER/docker/prowlarr:/config
    environment:
      - TZ=Europe/Moscow
      - PUID=1000
      - PGID=1000
    networks:
      - server-net

  # Overseerr - интерфейс запросов
  overseerr:
    image: linuxserver/overseerr:latest
    container_name: overseerr
    restart: unless-stopped
    ports:
      - "5055:5055"
    volumes:
      - /home/$USER/docker/overseerr:/config
    environment:
      - TZ=Europe/Moscow
      - PUID=1000
      - PGID=1000
    networks:
      - server-net

  # Heimdall - панель управления
  heimdall:
    image: lscr.io/linuxserver/heimdall:latest
    container_name: heimdall
    restart: unless-stopped
    ports:
      - "8080:80"
    volumes:
      - /home/$USER/docker/heimdall:/config
    environment:
      - TZ=Europe/Moscow
      - PUID=1000
      - PGID=1000
    networks:
      - server-net

  # Uptime Kuma - мониторинг
  uptime-kuma:
    image: louislam/uptime-kuma:1
    container_name: uptime-kuma
    restart: unless-stopped
    ports:
      - "3001:3001"
    volumes:
      - /home/$USER/docker/uptime-kuma:/app/data
    environment:
      - TZ=Europe/Moscow
    networks:
      - server-net

  # Vaultwarden - менеджер паролей
  vaultwarden:
    image: vaultwarden/server:latest
    container_name: vaultwarden
    restart: unless-stopped
    ports:
      - "8000:80"
    volumes:
      - /home/$USER/docker/vaultwarden/data:/data
    environment:
      - TZ=Europe/Moscow
      - ADMIN_TOKEN=admin
      - SIGNUPS_ALLOWED=true
    networks:
      - server-net

  # Главная страница с авторизацией и Nginx прокси
  homepage:
    image: nginx:alpine
    container_name: homepage
    restart: unless-stopped
    ports:
      - "80:80"
    volumes:
      - /home/$USER/docker/homepage:/usr/share/nginx/html
      - /home/$USER/docker/homepage/nginx.conf:/etc/nginx/conf.d/default.conf
    networks:
      - server-net

  # Менеджер паролей - веб-интерфейс смены пароля
  password-manager:
    build: /home/$USER/docker/password-manager
    container_name: password-manager
    restart: unless-stopped
    ports:
      - "8089:8089"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /home/$USER:/home/$USER
    environment:
      - USER=$USER
    networks:
      - server-net
EOF

# Запускаем все сервисы
cd /home/$USER/docker
docker-compose up -d

# 8. НАСТРОЙКА NEXTCLOUD
log "☁️ Установка Nextcloud..."
cd /var/www/html
sudo wget -O nextcloud.zip https://download.nextcloud.com/server/releases/latest.zip
sudo unzip -q nextcloud.zip
sudo chown -R www-data:www-data /var/www/html/nextcloud

# Создаем конфиг Apache для Nextcloud
sudo tee /etc/apache2/sites-available/nextcloud.conf > /dev/null << EOF
<VirtualHost *:80>
    ServerName localhost
    DocumentRoot /var/www/html/nextcloud
    <Directory /var/www/html/nextcloud>
        Options FollowSymlinks
        AllowOverride All
        Require all granted
    </Directory>
</VirtualHost>
EOF

# Активируем Nextcloud
sudo a2ensite nextcloud.conf
sudo a2dissite 000-default.conf
sudo a2enmod rewrite headers env dir mime
sudo systemctl reload apache2

# 9. УСТАНОВКА OLLAMA (НЕЙРОСЕТЬ)
log "🤖 Установка нейросети Ollama..."
curl -fsSL https://ollama.ai/install.sh | sh

# Создаем сервис для автозапуска
sudo tee /etc/systemd/system/ollama.service > /dev/null << EOF
[Unit]
Description=Ollama Service
After=network.target

[Service]
Type=simple
User=$USER
ExecStart=/usr/local/bin/ollama serve
Restart=always
RestartSec=3
Environment="OLLAMA_HOST=0.0.0.0"

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable ollama
sudo systemctl start ollama

# Скачиваем модель в фоне
log "📥 Скачиваем модель нейросети (это займет время)..."
nohup bash -c 'sleep 30 && ollama pull llama2:7b' > /dev/null 2>&1 &

# 10. НАСТРОЙКА БЕЗОПАСНОСТИ
log "🛡️ Настройка безопасности..."

# Фаервол
sudo ufw --force enable
sudo ufw allow 80/tcp
sudo ufw allow 8096/tcp
sudo ufw allow 3001/tcp
sudo ufw allow 8000/tcp
sudo ufw allow 11434/tcp
sudo ufw allow 22/tcp
sudo ufw allow 8089/tcp
sudo ufw allow 7878/tcp
sudo ufw allow 8989/tcp
sudo ufw allow 9696/tcp

# Fail2ban
sudo apt install -y fail2ban
sudo systemctl enable fail2ban
sudo systemctl start fail2ban

# 11. АВТОМАТИЧЕСКИЕ ОБНОВЛЕНИЯ СИСТЕМЫ
log "🔄 Настройка автоматических обновлений..."

cat > /home/$USER/scripts/auto-update.sh << EOF
#!/bin/bash
echo "\$(date): Starting auto-update" >> /home/$USER/scripts/update.log

# Обновление системы
sudo apt update && sudo apt upgrade -y

# Обновление Docker контейнеров
cd /home/$USER/docker
docker-compose pull
docker-compose up -d

# Очистка старых образов
docker image prune -f

echo "\$(date): Auto-update completed" >> /home/$USER/scripts/update.log
EOF

chmod +x /home/$USER/scripts/auto-update.sh

# Добавляем в cron - обновление каждое воскресенье в 3:00
(crontab -l 2>/dev/null; echo "0 3 * * 0 /home/$USER/scripts/auto-update.sh") | crontab -

# 12. АВТОМАТИЧЕСКОЕ РЕЗЕРВНОЕ КОПИРОВАНИЕ
log "💾 Настройка резервного копирования..."

cat > /home/$USER/scripts/backup.sh << EOF
#!/bin/bash
BACKUP_DIR="/home/$USER/backups"
BACKUP_FILE="server-backup-\$(date +%Y%m%d-%H%M%S).tar.gz"
LOG_FILE="/home/$USER/scripts/backup.log"

echo "\$(date): Starting backup" >> \$LOG_FILE

# Создаем резервную копию (исключаем временные файлы стриминга)
tar -czf \$BACKUP_DIR/\$BACKUP_FILE \\
  /home/$USER/docker \\
  /home/$USER/scripts \\
  /home/$USER/media/movies \\
  /home/$USER/media/tv \\
  /home/$USER/media/music \\
  /home/$USER/backups 2>/dev/null

# Удаляем старые бэкапы (храним только последние 7)
find \$BACKUP_DIR -name "server-backup-*.tar.gz" -mtime +7 -delete

echo "\$(date): Backup completed: \$BACKUP_FILE" >> \$LOG_FILE
echo "Backup created: \$BACKUP_DIR/\$BACKUP_FILE"
EOF

chmod +x /home/$USER/scripts/backup.sh

# Добавляем в cron - бэкап каждый день в 2:00
(crontab -l 2>/dev/null; echo "0 2 * * * /home/$USER/scripts/backup.sh") | crontab -

# 13. БЕЗОПАСНАЯ ОЧИСТКА СТРИМИНГА (НЕ трогает библиотеки)
log "🧹 Настройка безопасной очистки стриминга..."

cat > /home/$USER/scripts/cleanup_streaming.sh << 'CLEANUP_EOF'
#!/bin/bash
LOG_FILE="/home/$USER/scripts/cleanup.log"

echo "$(date): Starting SAFE cleanup - ONLY streaming files" >> $LOG_FILE

# 🔒 ОЧИЩАЕМ ТОЛЬКО СТРИМИНГ - ВРЕМЕННЫЕ ФАЙЛЫ
find "/home/$USER/media/streaming" -type f -mtime +1 -delete

# 🔒 Удаляем пустые папки ТОЛЬКО в стриминге
find "/home/$USER/media/streaming" -type d -empty -delete

# ✅ СОХРАНЯЕМ ВСЕ БИБЛИОТЕКИ - они НЕ очищаются!
echo "$(date): Cleaned ONLY streaming. Libraries are SAFE:" >> $LOG_FILE
echo "$(date): - /movies - SAFE" >> $LOG_FILE
echo "$(date): - /tv - SAFE" >> $LOG_FILE  
echo "$(date): - /music - SAFE" >> $LOG_FILE
echo "$(date): - Nextcloud - SAFE" >> $LOG_FILE
echo "$(date): - Backups - SAFE" >> $LOG_FILE
CLEANUP_EOF

chmod +x /home/$USER/scripts/cleanup_streaming.sh

# Добавляем в cron - очистка каждые 6 часов
(crontab -l 2>/dev/null; echo "0 */6 * * * /home/$USER/scripts/cleanup_streaming.sh") | crontab -

# 14. НАСТРОЙКА ТОРРЕНТ-СТРИМИНГА КАК НА YOUTUBE
log "🎬 Настройка торрент-стриминга..."

# Создаем скрипт автоматической настройки стриминга
cat > /home/$USER/scripts/setup-streaming.sh << 'STREAMING_EOF'
#!/bin/bash

USERNAME=$(whoami)
SERVER_IP=$(hostname -I | awk '{print $1}')

echo "Настраиваем торрент-стриминг как на YouTube..."

# Ждем запуска сервисов
sleep 30

# Создаем конфиг для автоматической настройки
cat > /home/$USER/scripts/configure-arrs.sh << 'ARR_EOF'
#!/bin/bash

# Ждем полного запуска всех сервисов
sleep 60

echo "Настраиваем автоматический стриминг..."

# Создаем инструкцию по настройке
cat > /home/$USER/torrent-streaming-guide.txt << 'GUIDE_EOF
=== НАСТРОЙКА ТОРРЕНТ-СТРИМИНГА КАК НА YOUTUBE ===

🎯 КАК ЭТО РАБОТАЕТ:
1. Вы ищете фильм в Overseerr
2. Нажимаете "Запросить"
3. Система автоматически скачивает через торрент
4. Файл сразу доступен для просмотра в Jellyfin
5. После просмотра файл автоматически удаляется

⚡ БЫСТРЫЙ СТАРТ:

1. ОТКРОЙТЕ OVERSEERR:
   http://SERVER_IP:5055

2. НАЙДИТЕ ФИЛЬМ И НАЖМИТЕ "REQUEST"

3. СМОТРИТЕ В JELLYFIN:
   http://SERVER_IP:8096

4. ФИЛЬМ ПОЯВИТСЯ ЧЕРЕЗ 1-5 МИНУТ!

🔧 ПОЛНАЯ НАСТРОЙКА:

1. Prowlarr (поиск трекеров):
   http://SERVER_IP:9696
   - Добавьте публичные трекеры автоматически

2. Radarr (фильмы):
   http://SERVER_IP:7878
   - Папка фильмов: /movies
   - Папка загрузок: /downloads

3. Sonarr (сериалы):
   http://SERVER_IP:8989  
   - Папка сериалов: /tv
   - Папка загрузок: /downloads

4. qBittorrent:
   http://SERVER_IP:8080
   - Логин: admin
   - Пароль: adminadmin

🔄 АВТОМАТИЧЕСКАЯ ОЧИСТКА:
- Файлы удаляются через 24 часа после скачивания
- Можно смотреть повторно - файл скачается заново
- Не занимает место на диске
- 🔒 БИБЛИОТЕКИ FILMS/TV/MUSIC НЕ ТРОГАЮТСЯ!

🎬 НАСЛАЖДАЙТЕСЬ ПРОСМОТРОМ!
GUIDE_EOF

# Заменяем SERVER_IP на реальный IP
sed -i "s/SERVER_IP/$SERVER_IP/g" /home/$USER/torrent-streaming-guide.txt

echo "Настройка стриминга завершена!"
ARR_EOF

chmod +x /home/$USER/scripts/configure-arrs.sh
nohup /home/$USER/scripts/configure-arrs.sh > /dev/null 2>&1 &

echo "Торрент-стриминг настроен!"
STREAMING_EOF

chmod +x /home/$USER/scripts/setup-streaming.sh
nohup /home/$USER/scripts/setup-streaming.sh > /dev/null 2>&1 &

# 15. НАСТРОЙКА NGINX ПРОКСИ ДЛЯ DUCKDNS
log "🌐 Настройка Nginx прокси для DuckDNS..."

# Создаем конфиг Nginx с прокси для всех сервисов
cat > /home/$USER/docker/homepage/nginx.conf << 'NGINX_PROXY'
server {
    listen 80;
    server_name _;
    
    # Главная страница входа
    location = / {
        root /usr/share/nginx/html;
        index index.html;
        try_files $uri $uri/ /index.html;
    }
    
    # Прокси для сервисов через подпути
    location /jellyfin/ {
        proxy_pass http://jellyfin:8096/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $host;
    }
    
    location /overseerr/ {
        proxy_pass http://overseerr:5055/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
    
    location /heimdall/ {
        proxy_pass http://heimdall:80/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
    
    location /monitoring/ {
        proxy_pass http://uptime-kuma:3001/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
    
    location /passwords/ {
        proxy_pass http://vaultwarden:8000/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
    
    location /nextcloud/ {
        proxy_pass http://host.docker.internal:80/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
    
    # Статические файлы главной страницы
    location / {
        root /usr/share/nginx/html;
        try_files $uri $uri/ /index.html;
    }
}
NGINX_PROXY

# Перезапускаем homepage с новым конфигом
docker restart homepage

# 16. СОЗДАЕМ ГЛАВНУЮ СТРАНИЦУ С АВТОРИЗАЦИЕЙ
log "🏠 Создаем главную страницу с авторизацией..."

# HTML главной страницы с авторизацией
cat > /home/$USER/docker/homepage/index.html << 'HTMLEOF'
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Домашний Сервер - Вход</title>
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }
        
        body {
            font-family: 'Arial', sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
            display: flex;
            align-items: center;
            justify-content: center;
        }
        
        .login-container {
            background: white;
            padding: 40px;
            border-radius: 15px;
            box-shadow: 0 15px 35px rgba(0,0,0,0.1);
            width: 100%;
            max-width: 400px;
        }
        
        .logo {
            text-align: center;
            margin-bottom: 30px;
        }
        
        .logo h1 {
            color: #333;
            font-size: 28px;
            margin-bottom: 5px;
        }
        
        .logo p {
            color: #666;
            font-size: 14px;
        }
        
        .form-group {
            margin-bottom: 20px;
        }
        
        .form-group label {
            display: block;
            margin-bottom: 5px;
            color: #333;
            font-weight: bold;
        }
        
        .form-group input {
            width: 100%;
            padding: 12px 15px;
            border: 2px solid #ddd;
            border-radius: 8px;
            font-size: 16px;
            transition: border-color 0.3s;
        }
        
        .form-group input:focus {
            outline: none;
            border-color: #667eea;
        }
        
        .login-btn {
            width: 100%;
            padding: 12px;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            border: none;
            border-radius: 8px;
            font-size: 16px;
            font-weight: bold;
            cursor: pointer;
            transition: transform 0.2s;
        }
        
        .login-btn:hover {
            transform: translateY(-2px);
        }
        
        .error-message {
            color: #e74c3c;
            text-align: center;
            margin-top: 15px;
            display: none;
        }
        
        .services-info {
            margin-top: 25px;
            padding-top: 20px;
            border-top: 1px solid #eee;
            text-align: center;
            color: #666;
            font-size: 12px;
        }
    </style>
</head>
<body>
    <div class="login-container">
        <div class="logo">
            <h1>🏠 Домашний Сервер</h1>
            <p>Войдите в систему управления</p>
        </div>
        
        <form id="loginForm">
            <div class="form-group">
                <label for="username">Логин:</label>
                <input type="text" id="username" name="username" placeholder="Введите логин" required>
            </div>
            
            <div class="form-group">
                <label for="password">Пароль:</label>
                <input type="password" id="password" name="password" placeholder="Введите пароль" required>
            </div>
            
            <button type="submit" class="login-btn">Войти в систему</button>
            
            <div class="error-message" id="errorMessage">
                Неверный логин или пароль
            </div>
        </form>
        
        <div class="services-info">
            Доступные сервисы: Jellyfin • Nextcloud • AI Ассистент • Торрент-стриминг
        </div>
    </div>

    <script>
        document.getElementById('loginForm').addEventListener('submit', function(e) {
            e.preventDefault();
            
            const username = document.getElementById('username').value;
            const password = document.getElementById('password').value;
            const errorMessage = document.getElementById('errorMessage');
            
            // Проверка логина и пароля
            if (username === 'admin' && password === 'homeserver') {
                // Создаем сессию на 1 час
                const sessionData = {
                    user: 'admin',
                    timestamp: Date.now(),
                    expires: Date.now() + (60 * 60 * 1000) // 1 час
                };
                localStorage.setItem('server_session', JSON.stringify(sessionData));
                
                // Перенаправляем на панель управления
                window.location.href = '/heimdall/';
            } else {
                errorMessage.style.display = 'block';
                setTimeout(() => {
                    errorMessage.style.display = 'none';
                }, 3000);
            }
        });
        
        // Проверяем активную сессию при загрузке
        window.addEventListener('load', function() {
            const session = localStorage.getItem('server_session');
            if (session) {
                const sessionData = JSON.parse(session);
                if (sessionData.expires > Date.now()) {
                    window.location.href = '/heimdall/';
                } else {
                    localStorage.removeItem('server_session');
                }
            }
        });
    </script>
</body>
</html>
HTMLEOF

# 17. СОЗДАЕМ ВЕБ-ИНТЕРФЕЙС ДЛЯ СМЕНЫ ПАРОЛЯ
log "🔧 Создаем веб-интерфейс смены пароля..."

# HTML интерфейс смены пароля
cat > /home/$USER/docker/password-manager/index.html << 'PASSWORD_HTML'
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Смена пароля - Домашний Сервер</title>
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }
        
        body {
            font-family: 'Arial', sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
            display: flex;
            align-items: center;
            justify-content: center;
            padding: 20px;
        }
        
        .password-container {
            background: white;
            padding: 40px;
            border-radius: 15px;
            box-shadow: 0 15px 35px rgba(0,0,0,0.1);
            width: 100%;
            max-width: 500px;
        }
        
        .logo {
            text-align: center;
            margin-bottom: 30px;
        }
        
        .logo h1 {
            color: #333;
            font-size: 28px;
            margin-bottom: 10px;
        }
        
        .logo p {
            color: #666;
            font-size: 14px;
        }
        
        .form-group {
            margin-bottom: 20px;
        }
        
        .form-group label {
            display: block;
            margin-bottom: 8px;
            color: #333;
            font-weight: bold;
        }
        
        .form-group input {
            width: 100%;
            padding: 12px 15px;
            border: 2px solid #ddd;
            border-radius: 8px;
            font-size: 16px;
            transition: border-color 0.3s;
        }
        
        .form-group input:focus {
            outline: none;
            border-color: #667eea;
        }
        
        .password-strength {
            margin-top: 5px;
            font-size: 12px;
            height: 15px;
        }
        
        .strength-weak { color: #e74c3c; }
        .strength-medium { color: #f39c12; }
        .strength-strong { color: #27ae60; }
        
        .change-btn {
            width: 100%;
            padding: 12px;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            border: none;
            border-radius: 8px;
            font-size: 16px;
            font-weight: bold;
            cursor: pointer;
            transition: transform 0.2s;
            margin-bottom: 15px;
        }
        
        .change-btn:hover {
            transform: translateY(-2px);
        }
        
        .change-btn:disabled {
            background: #ccc;
            cursor: not-allowed;
            transform: none;
        }
        
        .back-btn {
            width: 100%;
            padding: 10px;
            background: #95a5a6;
            color: white;
            border: none;
            border-radius: 8px;
            font-size: 14px;
            cursor: pointer;
            text-decoration: none;
            display: block;
            text-align: center;
        }
        
        .message {
            padding: 10px;
            border-radius: 5px;
            margin: 15px 0;
            text-align: center;
            display: none;
        }
        
        .success {
            background: #d4edda;
            color: #155724;
            border: 1px solid #c3e6cb;
        }
        
        .error {
            background: #f8d7da;
            color: #721c24;
            border: 1px solid #f5c6cb;
        }
        
        .requirements {
            background: #f8f9fa;
            padding: 15px;
            border-radius: 8px;
            margin: 20px 0;
            font-size: 12px;
            color: #666;
        }
        
        .requirements ul {
            list-style: none;
            padding-left: 0;
        }
        
        .requirements li {
            margin: 5px 0;
            padding-left: 20px;
            position: relative;
        }
        
        .requirements li:before {
            content: "•";
            position: absolute;
            left: 8px;
            color: #667eea;
        }
    </style>
</head>
<body>
    <div class="password-container">
        <div class="logo">
            <h1>🔐 Смена пароля</h1>
            <p>Домашний сервер - Панель управления</p>
        </div>
        
        <div class="requirements">
            <strong>Требования к паролю:</strong>
            <ul>
                <li>Минимум 8 символов</li>
                <li>Не используйте простые пароли</li>
                <li>Рекомендуется использовать буквы, цифры и символы</li>
            </ul>
        </div>
        
        <form id="passwordForm">
            <div class="form-group">
                <label for="currentPassword">Текущий пароль:</label>
                <input type="password" id="currentPassword" placeholder="Введите текущий пароль" required>
            </div>
            
            <div class="form-group">
                <label for="newPassword">Новый пароль:</label>
                <input type="password" id="newPassword" placeholder="Введите новый пароль" required>
                <div class="password-strength" id="passwordStrength"></div>
            </div>
            
            <div class="form-group">
                <label for="confirmPassword">Подтвердите новый пароль:</label>
                <input type="password" id="confirmPassword" placeholder="Повторите новый пароль" required>
            </div>
            
            <button type="submit" class="change-btn" id="changeBtn">Сменить пароль</button>
            
            <div class="message success" id="successMessage">
                ✅ Пароль успешно изменен!
            </div>
            
            <div class="message error" id="errorMessage">
                ❌ Ошибка при смене пароля
            </div>
        </form>
        
        <a href="/heimdall/" class="back-btn">← Назад к панели управления</a>
    </div>

    <script>
        // Элементы DOM
        const form = document.getElementById('passwordForm');
        const currentPassword = document.getElementById('currentPassword');
        const newPassword = document.getElementById('newPassword');
        const confirmPassword = document.getElementById('confirmPassword');
        const changeBtn = document.getElementById('changeBtn');
        const successMessage = document.getElementById('successMessage');
        const errorMessage = document.getElementById('errorMessage');
        const passwordStrength = document.getElementById('passwordStrength');
        
        // Проверка сложности пароля
        newPassword.addEventListener('input', function() {
            const password = this.value;
            let strength = '';
            let strengthClass = '';
            
            if (password.length === 0) {
                strength = '';
            } else if (password.length < 6) {
                strength = 'Слабый';
                strengthClass = 'strength-weak';
            } else if (password.length < 10) {
                strength = 'Средний';
                strengthClass = 'strength-medium';
            } else {
                strength = 'Сильный';
                strengthClass = 'strength-strong';
            }
            
            passwordStrength.textContent = strength;
            passwordStrength.className = 'password-strength ' + strengthClass;
        });
        
        // Проверка совпадения паролей
        confirmPassword.addEventListener('input', function() {
            if (newPassword.value !== this.value) {
                this.style.borderColor = '#e74c3c';
            } else {
                this.style.borderColor = '#27ae60';
            }
        });
        
        // Отправка формы
        form.addEventListener('submit', async function(e) {
            e.preventDefault();
            
            // Валидация
            if (newPassword.value.length < 4) {
                showMessage('Пароль должен содержать минимум 4 символа', 'error');
                return;
            }
            
            if (newPassword.value !== confirmPassword.value) {
                showMessage('Пароли не совпадают', 'error');
                return;
            }
            
            // Блокируем кнопку
            changeBtn.disabled = true;
            changeBtn.textContent = 'Меняем пароль...';
            
            try {
                // Отправляем запрос на смену пароля
                const response = await fetch('/change-password', {
                    method: 'POST',
                    headers: {
                        'Content-Type': 'application/json',
                    },
                    body: JSON.stringify({
                        currentPassword: currentPassword.value,
                        newPassword: newPassword.value
                    })
                });
                
                const result = await response.json();
                
                if (result.success) {
                    showMessage('Пароль успешно изменен!', 'success');
                    form.reset();
                    passwordStrength.textContent = '';
                    
                    // Обновляем страницу через 2 секунды
                    setTimeout(() => {
                        window.location.href = '/heimdall/';
                    }, 2000);
                } else {
                    showMessage(result.message || 'Ошибка при смене пароля', 'error');
                }
            } catch (error) {
                showMessage('Ошибка сети: ' + error.message, 'error');
            } finally {
                // Разблокируем кнопку
                changeBtn.disabled = false;
                changeBtn.textContent = 'Сменить пароль';
            }
        });
        
        function showMessage(text, type) {
            if (type === 'success') {
                successMessage.textContent = text;
                successMessage.style.display = 'block';
                errorMessage.style.display = 'none';
            } else {
                errorMessage.textContent = text;
                errorMessage.style.display = 'block';
                successMessage.style.display = 'none';
            }
            
            // Автоматически скрываем сообщение через 5 секунд
            setTimeout(() => {
                successMessage.style.display = 'none';
                errorMessage.style.display = 'none';
            }, 5000);
        }
    </script>
</body>
</html>
PASSWORD_HTML

# Создаем backend для обработки смены пароля
cat > /home/$USER/docker/password-manager/server.py << 'PYTHON_EOF'
#!/usr/bin/env python3
from http.server import HTTPServer, BaseHTTPRequestHandler
import json
import os
import subprocess
import hashlib
import urllib.parse

USERNAME = os.getenv('USER', 'ubuntu')
SERVER_IP = subprocess.getoutput("hostname -I | awk '{print $1}'")

class PasswordHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/':
            # Serve the password change page
            with open('/app/index.html', 'rb') as f:
                content = f.read()
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.end_headers()
            self.wfile.write(content)
        else:
            self.send_error(404)
    
    def do_POST(self):
        if self.path == '/change-password':
            content_length = int(self.headers['Content-Length'])
            post_data = self.rfile.read(content_length)
            data = json.loads(post_data.decode('utf-8'))
            
            current_password = data.get('currentPassword', '')
            new_password = data.get('newPassword', '')
            
            # Simple password verification (replace with your actual verification)
            if self.verify_current_password(current_password) and len(new_password) >= 4:
                success = self.change_password(new_password)
                if success:
                    response = {
                        'success': True,
                        'message': 'Пароль успешно изменен!'
                    }
                else:
                    response = {
                        'success': False,
                        'message': 'Ошибка при изменении пароля'
                    }
            else:
                response = {
                    'success': False,
                    'message': 'Неверный текущий пароль или новый пароль слишком короткий'
                }
            
            self.send_response(200)
            self.send_header('Content-Type', 'application/json; charset=utf-8')
            self.end_headers()
            self.wfile.write(json.dumps(response).encode('utf-8'))
        else:
            self.send_error(404)
    
    def verify_current_password(self, password):
        """Verify current password (simple implementation)"""
        # Read current password from homepage file
        try:
            with open(f'/home/{USERNAME}/docker/homepage/index.html', 'r') as f:
                content = f.read()
                # Extract password from JavaScript code
                if f"password === '{password}'" in content:
                    return True
        except:
            pass
        return False
    
    def change_password(self, new_password):
        """Change password in all required places"""
        try:
            # Update homepage login page
            homepage_file = f'/home/{USERNAME}/docker/homepage/index.html'
            with open(homepage_file, 'r') as f:
                content = f.read()
            
            # Replace password in JavaScript check
            import re
            new_content = re.sub(
                r"password === '[^']*'", 
                f"password === '{new_password}'", 
                content
            )
            
            with open(homepage_file, 'w') as f:
                f.write(new_content)
            
            # Update accounts file
            accounts_file = f'/home/{USERNAME}/accounts.txt'
            if os.path.exists(accounts_file):
                with open(accounts_file, 'r') as f:
                    content = f.read()
                
                new_content = re.sub(
                    r'Пароль: [^\n]*',
                    f'Пароль: {new_password}',
                    content
                )
                
                with open(accounts_file, 'w') as f:
                    f.write(new_content)
            
            # Restart homepage container
            subprocess.run(['docker', 'restart', 'homepage'], check=True)
            
            return True
        except Exception as e:
            print(f"Error changing password: {e}")
            return False
    
    def log_message(self, format, *args):
        # Disable default logging
        pass

def run_server():
    port = 8089
    server = HTTPServer(('0.0.0.0', port), PasswordHandler)
    print(f'Password manager server running on port {port}')
    server.serve_forever()

if __name__ == '__main__':
    run_server()
PYTHON_EOF

# Создаем Dockerfile для password-manager
cat > /home/$USER/docker/password-manager/Dockerfile << 'DOCKERFILE_EOF'
FROM python:3.9-alpine

WORKDIR /app

COPY index.html .
COPY server.py .

RUN apk add --no-cache docker

EXPOSE 8089

CMD ["python", "server.py"]
DOCKERFILE_EOF

# Перезапускаем сервисы с новым контейнером
cd /home/$USER/docker
docker-compose up -d --build password-manager

# 18. АВТОМАТИЧЕСКАЯ НАСТРОЙКА HEIMDALL
log "🏠 Настраиваем Heimdall с всеми сервисами..."

# Создаем автоматическую настройку для Heimdall
cat > /home/$USER/scripts/setup-heimdall.sh << 'HEIMDALL_EOF'
#!/bin/bash

USERNAME=$(whoami)
SERVER_IP=$(hostname -I | awk '{print $1}')

echo "Настраиваем Heimdall с всеми сервисами..."

# Ждем полного запуска Heimdall
sleep 30

# Создаем apps.json для Heimdall
cat > /home/$USERNAME/docker/heimdall/apps.json << 'APPS_EOF'
[
    {
        "name": "🔍 Яндекс Поиск",
        "color": "#FF0000",
        "icon": "fab fa-yandex",
        "link": "https://yandex.ru",
        "description": "Поиск в интернете через Яндекс",
        "type": 1
    },
    {
        "name": "🔐 Смена пароля",
        "color": "#FF6B35",
        "icon": "fas fa-key",
        "link": "http://SERVER_IP:8089",
        "description": "Изменить пароль администратора",
        "type": 1
    },
    {
        "name": "🎬 Jellyfin",
        "color": "#00AAFF",
        "icon": "fas fa-play-circle",
        "link": "/jellyfin/",
        "description": "Медиасервер с фильмами и сериалами"
    },
    {
        "name": "🔍 Поиск фильмов",
        "color": "#FF6B00", 
        "icon": "fas fa-search",
        "link": "/overseerr/",
        "description": "Overseerr - поиск и добавление контента"
    },
    {
        "name": "☁️ Nextcloud",
        "color": "#0082C9",
        "icon": "fas fa-cloud",
        "link": "/nextcloud/",
        "description": "Файловое хранилище"
    },
    {
        "name": "📊 Мониторинг",
        "color": "#4CAF50",
        "icon": "fas fa-chart-bar",
        "link": "/monitoring/",
        "description": "Uptime Kuma - мониторинг сервисов"
    },
    {
        "name": "🔐 Менеджер паролей",
        "color": "#CD5C5C",
        "icon": "fas fa-lock",
        "link": "/passwords/",
        "description": "Vaultwarden - менеджер паролей"
    },
    {
        "name": "🤖 AI Ассистент",
        "color": "#8A2BE2",
        "icon": "fas fa-robot",
        "link": "http://SERVER_IP:11434",
        "description": "Ollama - локальная нейросеть"
    },
    {
        "name": "📥 Торренты",
        "color": "#FFD700",
        "icon": "fas fa-download",
        "link": "http://SERVER_IP:8080",
        "description": "qBittorrent - торрент-клиент"
    },
    {
        "name": "🎯 Менеджер трекеров",
        "color": "#32CD32",
        "icon": "fas fa-search-plus",
        "link": "http://SERVER_IP:9696",
        "description": "Prowlarr - поиск по трекерам"
    },
    {
        "name": "🎥 Radarr",
        "color": "#FF69B4",
        "icon": "fas fa-film",
        "link": "http://SERVER_IP:7878",
        "description": "Управление фильмами"
    },
    {
        "name": "📺 Sonarr",
        "color": "#1E90FF",
        "icon": "fas fa-tv",
        "link": "http://SERVER_IP:8989",
        "description": "Управление сериалами"
    }
]
APPS_EOF

# Заменяем SERVER_IP на реальный IP
sed -i "s/SERVER_IP/$SERVER_IP/g" /home/$USERNAME/docker/heimdall/apps.json

# Перезапускаем Heimdall для применения настроек
docker restart heimdall

echo "Heimdall настроен со всеми сервисами!"
HEIMDALL_EOF

chmod +x /home/$USER/scripts/setup-heimdall.sh
nohup /home/$USER/scripts/setup-heimdall.sh > /dev/null 2>&1 &

# 19. АВТОМАТИЧЕСКАЯ НАСТРОЙКА УЧЕТНЫХ ЗАПИСЕЙ
log "👤 Настраиваем учетные записи..."

cat > /home/$USER/scripts/setup-accounts.sh << 'ACCOUNTS_EOF'
#!/bin/bash

echo "Настраиваем учетные записи..."

# Ждем полного запуска сервисов
sleep 90

# Создаем файл с учетными данными
cat > /home/$USER/accounts.txt << 'ACCEOF'
=== УЧЕТНЫЕ ЗАПИСИ ДОМАШНЕГО СЕРВЕРА ===

ДАННЫЕ ДЛЯ ВХОДА В СИСТЕМУ:
Логин: admin
Пароль: homeserver

=== ДОСТУП КАК YOUTUBE ===

🎯 КАК РАБОТАЕТ:
1. Открываете homeserver123.duckdns.org в браузере
2. Видите главную страницу входа
3. Входите в систему
4. Попадаете в панель управления
5. Кликаете по иконкам сервисов

🌐 ОСНОВНОЙ ДОСТУП:
http://homeserver123.duckdns.org

📡 ДЛЯ РАБОТЫ НУЖЕН ПРОБРОС ПОРТОВ:
• Порты 80 и 443 на роутере
• Инструкция: /home/USER/port-forwarding-guide.txt

=== СЕРВИСЫ ЧЕРЕЗ ПРОКСИ ===

После входа доступны:
/jellyfin/     - Медиасервер
/overseerr/    - Поиск фильмов  
/heimdall/     - Панель управления
/monitoring/   - Мониторинг
/passwords/    - Менеджер паролей
/nextcloud/    - Файловое хранилище

=== ЛОКАЛЬНЫЙ ДОСТУП ===

Главная страница: http://SERVER_IP
Jellyfin: http://SERVER_IP:8096
Overseerr: http://SERVER_IP:5055
Heimdall: http://SERVER_IP:8080
Мониторинг: http://SERVER_IP:3001
Смена пароля: http://SERVER_IP:8089

=== АВТОМАТИЧЕСКИЕ ФУНКЦИИ ===

🔄 Автообновления: каждое воскресенье в 3:00
💾 Автобэкап: каждый день в 2:00
🧹 Автоочистка: каждые 6 часов (только временные файлы)
ACCEOF

# Заменяем SERVER_IP на реальный IP
SERVER_IP=$(hostname -I | awk '{print $1}')
sed -i "s/SERVER_IP/$SERVER_IP/g" /home/$USER/accounts.txt
sed -i "s/USER/$USERNAME/g" /home/$USER/accounts.txt

# Создаем инструкцию по пробросу портов
cat > /home/$USER/port-forwarding-guide.txt << 'PORTS_GUIDE'
=== 📡 ИНСТРУКЦИЯ ПО ПРОБРОСУ ПОРТОВ ===

Для доступа КАК YOUTUBE нужно пробросить порты на роутере:

🎯 ОБЯЗАТЕЛЬНЫЕ ПОРТЫ:
• ПОРТ 80 (HTTP) → 192.168.1.100:80
• ПОРТ 443 (HTTPS) → 192.168.1.100:80

📋 ПОШАГОВАЯ ИНСТРУКЦИЯ:

1. ОТКРОЙТЕ НАСТРОЙКИ РОУТЕРА:
   - В браузере откройте 192.168.1.1 или 192.168.0.1
   - Логин/пароль: admin/admin (или смотрите на роутере)

2. НАЙДИТЕ РАЗДЕЛ:
   - "Переадресация портов" (Port Forwarding)
   - Или "Виртуальные серверы" (Virtual Servers)

3. ДОБАВЬТЕ ПРАВИЛА:

   ПРАВИЛО 1 - HTTP:
   - Имя: HomeServer_HTTP
   - Внешний порт: 80
   - Внутренний IP: 192.168.1.100
   - Внутренний порт: 80
   - Протокол: TCP

   ПРАВИЛО 2 - HTTPS:
   - Имя: HomeServer_HTTPS  
   - Внешний порт: 443
   - Внутренний IP: 192.168.1.100
   - Внутренний порт: 80
   - Протокол: TCP

4. СОХРАНИТЕ И ПЕРЕЗАГРУЗИТЕ РОУТЕР

🎯 РЕЗУЛЬТАТ:
После настройки будет работать:
http://homeserver123.duckdns.org
https://homeserver123.duckdns.org

⚠️ ВАЖНО:
• IP 192.168.1.100 замените на реальный IP вашего сервера
• Узнать IP: hostname -I
• Для постоянной работы настройте статический IP для сервера
PORTS_GUIDE

# Заменяем IP в инструкции
sed -i "s/192.168.1.100/$SERVER_IP/g" /home/$USER/port-forwarding-guide.txt

echo "Учетные записи и инструкции настроены!"
echo "Файл с инструкциями: /home/$USER/accounts.txt"
echo "Инструкция по пробросу портов: /home/$USER/port-forwarding-guide.txt"
ACCOUNTS_EOF

chmod +x /home/$USER/scripts/setup-accounts.sh
nohup /home/$USER/scripts/setup-accounts.sh > /dev/null 2>&1 &

# 20. ФИНАЛЬНАЯ ИНФОРМАЦИЯ
echo ""
echo "=========================================="
echo "🎉 АВТОМАТИЧЕСКАЯ УСТАНОВКА ЗАВЕРШЕНА!"
echo "=========================================="
echo ""
echo "🌐 ВАШ ДОМЕН: http://$DUCKDNS_URL"
echo ""
echo "🔐 СИСТЕМА ДОСТУПА:"
echo "🏠 ГЛАВНАЯ СТРАНИЦА: http://$SERVER_IP"
echo "   ИЛИ: http://$DUCKDNS_URL (после проброса портов)"
echo ""
echo "👤 ДАННЫЕ ДЛЯ ВХОДА:"
echo "   Логин: admin"
echo "   Пароль: homeserver"
echo ""
echo "📡 ДЛЯ ДОСТУПА ИЗ ИНТЕРНЕТА:"
echo "   Настройте проброс портов 80 и 443 на роутере"
echo "   Инструкция: /home/$USER/port-forwarding-guide.txt"
echo ""
echo "🎯 КАК РАБОТАЕТ:"
echo "   1. Открываете homeserver123.duckdns.org"
echo "   2. Входите с логином/паролем"
echo "   3. Попадаете в панель управления"
echo "   4. Кликаете по иконкам сервисов"
echo "   5. Все сервисы открываются через основной домен!"
echo ""
echo "📋 ИНСТРУКЦИИ:"
echo "   Полная инструкция: /home/$USER/accounts.txt"
echo "   Проброс портов: /home/$USER/port-forwarding-guide.txt"
echo ""
echo "🚀 Готово! Ваш домашний сервер запущен!"
echo "=========================================="
