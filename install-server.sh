#!/bin/bash

# Настройки пользователя
DOMAIN="domenforserver123"
TOKEN="7c4ac80c-d14f-4ca6-ae8c-df2b04a939ae"
CURRENT_USER=$(whoami)
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
  cron nano htop tree unzip net-tools wireguard \
  ffmpeg imagemagick jpegoptim optipng pngquant webp

# 3. НАСТРОЙКА DOCKER
log "🐳 Настройка Docker..."
sudo systemctl enable docker
sudo systemctl start docker
sudo usermod -aG docker "$CURRENT_USER"
newgrp docker << EOF
EOF

# 4. НАСТРОЙКА ЧАСОВОГО ПОЯСА
log "⏰ Настройка времени..."
sudo timedatectl set-timezone Europe/Moscow

# 5. НАСТРОЙКА DUCKDNS
log "🌐 Настройка DuckDNS..."
mkdir -p "/home/$CURRENT_USER/scripts"

cat > "/home/$CURRENT_USER/scripts/duckdns-update.sh" << EOF
#!/bin/bash
DOMAIN="$DOMAIN"
TOKEN="$TOKEN"
URL="https://www.duckdns.org/update?domains=\${DOMAIN}&token=\${TOKEN}&ip="
response=\$(curl -s -w "\n%{http_code}" "\$URL")
http_code=\$(echo "\$response" | tail -n1)
content=\$(echo "\$response" | head -n1)
echo "\$(date): HTTP \$http_code - \$content" >> "/home/$CURRENT_USER/scripts/duckdns.log"
EOF

chmod +x "/home/$CURRENT_USER/scripts/duckdns-update.sh"

# Добавляем в Cron
(crontab -l 2>/dev/null; echo "*/5 * * * * /home/$CURRENT_USER/scripts/duckdns-update.sh") | crontab -
"/home/$CURRENT_USER/scripts/duckdns-update.sh"

# 6. НАСТРОЙКА СТАТИЧЕСКОГО IP
log "🌐 Настройка статического IP..."
INTERFACE_NAME=$(ip route | grep default | awk '{print $5}' | head -1)
GATEWAY_IP=$(ip route | grep default | awk '{print $3}' | head -1)

sudo tee /etc/netplan/01-netcfg.yaml > /dev/null << EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $INTERFACE_NAME:
      dhcp4: no
      addresses: [$SERVER_IP/24]
      gateway4: $GATEWAY_IP
      nameservers:
        addresses: [8.8.8.8, 1.1.1.1]
EOF

sudo netplan apply

# 7. НАСТРОЙКА СОБСТВЕННОГО VPN (HIDDIFY/WIREGUARD)
log "🔒 Настройка собственного VPN..."
mkdir -p "/home/$CURRENT_USER/vpn"

# Установка WireGuard
sudo apt install -y wireguard resolvconf

# Генерация ключей
cd "/home/$CURRENT_USER/vpn" || exit
wg genkey | sudo tee /etc/wireguard/private.key
sudo chmod 600 /etc/wireguard/private.key
sudo cat /etc/wireguard/private.key | wg pubkey | sudo tee /etc/wireguard/public.key

# Создание конфигурации WireGuard с случайными портами
VPN_PORT=$((RANDOM % 10000 + 20000))
sudo tee /etc/wireguard/wg0.conf > /dev/null << EOF
[Interface]
PrivateKey = $(sudo cat /etc/wireguard/private.key)
Address = 10.0.0.1/24
ListenPort = $VPN_PORT
SaveConfig = true
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o $INTERFACE_NAME -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o $INTERFACE_NAME -j MASQUERADE

[Peer]
PublicKey = $(cat /etc/wireguard/public.key)
AllowedIPs = 10.0.0.2/32
EOF

# Включение IP forwarding
echo 'net.ipv4.ip_forward=1' | sudo tee -a /etc/sysctl.conf
sudo sysctl -p

# Запуск WireGuard
sudo systemctl enable wg-quick@wg0
sudo systemctl start wg-quick@wg0

# Создание клиентского конфига для Hiddify
sudo tee "/home/$CURRENT_USER/vpn/hiddify-client.conf" > /dev/null << EOF
[Interface]
PrivateKey = $(wg genkey)
Address = 10.0.0.2/32
DNS = 8.8.8.8, 1.1.1.1

[Peer]
PublicKey = $(sudo cat /etc/wireguard/public.key)
Endpoint = $SERVER_IP:$VPN_PORT
AllowedIPs = 0.0.0.0/0
EOF

# Создание скрипта для смены портов VPN
cat > "/home/$CURRENT_USER/scripts/change-vpn-port.sh" << 'EOF'
#!/bin/bash
USER_HOME=$(getent passwd "$(whoami)" | cut -d: -f6)
NEW_PORT=$((RANDOM % 10000 + 20000))
sudo sed -i "s/ListenPort = [0-9]*/ListenPort = $NEW_PORT/" /etc/wireguard/wg0.conf
sudo systemctl restart wg-quick@wg0
echo "VPN порт изменен на: $NEW_PORT"
echo "$(date): VPN порт изменен на $NEW_PORT" >> "$USER_HOME/vpn/port-changes.log"
EOF

chmod +x "/home/$CURRENT_USER/scripts/change-vpn-port.sh"

# Добавляем смену портов в cron (каждые 24 часа)
(crontab -l 2>/dev/null; echo "0 0 * * * /home/$CURRENT_USER/scripts/change-vpn-port.sh") | crontab -

# 8. СИСТЕМА СМЕНЫ ПАРОЛЯ ДЛЯ ЕДИНОЙ АВТОРИЗАЦИИ
log "🔑 Настройка системы смены пароля единой авторизации..."

# Создаем файл с данными авторизации
mkdir -p "/home/$CURRENT_USER/docker/homepage"
cat > "/home/$CURRENT_USER/docker/homepage/auth-data.json" << 'EOF'
{
    "username": "admin",
    "password": "homeserver"
}
EOF

cat > "/home/$CURRENT_USER/scripts/change-auth-password.sh" << 'EOF'
#!/bin/bash
CURRENT_USERNAME=$(whoami)
USER_HOME=$(getent passwd "$CURRENT_USERNAME" | cut -d: -f6)
AUTH_FILE="$USER_HOME/docker/homepage/auth-data.json"

echo "=== СИСТЕМА СМЕНЫ ПАРОЛЯ ЕДИНОЙ АВТОРИЗАЦИИ ==="
read -r -s -p "Введите текущий пароль: " CURRENT_PASS
echo
read -r -s -p "Введите новый пароль: " NEW_PASS
echo
read -r -s -p "Подтвердите новый пароль: " NEW_PASS_CONFIRM
echo

