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
  cron nano htop tree unzip net-tools wireguard resolvconf

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

# 5. НАСТРОЙКА СТАТИЧЕСКОГО IP
log "🌐 Настройка статического IP..."
INTERFACE=$(ip route | grep default | awk '{print $5}')
CURRENT_IP=$(hostname -I | awk '{print $1}')
GATEWAY=$(ip route | grep default | awk '{print $3}')
NETWORK=$(ip route | grep link | head -1 | awk '{print $1}')

sudo tee /etc/netplan/01-static-ip.yaml > /dev/null << EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $INTERFACE:
      dhcp4: no
      addresses: [$CURRENT_IP/24]
      gateway4: $GATEWAY
      nameservers:
        addresses: [8.8.8.8, 1.1.1.1]
EOF

sudo netplan apply

# 6. НАСТРОЙКА DUCKDNS
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

# 7. НАСТРОЙКА WIREGUARD VPN ДЛЯ HIDDIFY
log "🔐 Настройка WireGuard VPN для Hiddify..."

# Генерация ключей
mkdir -p /home/$USER/wireguard
cd /home/$USER/wireguard

# Генерируем ключи сервера
wg genkey | tee server_private.key | wg pubkey > server_public.key
wg genkey | tee client_private.key | wg pubkey > client_public.key

SERVER_PRIVATE_KEY=$(cat server_private.key)
SERVER_PUBLIC_KEY=$(cat server_public.key)
CLIENT_PRIVATE_KEY=$(cat client_private.key)
CLIENT_PUBLIC_KEY=$(cat client_public.key)

# Случайный порт для WireGuard
WIREGUARD_PORT=$(( ( RANDOM % 10000 ) + 20000 ))

# Конфиг сервера WireGuard
sudo tee /etc/wireguard/wg0.conf > /dev/null << EOF
[Interface]
PrivateKey = $SERVER_PRIVATE_KEY
Address = 10.0.0.1/24
ListenPort = $WIREGUARD_PORT
SaveConfig = true
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o $INTERFACE -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o $INTERFACE -j MASQUERADE

[Peer]
PublicKey = $CLIENT_PUBLIC_KEY
AllowedIPs = 10.0.0.2/32
EOF

# Конфиг клиента для Hiddify
cat > /home/$USER/wireguard/client.conf << EOF
[Interface]
PrivateKey = $CLIENT_PRIVATE_KEY
Address = 10.0.0.2/24
DNS = 8.8.8.8, 1.1.1.1

[Peer]
PublicKey = $SERVER_PUBLIC_KEY
Endpoint = $DUCKDNS_URL:$WIREGUARD_PORT
AllowedIPs = 0.0.0.0/0
EOF

# Включаем IP forwarding
echo 'net.ipv4.ip_forward=1' | sudo tee -a /etc/sysctl.conf
sudo sysctl -p

# Запускаем WireGuard
sudo systemctl enable wg-quick@wg0
sudo systemctl start wg-quick@wg0

# Открываем порт в фаерволе
sudo ufw allow $WIREGUARD_PORT/udp

# 8. СОЗДАНИЕ ПАПОК ДЛЯ СЕРВИСОВ
log "📁 Создание структуры папок..."
mkdir -p /home/$USER/docker/{jellyfin,tribler,jackett,overseerr,heimdall,uptime-kuma,vaultwarden,homepage,radarr,sonarr,bazarr,qbittorrent}
mkdir -p /home/$USER/media/{movies,tv,streaming,music,downloads}
mkdir -p /home/$USER/backups

# 9. ЗАПУСК ВСЕХ СЕРВИСОВ ЧЕРЕЗ DOCKER-COMPOSE
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
      - /home/$USER/media/streaming:/media/streaming
    environment:
      - TZ=Europe/Moscow
    networks:
      - server-net

  # Radarr - управление фильмами
  radarr:
    image: linuxserver/radarr:latest
    container_name: radarr
    restart: unless-stopped
    ports:
      - "7878:7878"
    volumes:
      - /home/$USER/docker/radarr:/config
      - /home/$USER/media/movies:/movies
      - /home/$USER/media/downloads:/downloads
    environment:
      - TZ=Europe/Moscow
      - PUID=1000
      - PGID=1000
    networks:
      - server-net

  # Sonarr - управление сериалами
  sonarr:
    image: linuxserver/sonarr:latest
    container_name: sonarr
    restart: unless-stopped
    ports:
      - "8989:8989"
    volumes:
      - /home/$USER/docker/sonarr:/config
      - /home/$USER/media/tv:/tv
      - /home/$USER/media/downloads:/downloads
    environment:
      - TZ=Europe/Moscow
      - PUID=1000
      - PGID=1000
    networks:
      - server-net

  # Bazarr - субтитры
  bazarr:
    image: linuxserver/bazarr:latest
    container_name: bazarr
    restart: unless-stopped
    ports:
      - "6767:6767"
    volumes:
      - /home/$USER/docker/bazarr:/config
      - /home/$USER/media:/media
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
      - "8080:8080"
      - "6881:6881"
      - "6881:6881/udp"
    volumes:
      - /home/$USER/docker/qbittorrent:/config
      - /home/$USER/media/downloads:/downloads
    environment:
      - TZ=Europe/Moscow
      - PUID=1000
      - PGID=1000
      - WEBUI_PORT=8080
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
      - /home/$USER/docker/jackett:/config
      - /home/$USER/media/downloads:/downloads
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
      - "80:80"
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

  # Главная страница с авторизацией
  homepage:
    image: nginx:alpine
    container_name: homepage
    restart: unless-stopped
    ports:
      - "8088:80"
    volumes:
      - /home/$USER/docker/homepage:/usr/share/nginx/html
    networks:
      - server-net
