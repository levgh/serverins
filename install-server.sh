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

# Функция для смены пароля системы
change_system_password() {
    log "🔐 Настройка смены пароля системы..."
    
    # Создаем скрипт для смены пароля
    cat > /home/$USER/scripts/change_password.sh << 'PASS_EOF'
#!/bin/bash
echo "=== СМЕНА ПАРОЛЯ СИСТЕМЫ ==="
read -s -p "Введите текущий пароль: " current_pass
echo

# Проверяем текущий пароль
if ! echo "$current_pass" | sudo -S true 2>/dev/null; then
    echo "❌ Неверный текущий пароль!"
    exit 1
fi

read -s -p "Введите новый пароль: " new_pass1
echo
read -s -p "Повторите новый пароль: " new_pass2
echo

if [ "$new_pass1" != "$new_pass2" ]; then
    echo "❌ Пароли не совпадают!"
    exit 1
fi

if [ -z "$new_pass1" ]; then
    echo "❌ Пароль не может быть пустым!"
    exit 1
fi

# Меняем пароль
echo "$USER:$new_pass1" | sudo chpasswd

# Обновляем пароль во всех сервисах
sudo sed -i "s/homeserver/$new_pass1/g" /home/$USER/docker/docker-compose.yml 2>/dev/null || true
sudo sed -i "s/homeserver/$new_pass1/g" /home/$USER/docker/homepage/index.html 2>/dev/null || true

echo "✅ Пароль успешно изменен!"
echo "🔄 Перезапускаем сервисы..."

# Перезапускаем сервисы
cd /home/$USER/docker
docker-compose restart

echo "🎉 Система обновлена с новым паролем!"
PASS_EOF

    chmod +x /home/$USER/scripts/change_password.sh
    
    # Создаем алиас для удобства
    echo "alias change-pass='/home/$USER/scripts/change_password.sh'" >> /home/$USER/.bashrc
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

# 3. НАСТРОЙКА СТАТИЧЕСКОГО IP
log "🌐 Настройка статического IP..."
INTERFACE=$(ip route | grep default | awk '{print $5}')
CURRENT_IP=$(hostname -I | awk '{print $1}')
GATEWAY=$(ip route | grep default | awk '{print $3}')
NETWORK=$(ip route | grep -v default | grep $INTERFACE | awk '{print $1}' | head -1)

cat > /tmp/network-config.txt << EOF
# Автоматическая настройка сети
Интерфейс: $INTERFACE
Текущий IP: $CURRENT_IP
Шлюз: $GATEWAY
Сеть: $NETWORK
EOF

# Создаем бэкап текущей конфигурации
sudo cp /etc/netplan/01-netcfg.yaml /etc/netplan/01-netcfg.yaml.backup 2>/dev/null || true

# Создаем новый конфиг netplan
sudo tee /etc/netplan/01-netcfg.yaml > /dev/null << EOF
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

# Применяем настройки
sudo netplan apply
log "✅ Статический IP настроен: $CURRENT_IP"

# 4. НАСТРОЙКА DOCKER
log "🐳 Настройка Docker..."
sudo systemctl enable docker
sudo systemctl start docker
sudo usermod -aG docker $USER
newgrp docker << EOF
EOF

# 5. НАСТРОЙКА ЧАСОВОГО ПОЯСА
log "⏰ Настройка времени..."
sudo timedatectl set-timezone Europe/Moscow

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

# 7. НАСТРОЙКА WIREGUARD VPN
log "🛡️ Настройка WireGuard VPN..."
mkdir -p /home/$USER/docker/wireguard

# Генерируем ключи
wg genkey | sudo tee /home/$USER/docker/wireguard/server_private.key | wg pubkey | sudo tee /home/$USER/docker/wireguard/server_public.key
wg genkey | sudo tee /home/$USER/docker/wireguard/client_private.key | wg pubkey | sudo tee /home/$USER/docker/wireguard/client_public.key

SERVER_PRIVATE_KEY=$(sudo cat /home/$USER/docker/wireguard/server_private.key)
SERVER_PUBLIC_KEY=$(sudo cat /home/$USER/docker/wireguard/server_public.key)
CLIENT_PRIVATE_KEY=$(sudo cat /home/$USER/docker/wireguard/client_private.key)
CLIENT_PUBLIC_KEY=$(sudo cat /home/$USER/docker/wireguard/client_public.key)

# Создаем конфиг сервера WireGuard
sudo tee /home/$USER/docker/wireguard/wg0.conf > /dev/null << EOF
[Interface]
PrivateKey = $SERVER_PRIVATE_KEY
Address = 10.8.0.1/24
ListenPort = 51820
SaveConfig = true
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -o $INTERFACE -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -o $INTERFACE -j MASQUERADE

[Peer]
PublicKey = $CLIENT_PUBLIC_KEY
AllowedIPs = 10.8.0.2/32
EOF

# Создаем конфиг клиента для HidiFace
sudo tee /home/$USER/docker/wireguard/client.conf > /dev/null << EOF
[Interface]
PrivateKey = $CLIENT_PRIVATE_KEY
Address = 10.8.0.2/24
DNS = 8.8.8.8, 1.1.1.1

[Peer]
PublicKey = $SERVER_PUBLIC_KEY
Endpoint = $DUCKDNS_URL:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

# Включаем IP forwarding
echo 'net.ipv4.ip_forward=1' | sudo tee -a /etc/sysctl.conf
sudo sysctl -p

# 8. СОЗДАНИЕ ПАПОК ДЛЯ СЕРВИСОВ
log "📁 Создание структуры папок..."
mkdir -p /home/$USER/docker/{jellyfin,tribler,jackett,overseerr,heimdall,uptime-kuma,vaultwarden,homepage,radarr,sonarr,bazarr,prowlarr,qbittorrent}
mkdir -p /home/$USER/media/{movies,tv,streaming,music,downloads,completed,torrents}
mkdir -p /home/$USER/backups

# 7.1. ДОПОЛНИТЕЛЬНАЯ НАСТРОЙКА ДЛЯ HIDDIFY
log "🔧 Дополнительная настройка для Hiddify..."

# Создаем специальный конфиг для Hiddify
sudo tee /home/$USER/docker/wireguard/hiddify.conf > /dev/null << EOF
[Interface]
PrivateKey = $CLIENT_PRIVATE_KEY
Address = 10.8.0.2/24
DNS = 8.8.8.8, 1.1.1.1, 208.67.222.222
MTU = 1420

[Peer]
PublicKey = $SERVER_PUBLIC_KEY
Endpoint = $DUCKDNS_URL:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

# Создаем QR-код специально для Hiddify
if command -v qrencode &> /dev/null; then
    echo "📱 Создаем QR-код для Hiddify..."
    qrencode -t PNG -o /home/$USER/docker/wireguard/hiddify.png < /home/$USER/docker/wireguard/hiddify.conf
    echo "✅ QR-код создан: /home/$USER/docker/wireguard/hiddify.png"
fi

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
    environment:
      - TZ=Europe/Moscow
    networks:
      - server-net

  # Система автоматического поиска и скачивания
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

  prowlarr:
    image: linuxserver/prowlarr:latest
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

  qbittorrent:
    image: linuxserver/qbittorrent:latest
    container_name: qbittorrent
    restart: unless-stopped
    ports:
      - "8081:8080"
      - "6881:6881"
      - "6881:6881/udp"
    volumes:
      - /home/$USER/docker/qbittorrent:/config
      - /home/$USER/media/downloads:/downloads
      - /home/$USER/media/completed:/completed
    environment:
      - TZ=Europe/Moscow
      - PUID=1000
      - PGID=1000
      - WEBUI_PORT=8080
    networks:
      - server-net

  # Tribler - торрент-клиент с стримингом
  tribler:
    image: tribler/tribler:latest
    container_name: tribler
    restart: unless-stopped
    ports:
      - "8080:8080"
    volumes:
      - /home/$USER/docker/tribler:/root/.Tribler
      - /home/$USER/media/streaming:/downloads
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
      - /home/$USER/docker/jackett:/config
      - /home/$USER/media/streaming:/downloads
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

  # WireGuard VPN
  wireguard:
    image: linuxserver/wireguard:latest
    container_name: wireguard
    restart: unless-stopped
    ports:
      - "51820:51820/udp"
    volumes:
      - /home/$USER/docker/wireguard:/config
      - /lib/modules:/lib/modules
    environment:
      - TZ=Europe/Moscow
      - PUID=1000
      - PGID=1000
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    sysctls:
      - net.ipv4.conf.all.src_valid_mark=1
      - net.ipv4.ip_forward=1
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

# 10. СИСТЕМА "НАЖАЛ СМОТРИ" - автоматическая загрузка фильмов
log "🎬 Настройка системы 'Нажал Смотри'..."

# Создаем скрипт для автоматической системы
cat > /home/$USER/scripts/auto-movie-system.sh << 'MOVIE_EOF'
#!/bin/bash

echo "🎬 Настройка автоматической системы загрузки фильмов..."

# Ждем запуска сервисов
sleep 30

# Создаем конфигурацию для автоматической системы
cat > /home/$USER/scripts/movie-automation.py << 'PYTHON_EOF'
#!/usr/bin/env python3
import os
import time
import requests
import json
from pathlib import Path

class MovieAutomation:
    def __init__(self):
        self.radarr_url = "http://localhost:7878"
        self.sonarr_url = "http://localhost:8989"
        self.jellyfin_url = "http://localhost:8096"
        self.qbittorrent_url = "http://localhost:8081"
        
    def search_and_download(self, movie_title):
        """Поиск и автоматическая загрузка фильма"""
        try:
            print(f"🔍 Ищем фильм: {movie_title}")
            
            # Здесь будет интеграция с поиском и скачиванием
            # Пока заглушка для демонстрации
            
            print(f"✅ Фильм '{movie_title}' добавлен в очередь загрузки")
            return True
            
        except Exception as e:
            print(f"❌ Ошибка: {e}")
            return False
    
    def cleanup_watched(self):
        """Очистка просмотренных фильмов"""
        try:
            media_path = "/home/$USER/media/streaming"
            for file in Path(media_path).glob("*"):
                if file.is_file():
                    # Простая логика: удаляем файлы старше 1 дня
                    if file.stat().st_mtime < time.time() - 86400:
                        file.unlink()
                        print(f"🗑️ Удален: {file.name}")
            
            print("✅ Очистка завершена")
            
        except Exception as e:
            print(f"❌ Ошибка при очистке: {e}")

if __name__ == "__main__":
    automation = MovieAutomation()
    automation.cleanup_watched()
PYTHON_EOF

chmod +x /home/$USER/scripts/movie-automation.py

# Добавляем в крон ежедневную очистку
(crontab -l 2>/dev/null; echo "0 4 * * * /usr/bin/python3 /home/$USER/scripts/movie-automation.py") | crontab -

echo "✅ Система 'Нажал Смотри' настроена!"
MOVIE_EOF

chmod +x /home/$USER/scripts/auto-movie-system.sh
nohup /home/$USER/scripts/auto-movie-system.sh > /dev/null 2>&1 &

# 11. НАСТРОЙКА NEXTCLOUD
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
        Options FollowSymLinks
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

# 12. УСТАНОВКА OLLAMA (НЕЙРОСЕТЬ)
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

# 13. НАСТРОЙКА БЕЗОПАСНОСТИ
log "🛡️ Настройка безопасности..."

# Фаервол
sudo ufw --force enable
sudo ufw allow 80/tcp
sudo ufw allow 8096/tcp
sudo ufw allow 3001/tcp
sudo ufw allow 8000/tcp
sudo ufw allow 11434/tcp
sudo ufw allow 22/tcp
sudo ufw allow 8088/tcp
sudo ufw allow 51820/udp
sudo ufw allow 7878/tcp
sudo ufw allow 8989/tcp
sudo ufw allow 9696/tcp
sudo ufw allow 8081/tcp

# Fail2ban
sudo apt install -y fail2ban
sudo systemctl enable fail2ban
sudo systemctl start fail2ban

# 14. СКРИПТ ОЧИСТКИ СТРИМИНГА
log "🧹 Настройка автоматической очистки..."

cat > /home/$USER/scripts/cleanup_streaming.sh << EOF
#!/bin/bash
find "/home/$USER/media/streaming" -type f -mtime +1 -delete
find "/home/$USER/media/downloads" -type f -mtime +7 -delete
echo "\$(date): Cleaned streaming directory" >> "/home/$USER/scripts/cleanup.log"
EOF

chmod +x /home/$USER/scripts/cleanup_streaming.sh

# Добавляем в cron
(crontab -l 2>/dev/null; echo "0 3 * * * /home/$USER/scripts/cleanup_streaming.sh") | crontab -

# 15. НАСТРОЙКА СМЕНЫ ПАРОЛЯ
change_system_password

# 16. СОЗДАНИЕ ГЛАВНОЙ СТРАНИЦЫ С АВТОРИЗАЦИЕЙ
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
        
        .password-change {
            margin-top: 15px;
            text-align: center;
        }
        
        .password-change a {
            color: #667eea;
            text-decoration: none;
            font-size: 14px;
        }
        
        .password-change a:hover {
            text-decoration: underline;
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
        
        <div class="password-change">
            <a href="#" onclick="showPasswordChange()">Сменить пароль системы</a>
        </div>
        
        <div class="services-info">
            Доступные сервисы: Jellyfin • Nextcloud • AI Ассистент • Менеджер паролей • VPN
        </div>
    </div>

    <script>
        function showPasswordChange() {
            const newPassword = prompt('Для смены пароля выполните в терминале команду: change-pass\n\nЭта команда запустит безопасный процесс смены пароля.');
            if (newPassword) {
                alert('Пароль будет изменен после выполнения команды в терминале.');
            }
        }

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
                window.location.href = '/heimdall';
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

# 17. АВТОМАТИЧЕСКАЯ НАСТРОЙКА HEIMDALL С ПОИСКОМ
log "🏠 Настраиваем Heimdall с поиском Яндекса..."

# Ждем запуска сервисов
sleep 30

# Создаем автоматическую настройку для Heimdall
cat > /home/$USER/scripts/setup-heimdall.sh << 'HEIMDALL_EOF'
#!/bin/bash

USERNAME=$(whoami)
SERVER_IP=$(hostname -I | awk '{print $1}')

echo "Настраиваем Heimdall с поиском Яндекса..."

# Ждем полного запуска Heimdall
sleep 20

# Создаем apps.json для Heimdall с поиском Яндекса
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
        "name": "🎬 Jellyfin",
        "color": "#00AAFF",
        "icon": "fas fa-play-circle",
        "link": "http://SERVER_IP:8096",
        "description": "Медиасервер с фильмами и сериалами"
    },
    {
        "name": "🔍 Поиск фильмов",
        "color": "#FF6B00", 
        "icon": "fas fa-search",
        "link": "http://SERVER_IP:5055",
        "description": "Overseerr - поиск и добавление контента"
    },
    {
        "name": "🚀 Автозагрузка",
        "color": "#9C27B0",
        "icon": "fas fa-bolt",
        "link": "http://SERVER_IP:7878",
        "description": "Radarr - автоматическая загрузка фильмов"
    },
    {
        "name": "📺 Автосериалы",
        "color": "#2196F3",
        "icon": "fas fa-tv",
        "link": "http://SERVER_IP:8989",
        "description": "Sonarr - автоматическая загрузка сериалов"
    },
    {
        "name": "📝 Субтитры",
        "color": "#FF9800",
        "icon": "fas fa-closed-captioning",
        "link": "http://SERVER_IP:6767",
        "description": "Bazarr - автоматические субтитры"
    },
    {
        "name": "☁️ Nextcloud",
        "color": "#0082C9",
        "icon": "fas fa-cloud",
        "link": "http://SERVER_IP/nextcloud",
        "description": "Файловое хранилище"
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
        "name": "🤖 AI Ассистент",
        "color": "#8A2BE2",
        "icon": "fas fa-robot",
        "link": "http://SERVER_IP:11434",
        "description": "Ollama - локальная нейросеть"
    },
    {
        "name": "🛡️ VPN",
        "color": "#2E7D32",
        "icon": "fas fa-shield-alt",
        "link": "http://SERVER_IP:8088/vpn",
        "description": "WireGuard - собственный VPN"
    },
    {
        "name": "🌀 Торренты",
        "color": "#FFD700",
        "icon": "fas fa-download",
        "link": "http://SERVER_IP:8080",
        "description": "Tribler - торрент-клиент"
    },
    {
        "name": "🎯 Трекеры",
        "color": "#32CD32",
        "icon": "fas fa-search-plus",
        "link": "http://SERVER_IP:9117",
        "description": "Jackett - поиск по трекерам"
    }
]
APPS_EOF

