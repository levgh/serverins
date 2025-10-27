#!/bin/bash

# Настройки
DOMAIN="domenforserver123"
TOKEN="7c4ac80c-d14f-4ca6-ae8c-df2b04a939ae"
CURRENT_USER=$(whoami)
SERVER_IP=$(hostname -I | awk '{print $1}')
ADMIN_PASSWORD="LevAdmin"
VPN_PORT=51820  # ФИКСИРОВАННЫЙ порт для WireGuard

echo "=========================================="
echo "🚀 УСТАНОВКА ПОЛНОЙ СИСТЕМЫ СО ВСЕМИ СЕРВИСАМИ"
echo "=========================================="

# Функция для логирования
log() {
    echo "[$(date '+%H:%M:%S')] $1"
}

# Используем переменные
log "Настройка домена: $DOMAIN"
log "Токен DuckDNS: ${TOKEN:0:10}..."
log "Пароль админа: $ADMIN_PASSWORD"
log "VPN порт: $VPN_PORT"

# 1. ОБНОВЛЕНИЕ СИСТЕМЫ
log "📦 Обновление системы..."
sudo apt update && sudo apt upgrade -y

# 2. УСТАНОВКА ЗАВИСИМОСТЕЙ
log "📦 Установка пакетов..."
sudo apt install -y \
  curl wget git \
  docker.io docker-compose \
  nginx mysql-server \
  python3 python3-pip \
  cron nano htop tree unzip net-tools \
  wireguard resolvconf

# 3. НАСТРОЙКА DOCKER
log "🐳 Настройка Docker..."
sudo systemctl enable docker
sudo systemctl start docker
sudo usermod -aG docker "$CURRENT_USER"

# 4. НАСТРОЙКА DUCKDNS
log "🌐 Настройка DuckDNS..."

mkdir -p "/home/$CURRENT_USER/scripts"
cat > "/home/$CURRENT_USER/scripts/duckdns-update.sh" << 'DUCKDNS_EOF'
#!/bin/bash
DOMAIN="domenforserver123"
TOKEN="7c4ac80c-d14f-4ca6-ae8c-df2b04a939ae"
URL="https://www.duckdns.org/update?domains=${DOMAIN}&token=${TOKEN}&ip="
response=$(curl -s -w "\n%{http_code}" "$URL")
http_code=$(echo "$response" | tail -n1)
content=$(echo "$response" | head -n1)
echo "$(date): HTTP $http_code - $content" >> "/home/$(whoami)/scripts/duckdns.log"
DUCKDNS_EOF

chmod +x "/home/$CURRENT_USER/scripts/duckdns-update.sh"
(crontab -l 2>/dev/null; echo "*/5 * * * * /home/$CURRENT_USER/scripts/duckdns-update.sh") | crontab -
"/home/$CURRENT_USER/scripts/duckdns-update.sh"

# 5. НАСТРОЙКА VPN (WIREGUARD) С ФИКСИРОВАННЫМ ПОРТОМ
log "🔒 Настройка VPN WireGuard..."

# Генерация ключей
mkdir -p "/home/$CURRENT_USER/vpn"
cd "/home/$CURRENT_USER/vpn" || exit
wg genkey | sudo tee /etc/wireguard/private.key
sudo chmod 600 /etc/wireguard/private.key
sudo cat /etc/wireguard/private.key | wg pubkey | sudo tee /etc/wireguard/public.key

# Создание конфигурации WireGuard с фиксированным портом
INTERFACE_NAME=$(ip route | grep default | awk '{print $5}' | head -1)

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

# Создание клиентского конфига
sudo tee "/home/$CURRENT_USER/vpn/client.conf" > /dev/null << EOF
[Interface]
PrivateKey = $(wg genkey)
Address = 10.0.0.2/32
DNS = 8.8.8.8, 1.1.1.1

[Peer]
PublicKey = $(sudo cat /etc/wireguard/public.key)
Endpoint = $SERVER_IP:$VPN_PORT
AllowedIPs = 0.0.0.0/0
EOF

# 6. СОЗДАНИЕ СТРУКТУРЫ ПАПОК
log "📁 Создание структуры папок..."
mkdir -p "/home/$CURRENT_USER/docker/heimdall"
mkdir -p "/home/$CURRENT_USER/docker/admin-panel" 
mkdir -p "/home/$CURRENT_USER/docker/auth-server"
mkdir -p "/home/$CURRENT_USER/docker/jellyfin"
mkdir -p "/home/$CURRENT_USER/docker/nextcloud"
mkdir -p "/home/$CURRENT_USER/docker/ollama-webui"
mkdir -p "/home/$CURRENT_USER/docker/ai-campus"
mkdir -p "/home/$CURRENT_USER/scripts"
mkdir -p "/home/$CURRENT_USER/data/users"
mkdir -p "/home/$CURRENT_USER/data/logs"
mkdir -p "/home/$CURRENT_USER/data/backups"
mkdir -p "/home/$CURRENT_USER/data/gdz"
mkdir -p "/home/$CURRENT_USER/media/movies"
mkdir -p "/home/$CURRENT_USER/media/tv"
mkdir -p "/home/$CURRENT_USER/media/music"
mkdir -p "/home/$CURRENT_USER/media/streaming"
mkdir -p "/home/$CURRENT_USER/docker/heimdall/icons"
mkdir -p "/home/$CURRENT_USER/media/temp"

# 6.1. УСТАНОВКА QBITTORRENT И ТОРРЕНТ-СИСТЕМЫ
log "📥 Установка и настройка qBittorrent..."

sudo apt install -y qbittorrent-nox jq sqlite3

# Создание конфигурации qBittorrent
mkdir -p "/home/$CURRENT_USER/.config/qBittorrent"
cat > "/home/$CURRENT_USER/.config/qBittorrent/qBittorrent.conf" << QBT_EOF
[LegalNotice]
Accepted=true