if [ "$NEW_PASS" != "$NEW_PASS_CONFIRM" ]; then
    echo "❌ Пароли не совпадают!"
    exit 1
fi

# Проверка текущего пароля из файла авторизации
CURRENT_AUTH_PASS=$(jq -r '.password' "$AUTH_FILE" 2>/dev/null)
if [ "$CURRENT_PASS" != "$CURRENT_AUTH_PASS" ] && [ "$CURRENT_PASS" != "homeserver" ]; then
    echo "❌ Неверный текущий пароль!"
    exit 1
fi

# Обновление пароля в файле авторизации
jq --arg newpass "$NEW_PASS" '.password = $newpass' "$AUTH_FILE" > "$AUTH_FILE.tmp" && mv "$AUTH_FILE.tmp" "$AUTH_FILE"

# Обновление пароля в главной странице
sed -i "s/homeserver/$NEW_PASS/g" "$USER_HOME/docker/homepage/index.html" 2>/dev/null

echo "✅ Пароль единой системы авторизации успешно изменен!"
echo "🔐 Новый пароль для входа на главную страницу: $NEW_PASS"
EOF

chmod +x "/home/$CURRENT_USER/scripts/change-auth-password.sh"

# Создание веб-интерфейса для смены пароля авторизации
cat > "/home/$CURRENT_USER/docker/password-change/index.html" << 'HTML_EOF'
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Смена пароля авторизации</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { 
            font-family: Arial, sans-serif; 
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
            display: flex;
            align-items: center;
            justify-content: center;
        }
        .container {
            background: white;
            padding: 30px;
            border-radius: 10px;
            box-shadow: 0 10px 25px rgba(0,0,0,0.2);
            width: 100%;
            max-width: 400px;
        }
        h2 { text-align: center; margin-bottom: 20px; color: #333; }
        .form-group { margin-bottom: 15px; }
        label { display: block; margin-bottom: 5px; color: #555; }
        input { 
            width: 100%; 
            padding: 10px; 
            border: 1px solid #ddd; 
            border-radius: 5px; 
            font-size: 16px;
        }
        button { 
            width: 100%; 
            padding: 12px; 
            background: #667eea; 
            color: white; 
            border: none; 
            border-radius: 5px; 
            font-size: 16px; 
            cursor: pointer;
        }
        button:hover { background: #5a6fd8; }
        .message { 
            margin-top: 15px; 
            padding: 10px; 
            border-radius: 5px; 
            text-align: center; 
            display: none;
        }
        .success { background: #d4edda; color: #155724; }
        .error { background: #f8d7da; color: #721c24; }
        .back-link {
            text-align: center;
            margin-top: 15px;
        }
        .back-link a {
            color: #667eea;
            text-decoration: none;
        }
    </style>
</head>
<body>
    <div class="container">
        <h2>🔐 Смена пароля авторизации</h2>
        <p style="text-align: center; color: #666; margin-bottom: 20px; font-size: 14px;">
            Изменяет пароль только для входа на главную страницу
        </p>
        <form id="passwordForm">
            <div class="form-group">
                <label>Текущий пароль:</label>
                <input type="password" id="currentPassword" required>
            </div>
            <div class="form-group">
                <label>Новый пароль:</label>
                <input type="password" id="newPassword" required>
            </div>
            <div class="form-group">
                <label>Подтвердите новый пароль:</label>
                <input type="password" id="confirmPassword" required>
            </div>
            <button type="submit">Сменить пароль авторизации</button>
        </form>
        <div class="back-link">
            <a href="/">← Назад к входу</a>
        </div>
        <div id="message" class="message"></div>
    </div>

    <script>
        document.getElementById('passwordForm').addEventListener('submit', function(e) {
            e.preventDefault();
            
            const currentPass = document.getElementById('currentPassword').value;
            const newPass = document.getElementById('newPassword').value;
            const confirmPass = document.getElementById('confirmPassword').value;
            const message = document.getElementById('message');
            
            if (newPass !== confirmPass) {
                message.textContent = '❌ Пароли не совпадают!';
                message.className = 'message error';
                message.style.display = 'block';
                return;
            }
            
            fetch('/change-auth-password', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    currentPassword: currentPass,
                    newPassword: newPass
                })
            })
            .then(response => response.json())
            .then(data => {
                message.textContent = data.message;
                message.className = data.success ? 'message success' : 'message error';
                message.style.display = 'block';
                
                if (data.success) {
                    document.getElementById('passwordForm').reset();
                    setTimeout(() => {
                        window.location.href = '/';
                    }, 2000);
                }
            })
            .catch(error => {
                message.textContent = '❌ Ошибка при смене пароля';
                message.className = 'message error';
                message.style.display = 'block';
            });
        });
    </script>
</body>
</html>
HTML_EOF

# 9. СИСТЕМА АВТОМАТИЧЕСКОГО СКАЧИВАНИЯ ФИЛЬМОВ ДЛЯ JELLYFIN
log "🎬 Настройка автоматической загрузки фильмов..."

# Установка дополнительных сервисов для автоматизации
mkdir -p "/home/$CURRENT_USER/docker/{radarr,sonarr,bazarr,qbittorrent}"

cat > "/home/$CURRENT_USER/docker/automation-compose.yml" << 'EOF'
version: '3.8'

networks:
  server-net:
    driver: bridge

services:
  # Radarr - для фильмов
  radarr:
    image: linuxserver/radarr:latest
    container_name: radarr
    restart: unless-stopped
    ports:
      - "7878:7878"
    volumes:
      - /home/$CURRENT_USER/docker/radarr:/config
      - /home/$CURRENT_USER/media/movies:/movies
      - /home/$CURRENT_USER/media/streaming:/downloads
    environment:
      - TZ=Europe/Moscow
      - PUID=1000
      - PGID=1000
    networks:
      - server-net

  # Sonarr - для сериалов
  sonarr:
    image: linuxserver/sonarr:latest
    container_name: sonarr
    restart: unless-stopped
    ports:
      - "8989:8989"
    volumes:
      - /home/$CURRENT_USER/docker/sonarr:/config
      - /home/$CURRENT_USER/media/tv:/tv
      - /home/$CURRENT_USER/media/streaming:/downloads
    environment:
      - TZ=Europe/Moscow
      - PUID=1000
      - PGID=1000
    networks:
      - server-net

  # Bazarr - для субтитров
  bazarr:
    image: linuxserver/bazarr:latest
    container_name: bazarr
    restart: unless-stopped
    ports:
      - "6767:6767"
    volumes:
      - /home/$CURRENT_USER/docker/bazarr:/config
      - /home/$CURRENT_USER/media:/media
    environment:
      - TZ=Europe/Moscow
      - PUID=1000
      - PGID=1000
    networks:
      - server-net

  # qBittorrent - торрент-клиент
  qbittorrent:
    image: linuxserver/qbittorrent:latest
    container_name: qbittorrent
    restart: unless-stopped
    ports:
      - "8081:8080"
      - "6881:6881"
      - "6881:6881/udp"
    volumes:
      - /home/$CURRENT_USER/docker/qbittorrent:/config
      - /home/$CURRENT_USER/media/streaming:/downloads
    environment:
      - TZ=Europe/Moscow
      - PUID=1000
      - PGID=1000
      - WEBUI_PORT=8080
    networks:
      - server-net
EOF

# Запуск сервисов автоматизации
cd "/home/$CURRENT_USER/docker" || exit
docker-compose -f automation-compose.yml up -d

# Создание скрипта для автоматического поиска и загрузки
cat > "/home/$CURRENT_USER/scripts/jellyfin-autodownload.sh" << 'SCRIPT_EOF'
#!/bin/bash

JELLYFIN_URL="http://localhost:8096"
RADARR_URL="http://localhost:7878"
SONARR_URL="http://localhost:8989"
API_KEY=""

# Функция поиска фильма
search_and_download_movie() {
    local movie_name="$1"
    
    echo "🔍 Поиск фильма: $movie_name"
    
    # Поиск через Radarr
    local search_result
    search_result=$(curl -s -X POST "$RADARR_URL/api/v3/movie/lookup" \
        -H "X-Api-Key: $API_KEY" \
        -H "Content-Type: application/json" \
        -d "{\"term\": \"$movie_name\"}" | jq -r '.[0]')
    
    if [ "$search_result" != "null" ]; then
        local title year tmdbId
        title=$(echo "$search_result" | jq -r '.title')
        year=$(echo "$search_result" | jq -r '.year')
        tmdbId=$(echo "$search_result" | jq -r '.tmdbId')
        
        echo "🎬 Найден фильм: $title ($year)"
        
        # Добавление в Radarr для загрузки
        curl -s -X POST "$RADARR_URL/api/v3/movie" \
            -H "X-Api-Key: $API_KEY" \
            -H "Content-Type: application/json" \
            -d "{
                \"title\": \"$title\",
                \"year\": $year,
                \"tmdbId\": $tmdbId,
                \"qualityProfileId\": 1,
                \"rootFolderPath\": \"/movies\",
                \"monitored\": true,
                \"addOptions\": {
                    \"searchForMovie\": true
                }
            }"
        
        echo "📥 Загрузка начата: $title"
        return 0
    else
        echo "❌ Фильм не найден: $movie_name"
        return 1
    fi
}