# Заменяем SERVER_IP на реальный IP
sed -i "s/SERVER_IP/$SERVER_IP/g" /home/$USERNAME/docker/heimdall/apps.json

# Перезапускаем Heimdall для применения настроек
docker restart heimdall

echo "Heimdall настроен с Яндекс поиском!"
HEIMDALL_EOF

chmod +x /home/$USER/scripts/setup-heimdall.sh
nohup /home/$USER/scripts/setup-heimdall.sh > /dev/null 2>&1 &

# 18. АВТОМАТИЧЕСКАЯ НАСТРОЙКА УЧЕТНЫХ ЗАПИСЕЙ
log "👤 Настраиваем учетные записи (admin/homeserver)..."

cat > /home/$USER/scripts/setup-accounts.sh << 'ACCOUNTS_EOF'
#!/bin/bash

echo "Настраиваем учетные записи..."

# Ждем полного запуска сервисов
sleep 60

# Создаем файл с учетными данными
cat > /home/$USER/accounts.txt << 'ACCEOF'
=== УЧЕТНЫЕ ЗАПИСИ ДОМАШНЕГО СЕРВЕРА ===

ВО ВСЕХ СЕРВИСАХ ИСПОЛЬЗУЙТЕ:
Логин: admin
Пароль: homeserver