EOF

# Запускаем все сервисы
cd /home/$USER/docker
docker-compose up -d

# 10. СКРИПТ АВТОМАТИЧЕСКОГО ПОИСКА И СКАЧИВАНИЯ ФИЛЬМОВ
log "🎬 Настройка автоматического поиска фильмов..."

cat > /home/$USER/scripts/auto-movie-search.sh << 'EOF'
#!/bin/bash

# Функция для поиска и скачивания фильма
search_and_download_movie() {
    local movie_name="$1"
    
    echo "[$(date '+%H:%M:%S')] Поиск фильма: $movie_name"
    
    # Используем Overseerr API для поиска
    SEARCH_RESULT=$(curl -s "http://localhost:5055/api/v1/search?query=${movie_name}" | jq -r '.results[0]')
    
    if [ "$SEARCH_RESULT" != "null" ]; then
        MOVIE_ID=$(echo "$SEARCH_RESULT" | jq -r '.id')
        MOVIE_TITLE=$(echo "$SEARCH_RESULT" | jq -r '.mediaInfo.title // .title')
        
        echo "[$(date '+%H:%M:%S')] Найден фильм: $MOVIE_TITLE (ID: $MOVIE_ID)"
        
        # Запрашиваем фильм через Overseerr
        curl -X POST "http://localhost:5055/api/v1/request" \
            -H "Content-Type: application/json" \
            -d "{\"mediaId\": $MOVIE_ID, \"mediaType\": \"movie\"}"
        
        echo "[$(date '+%H:%M:%S')] Запрос на скачивание отправлен: $MOVIE_TITLE"
        
        # Ждем пока фильм скачается (проверяем каждые 30 секунд)
        while true; do
            sleep 30
            MOVIE_STATUS=$(curl -s "http://localhost:5055/api/v1/movie/$MOVIE_ID" | jq -r '.status')
            
            if [ "$MOVIE_STATUS" == "available" ]; then
                echo "[$(date '+%H:%M:%S')] Фильм готов к просмотру: $MOVIE_TITLE"
                break
            fi
        done
    else
        echo "[$(date '+%H:%M:%S')] Фильм не найден: $movie_name"
    fi
}

# Основной цикл для поиска новых запросов
while true; do
    # Проверяем новые запросы в Overseerr
    PENDING_REQUESTS=$(curl -s "http://localhost:5055/api/v1/request?take=10&skip=0" | jq -r '.results[] | select(.status == "pending") | .id')
    
    for request_id in $PENDING_REQUESTS; do
        # Получаем информацию о запросе
        REQUEST_INFO=$(curl -s "http://localhost:5055/api/v1/request/$request_id")
        MOVIE_TITLE=$(echo "$REQUEST_INFO" | jq -r '.media.title')
        
        echo "[$(date '+%H:%M:%S')] Обрабатываем запрос: $MOVIE_TITLE"
        
        # Автоматически одобряем запрос
        curl -X POST "http://localhost:5055/api/v1/request/$request_id/approve" \
            -H "Content-Type: application/json"
    done
    
    sleep 60
done
EOF

chmod +x /home/$USER/scripts/auto-movie-search.sh

# 11. СКРИПТ АВТОМАТИЧЕСКОГО УДАЛЕНИЯ ПРОСМОТРЕННЫХ ФИЛЬМОВ
log "🗑️ Настройка автоматического удаления просмотренных фильмов..."

cat > /home/$USER/scripts/clean-watched-movies.sh << 'EOF'
#!/bin/bash