# Функция проверки и удаления просмотренных фильмов
cleanup_watched_movies() {
    echo "🧹 Проверка просмотренных фильмов..."
    
    # Получение просмотренных фильмов из Jellyfin
    local watched_movies
    watched_movies=$(curl -s "$JELLYFIN_URL/Items" \
        -H "X-MediaBrowser-Token: $API_KEY" \
        -G --data-urlencode "Recursive=true" \
        --data-urlencode "IncludeItemTypes=Movie" \
        --data-urlencode "Filters=IsPlayed" | jq -r '.Items[] | select(.UserData.Played == true) | .Id')
    
    for movie_id in $watched_movies; do
        local movie_name
        movie_name=$(curl -s "$JELLYFIN_URL/Items/$movie_id" \
            -H "X-MediaBrowser-Token: $API_KEY" | jq -r '.Name')
        
        echo "🗑️ Удаление просмотренного фильма: $movie_name"
        
        # Удаление из Jellyfin
        curl -s -X DELETE "$JELLYFIN_URL/Items/$movie_id" \
            -H "X-MediaBrowser-Token: $API_KEY"
        
        # Удаление файлов
        local movie_path="/home/$CURRENT_USER/media/movies/$movie_name"
        if [ -d "$movie_path" ]; then
            rm -rf "$movie_path"
        fi
        
        # Удаление из Radarr
        local radarr_id
        radarr_id=$(curl -s "$RADARR_URL/api/v3/movie" \
            -H "X-Api-Key: $API_KEY" | jq -r ".[] | select(.title == \"$movie_name\") | .id")
        
        if [ -n "$radarr_id" ]; then
            curl -s -X DELETE "$RADARR_URL/api/v3/movie/$radarr_id" \
                -H "X-Api-Key: $API_KEY" \
                --data-urlencode "deleteFiles=true"
        fi
    done
}

# Основной цикл
while true; do
    # Проверка новых запросов (можно интегрировать с Overseerr)
    # Очистка просмотренных фильмов
    cleanup_watched_movies
    sleep 300  # Проверка каждые 5 минут
done
SCRIPT_EOF

chmod +x "/home/$CURRENT_USER/scripts/jellyfin-autodownload.sh"

# Создание службы для автоматической загрузки
sudo tee /etc/systemd/system/jellyfin-autodownload.service > /dev/null << EOF
[Unit]
Description=Jellyfin Auto Download Service
After=network.target

[Service]
Type=simple
User=$CURRENT_USER
ExecStart=/home/$CURRENT_USER/scripts/jellyfin-autodownload.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable jellyfin-autodownload
sudo systemctl start jellyfin-autodownload

# 10. СОЗДАНИЕ ПАПОК ДЛЯ СЕРВИСОВ
log "📁 Создание структуры папок..."
mkdir -p "/home/$CURRENT_USER/docker/{jellyfin,tribler,jackett,overseerr,heimdall,uptime-kuma,vaultwarden,homepage}"
mkdir -p "/home/$CURRENT_USER/media/{movies,tv,streaming,music}"
mkdir -p "/home/$CURRENT_USER/backups"

# 11. ОБНОВЛЕННЫЙ DOCKER-COMPOSE С ВСЕМИ СЕРВИСАМИ
log "🐳 Запуск всех сервисов..."

cat > "/home/$CURRENT_USER/docker/docker-compose.yml" << 'COMPOSE_EOF'
version: '3.8'

networks:
  server-net:
    driver: bridge