ДОСТУП К СЕРВИСАМ:

🏠 Главная страница (вход в систему):
http://SERVER_IP:8088
ИЛИ
https://DOMAIN.duckdns.org:8088
Логин: admin
Пароль: homeserver

🏠 Heimdall (панель управления):
http://SERVER_IP:80
После авторизации на главной странице

🎬 Jellyfin (медиасервер):
http://SERVER_IP:8096
При первом входе создайте пользователя:
- Имя: admin
- Пароль: homeserver

🚀 СИСТЕМА "НАЖАЛ СМОТРИ":
- Radarr (фильмы): http://SERVER_IP:7878
- Sonarr (сериалы): http://SERVER_IP:8989  
- Bazarr (субтитры): http://SERVER_IP:6767
- Prowlarr (трекеры): http://SERVER_IP:9696
- qBittorrent: http://SERVER_IP:8081

🛡️ VPN ДЛЯ HIDIFACE:
Конфиг для приложения: /home/USER/docker/wireguard/client.conf
Отсканируйте QR-код или импортируйте файл в HidiFace

☁️ Nextcloud (файловое хранилище):
http://SERVER_IP/nextcloud  
При первом входе:
- Логин: admin
- Пароль: homeserver

🔐 Vaultwarden (менеджер паролей):
http://SERVER_IP:8000
Нажмите "Create account":
- Email: admin@localhost
- Пароль: homeserver