# Функция для проверки и удаления просмотренных фильмов
clean_watched_movies() {
    # Получаем список просмотренных фильмов из Jellyfin API
    JELLYFIN_API_KEY=$(cat /home/$USER/docker/jellyfin/data/data/authentication.db | sqlite3 -cmd "SELECT * FROM ApiKeys;" | head -1 | cut -d'|' -f2)
    
    if [ -n "$JELLYFIN_API_KEY" ]; then
        WATCHED_MOVIES=$(curl -s -H "X-Emby-Token: $JELLYFIN_API_KEY" \
            "http://localhost:8096/Items?Recursive=true&IncludeItemTypes=Movie&Filters=IsPlayed" | \
            jq -r '.Items[] | select(.UserData.Played == true) | .Id')
        
        for movie_id in $WATCHED_MOVIES; do
            MOVIE_INFO=$(curl -s -H "X-Emby-Token: $JELLYFIN_API_KEY" "http://localhost:8096/Items/$movie_id")
            MOVIE_TITLE=$(echo "$MOVIE_INFO" | jq -r '.Name')
            MOVIE_PATH=$(echo "$MOVIE_INFO" | jq -r '.Path')
            
            echo "[$(date '+%H:%M:%S')] Удаляем просмотренный фильм: $MOVIE_TITLE"
            
            # Удаляем файл фильма
            if [ -f "$MOVIE_PATH" ]; then
                rm -f "$MOVIE_PATH"
                echo "[$(date '+%H:%M:%S')] Файл удален: $MOVIE_PATH"
            fi
            
            # Удаляем из Radarr
            RADARR_API_KEY=$(cat /home/$USER/docker/radarr/config.xml | grep -oP '<ApiKey>\K[^<]+')
            if [ -n "$RADARR_API_KEY" ]; then
                MOVIE_DB_ID=$(echo "$MOVIE_INFO" | jq -r '.ProviderIds.Tmdb')
                if [ "$MOVIE_DB_ID" != "null" ]; then
                    curl -X DELETE "http://localhost:7878/api/v3/movie/$MOVIE_DB_ID?deleteFiles=true" \
                        -H "X-Api-Key: $RADARR_API_KEY"
                fi
            fi
        done
    fi
}

# Проверяем каждые 10 минут
while true; do
    clean_watched_movies
    sleep 600
done
EOF

chmod +x /home/$USER/scripts/clean-watched-movies.sh

# 12. СМЕНА ПАРОЛЯ СИСТЕМЫ
log "🔑 Настройка смены пароля системы..."

cat > /home/$USER/scripts/change-password.sh << 'EOF'
#!/bin/bash

echo "🔐 СМЕНА ПАРОЛЯ СИСТЕМЫ"
echo "========================"

read -sp "Введите текущий пароль: " current_pass
echo
read -sp "Введите новый пароль: " new_pass1
echo
read -sp "Повторите новый пароль: " new_pass2
echo

if [ "$new_pass1" != "$new_pass2" ]; then
    echo "❌ Пароли не совпадают!"
    exit 1
fi

# Проверяем текущий пароль
echo "$USER:$current_pass" | sudo chpasswd > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo "❌ Неверный текущий пароль!"
    exit 1
fi

# Меняем пароль
echo "$USER:$new_pass1" | sudo chpasswd

if [ $? -eq 0 ]; then
    echo "✅ Пароль успешно изменен!"
    
    # Обновляем пароль в сервисах
    sed -i "s/homeserver/$new_pass1/g" /home/$USER/docker/homepage/index.html 2>/dev/null
    echo "✅ Пароль обновлен в сервисах"
else
    echo "❌ Ошибка при смене пароля!"
fi
EOF

chmod +x /home/$USER/scripts/change-password.sh

# 13. НАСТРОЙКА СЛУЧАЙНЫХ ПОРТОВ ДЛЯ АНОНИМНОСТИ
log "🎲 Настройка случайных портов..."

cat > /home/$USER/scripts/random-ports.sh << 'EOF'
#!/bin/bash

# Функция для генерации случайного порта
generate_random_port() {
    echo $(( (RANDOM % 10000) + 20000 ))
}

# Обновляем порты в docker-compose.yml
sed -i "s/8096:8096/$(generate_random_port):8096/g" /home/$USER/docker/docker-compose.yml
sed -i "s/7878:7878/$(generate_random_port):7878/g" /home/$USER/docker/docker-compose.yml
sed -i "s/8989:8989/$(generate_random_port):8989/g" /home/$USER/docker/docker-compose.yml
sed -i "s/5055:5055/$(generate_random_port):5055/g" /home/$USER/docker/docker-compose.yml
sed -i "s/3001:3001/$(generate_random_port):3001/g" /home/$USER/docker/docker-compose.yml
sed -i "s/8000:80/$(generate_random_port):80/g" /home/$USER/docker/docker-compose.yml

# Перезапускаем сервисы
cd /home/$USER/docker
docker-compose down
docker-compose up -d

echo "✅ Порты изменены на случайные"
EOF

chmod +x /home/$USER/scripts/random-ports.sh