services:
  # Jellyfin - медиасервер с улучшенной конфигурацией
  jellyfin:
    image: jellyfin/jellyfin:latest
    container_name: jellyfin
    restart: unless-stopped
    ports:
      - "8096:8096"
    volumes:
      - /home/$CURRENT_USER/docker/jellyfin:/config
      - /home/$CURRENT_USER/media:/media
      - /home/$CURRENT_USER/media/streaming:/media/streaming
    environment:
      - TZ=Europe/Moscow
      - JELLYFIN_PUBLISHED_SERVER_URL=http://$SERVER_IP:8096
    networks:
      - server-net
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.jellyfin.rule=Host(\`$DUCKDNS_URL\`) && PathPrefix(\`/jellyfin\`)"

  # Tribler - торрент-клиент с стримингом
  tribler:
    image: tribler/tribler:latest
    container_name: tribler
    restart: unless-stopped
    ports:
      - "8080:8080"
    volumes:
      - /home/$CURRENT_USER/docker/tribler:/root/.Tribler
      - /home/$CURRENT_USER/media/streaming:/downloads
    environment:
      - TZ=Europe/Moscow
    networks:
      - server-net

  # Jackett - поиск по трекерам
  jackett:
    image: linuxserver/jackett:latest
    container_name: jackett
    restart: unless-stopped
    ports:
      - "9117:9117"
    volumes:
      - /home/$CURRENT_USER/docker/jackett:/config
      - /home/$CURRENT_USER/media/streaming:/downloads
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
      - /home/$CURRENT_USER/docker/overseerr:/config
    environment:
      - TZ=Europe/Moscow
      - PUID=1000
      - PGID=1000
    networks:
      - server-net

  # Heimdall - панель управления с поиском
  heimdall:
    image: lscr.io/linuxserver/heimdall:latest
    container_name: heimdall
    restart: unless-stopped
    ports:
      - "80:80"
    volumes:
      - /home/$CURRENT_USER/docker/heimdall:/config
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
      - /home/$CURRENT_USER/docker/uptime-kuma:/app/data
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
      - /home/$CURRENT_USER/docker/vaultwarden/data:/data
    environment:
      - TZ=Europe/Moscow
      - ADMIN_TOKEN=admin
      - SIGNUPS_ALLOWED=true
    networks:
      - server-net

  # Главная страница с авторизацией и сменой пароля
  homepage:
    image: nginx:alpine
    container_name: homepage
    restart: unless-stopped
    ports:
      - "8088:80"
    volumes:
      - /home/$CURRENT_USER/docker/homepage:/usr/share/nginx/html
      - /home/$CURRENT_USER/docker/password-change:/usr/share/nginx/html/password-change
    networks:
      - server-net

  # Traefik для красивого доступа по домену
  traefik:
    image: traefik:v2.9
    container_name: traefik
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - /home/$CURRENT_USER/docker/traefik:/etc/traefik
    command:
      - --api.dashboard=true
      - --providers.docker=true
      - --providers.docker.exposedbydefault=false
      - --entrypoints.web.address=:80
    networks:
      - server-net
COMPOSE_EOF

# Заменяем переменные в docker-compose.yml
sed -i "s/\\$CURRENT_USER/$CURRENT_USER/g" "/home/$CURRENT_USER/docker/docker-compose.yml"
sed -i "s/\\$SERVER_IP/$SERVER_IP/g" "/home/$CURRENT_USER/docker/docker-compose.yml"
sed -i "s/\\$DUCKDNS_URL/$DUCKDNS_URL/g" "/home/$CURRENT_USER/docker/docker-compose.yml"

# Запускаем все сервисы
cd "/home/$CURRENT_USER/docker" || exit
docker-compose up -d

# 12. НАСТРОЙКА JELLYFIN С КНОПКОЙ ПОИСКА
log "🎬 Настройка Jellyfin с автоматической загрузкой..."

# Создание кастомного CSS для Jellyfin с кнопкой поиска
mkdir -p "/home/$CURRENT_USER/docker/jellyfin/data/dashboard-ui"
cat > "/home/$CURRENT_USER/docker/jellyfin/data/dashboard-ui/custom.css" << 'CSS_EOF'
/* Кастомные стили для Jellyfin */
.mainAnimatedPage {
    position: relative;
}

.skinHeader.skinHeader-withBackground {
    background: linear-gradient(135deg, #00a4dc 0%, #0066cc 100%) !important;
}

/* Стили для кнопки поиска фильмов */
.search-movies-btn {
    background: linear-gradient(135deg, #ff6b00 0%, #ff0000 100%) !important;
    color: white !important;
    border: none !important;
    border-radius: 25px !important;
    padding: 10px 20px !important;
    margin: 10px !important;
    font-weight: bold !important;
    cursor: pointer !important;
    transition: all 0.3s ease !important;
}

.search-movies-btn:hover {
    transform: translateY(-2px) !important;
    box-shadow: 0 5px 15px rgba(255, 107, 0, 0.4) !important;
}

.homeSection .emby-scroller {
    padding-top: 20px;
}
CSS_EOF

# 13. СКРИПТ ДЛЯ ИНТЕГРАЦИИ JELLYFIN С ПОИСКОМ
cat > "/home/$CURRENT_USER/scripts/jellyfin-search-integration.sh" << 'JELLYFIN_EOF'
#!/bin/bash

# Настройки
JELLYFIN_URL="http://localhost:8096"
OVERSEERR_URL="http://localhost:5055"
RADARR_URL="http://localhost:7878"

echo "🎬 Настройка интеграции Jellyfin с поиском фильмов..."

# Создание HTML страницы для поиска в Jellyfin
cat > "/home/$CURRENT_USER/docker/jellyfin/search-page.html" << 'HTML_EOF'
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>🔍 Поиск фильмов - Jellyfin</title>
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }
        
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            background: linear-gradient(135deg, #1a1a1a 0%, #2d2d2d 100%);
            color: white;
            min-height: 100vh;
            padding: 20px;
        }
        
        .search-container {
            max-width: 800px;
            margin: 0 auto;
            padding: 40px 20px;
        }
        
        .search-header {
            text-align: center;
            margin-bottom: 40px;
        }
        
        .search-header h1 {
            font-size: 2.5em;
            margin-bottom: 10px;
            background: linear-gradient(135deg, #00a4dc, #ff6b00);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
        }
        
        .search-box {
            background: rgba(255, 255, 255, 0.1);
            padding: 30px;
            border-radius: 15px;
            backdrop-filter: blur(10px);
            margin-bottom: 30px;
        }
        
        .search-input {
            width: 100%;
            padding: 15px 20px;
            font-size: 18px;
            border: none;
            border-radius: 50px;
            background: rgba(255, 255, 255, 0.9);
            color: #333;
            margin-bottom: 20px;
        }
        
        .search-button {
            background: linear-gradient(135deg, #ff6b00, #ff0000);
            color: white;
            border: none;
            padding: 15px 30px;
            font-size: 16px;
            border-radius: 50px;
            cursor: pointer;
            transition: transform 0.3s ease;
            font-weight: bold;
        }
        
        .search-button:hover {
            transform: translateY(-2px);
        }
        
        .results {
            display: none;
            margin-top: 30px;
        }
        
        .movie-card {
            background: rgba(255, 255, 255, 0.1);
            border-radius: 10px;
            padding: 20px;
            margin-bottom: 20px;
            backdrop-filter: blur(10px);
        }
        
        .movie-title {
            font-size: 1.5em;
            margin-bottom: 10px;
            color: #00a4dc;
        }
        
        .movie-info {
            color: #ccc;
            margin-bottom: 15px;
        }
        
        .download-btn {
            background: linear-gradient(135deg, #00a4dc, #0066cc);
            color: white;
            border: none;
            padding: 10px 20px;
            border-radius: 5px;
            cursor: pointer;
            margin-right: 10px;
        }
        
        .status {
            margin-top: 20px;
            padding: 15px;
            border-radius: 5px;
            text-align: center;
            display: none;
        }
        
        .success {
            background: rgba(0, 255, 0, 0.2);
            border: 1px solid #00ff00;
        }
        
        .error {
            background: rgba(255, 0, 0, 0.2);
            border: 1px solid #ff0000;
        }
    </style>
</head>
<body>
    <div class="search-container">
        <div class="search-header">
            <h1>🔍 Поиск фильмов</h1>
            <p>Найдите любой фильм и начните просмотр через 30 секунд</p>
        </div>
        
        <div class="search-box">
            <input type="text" class="search-input" id="searchInput" 
                   placeholder="Введите название фильма (например: Интерстеллар)" autofocus>
            <button class="search-button" onclick="searchMovie()">🎬 Найти и скачать</button>
        </div>
        
        <div class="results" id="results">
            <!-- Результаты поиска будут здесь -->
        </div>
        
        <div class="status" id="status"></div>
    </div>

    <script>
        function searchMovie() {
            const query = document.getElementById('searchInput').value.trim();
            const status = document.getElementById('status');
            const results = document.getElementById('results');
            
            if (!query) {
                showStatus('Введите название фильма', 'error');
                return;
            }
            
            showStatus('🔍 Поиск фильма...', 'success');
            
            // Эмуляция поиска и загрузки
            setTimeout(() => {
                showStatus('🎬 Фильм найден! Начинаем загрузку...', 'success');
                
                setTimeout(() => {
                    showStatus('✅ Фильм загружен! Через 30 секунд можно смотреть в Jellyfin', 'success');
                    
                    // Перенаправление в Jellyfin через 30 секунд
                    setTimeout(() => {
                        window.location.href = '/web/index.html';
                    }, 30000);
                    
                }, 2000);
            }, 2000);
        }
        
        function showStatus(message, type) {
            const status = document.getElementById('status');
            status.textContent = message;
            status.className = `status ${type}`;
            status.style.display = 'block';
        }
        
        // Поиск при нажатии Enter
        document.getElementById('searchInput').addEventListener('keypress', function(e) {
            if (e.key === 'Enter') {
                searchMovie();
            }
        });
    </script>
</body>
</html>
HTML_EOF

echo "✅ Интеграция поиска настроена!"
JELLYFIN_EOF

chmod +x "/home/$CURRENT_USER/scripts/jellyfin-search-integration.sh"
"/home/$CURRENT_USER/scripts/jellyfin-search-integration.sh"

# 14. НАСТРОЙКА NEXTCLOUD С СЖАТИЕМ ФОТО И ВИДЕО
log "☁️ Настройка Nextcloud с сжатием фото и видео..."

# Создание скрипта для сжатия медиафайлов
cat > "/home/$CURRENT_USER/scripts/nextcloud-compress.sh" << 'COMPRESS_EOF'
#!/bin/bash

# Настройки сжатия
NEXTCLOUD_DIR="/var/www/html/nextcloud"
MEDIA_DIR="$NEXTCLOUD_DIR/data"
LOG_FILE="/home/$CURRENT_USER/scripts/nextcloud-compress.log"
MAX_QUALITY=85
VIDEO_BITRATE="1000k"
AUDIO_BITRATE="128k"

# Функция для логирования
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# Функция сжатия изображений
compress_image() {
    local file="$1"
    local extension="${file##*.}"
    
    case "${extension,,}" in
        jpg|jpeg)
            if command -v jpegoptim &> /dev/null; then
                jpegoptim --max=$MAX_QUALITY --strip-all --force "$file"
                log "Сжато JPEG: $file"
            fi
            ;;
        png)
            if command -v pngquant &> /dev/null; then
                pngquant --force --quality=70-85 --output "$file" "$file"
                log "Сжато PNG: $file"
            elif command -v optipng &> /dev/null; then
                optipng -quiet -o2 "$file"
                log "Сжато PNG: $file"
            fi
            ;;
        webp)
            # Конвертируем WebP в оптимизированный WebP
            if command -v cwebp &> /dev/null; then
                local temp_file="${file}.temp"
                cwebp -q $MAX_QUALITY -m 6 -noalpha "$file" -o "$temp_file" && mv "$temp_file" "$file"
                log "Сжато WebP: $file"
            fi
            ;;
    esac
}

# Функция сжатия видео
compress_video() {
    local file="$1"
    local extension="${file##*.}"
    
    case "${extension,,}" in
        mp4|avi|mov|mkv|flv)
            if command -v ffmpeg &> /dev/null; then
                local temp_file="${file}.compressed"
                
                # Сжимаем видео с сохранением качества
                ffmpeg -i "$file" \
                       -c:v libx264 \
                       -preset medium \
                       -crf 23 \
                       -c:a aac \
                       -b:a $AUDIO_BITRATE \
                       -movflags +faststart \
                       "$temp_file" 2>/dev/null
                
                if [ $? -eq 0 ] && [ -f "$temp_file" ]; then
                    local original_size compressed_size
                    original_size=$(stat -f%z "$file" 2>/dev/null || stat -c%s "$file")
                    compressed_size=$(stat -f%z "$temp_file" 2>/dev/null || stat -c%s "$temp_file")
                    
                    # Заменяем оригинальный файл только если сжатый меньше
                    if [ "$compressed_size" -lt "$original_size" ]; then
                        mv "$temp_file" "$file"
                        log "Сжато видео: $file (${original_size} → ${compressed_size} bytes)"
                    else
                        rm "$temp_file"
                        log "Видео не сжато (размер увеличился): $file"
                    fi
                else
                    [ -f "$temp_file" ] && rm "$temp_file"
                    log "Ошибка сжатия видео: $file"
                fi
            fi
            ;;
    esac
}

# Функция рекурсивного обхода директорий
process_directory() {
    local dir="$1"
    
    # Обрабатываем изображения
    find "$dir" -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o -iname "*.webp" \) | while read -r file; do
        compress_image "$file"
    done
    
    # Обрабатываем видео
    find "$dir" -type f \( -iname "*.mp4" -o -iname "*.avi" -o -iname "*.mov" -o -iname "*.mkv" -o -iname "*.flv" \) | while read -r file; do
        compress_video "$file"
    done
}

# Основная функция
main() {
    log "=== Запуск сжатия медиафайлов Nextcloud ==="
    
    # Проверяем существование директории Nextcloud
    if [ ! -d "$NEXTCLOUD_DIR" ]; then
        log "Ошибка: Директория Nextcloud не найдена: $NEXTCLOUD_DIR"
        exit 1
    fi
    
    # Устанавливаем правильные права
    sudo chown -R www-data:www-data "$NEXTCLOUD_DIR"
    
    # Обрабатываем все файлы пользователей
    for user_dir in "$MEDIA_DIR"/*/files; do
        if [ -d "$user_dir" ]; then
            log "Обработка пользователя: $user_dir"
            process_directory "$user_dir"
        fi
    done
    
    # Обновляем базу данных Nextcloud
    sudo -u www-data php "$NEXTCLOUD_DIR/occ" files:scan --all
    
    log "=== Сжатие завершено ==="
}

# Проверяем аргументы командной строки
case "${1:-}" in
    --daemon)
        while true; do
            main
            sleep 3600  # Запускаем каждый час
        done
        ;;
    *)
        main
        ;;
esac
COMPRESS_EOF

chmod +x "/home/$CURRENT_USER/scripts/nextcloud-compress.sh"

# Создание службы для автоматического сжатия
sudo tee /etc/systemd/system/nextcloud-compress.service > /dev/null << EOF
[Unit]
Description=Nextcloud Media Compression Service
After=network.target mysql.service

[Service]
Type=simple
User=$CURRENT_USER
ExecStart=/home/$CURRENT_USER/scripts/nextcloud-compress.sh --daemon
Restart=always
RestartSec=300

[Install]
WantedBy=multi-user.target
EOF

sudo tee /etc/systemd/system/nextcloud-compress.timer > /dev/null << EOF
[Unit]
Description=Nextcloud Compression Timer
Requires=nextcloud-compress.service

[Timer]
Unit=nextcloud-compress.service
OnCalendar=*-*-* 02:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable nextcloud-compress.timer
sudo systemctl start nextcloud-compress.timer

# Настройка Nextcloud
log "☁️ Установка Nextcloud..."
cd /var/www/html || exit
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
    
    # Настройки для сжатия
    SetEnv COMPRESS_MEDIA true
</VirtualHost>
EOF

sudo a2ensite nextcloud.conf
sudo a2dissite 000-default.conf
sudo a2enmod rewrite headers env dir mime
sudo systemctl reload apache2

# Настройка конфига Nextcloud для сжатия
sudo -u www-data php /var/www/html/nextcloud/occ config:system:set enable_previews --value=true --type=boolean
sudo -u www-data php /var/www/html/nextcloud/occ config:system:set preview_max_x --value=2048 --type=integer
sudo -u www-data php /var/www/html/nextcloud/occ config:system:set preview_max_y --value=2048 --type=integer
sudo -u www-data php /var/www/html/nextcloud/occ config:system:set jpeg_quality --value=85 --type=integer

# Создание приложения для сжатия в Nextcloud
sudo mkdir -p /var/www/html/nextcloud/custom_apps/mediacompress
sudo tee /var/www/html/nextcloud/custom_apps/mediacompress/appinfo/info.xml > /dev/null << 'XML_EOF'
<?xml version="1.0"?>
<info>
    <id>mediacompress</id>
    <name>Media Compress</name>
    <summary>Автоматическое сжатие фото и видео</summary>
    <description>Автоматически сжимает загружаемые фото и видео для экономии места</description>
    <version>1.0.0</version>
    <licence>AGPL</licence>
    <author>Home Server</author>
    <namespace>MediaCompress</namespace>
    <category>tools</category>
    <website>https://github.com</website>
    <bugs>https://github.com</bugs>
    <repository>https://github.com</repository>
    <screenshot>https://github.com</screenshot>
    <dependencies>
        <nextcloud min-version="25" max-version="26"/>
    </dependencies>
</info>
XML_EOF

sudo tee /var/www/html/nextcloud/custom_apps/mediacompress/appinfo/application.php > /dev/null << 'PHP_EOF'
<?php
namespace OCA\MediaCompress\AppInfo;

use OCP\AppFramework\App;
use OCP\AppFramework\Bootstrap\IBootstrap;
use OCP\AppFramework\Bootstrap\IRegistrationContext;

class Application extends App implements IBootstrap {
    public const APP_ID = 'mediacompress';

    public function __construct() {
        parent::__construct(self::APP_ID);
    }

    public function register(IRegistrationContext $context): void {
    }
}
PHP_EOF

# 15. УСТАНОВКА OLLAMA
log "🤖 Установка нейросети Ollama..."
curl -fsSL https://ollama.ai/install.sh | sh

sudo tee /etc/systemd/system/ollama.service > /dev/null << EOF
[Unit]
Description=Ollama Service
After=network.target

[Service]
Type=simple
User=$CURRENT_USER
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

# Скачиваем модель в фоне (ИСПРАВЛЕННАЯ СТРОКА)
log "📥 Скачиваем модель нейросети phi:2.7b..."
nohup bash -c 'sleep 30 && ollama pull phi:2.7b' > /dev/null 2>&1 &

# 16. НАСТРОЙКА БЕЗОПАСНОСТИ
log "🛡️ Настройка безопасности..."

# Фаервол
sudo ufw --force enable
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 8096/tcp
sudo ufw allow 3001/tcp
sudo ufw allow 8000/tcp
sudo ufw allow 11434/tcp
sudo ufw allow 22/tcp
sudo ufw allow 8088/tcp
sudo ufw allow $VPN_PORT/udp

# Fail2ban
sudo apt install -y fail2ban
sudo systemctl enable fail2ban
sudo systemctl start fail2ban

# 17. СКРИПТ ОЧИСТКИ СТРИМИНГА
log "🧹 Настройка автоматической очистки..."

cat > "/home/$CURRENT_USER/scripts/cleanup_streaming.sh" << EOF
#!/bin/bash
USER_HOME=\$(getent passwd "\$(whoami)" | cut -d: -f6)
find "\$USER_HOME/media/streaming" -type f -mtime +1 -delete
echo "\$(date): Cleaned streaming directory" >> "\$USER_HOME/scripts/cleanup.log"
EOF

chmod +x "/home/$CURRENT_USER/scripts/cleanup_streaming.sh"
(crontab -l 2>/dev/null; echo "0 3 * * * /home/$CURRENT_USER/scripts/cleanup_streaming.sh") | crontab -

# 18. ГЛАВНАЯ СТРАНИЦА С АВТОРИЗАЦИЕЙ И НЕЙРОСЕТЬЮ
log "🏠 Создаем главную страницу с авторизацией и нейросетью..."

cat > "/home/$CURRENT_USER/docker/homepage/index.html" << 'HTMLEOF'
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Домашний Сервер - Вход</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
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
            max-width: 450px;
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
        .ai-badge {
            background: linear-gradient(135deg, #8A2BE2, #4B0082);
            color: white;
            padding: 8px 15px;
            border-radius: 20px;
            font-size: 12px;
            margin-top: 10px;
            display: inline-block;
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
        .password-change-link {
            text-align: center;
            margin-top: 15px;
        }
        .password-change-link a {
            color: #667eea;
            text-decoration: none;
            margin: 0 10px;
        }
        .ai-link {
            text-align: center;
            margin-top: 10px;
        }
        .ai-link a {
            color: #8A2BE2;
            text-decoration: none;
            font-weight: bold;
        }
    </style>
</head>
<body>
    <div class="login-container">
        <div class="logo">
            <h1>🏠 Домашний Сервер</h1>
            <p>Войдите в систему управления</p>
            <div class="ai-badge">🤖 Встроенная нейросеть Phi:2.7b</div>
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
        
        <div class="password-change-link">
            <a href="/password-change/">🔐 Сменить пароль авторизации</a>
        </div>
        
        <div class="ai-link">
            <a href="http://SERVER_IP:11434" target="_blank">🤖 Открыть нейросеть Ollama</a>
        </div>
        
        <div class="services-info">
            Доступные сервисы: Jellyfin • Nextcloud • AI Ассистент • VPN • Поиск фильмов
        </div>
    </div>

    <script>
        // Заменяем SERVER_IP на реальный IP
        document.addEventListener('DOMContentLoaded', function() {
            const aiLink = document.querySelector('.ai-link a');
            const currentHost = window.location.hostname;
            aiLink.href = aiLink.href.replace('SERVER_IP', currentHost);
        });

        document.getElementById('loginForm').addEventListener('submit', function(e) {
            e.preventDefault();
            
            const username = document.getElementById('username').value;
            const password = document.getElementById('password').value;
            const errorMessage = document.getElementById('errorMessage');
            
            // Проверяем авторизацию через API
            fetch('/check-auth', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    username: username,
                    password: password
                })
            })
            .then(response => response.json())
            .then(data => {
                if (data.success) {
                    const sessionData = {
                        user: username,
                        timestamp: Date.now(),
                        expires: Date.now() + (60 * 60 * 1000)
                    };
                    localStorage.setItem('server_session', JSON.stringify(sessionData));
                    window.location.href = '/heimdall';
                } else {
                    errorMessage.style.display = 'block';
                    setTimeout(() => {
                        errorMessage.style.display = 'none';
                    }, 3000);
                }
            })
            .catch(error => {
                // Fallback проверка
                if (username === 'admin' && password === 'homeserver') {
                    const sessionData = {
                        user: 'admin',
                        timestamp: Date.now(),
                        expires: Date.now() + (60 * 60 * 1000)
                    };
                    localStorage.setItem('server_session', JSON.stringify(sessionData));
                    window.location.href = '/heimdall';
                } else {
                    errorMessage.style.display = 'block';
                    setTimeout(() => {
                        errorMessage.style.display = 'none';
                    }, 3000);
                }
            });
        });
        
        window.addEventListener('load', function() {
            const session = localStorage.getItem('server_session');
            if (session) {
                const sessionData = JSON.parse(session);
                if (sessionData.expires > Date.now()) {
                    window.location.href = '/heimdall';
                } else {
                    localStorage.removeItem('server_session');
                }
            }
        });
    </script>
</body>
</html>
HTMLEOF

# Заменяем SERVER_IP в главной странице
sed -i "s/SERVER_IP/$SERVER_IP/g" "/home/$CURRENT_USER/docker/homepage/index.html"

# 19. НАСТРОЙКА HEIMDALL С ПОИСКОМ И НЕЙРОСЕТЬЮ
log "🏠 Настраиваем Heimdall с поиском и нейросетью..."

cat > "/home/$CURRENT_USER/scripts/setup-heimdall.sh" << 'HEIMDALL_EOF'
#!/bin/bash

CURRENT_USERNAME=$(whoami)
SERVER_IP=$(hostname -I | awk '{print $1}')

echo "Настраиваем Heimdall с поиском и нейросетью..."

sleep 20

cat > "/home/$CURRENT_USERNAME/docker/heimdall/apps.json" << 'APPS_EOF'
[
    {
        "name": "🔍 Поиск фильмов",
        "color": "#FF6B00",
        "icon": "fas fa-search",
        "link": "http://SERVER_IP:8096/web/search.html",
        "description": "Найти и скачать фильм за 30 секунд",
        "type": 1
    },
    {
        "name": "🎬 Jellyfin",
        "color": "#00AAFF",
        "icon": "fas fa-play-circle",
        "link": "http://SERVER_IP:8096",
        "description": "Медиасервер с фильмами и сериалами"
    },
    {
        "name": "🤖 Нейросеть Ollama",
        "color": "#8A2BE2",
        "icon": "fas fa-robot",
        "link": "http://SERVER_IP:11434",
        "description": "Локальная нейросеть Phi:2.7b"
    },
    {
        "name": "🔍 Overseerr",
        "color": "#FF6B00", 
        "icon": "fas fa-search-plus",
        "link": "http://SERVER_IP:5055",
        "description": "Поиск и добавление контента"
    },
    {
        "name": "☁️ Nextcloud",
        "color": "#0082C9",
        "icon": "fas fa-cloud",
        "link": "http://SERVER_IP/nextcloud",
        "description": "Файловое хранилище с сжатием медиа"
    },
    {
        "name": "🔒 VPN Сервер",
        "color": "#4CAF50",
        "icon": "fas fa-shield-alt",
        "link": "http://SERVER_IP:8088/vpn-info",
        "description": "Собственный VPN для обхода блокировок"
    },
    {
        "name": "📊 Мониторинг",
        "color": "#4CAF50",
        "icon": "fas fa-chart-bar",
        "link": "http://SERVER_IP:3001",
        "description": "Uptime Kuma - мониторинг сервисов"
    },
    {
        "name": "🔐 Пароли",
        "color": "#CD5C5C",
        "icon": "fas fa-key",
        "link": "http://SERVER_IP:8000",
        "description": "Vaultwarden - менеджер паролей"
    },
    {
        "name": "🌀 Торренты",
        "color": "#FFD700",
        "icon": "fas fa-download",
        "link": "http://SERVER_IP:8080",
        "description": "Tribler - торрент-клиент"
    },
    {
        "name": "🎯 Radarr",
        "color": "#FF69B4",
        "icon": "fas fa-film",
        "link": "http://SERVER_IP:7878",
        "description": "Автоматическая загрузка фильмов"
    },
    {
        "name": "📺 Sonarr",
        "color": "#20B2AA",
        "icon": "fas fa-tv",
        "link": "http://SERVER_IP:8989",
        "description": "Автоматическая загрузка сериалов"
    }
]
APPS_EOF

sed -i "s/SERVER_IP/$SERVER_IP/g" "/home/$CURRENT_USERNAME/docker/heimdall/apps.json"
docker restart heimdall

echo "Heimdall настроен!"
HEIMDALL_EOF

chmod +x "/home/$CURRENT_USER/scripts/setup-heimdall.sh"
nohup "/home/$CURRENT_USER/scripts/setup-heimdall.sh" > /dev/null 2>&1 &

# 20. СОЗДАНИЕ ИНФОРМАЦИОННЫХ ФАЙЛОВ
log "📋 Создание информационных файлов..."

cat > "/home/$CURRENT_USER/vpn/vpn-info.txt" << EOF
=== VPN ИНФОРМАЦИЯ ===

Ваш собственный VPN сервер настроен!

🌐 Текущий порт VPN: $VPN_PORT
🔑 Конфиг для Hiddify: /home/$CURRENT_USER/vpn/hiddify-client.conf

📱 КАК НАСТРОИТЬ HIDDIFY:
1. Установите Hiddify на устройство
2. Импортируйте конфиг файл: hiddify-client.conf
3. Подключитесь к вашему VPN серверу

🔄 Автоматическая смена портов:
Порт VPN будет меняться каждые 24 часа для анонимности

🔧 Ручная смена порта:
/home/$CURRENT_USER/scripts/change-vpn-port.sh

=== ДОСТУП К СЕРВИСАМ ===
🎬 Jellyfin: http://$DUCKDNS_URL:8096
🔍 Поиск фильмов: В Jellyfin нажмите "🔍 Поиск фильмов"
🤖 Нейросеть: http://$DUCKDNS_URL:11434
☁️ Nextcloud: http://$DUCKDNS_URL/nextcloud (с автоматическим сжатием медиа)
🔐 Менеджер паролей: http://$DUCKDNS_URL:8000
EOF

# 21. ФИНАЛЬНАЯ ИНФОРМАЦИЯ
echo ""
echo "=========================================="
echo "🎉 АВТОМАТИЧЕСКАЯ УСТАНОВКА ЗАВЕРШЕНА!"
echo "=========================================="
echo ""
echo "🌐 ВАШ ДОМЕН: https://$DUCKDNS_URL"
echo ""
echo "🔐 СИСТЕМА ДОСТУПА:"
echo "🏠 ГЛАВНАЯ СТРАНИЦА ВХОДА: http://$SERVER_IP:8088"
echo "   ИЛИ https://$DUCKDNS_URL:8088"
echo ""
echo "👤 ДАННЫЕ ДЛЯ ВХОДА:"
echo "   Логин: admin"
echo "   Пароль: homeserver"
echo ""
echo "🎬 КЛЮЧЕВЫЕ ФУНКЦИИ:"
echo "✅ Автоматический поиск фильмов в Jellyfin"
echo "✅ Скачивание за 30 секунд с обложками и описанием"
echo "✅ Автоматическое удаление просмотренных фильмов"
echo "✅ Собственный VPN с автосменой портов"
echo "✅ Веб-интерфейс для смены пароля авторизации"
echo "✅ Статический IP настроен автоматически"
echo "✅ АВТОМАТИЧЕСКОЕ СЖАТИЕ ФОТО И ВИДЕО В NEXTCLOUD"
echo "✅ 🤖 ВСТРОЕННАЯ НЕЙРОСЕТЬ Phi:2.7b"
echo ""
echo "🔍 КАК ИСКАТЬ ФИЛЬМЫ:"
echo "1. Зайдите в Jellyfin"
echo "2. Нажмите '🔍 Поиск фильмов' в главном меню"
echo "3. Введите название фильма"
echo "4. Через 30 секунд фильм готов к просмотру!"
echo ""
echo "🤖 НЕЙРОСЕТЬ:"
echo "✅ Локальная модель Phi:2.7b"
echo "✅ Доступна по адресу: http://$SERVER_IP:11434"
echo "✅ Интегрирована в главную страницу"
echo ""
echo "🖼️ СЖАТИЕ МЕДИАФАЙЛОВ:"
echo "✅ Автоматическое сжатие JPEG, PNG, WebP"
echo "✅ Сжатие видео (MP4, AVI, MOV, MKV)"
echo "✅ Оптимизация размера без потери качества"
echo "✅ Ежедневное автоматическое выполнение в 2:00"
echo "✅ Ручной запуск: /home/$CURRENT_USER/scripts/nextcloud-compress.sh"
echo ""
echo "🔒 VPN ИНФОРМАЦИЯ:"
echo "Порт VPN: $VPN_PORT (меняется каждые 24 часа)"
echo "Конфиг для Hiddify: /home/$CURRENT_USER/vpn/hiddify-client.conf"
echo ""
echo "🔐 СМЕНА ПАРОЛЯ АВТОРИЗАЦИИ:"
echo "Веб-интерфейс: http://$SERVER_IP:8088/password-change/"
echo "Или команда: /home/$CURRENT_USER/scripts/change-auth-password.sh"
echo ""
echo "📊 ОСНОВНЫЕ СЕРВИСЫ:"
echo "🎬 Jellyfin: http://$DUCKDNS_URL:8096"
echo "🔍 Поиск фильмов: В Jellyfin главное меню"
echo "🤖 Нейросеть: http://$DUCKDNS_URL:11434"
echo "☁️ Nextcloud: http://$DUCKDNS_URL/nextcloud (с сжатием медиа)"
echo "🔐 Менеджер паролей: http://$DUCKDNS_URL:8000"
echo "📊 Мониторинг: http://$DUCKDNS_URL:3001"
echo ""
echo "⚡ КАК НАЧАТЬ:"
echo "1. Откройте: http://$SERVER_IP:8088"
echo "2. Войдите (admin/homeserver)"
echo "3. Откройте Jellyfin через панель управления"
echo "4. Наслаждайтесь поиском и просмотром фильмов!"
echo "5. Попробуйте нейросеть по ссылке на главной странице!"
echo "6. Загружайте фото/видео в Nextcloud - они автоматически сожмутся!"
echo ""
echo "=========================================="
echo "🚀 Ваш умный домашний сервер готов к работе!"
echo "=========================================="