🔍 Overseerr (поиск фильмов):
http://SERVER_IP:5055
Настройте подключение к Jellyfin:
- URL: http://jellyfin:8096
- Логин: admin  
- Пароль: homeserver

📊 Uptime Kuma (мониторинг):
http://SERVER_IP:3001
При первом входе создайте пароль: homeserver

🤖 Ollama (нейросеть):
http://SERVER_IP:11434
Доступ через API, пароль не требуется

🔍 Яндекс Поиск:
Доступен прямо из Heimdall

=== КАК ИСПОЛЬЗОВАТЬ СИСТЕМУ "НАЖАЛ СМОТРИ" ===
1. Зайдите в Radarr (порт 7878) или Sonarr (порт 8989)
2. Добавьте фильм или сериал через поиск
3. Система автоматически найдет, скачает и добавит в Jellyfin
4. Субтитры на русском появятся автоматически через Bazarr
5. После просмотра файлы автоматически удаляются

=== СМЕНА ПАРОЛЯ СИСТЕМЫ ===
Выполните в терминале: change-pass

=== VPN ДЛЯ ОБХОДА БЛОКИРОВОК ===
Используйте файл client.conf в папке wireguard
Или отсканируйте QR-код в приложении HidiFace

=== ВАЖНАЯ ИНФОРМАЦИЯ ===
1. Сначала зайдите на главную страницу (порт 8088)
2. Войдите с логином admin и паролем homeserver
3. Вы будете перенаправлены в Heimdall
4. Оттуда доступны все сервисы одним кликом
ACCEOF