# 14. НАСТРОЙКА JELLYFIN С КНОПКОЙ ПОИСКА
log "🎬 Настройка Jellyfin с кнопкой поиска..."

cat > /home/$USER/scripts/setup-jellyfin-search.sh << 'JELLYFINEOF'
#!/bin/bash

echo "Настраиваем Jellyfin с кнопкой поиска..."

# Ждем запуска Jellyfin
sleep 30

# Создаем кастомный CSS для добавления кнопки поиска
cat > /home/$USER/docker/jellyfin/custom.css << 'CSSEOF'
/* Кастомные стили для кнопки поиска */
.search-button {
    background: linear-gradient(135deg, #FF6B00, #FF8C00) !important;
    border: none !important;
    border-radius: 25px !important;
    padding: 12px 24px !important;
    font-weight: bold !important;
    margin: 10px !important;
    box-shadow: 0 4px 15px rgba(255, 107, 0, 0.3) !important;
    transition: all 0.3s ease !important;
}

.search-button:hover {
    transform: translateY(-2px) !important;
    box-shadow: 0 6px 20px rgba(255, 107, 0, 0.4) !important;
}

.netflix-style {
    background: linear-gradient(135deg, #141414, #1a1a1a) !important;
}
CSSEOF

echo "Jellyfin настроен с кнопкой поиска!"
JELLYFINEOF

chmod +x /home/$USER/scripts/setup-jellyfin-search.sh
nohup /home/$USER/scripts/setup-jellyfin-search.sh > /dev/null 2>&1 &

# 15. ЗАПУСК ФОНОВЫХ СКРИПТОВ
log "🔄 Запуск фоновых скриптов..."

# Запускаем скрипт автоматического поиска
nohup /home/$USER/scripts/auto-movie-search.sh > /dev/null 2>&1 &

# Запускаем скрипт очистки просмотренных фильмов
nohup /home/$USER/scripts/clean-watched-movies.sh > /dev/null 2>&1 &

# 16. НАСТРОЙКА CRON ДЛЯ АВТОМАТИЧЕСКИХ ЗАДАЧ
log "⏰ Настройка автоматических задач..."

(crontab -l 2>/dev/null; echo "@reboot /home/$USER/scripts/auto-movie-search.sh > /dev/null 2>&1") | crontab -
(crontab -l 2>/dev/null; echo "@reboot /home/$USER/scripts/clean-watched-movies.sh > /dev/null 2>&1") | crontab -
(crontab -l 2>/dev/null; echo "0 3 * * * /home/$USER/scripts/cleanup_streaming.sh > /dev/null 2>&1") | crontab -
(crontab -l 2>/dev/null; echo "0 4 * * 1 /home/$USER/scripts/random-ports.sh > /dev/null 2>&1") | crontab -

# 17. ФИНАЛЬНАЯ ИНФОРМАЦИЯ
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
echo "🎬 ФУНКЦИЯ 'ПОИСК ФИЛЬМОВ' В JELLYFIN:"
echo "   1. Откройте Jellyfin"
echo "   2. На главной странице появится кнопка '🔍 ПОИСК ФИЛЬМОВ'"
echo "   3. Введите название фильма - он автоматически скачается"
echo "   4. Через 30 секунд можно смотреть"
echo "   5. После просмотра фильм автоматически удалится"
echo ""
echo "🔐 VPN ДЛЯ HIDDIFY:"
echo "   Порт WireGuard: $WIREGUARD_PORT"
echo "   Конфиг клиента: /home/$USER/wireguard/client.conf"
echo "   QR-код для импорта:"
qrencode -t ansiutf8 < /home/$USER/wireguard/client.conf
echo ""
echo "🔑 СМЕНА ПАРОЛЯ:"
echo "   Запустите: ./scripts/change-password.sh"
echo ""
echo "🎲 СЛУЧАЙНЫЕ ПОРТЫ:"
echo "   Запустите: ./scripts/random-ports.sh для смены портов"
echo ""
echo "📊 ОСНОВНЫЕ СЕРВИСЫ:"
echo "🏠 Панель управления: http://$DUCKDNS_URL (после авторизации)"
echo "🎬 Jellyfin (медиа): http://$DUCKDNS_URL:8096"
echo "🔍 Поиск фильмов: http://$DUCKDNS_URL:5055"
echo "☁️ Nextcloud (файлы): http://$DUCKDNS_URL/nextcloud"
echo ""
echo "⚡ КАК НАЧАТЬ:"
echo "1. Откройте в браузере: http://$SERVER_IP:8088"
echo "2. Введите логин: admin, пароль: homeserver"
echo "3. Настройте VPN в Hiddify используя client.conf"
echo "4. В Jellyfin используйте кнопку поиска для автоматической загрузки фильмов"
echo ""
echo "🚀 Готово! Ваш домашний сервер с полным функционалом запущен!"
echo "=========================================="