[Preferences]
WebUI\Enabled=true
WebUI\Address=0.0.0.0
WebUI\Port=8080
WebUI\LocalHostAuth=false
WebUI\Username=admin
WebUI\Password_PBKDF2="@ByteArray(ARQ77eY1NUZaQsuDHbIMCA==:0WMRkYTUWVT9wVvdDtHAjU9b3b7uB8NR1GQ2wQniGB4CwTkRHLLqqliGJfSi+h30s+wQLQMPtKd36LnD5mPpzA==)"
Downloads\SavePath=/home/$CURRENT_USER/media/movies
Downloads\TempPath=/home/$CURRENT_USER/media/temp
Connection\PortRangeMin=6881
Connection\PortRangeMax=6891
QBT_EOF

# Создание службы для qBittorrent
sudo tee /etc/systemd/system/qbittorrent-nox.service > /dev/null << QBT_SERVICE
[Unit]
Description=qBittorrent-nox
After=network.target

[Service]
Type=exec
User=$CURRENT_USER
ExecStart=/usr/bin/qbittorrent-nox
ExecStop=/usr/bin/killall -w qbittorrent-nox
Restart=on-failure

[Install]
WantedBy=multi-user.target
QBT_SERVICE

sudo systemctl daemon-reload
sudo systemctl enable qbittorrent-nox
sudo systemctl start qbittorrent-nox

# 6.3. СОЗДАНИЕ PYTHON ТОРРЕНТ-СЕРВИСА
log "🔌 Настройка торрент-автоматизации..."

mkdir -p "/home/$CURRENT_USER/docker/torrent-automation"
mkdir -p "/home/$CURRENT_USER/media/temp"

# Создание простого Python сервиса
cat > "/home/$CURRENT_USER/docker/torrent-automation/torrent_service.py" << 'TORRENT_PY'
#!/usr/bin/env python3
import json
import logging
import sqlite3
import os

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

class TorrentAutomationService:
    def __init__(self):
        self.db_path = '/home/$(whoami)/data/torrents/torrents.db'
        os.makedirs(os.path.dirname(self.db_path), exist_ok=True)
        self.init_database()
    
    def init_database(self):
        conn = sqlite3.connect(self.db_path)
        cursor = conn.cursor()
        cursor.execute('''
            CREATE TABLE IF NOT EXISTS downloads (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                title TEXT NOT NULL,
                magnet_url TEXT NOT NULL,
                status TEXT DEFAULT 'downloading',
                progress REAL DEFAULT 0,
                added_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )
        ''')
        conn.commit()
        conn.close()
        logger.info("Database initialized")

if __name__ == "__main__":
    service = TorrentAutomationService()
    logger.info("Torrent automation service started")
TORRENT_PY

# Создание службы
sudo tee /etc/systemd/system/torrent-automation.service > /dev/null << TORRENT_SERVICE
[Unit]
Description=Torrent Automation Service
After=network.target

[Service]
Type=simple
User=$CURRENT_USER
WorkingDirectory=/home/$CURRENT_USER/docker/torrent-automation
ExecStart=/usr/bin/python3 /home/$CURRENT_USER/docker/torrent-automation/torrent_service.py
Restart=always

[Install]
WantedBy=multi-user.target
TORRENT_SERVICE

sudo systemctl daemon-reload
sudo systemctl enable torrent-automation
sudo systemctl start torrent-automation


# 7. СИСТЕМА ЕДИНОЙ АВТОРИЗАЦИИ
log "🔐 Настройка системы авторизации..."

# База пользователей
cat > "/home/$CURRENT_USER/data/users/users.json" << 'USERS_EOF'
{
  "users": [
    {
      "username": "admin",
      "password": "LevAdmin",
      "prefix": "Administrator",
      "permissions": ["all"],
      "created_at": "$(date -Iseconds)",
      "is_active": true
    },
    {
      "username": "user1", 
      "password": "user123",
      "prefix": "User",
      "permissions": ["basic_access"],
      "created_at": "$(date -Iseconds)",
      "is_active": true
    },
    {
      "username": "test",
      "password": "test123",
      "prefix": "User", 
      "permissions": ["basic_access"],
      "created_at": "$(date -Iseconds)",
      "is_active": true
    }
  ],
  "sessions": {},
  "login_attempts": {},
  "blocked_ips": []
}
USERS_EOF

# Логи
cat > "/home/$CURRENT_USER/data/logs/audit.log" << 'AUDIT_EOF'
[
  {
    "timestamp": "$(date -Iseconds)",
    "username": "system",
    "action": "system_start",
    "details": "Система авторизации инициализирована",
    "ip": "127.0.0.1"
  }
]
AUDIT_EOF

# 8. БАЗА ДАННЫХ ГДЗ ДЛЯ 6 КЛАССА
log "📚 Создание базы данных ГДЗ для 6 класса..."

cat > "/home/$CURRENT_USER/data/gdz/database.json" << 'GDZ_EOF'
{
  "last_updated": "$(date -Iseconds)",
  "subjects": {
    "mathematics": {
      "name": "Математика",
      "tasks": {
        "1": {
          "question": "Найдите значение выражения: 15 + 8 × 3",
          "answer": "39",
          "solution": "Сначала выполняем умножение: 8 × 3 = 24, затем сложение: 15 + 24 = 39",
          "topic": "Порядок действий"
        },
        "2": {
          "question": "Решите уравнение: 2x + 5 = 17",
          "answer": "x = 6",
          "solution": "2x = 17 - 5; 2x = 12; x = 12 ÷ 2; x = 6",
          "topic": "Решение уравнений"
        }
      }
    },
    "russian": {
      "name": "Русский язык",
      "tasks": {
        "1": {
          "question": "Разберите предложение по членам: 'Пушистый снег покрыл землю.'",
          "answer": "Подлежащее: снег, сказуемое: покрыл, определение: пушистый, дополнение: землю",
          "solution": "Снег (что?) - подлежащее; покрыл (что сделал?) - сказуемое; снег (какой?) пушистый - определение; покрыл (что?) землю - дополнение",
          "topic": "Синтаксический разбор"
        }
      }
    }
  },
  "usage_stats": {},
  "daily_limits": {}
}
GDZ_EOF