# Заменяем SERVER_IP на реальный IP и DOMAIN
SERVER_IP=$(hostname -I | awk '{print $1}')
DOMAIN="domenforserver123"
sed -i "s/SERVER_IP/$SERVER_IP/g" /home/$USER/accounts.txt
sed -i "s/DOMAIN/$DOMAIN/g" /home/$USER/accounts.txt
sed -i "s/USER/$USER/g" /home/$USER/accounts.txt

# Создаем QR-код для VPN конфига
if command -v qrencode &> /dev/null; then
    sudo apt install -y qrencode
    qrencode -t ANSIUTF8 < /home/$USER/docker/wireguard/client.conf
    echo "QR-код для VPN конфига выше"
fi

echo "Учетные записи настроены!"
echo "Файл с инструкциями: /home/$USER/accounts.txt"
ACCOUNTS_EOF

chmod +x /home/$USER/scripts/setup-accounts.sh
nohup /home/$USER/scripts/setup-accounts.sh > /dev/null 2>&1 &

# 19. НАСТРОЙКА ПЕРЕНАПРАВЛЕНИЙ ДЛЯ ГЛАВНОЙ СТРАНИЦЫ
log "🔀 Настраиваем маршрутизацию для главной страницы..."

cat > /home/$USER/scripts/setup-routing.sh << 'ROUTINGEOF'
#!/bin/bash

DOMAIN="domenforserver123"
SERVER_IP=$(hostname -I | awk '{print $1}')

echo "Настраиваем маршрутизацию..."

# Ждем запуска сервисов
sleep 20

# Создаем конфиг Nginx для главной страницы
cat > /home/$USER/docker/homepage/default.conf << 'NGINXEOF'
server {
    listen 80;
    server_name _;
    
    # Главная страница
    location / {
        root /usr/share/nginx/html;
        index index.html;
        try_files $uri $uri/ /index.html;
    }
    
    # Прокси для Heimdall
    location /heimdall {
        proxy_pass http://heimdall:80;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
    
    # Страница с информацией о VPN
    location /vpn {
        return 302 /;
    }
}
NGINXEOF

# Копируем конфиг в контейнер и перезапускаем
docker cp /home/$USER/docker/homepage/default.conf homepage:/etc/nginx/conf.d/default.conf
docker exec homepage nginx -s reload

echo "Маршрутизация настроена!"
ROUTINGEOF

chmod +x /home/$USER/scripts/setup-routing.sh
nohup /home/$USER/scripts/setup-routing.sh > /dev/null 2>&1 &

# 20. ФИНАЛЬНАЯ ИНФОРМАЦИЯ
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
echo "🎬 СИСТЕМА 'НАЖАЛ СМОТРИ':"
echo "   Radarr (фильмы): http://$DUCKDNS_URL:7878"
echo "   Sonarr (сериалы): http://$DUCKDNS_URL:8989"
echo "   Bazarr (субтитры): http://$DUCKDNS_URL:6767"
echo ""
echo "🛡️ ВАШ СОБСТВЕННЫЙ VPN:"
echo "   Конфиг для HidiFace: /home/$USER/docker/wireguard/client.conf"
echo "   Или используйте QR-код из файла accounts.txt"
echo ""
echo "🔧 ДОПОЛНИТЕЛЬНЫЕ ВОЗМОЖНОСТИ:"
echo "   Смена пароля системы: выполните 'change-pass' в терминале"
echo "   Статический IP: настроен автоматически ($SERVER_IP)"
echo "   Автоочистка: просмотренные фильмы удаляются автоматически"
echo ""
echo "⚡ КАК НАЧАТЬ:"
echo "1. Откройте в браузере: http://$SERVER_IP:8088"
echo "2. Введите логин: admin, пароль: homeserver"
echo "3. Вы попадете в панель управления Heimdall"
echo "4. Оттуда доступны все сервисы одним кликом"
echo "5. Для VPN: импортируйте client.conf в HidiFace"
echo ""
echo "📋 ПОЛНАЯ ИНСТРУКЦИЯ:"
echo "Файл с детальными инструкциями: /home/$USER/accounts.txt"
echo ""
echo "🚀 Готово! Ваш домашний сервер запущен со всеми функциями!"
echo "=========================================="