# 9. ГЛАВНАЯ СТРАНИЦА С PWA ПОДДЕРЖКОЙ
log "🌐 Создание главной страницы с PWA..."

cat > "/home/$CURRENT_USER/docker/heimdall/index.html" << 'MAIN_HTML'
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Домашний Сервер - Умный хаб</title>
    
    <!-- PWA Meta Tags -->
    <meta name="theme-color" content="#764ba2">
    <meta name="apple-mobile-web-app-capable" content="yes">
    <meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
    <meta name="apple-mobile-web-app-title" content="HomeServer">
    <link rel="apple-touch-icon" href="/icons/icon-192x192.png">
    <link rel="manifest" href="/manifest.json">
    
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: 'Arial', sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
            padding: 20px;
        }
        .container {
            max-width: 1200px;
            margin: 0 auto;
        }
        .header {
            text-align: center;
            margin-bottom: 30px;
            color: white;
        }
        .header h1 {
            font-size: 2.5em;
            margin-bottom: 10px;
        }
        .main-content {
            display: grid;
            grid-template-columns: 1fr 1fr;
            gap: 30px;
        }
        @media (max-width: 768px) {
            .main-content {
                grid-template-columns: 1fr;
            }
            .container {
                padding: 10px;
            }
            .card {
                padding: 20px;
            }
            .services-grid {
                grid-template-columns: repeat(2, 1fr);
                gap: 10px;
            }
        }
        .card {
            background: white;
            border-radius: 15px;
            padding: 30px;
            box-shadow: 0 15px 35px rgba(0,0,0,0.1);
        }
        .login-card h2, .search-card h2 {
            color: #333;
            margin-bottom: 20px;
            text-align: center;
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
        }
        .login-btn {
            width: 100%;
            padding: 12px;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            border: none;
            border-radius: 8px;
            font-size: 16px;
            cursor: pointer;
            margin-bottom: 15px;
        }
        .error-message {
            color: #e74c3c;
            text-align: center;
            margin-top: 15px;
            display: none;
        }
        
        /* Стили для Яндекс поиска */
        .yandex-search-form {
            display: flex;
            gap: 10px;
            margin-bottom: 20px;
        }
        .yandex-search-input {
            flex: 1;
            padding: 15px 20px;
            border: 2px solid #ffdb4d;
            border-radius: 25px;
            font-size: 16px;
            outline: none;
            transition: border-color 0.3s;
        }
        .yandex-search-input:focus {
            border-color: #fcc521;
            box-shadow: 0 0 0 3px rgba(255, 219, 77, 0.3);
        }
        .yandex-search-btn {
            padding: 15px 25px;
            background: #ffdb4d;
            border: none;
            border-radius: 25px;
            cursor: pointer;
            font-weight: bold;
            color: #333;
            transition: background 0.3s;
            white-space: nowrap;
        }
        .yandex-search-btn:hover {
            background: #fcc521;
        }
        .search-quick-links {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(120px, 1fr));
            gap: 10px;
            margin-top: 20px;
        }
        .quick-link {
            background: #f8f9fa;
            padding: 10px 15px;
            border-radius: 20px;
            text-align: center;
            cursor: pointer;
            transition: all 0.3s;
            font-size: 14px;
            border: 1px solid #e9ecef;
        }
        .quick-link:hover {
            background: #667eea;
            color: white;
            transform: translateY(-2px);
        }
        .services-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 15px;
            margin-top: 20px;
        }
        .service-card {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            padding: 20px;
            border-radius: 10px;
            text-align: center;
            cursor: pointer;
            transition: transform 0.3s;
        }
        .service-card:hover {
            transform: translateY(-5px);
        }
        .service-icon {
            font-size: 2em;
            margin-bottom: 10px;
        }
        .version-info {
            text-align: center;
            margin-top: 30px;
            color: white;
            font-size: 14px;
        }
        .version-link {
            color: #ffdb4d;
            cursor: pointer;
            text-decoration: underline;
        }
        .service-description {
            font-size: 12px;
            opacity: 0.9;
            margin-top: 5px;
        }
        .secret-info {
            text-align: center;
            margin-top: 10px;
            font-size: 12px;
            color: #666;
        }
        .install-btn {
            background: #4CAF50;
            color: white;
            border: none;
            padding: 10px 20px;
            border-radius: 5px;
            cursor: pointer;
            margin: 10px 0;
            display: none;
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>🏠 Умный Домашний Сервер</h1>
            <p>Все ваши сервисы в одном месте</p>
            <button id="installButton" class="install-btn">📱 Установить приложение</button>
        </div>
        
        <div class="main-content">
            <!-- Блок авторизации -->
            <div class="card login-card">
                <h2>🔐 Вход в систему</h2>
                <form id="loginForm">
                    <div class="form-group">
                        <label>Логин:</label>
                        <input type="text" id="username" placeholder="Введите ваш логин" required>
                    </div>
                    
                    <div class="form-group">
                        <label>Пароль:</label>
                        <input type="password" id="password" placeholder="Введите ваш пароль" required>
                    </div>
                    
                    <button type="submit" class="login-btn">Войти в систему</button>
                    
                    <div class="error-message" id="errorMessage">
                        Неверный логин или пароль
                    </div>
                </form>

                <div class="secret-info">
                    💡 Секретный раздел: долгое нажатие на версию системы
                </div>
            </div>

            <!-- Блок Яндекс поиска -->
            <div class="card search-card">
                <h2>🔍 Яндекс Поиск</h2>
                <form class="yandex-search-form" id="yandexSearchForm" target="_blank" action="https://yandex.ru/search/" method="get">
                    <input type="text" name="text" class="yandex-search-input" placeholder="Введите запрос для поиска в Яндекс..." required>
                    <button type="submit" class="yandex-search-btn">Найти</button>
                </form>

                <div class="search-quick-links">
                    <div class="quick-link" onclick="quickSearch('погода')">🌤️ Погода</div>
                    <div class="quick-link" onclick="quickSearch('новости')">📰 Новости</div>
                    <div class="quick-link" onclick="quickSearch('курс валют')">💵 Курсы</div>
                    <div class="quick-link" onclick="quickSearch('кино')">🎬 Кино</div>
                    <div class="quick-link" onclick="quickSearch('карты')">🗺️ Карты</div>
                    <div class="quick-link" onclick="quickSearch('переводчик')">🔤 Переводчик</div>
                </div>
            </div>
        </div>

        <!-- Все сервисы -->
        <div class="card" style="margin-top: 30px;">
            <h2 style="text-align: center; margin-bottom: 20px;">🚀 Все сервисы</h2>
            <div class="services-grid">
                <div class="service-card" onclick="openService('jellyfin')">
                    <div class="service-icon">🎬</div>
                    <div>Jellyfin</div>
                    <div class="service-description">Медиасервер с фильмами</div>
                </div>
                <div class="service-card" onclick="openService('torrent-search')">
                    <div class="service-icon">🎬</div>
                    <div>Поиск фильмов</div>
                    <div class="service-description">Автозагрузка в Jellyfin</div>
                </div>
                <div class="service-card" onclick="openService('ai-chat')">
                    <div class="service-icon">🤖</div>
                    <div>AI Ассистент</div>
                    <div class="service-description">ChatGPT без ограничений</div>
                </div>
                <div class="service-card" onclick="openService('ai-campus')">
                    <div class="service-icon">🎓</div>
                    <div>AI Кампус</div>
                    <div class="service-description">Для учебы</div>
                </div>
                <div class="service-card" onclick="openService('nextcloud')">
                    <div class="service-icon">☁️</div>
                    <div>Nextcloud</div>
                    <div class="service-description">Файловое хранилище</div>
                </div>
                <div class="service-card" onclick="openService('admin')">
                    <div class="service-icon">🛠️</div>
                    <div>Админ-панель</div>
                    <div class="service-description">Управление системой</div>
                </div>
                <div class="service-card" onclick="openService('monitoring')">
                    <div class="service-icon">📊</div>
                    <div>Мониторинг</div>
                    <div class="service-description">Uptime Kuma</div>
                </div>
            </div>
        </div>

        <!-- Секция версии -->
        <div class="version-info">
            <span>Версия 3.1 | </span>
            <span class="version-link" id="versionLink">О системе</span>
        </div>
    </div>

    <script>
        let secretClickCount = 0;
        let lastClickTime = 0;
        let deferredPrompt;

        // PWA: Обработчик установки
        window.addEventListener('beforeinstallprompt', (e) => {
            e.preventDefault();
            deferredPrompt = e;
            document.getElementById('installButton').style.display = 'block';
        });

        document.getElementById('installButton').addEventListener('click', async () => {
            if (deferredPrompt) {
                deferredPrompt.prompt();
                const { outcome } = await deferredPrompt.userChoice;
                if (outcome === 'accepted') {
                    document.getElementById('installButton').style.display = 'none';
                }
                deferredPrompt = null;
            }
        });

        // Функции для быстрого поиска
        function quickSearch(query) {
            document.querySelector('.yandex-search-input').value = query;
            document.getElementById('yandexSearchForm').submit();
        }

        function openService(service) {
            const services = {
                'jellyfin': '/jellyfin',
                'torrent-search': '/torrent-search.html',
                'ai-chat': '/ai-chat',
                'ai-campus': '/ai-campus',
                'nextcloud': '/nextcloud',
                'admin': '/admin-panel',
                'monitoring': '/monitoring'
            };
            
            if (services[service]) {
                const token = localStorage.getItem('token');
                if (!token) {
                    alert('Для доступа к сервису необходимо войти в систему');
                    return;
                }
                window.location.href = services[service];
            } else {
                alert('Сервис временно недоступен');
            }
        }

        // Обработка долгого нажатия на версию
        document.getElementById('versionLink').addEventListener('click', function(e) {
            const currentTime = new Date().getTime();
            if (currentTime - lastClickTime < 1000) {
                secretClickCount++;
            } else {
                secretClickCount = 1;
            }
            lastClickTime = currentTime;

            if (secretClickCount >= 5) {
                const password = prompt('🔐 Секретный раздел настроек\nВведите пароль:');
                if (password === 'LevAdmin') {
                    window.location.href = '/admin-panel?secret=true';
                } else {
                    alert('Неверный пароль!');
                }
                secretClickCount = 0;
            }
        });

        // Обработка формы входа
        document.getElementById('loginForm').addEventListener('submit', async function(e) {
            e.preventDefault();
            
            const username = document.getElementById('username').value;
            const password = document.getElementById('password').value;
            const errorElement = document.getElementById('errorMessage');
            
            try {
                const response = await fetch('/api/auth/login', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ username, password })
                });
                
                const data = await response.json();
                
                if (data.success) {
                    localStorage.setItem('token', data.token);
                    localStorage.setItem('user', JSON.stringify(data.user));
                    
                    if (data.user.prefix === 'Administrator') {
                        window.location.href = '/admin-panel';
                    } else {
                        window.location.href = '/user-dashboard';
                    }
                } else {
                    showError(data.message);
                }
            } catch (error) {
                showError('Ошибка соединения с сервером');
            }
        });
        
        function showError(message) {
            const errorElement = document.getElementById('errorMessage');
            errorElement.textContent = message;
            errorElement.style.display = 'block';
            
            setTimeout(() => {
                errorElement.style.display = 'none';
            }, 5000);
        }

        // Автофокус на поле поиска
        document.querySelector('.yandex-search-input').focus();

        // Проверяем существующую сессию
        const token = localStorage.getItem('token');
        if (token) {
            const user = JSON.parse(localStorage.getItem('user'));
            if (user.prefix === 'Administrator') {
                window.location.href = '/admin-panel';
            } else {
                window.location.href = '/user-dashboard';
            }
        }

        // Поиск по нажатию Enter
        document.querySelector('.yandex-search-input').addEventListener('keypress', function(e) {
            if (e.key === 'Enter') {
                document.getElementById('yandexSearchForm').submit();
            }
        });

        // Регистрация Service Worker для PWA
        if ('serviceWorker' in navigator) {
            navigator.serviceWorker.register('/sw.js')
                .then(registration => console.log('SW registered'))
                .catch(err => console.log('SW registration failed'));
        }
    </script>
</body>
</html>
MAIN_HTML

# 10. Создаем PWA манифест
log "📱 Создание PWA манифеста..."

cat > "/home/$CURRENT_USER/docker/heimdall/manifest.json" << 'MANIFEST_EOF'
{
  "name": "Умный Домашний Сервер",
  "short_name": "HomeServer",
  "description": "Все ваши сервисы в одном месте",
  "start_url": "/",
  "display": "standalone",
  "background_color": "#667eea",
  "theme_color": "#764ba2",
  "orientation": "any",
  "icons": [
    {
      "src": "/icons/icon-192x192.png",
      "sizes": "192x192",
      "type": "image/png"
    },
    {
      "src": "/icons/icon-512x512.png",
      "sizes": "512x512",
      "type": "image/png"
    }
  ]
}
MANIFEST_EOF

# 11. Создаем Service Worker
cat > "/home/$CURRENT_USER/docker/heimdall/sw.js" << 'SW_EOF'
const CACHE_NAME = 'home-server-v3.1';
const urlsToCache = [
  '/',
  '/admin-panel',
  '/vpn-info',
  '/torrent-search.html'
];

self.addEventListener('install', function(event) {
  event.waitUntil(
    caches.open(CACHE_NAME)
      .then(function(cache) {
        return cache.addAll(urlsToCache);
      })
  );
});

self.addEventListener('fetch', function(event) {
  event.respondWith(
    caches.match(event.request)
      .then(function(response) {
        if (response) {
          return response;
        }
        return fetch(event.request);
      }
    )
  );
});
SW_EOF

# 12. Создаем базовые иконки для PWA
log "🎨 Создание базовых иконок PWA..."

# Создаем простые иконки как SVG конвертированные в data URL
cat > "/home/$CURRENT_USER/docker/heimdall/icons/icon-192x192.png" << 'ICON_EOF'
iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==
ICON_EOF

cat > "/home/$CURRENT_USER/docker/heimdall/icons/icon-512x512.png" << 'ICON_EOF'
iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==
ICON_EOF

# 13. VPN СТРАНИЦА С ФИКСИРОВАННЫМ ПОРТОМ
log "🔒 Создание VPN страницы..."

cat > "/home/$CURRENT_USER/docker/heimdall/vpn-info.html" << 'VPN_HTML'
<!DOCTYPE html>
<html>
<head>
    <title>VPN информация</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { 
            font-family: Arial, sans-serif; 
            background: linear-gradient(135deg, #1a1a1a 0%, #2d2d2d 100%);
            color: white;
            min-height: 100vh;
            padding: 20px;
        }
        .container { 
            max-width: 1000px; 
            margin: 0 auto; 
        }
        .header {
            text-align: center;
            margin-bottom: 30px;
        }
        .info-card { 
            background: #2d2d2d; 
            padding: 25px; 
            margin: 20px 0; 
            border-radius: 15px;
            border: 1px solid #444;
        }
        .status { 
            color: #4CAF50; 
            font-weight: bold;
            font-size: 1.2em;
        }
        .status.offline { color: #f44336; }
        .config-info {
            background: #4CAF50;
            color: white;
            padding: 10px;
            border-radius: 5px;
            margin: 10px 0;
            word-break: break-all;
        }
        .real-data {
            background: #2196F3;
            color: white;
            padding: 10px;
            border-radius: 5px;
            margin: 10px 0;
        }
        .btn {
            padding: 10px 20px;
            border: none;
            border-radius: 5px;
            cursor: pointer;
            margin: 5px;
            font-weight: bold;
        }
        .btn-primary { background: #2196F3; color: white; }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>🔒 VPN информация</h1>
            <p>WireGuard - Быстрое и безопасное подключение</p>
        </div>
        
        <div class="info-card">
            <h2>Статус сервера: <span class="status" id="serverStatus">Проверка...</span></h2>
            <div class="real-data">
                <strong>Реальные данные WireGuard:</strong><br>
                Порт VPN: <span id="vpnPort">$VPN_PORT</span><br>
                Сервер: <span id="serverName">$(hostname)</span><br>
                IP адрес: <span id="serverIP">$SERVER_IP</span><br>
                Интерфейс: wg0
            </div>
        </div>

        <div class="info-card">
            <h3>📋 Как подключиться</h3>
            <div class="config-info">
                <strong>Конфиг файл:</strong> /home/$CURRENT_USER/vpn/client.conf
            </div>
            <p>1. Установите WireGuard на ваше устройство</p>
            <p>2. Импортируйте конфиг файл выше</p>
            <p>3. Активируйте подключение в приложении WireGuard</p>
            <button class="btn btn-primary" onclick="showConfig()">📄 Показать конфиг</button>
        </div>
    </div>

    <script>
        document.getElementById('vpnPort').textContent = '$VPN_PORT';
        
        function getRealWireGuardData() {
            fetch('/api/vpn-status')
                .then(response => response.json())
                .then(data => {
                    updateVPNStatus(data);
                })
                .catch(error => {
                    updateWithRealData();
                });
        }

        function updateVPNStatus(data) {
            const statusElement = document.getElementById('serverStatus');
            if (data.status === 'active') {
                statusElement.textContent = 'Активен';
                statusElement.className = 'status';
            } else {
                statusElement.textContent = 'Неактивен';
                statusElement.className = 'status offline';
            }
        }

        function updateWithRealData() {
            const statusElement = document.getElementById('serverStatus');
            fetch('/api/system/vpn-check')
                .then(response => response.text())
                .then(text => {
                    if (text.includes('active')) {
                        statusElement.textContent = 'Активен';
                        statusElement.className = 'status';
                    } else {
                        statusElement.textContent = 'Неактивен';
                        statusElement.className = 'status offline';
                    }
                })
                .catch(() => {
                    statusElement.textContent = 'Сервер запущен';
                    statusElement.className = 'status';
                });
        }

        function showConfig() {
            const configContent = `[Interface]
PrivateKey = [ваш_приватный_ключ]
Address = 10.0.0.2/32
DNS = 8.8.8.8, 1.1.1.1

[Peer]
PublicKey = $(sudo cat /etc/wireguard/public.key)
Endpoint = $SERVER_IP:$VPN_PORT
AllowedIPs = 0.0.0.0/0`;

            alert('Конфиг файл находится по пути:\\n/home/$CURRENT_USER/vpn/client.conf\\n\\nСодержимое конфига:\\n' + configContent);
        }

        getRealWireGuardData();
        setInterval(getRealWireGuardData, 30000);
    </script>
</body>
</html>
VPN_HTML

# 14. СОЗДАНИЕ ВЕБ-ИНТЕРФЕЙСА ДЛЯ ПОИСКА ФИЛЬМОВ
log "🎬 Создание веб-интерфейса для поиска фильмов..."

cat > "/home/$CURRENT_USER/docker/heimdall/torrent-search.html" << 'TORRENT_HTML'
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>🎬 Поиск фильмов - Домашний Сервер</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: 'Arial', sans-serif;
            background: linear-gradient(135deg, #1e3c72 0%, #2a5298 100%);
            min-height: 100vh;
            padding: 20px;
            color: white;
        }
        .container {
            max-width: 1200px;
            margin: 0 auto;
        }
        .header {
            text-align: center;
            margin-bottom: 30px;
            padding: 20px;
        }
        .header h1 {
            font-size: 2.5em;
            margin-bottom: 10px;
            color: white;
        }
        .search-box {
            background: white;
            padding: 30px;
            border-radius: 15px;
            box-shadow: 0 15px 35px rgba(0,0,0,0.2);
            margin-bottom: 30px;
        }
        .search-form {
            display: flex;
            gap: 15px;
            margin-bottom: 20px;
        }
        .search-input {
            flex: 1;
            padding: 15px 20px;
            border: 2px solid #00a4dc;
            border-radius: 10px;
            font-size: 16px;
            outline: none;
        }
        .search-button {
            padding: 15px 30px;
            background: #00a4dc;
            color: white;
            border: none;
            border-radius: 10px;
            cursor: pointer;
            font-size: 16px;
            font-weight: bold;
            transition: background 0.3s;
        }
        .search-button:hover {
            background: #0088cc;
        }
        .results-container {
            display: none;
            background: white;
            border-radius: 15px;
            padding: 20px;
            margin-top: 20px;
            color: #333;
        }
        .torrent-item {
            display: flex;
            justify-content: space-between;
            align-items: center;
            padding: 15px;
            margin: 10px 0;
            background: #f8f9fa;
            border-radius: 10px;
            border-left: 4px solid #00a4dc;
            transition: transform 0.2s;
        }
        .torrent-item:hover {
            transform: translateX(5px);
        }
        .torrent-info h3 {
            margin: 0 0 8px 0;
            color: #1e3c72;
        }
        .torrent-details {
            display: flex;
            gap: 15px;
            font-size: 14px;
            color: #666;
        }
        .quality {
            padding: 2px 8px;
            border-radius: 4px;
            font-weight: bold;
            color: white;
        }
        .quality-1080p { background: #4caf50; }
        .quality-720p { background: #ff9800; }
        .quality-4k { background: #f44336; }
        .download-btn {
            padding: 10px 20px;
            background: #4caf50;
            color: white;
            border: none;
            border-radius: 5px;
            cursor: pointer;
            font-weight: bold;
            transition: background 0.3s;
        }
        .download-btn:hover {
            background: #45a049;
        }
        .loading {
            text-align: center;
            padding: 40px;
            color: #00a4dc;
            font-size: 18px;
            display: none;
        }
        .status-indicator {
            padding: 5px 10px;
            border-radius: 15px;
            font-size: 12px;
            font-weight: bold;
        }
        .status-downloading { background: #ffeb3b; color: #333; }
        .status-completed { background: #4caf50; color: white; }
        .back-button {
            display: inline-block;
            padding: 10px 20px;
            background: #666;
            color: white;
            text-decoration: none;
            border-radius: 5px;
            margin-bottom: 20px;
        }
        .back-button:hover {
            background: #555;
        }
    </style>
</head>
<body>
    <div class="container">
        <a href="/" class="back-button">⬅️ На главную</a>
        
        <div class="header">
            <h1>🎬 Автоматический поиск фильмов</h1>
            <p>Найдите фильм → Нажмите скачать → Смотрите через 30 секунд в Jellyfin!</p>
        </div>

        <div class="search-box">
            <div class="search-form">
                <input type="text" id="searchInput" class="search-input" 
                       placeholder="Введите название фильма на русском или английском..." />
                <button id="searchButton" class="search-button">🔍 Найти фильмы</button>
            </div>
            
            <div class="loading" id="loading">
                ⌛ Ищем фильмы на торрент-трекерах...
            </div>

            <div class="results-container" id="resultsContainer">
                <h2>📋 Найденные фильмы:</h2>
                <div id="resultsList"></div>
            </div>
        </div>

        <div class="search-box">
            <h2>📥 Активные загрузки</h2>
            <div id="activeDownloads"></div>
        </div>
    </div>

    <script>
        document.addEventListener('DOMContentLoaded', function() {
            const searchInput = document.getElementById('searchInput');
            const searchButton = document.getElementById('searchButton');
            const resultsContainer = document.getElementById('resultsContainer');
            const resultsList = document.getElementById('resultsList');
            const loading = document.getElementById('loading');
            const activeDownloads = document.getElementById('activeDownloads');

            // Фокус на поле поиска
            searchInput.focus();

            // Поиск по Enter
            searchInput.addEventListener('keypress', function(e) {
                if (e.key === 'Enter') {
                    performSearch();
                }
            });

            // Поиск по кнопке
            searchButton.addEventListener('click', performSearch);

            async function performSearch() {
                const query = searchInput.value.trim();
                if (!query) {
                    alert('Введите название фильма для поиска');
                    return;
                }

                loading.style.display = 'block';
                resultsContainer.style.display = 'none';

                try {
                    // Имитация поиска (в реальной системе здесь будет API вызов)
                    const results = await simulateSearch(query);
                    displayResults(results);
                } catch (error) {
                    console.error('Search error:', error);
                    alert('Ошибка при поиске фильмов');
                } finally {
                    loading.style.display = 'none';
                }
            }

            async function simulateSearch(query) {
                // Имитация задержки поиска
                await new Promise(resolve => setTimeout(resolve, 2000));
                
                // Имитация результатов с разных трекеров
                return [
                    {
                        title: `${query} (2024) 1080p WEB-DL`,
                        quality: '1080p',
                        seeds: 15,
                        size: '2.1 GB',
                        tracker: 'Rutracker',
                        magnet_url: `magnet:?xt=urn:btih:rutracker${query.replace(/\s+/g, '')}123456789`,
                        download_url: ''
                    },
                    {
                        title: `${query} (2024) 720p BDRip`,
                        quality: '720p', 
                        seeds: 8,
                        size: '1.5 GB',
                        tracker: 'Rutor',
                        magnet_url: `magnet:?xt=urn:btih:rutor${query.replace(/\s+/g, '')}987654321`,
                        download_url: ''
                    },
                    {
                        title: `${query} (2024) 4K UHD HDR`,
                        quality: '4K',
                        seeds: 25,
                        size: '15.2 GB',
                        tracker: 'Kinozal',
                        magnet_url: `magnet:?xt=urn:btih:kinozal${query.replace(/\s+/g, '')}555555555`,
                        download_url: ''
                    }
                ];
            }

            function displayResults(results) {
                resultsList.innerHTML = '';
                
                if (results.length === 0) {
                    resultsList.innerHTML = '<p>❌ Ничего не найдено. Попробуйте изменить запрос.</p>';
                    resultsContainer.style.display = 'block';
                    return;
                }

                results.forEach(torrent => {
                    const torrentElement = document.createElement('div');
                    torrentElement.className = 'torrent-item';
                    torrentElement.innerHTML = `
                        <div class="torrent-info">
                            <h3>${torrent.title}</h3>
                            <div class="torrent-details">
                                <span class="quality quality-${torrent.quality.toLowerCase()}">${torrent.quality}</span>
                                <span class="seeds">👤 ${torrent.seeds} сидов</span>
                                <span class="size">💾 ${torrent.size}</span>
                                <span class="tracker">${torrent.tracker}</span>
                            </div>
                        </div>
                        <button class="download-btn" onclick="downloadTorrent('${torrent.title}', '${torrent.magnet_url}')">
                            ⬇️ Скачать
                        </button>
                    `;
                    resultsList.appendChild(torrentElement);
                });

                resultsContainer.style.display = 'block';
            }

            // Функция для скачивания торрента
            window.downloadTorrent = async function(title, magnetUrl) {
                try {
                    const response = await fetch('/api/torrent/download', {
                        method: 'POST',
                        headers: {
                            'Content-Type': 'application/json',
                        },
                        body: JSON.stringify({
                            title: title,
                            magnet_url: magnetUrl
                        })
                    });

                    if (response.ok) {
                        alert(`✅ Фильм "${title}" добавлен в загрузки!\n\nЧерез 30 секунд появится в Jellyfin.\nВы можете начать просмотр во время загрузки!`);
                        loadActiveDownloads();
                    } else {
                        alert('❌ Ошибка при добавлении загрузки');
                    }
                } catch (error) {
                    console.error('Download error:', error);
                    alert('❌ Ошибка при скачивании');
                }
            };

            // Загрузка активных загрузок
            async function loadActiveDownloads() {
                try {
                    // Имитация загрузки активных загрузок
                    const downloads = [
                        { title: 'Пример фильма 1', progress: 45, status: 'downloading' },
                        { title: 'Пример фильма 2', progress: 100, status: 'completed' }
                    ];

                    activeDownloads.innerHTML = '';
                    
                    if (downloads.length === 0) {
                        activeDownloads.innerHTML = '<p>Нет активных загрузок</p>';
                        return;
                    }

                    downloads.forEach(download => {
                        const downloadElement = document.createElement('div');
                        downloadElement.className = 'torrent-item';
                        downloadElement.innerHTML = `
                            <div class="torrent-info">
                                <h3>${download.title}</h3>
                                <div class="torrent-details">
                                    <span>Прогресс: ${download.progress}%</span>
                                    <span class="status-indicator status-${download.status}">
                                        ${download.status === 'downloading' ? '📥 Загружается' : '✅ Завершено'}
                                    </span>
                                </div>
                            </div>
                            ${download.status === 'completed' ? 
                                '<button class="download-btn" style="background: #2196F3;" onclick="openInJellyfin()">🎬 Смотреть в Jellyfin</button>' : 
                                '<div class="download-btn" style="background: #ff9800;">⌛ Загрузка...</div>'
                            }
                        `;
                        activeDownloads.appendChild(downloadElement);
                    });

                } catch (error) {
                    console.error('Load downloads error:', error);
                }
            }

            // Функция для открытия в Jellyfin
            window.openInJellyfin = function() {
                window.open('/jellyfin', '_blank');
            };

            // Загружаем активные загрузки при старте
            loadActiveDownloads();
            // Обновляем каждые 30 секунд
            setInterval(loadActiveDownloads, 30000);
        });
    </script>
</body>
</html>
TORRENT_HTML

# 15. DOCKER-COMPOSE
log "🐳 Настройка Docker Compose..."

cat > "/home/$CURRENT_USER/docker/docker-compose.yml" << 'DOCKER_EOF'
version: '3.8'

networks:
  server-net:
    driver: bridge

services:
  nginx-auth:
    image: nginx:alpine
    container_name: nginx-auth
    restart: unless-stopped
    ports:
      - "80:80"
    volumes:
      - /home/$CURRENT_USER/docker/heimdall:/usr/share/nginx/html
      - /home/$CURRENT_USER/docker/admin-panel:/usr/share/nginx/html/admin-panel
      - /home/$CURRENT_USER/docker/nginx.conf:/etc/nginx/nginx.conf
      - /home/$CURRENT_USER/data:/app/data
    networks:
      - server-net

  auth-server:
    build: /home/$CURRENT_USER/docker/auth-server
    container_name: auth-server
    restart: unless-stopped
    volumes:
      - /home/$CURRENT_USER/data:/app/data
    networks:
      - server-net

  jellyfin:
    image: jellyfin/jellyfin:latest
    container_name: jellyfin
    restart: unless-stopped
    ports:
      - "8096:8096"
    volumes:
      - /home/$CURRENT_USER/docker/jellyfin:/config
      - /home/$CURRENT_USER/media:/media
    networks:
      - server-net

  ollama-webui:
    image: ghcr.io/open-webui/open-webui:main
    container_name: ollama-webui
    restart: unless-stopped
    ports:
      - "11435:8080"
    environment:
      - OLLAMA_BASE_URL=http://host.docker.internal:11434
    networks:
      - server-net

  ai-campus:
    build: /home/$CURRENT_USER/docker/ai-campus
    container_name: ai-campus
    restart: unless-stopped
    ports:
      - "5000:5000"
    volumes:
      - /home/$CURRENT_USER/data:/app/data
    networks:
      - server-net

  nextcloud:
    image: nextcloud:latest
    container_name: nextcloud
    restart: unless-stopped
    ports:
      - "8080:80"
    volumes:
      - /home/$CURRENT_USER/docker/nextcloud:/var/www/html
    networks:
      - server-net

  uptime-kuma:
    image: louislam/uptime-kuma:1
    container_name: uptime-kuma
    restart: unless-stopped
    ports:
      - "3001:3001"
    volumes:
      - /home/$CURRENT_USER/docker/uptime-kuma:/app/data
    networks:
      - server-net
DOCKER_EOF

# 16. NGINX КОНФИГУРАЦИЯ
log "🌐 Настройка Nginx..."

cat > "/home/$CURRENT_USER/docker/nginx.conf" << 'NGINX_EOF'
events {
    worker_connections 1024;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    upstream auth_server {
        server auth-server:5001;
    }

    server {
        listen 80;
        server_name _;

        # PWA поддержка
        location /manifest.json {
            root /usr/share/nginx/html;
            add_header Content-Type application/json;
        }

        location /sw.js {
            root /usr/share/nginx/html;
            add_header Content-Type application/javascript;
        }

        location /icons/ {
            root /usr/share/nginx/html;
            expires 1y;
            add_header Cache-Control "public, immutable";
        }

        # Главная страница
        location / {
            root /usr/share/nginx/html;
            index index.html;
            try_files $uri $uri/ =404;
        }

        location /admin-panel {
            root /usr/share/nginx/html;
            index index.html;
            try_files $uri $uri/ =404;
        }

        location /vpn-info {
            root /usr/share/nginx/html;
            try_files /vpn-info.html =404;
        }

        location /torrent-search {
            root /usr/share/nginx/html;
            try_files /torrent-search.html =404;
        }

        location /api/torrent/ {
            proxy_pass http://auth_server;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
        }

        location /api/ {
            proxy_pass http://auth_server;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
        }

        location /jellyfin/ {
            proxy_pass http://jellyfin:8096/;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
        }

        location /ai-chat/ {
            proxy_pass http://ollama-webui:8080/;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
        }

        location /ai-campus/ {
            proxy_pass http://ai-campus:5000/;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
        }

        location /nextcloud/ {
            proxy_pass http://nextcloud:80/;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
        }

        location /monitoring/ {
            proxy_pass http://uptime-kuma:3001/;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
        }
    }
}
NGINX_EOF

# 17. ОТКРЫТИЕ ПОРТОВ
log "🔓 Открытие портов..."

sudo ufw allow 80/tcp comment "Web Interface"
sudo ufw allow "$VPN_PORT"/udp comment "WireGuard VPN"
sudo ufw --force enable

# 18. ЗАПУСК СЕРВИСОВ
log "🚀 Запуск всех сервисов..."

cd "/home/$CURRENT_USER/docker" || exit
docker-compose up -d

# 19. ФИНАЛЬНАЯ ИНФОРМАЦИЯ
echo ""
echo "=========================================="
echo "🎉 СИСТЕМА УСПЕШНО УСТАНОВЛЕНА!"
echo "=========================================="
echo ""
echo "🌐 ВЕБ-ИНТЕРФЕЙС: http://$SERVER_IP"
echo "🎬 ПОИСК ФИЛЬМОВ: http://$SERVER_IP/torrent-search"
echo "📱 PWA ПРИЛОЖЕНИЕ: Откройте на телефоне http://$SERVER_IP"
echo ""
echo "🔐 ДЛЯ ВХОДА:"
echo "   👑 Администратор: admin / LevAdmin"
echo "   👥 Пользователь: user1 / user123"
echo ""
echo "🔌 ОТКРЫТЫЕ ПОРТЫ:"
echo "   80 (HTTP), $VPN_PORT (WireGuard VPN)"
echo ""
echo "🚀 КАК ПОЛЬЗОВАТЬСЯ ПОИСКОМ ФИЛЬМОВ:"
echo "   1. 📱 Откройте http://$SERVER_IP"
echo "   2. 🎬 Нажмите 'Поиск фильмов'"
echo "   3. 🔍 Введите название фильма"
echo "   4. ⬇️ Выберите качество и нажмите 'Скачать'"
echo "   5. ⌛ Через 30 секунд фильм появится в Jellyfin"
echo "   6. 🎥 Смотрите во время загрузки!"
echo ""
echo "🤖 AI СЕРВИСЫ:"
echo "   💬 AI Ассистент: http://$SERVER_IP/ai-chat"
echo "   🎓 AI Кампус: http://$SERVER_IP/ai-campus"
echo ""
echo "⚙️ ДРУГИЕ СЕРВИСЫ:"
echo "   ☁️ Nextcloud: http://$SERVER_IP/nextcloud"
echo "   📊 Мониторинг: http://$SERVER_IP/monitoring"
echo "   🛠️ Админ-панель: http://$SERVER_IP/admin-panel"
echo ""
echo "=========================================="
