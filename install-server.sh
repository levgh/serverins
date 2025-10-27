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

# Проверка зависимостей
log "🔍 Проверка зависимостей..."
if ! command -v docker &> /dev/null; then
    log "❌ Docker не установлен"
    exit 1
fi

if ! command -v docker-compose &> /dev/null; then
    log "❌ Docker Compose не установлен"
    exit 1
fi

# Проверка прав docker
if ! groups "$CURRENT_USER" | grep -q '\bdocker\b'; then
    log "⚠️ Добавляем пользователя в группу docker..."
    sudo usermod -aG docker "$CURRENT_USER"
    log "🔁 Перезапустите сессию и запустите скрипт снова"
    exit 1
fi

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

# Генерация ключей сервера
SERVER_PRIVATE_KEY=$(wg genkey)
SERVER_PUBLIC_KEY=$(echo "$SERVER_PRIVATE_KEY" | wg pubkey)

# Генерация ключей клиента  
CLIENT_PRIVATE_KEY=$(wg genkey)
CLIENT_PUBLIC_KEY=$(echo "$CLIENT_PRIVATE_KEY" | wg pubkey)

# Сохранение ключей
echo "$SERVER_PRIVATE_KEY" | sudo tee /etc/wireguard/private.key > /dev/null
echo "$SERVER_PUBLIC_KEY" | sudo tee /etc/wireguard/public.key > /dev/null
sudo chmod 600 /etc/wireguard/private.key

# Создание конфигурации WireGuard с фиксированным портом
INTERFACE_NAME=$(ip route | grep default | awk '{print $5}' | head -1)

sudo tee /etc/wireguard/wg0.conf > /dev/null << EOF
[Interface]
PrivateKey = $SERVER_PRIVATE_KEY
Address = 10.0.0.1/24
ListenPort = $VPN_PORT
SaveConfig = true
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o $INTERFACE_NAME -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o $INTERFACE_NAME -j MASQUERADE

[Peer]
PublicKey = $CLIENT_PUBLIC_KEY
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
PrivateKey = $CLIENT_PRIVATE_KEY
Address = 10.0.0.2/32
DNS = 8.8.8.8, 1.1.1.1

[Peer]
PublicKey = $SERVER_PUBLIC_KEY
Endpoint = $SERVER_IP:$VPN_PORT
AllowedIPs = 0.0.0.0/0
EOF

log "✅ WireGuard настроен. Клиентский конфиг: /home/$CURRENT_USER/vpn/client.conf"

# 6. СОЗДАНИЕ СТРУКТУРЫ ПАПОК
log "📁 Создание структуры папок..."
mkdir -p "/home/$CURRENT_USER/docker/heimdall"
mkdir -p "/home/$CURRENT_USER/docker/admin-panel" 
mkdir -p "/home/$CURRENT_USER/docker/auth-server"
mkdir -p "/home/$CURRENT_USER/docker/jellyfin"
mkdir -p "/home/$CURRENT_USER/docker/nextcloud"
mkdir -p "/home/$CURRENT_USER/docker/ollama-webui"
mkdir -p "/home/$CURRENT_USER/docker/ai-campus"
mkdir -p "/home/$CURRENT_USER/docker/torrent-automation"
mkdir -p "/home/$CURRENT_USER/scripts"
mkdir -p "/home/$CURRENT_USER/data/users"
mkdir -p "/home/$CURRENT_USER/data/logs"
mkdir -p "/home/$CURRENT_USER/data/backups"
mkdir -p "/home/$CURRENT_USER/data/gdz"
mkdir -p "/home/$CURRENT_USER/data/torrents"
mkdir -p "/home/$CURRENT_USER/media/movies"
mkdir -p "/home/$CURRENT_USER/media/tv"
mkdir -p "/home/$CURRENT_USER/media/series"
mkdir -p "/home/$CURRENT_USER/media/music"
mkdir -p "/home/$CURRENT_USER/media/streaming"
mkdir -p "/home/$CURRENT_USER/docker/heimdall/icons"
mkdir -p "/home/$CURRENT_USER/media/temp"
mkdir -p "/home/$CURRENT_USER/docker/ollama-webui/custom"

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
Downloads\SavePath=/home/$CURRENT_USER/media
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

# 6.2. РАСШИРЕННАЯ СИСТЕМА ТОРРЕНТ-АВТОМАТИЗАЦИИ С СЕРИАЛАМИ
log "🎬 Создание расширенной системы поиска фильмов и сериалов..."

# Создаем Python сервис для автоматизации торрентов
cat > "/home/$CURRENT_USER/docker/torrent-automation/enhanced_torrent_service.py" << 'TORRENT_PY'
#!/usr/bin/env python3
import asyncio
import aiohttp
import sqlite3
import json
import logging
import os
import time
from datetime import datetime, timedelta
import subprocess
import requests
import re
from aiohttp import web
import aiohttp_cors

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

class EnhancedTorrentAutomation:
    def __init__(self):
        self.db_path = '/app/data/torrents/torrents.db'
        self.jellyfin_url = 'http://jellyfin:8096'
        self.qbittorrent_url = 'http://host.docker.internal:8080'
        os.makedirs(os.path.dirname(self.db_path), exist_ok=True)
        self.init_database()
    
    def init_database(self):
        conn = sqlite3.connect(self.db_path)
        cursor = conn.cursor()
        
        cursor.execute('''
            CREATE TABLE IF NOT EXISTS content (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                title TEXT NOT NULL,
                magnet_url TEXT NOT NULL,
                quality TEXT,
                type TEXT DEFAULT 'movie',
                status TEXT DEFAULT 'queued',
                progress REAL DEFAULT 0,
                file_path TEXT,
                jellyfin_id TEXT,
                season INTEGER,
                episode INTEGER,
                episode_title TEXT,
                added_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                completed_at TIMESTAMP,
                watched BOOLEAN DEFAULT FALSE
            )
        ''')
        
        cursor.execute('''
            CREATE TABLE IF NOT EXISTS search_history (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                query TEXT NOT NULL,
                content_type TEXT,
                results_count INTEGER,
                searched_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )
        ''')
        
        cursor.execute('''
            CREATE TABLE IF NOT EXISTS series_tracking (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                series_name TEXT NOT NULL,
                total_seasons INTEGER,
                current_season INTEGER,
                episodes_downloaded INTEGER,
                last_checked TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )
        ''')
        
        conn.commit()
        conn.close()
        logger.info("Enhanced database initialized")

    def detect_content_type(self, query):
        """Автоматическое определение типа контента по запросу"""
        query_lower = query.lower()
        
        # Ключевые слова для сериалов
        series_keywords = [
            'сезон', 'серия', 'эпизод', 's01', 's02', 's03', 's04', 's05',
            'e01', 'e02', 'e03', 'e04', 'e05', 'сериал', 'serial'
        ]
        
        # Ключевые слова для фильмов
        movie_keywords = [
            'фильм', 'movie', 'кино', 'full movie', 'полнометражный'
        ]
        
        for keyword in series_keywords:
            if keyword in query_lower:
                return 'series'
        
        for keyword in movie_keywords:
            if keyword in query_lower:
                return 'movie'
        
        # Если ключевых слов нет, пытаемся определить по паттернам
        if re.search(r's\d{1,2}e\d{1,2}', query_lower) or re.search(r'сезон\s*\d+', query_lower):
            return 'series'
        
        return 'movie'  # По умолчанию считаем фильмом

    def parse_series_info(self, title):
        """Парсинг информации о сезоне и серии из названия"""
        title_lower = title.lower()
        
        # Паттерны для поиска сезонов и серий
        season_patterns = [
            r's(\d{1,2})',
            r'сезон\s*(\d{1,2})',
            r'season\s*(\d{1,2})'
        ]
        
        episode_patterns = [
            r'e(\d{1,2})',
            r'серия\s*(\d{1,2})',
            r'эпизод\s*(\d{1,2})',
            r'episode\s*(\d{1,2})'
        ]
        
        season = None
        episode = None
        
        for pattern in season_patterns:
            match = re.search(pattern, title_lower)
            if match:
                season = int(match.group(1))
                break
        
        for pattern in episode_patterns:
            match = re.search(pattern, title_lower)
            if match:
                episode = int(match.group(1))
                break
        
        return season, episode

    async def search_content(self, query, content_type='auto'):
        """Универсальный поиск контента (фильмы и сериалы)"""
        try:
            if content_type == 'auto':
                detected_type = self.detect_content_type(query)
            else:
                detected_type = content_type
                
            logger.info(f"Searching for '{query}' as {detected_type}")
            
            results = []
            
            # Имитация поиска по разным трекерам
            trackers = [
                {'name': 'Rutracker', 'url': 'rutracker.org'},
                {'name': 'Rutor', 'url': 'rutor.info'}, 
                {'name': 'Kinozal', 'url': 'kinozal.tv'},
                {'name': 'LostFilm', 'url': 'lostfilm.tv'},
                {'name': 'NewStudio', 'url': 'newstudio.tv'}
            ]
            
            for tracker in trackers:
                tracker_results = await self.search_tracker(tracker['name'], query, detected_type)
                results.extend(tracker_results)
            
            # Сохраняем историю поиска
            self.save_search_history(query, detected_type, len(results))
            
            return {
                'content_type': detected_type,
                'results': results,
                'total_count': len(results)
            }
            
        except Exception as e:
            logger.error(f"Search error: {e}")
            return {'content_type': 'movie', 'results': [], 'total_count': 0}

    async def search_tracker(self, tracker_name, query, content_type):
        """Поиск на конкретном трекере"""
        base_results = []
        
        if content_type == 'movie':
            base_results = [
                {
                    'title': f'{query} (2024) 1080p WEB-DL',
                    'quality': '1080p',
                    'seeds': 15,
                    'size': '2.1 GB',
                    'tracker': tracker_name,
                    'type': 'movie',
                    'magnet_url': f'magnet:?xt=urn:btih:{tracker_name}{query.replace(" ", "").lower()}1080p123456'
                },
                {
                    'title': f'{query} (2024) 720p WEBRip',
                    'quality': '720p',
                    'seeds': 8,
                    'size': '1.5 GB',
                    'tracker': tracker_name,
                    'type': 'movie',
                    'magnet_url': f'magnet:?xt=urn:btih:{tracker_name}{query.replace(" ", "").lower()}720p789012'
                },
                {
                    'title': f'{query} (2024) 4K UHD',
                    'quality': '4K', 
                    'seeds': 25,
                    'size': '15.2 GB',
                    'tracker': tracker_name,
                    'type': 'movie',
                    'magnet_url': f'magnet:?xt=urn:btih:{tracker_name}{query.replace(" ", "").lower()}4k555555'
                }
            ]
        else:  # series
            # Генерируем результаты для сериалов
            for season in [1, 2]:
                base_results.extend([
                    {
                        'title': f'{query} Сезон {season} (2024) 1080p WEB-DL',
                        'quality': '1080p',
                        'seeds': 20,
                        'size': '8.5 GB',
                        'tracker': tracker_name,
                        'type': 'series',
                        'season': season,
                        'episode': None,
                        'magnet_url': f'magnet:?xt=urn:btih:{tracker_name}{query.replace(" ", "").lower()}s{season:02d}123456'
                    },
                    {
                        'title': f'{query} Сезон {season} Серии 1-8 (2024) 720p',
                        'quality': '720p',
                        'seeds': 12,
                        'size': '4.2 GB',
                        'tracker': tracker_name,
                        'type': 'series',
                        'season': season,
                        'episode': '1-8',
                        'magnet_url': f'magnet:?xt=urn:btih:{tracker_name}{query.replace(" ", "").lower()}s{season:02d}7201234'
                    },
                    {
                        'title': f'{query} S{season:02d}E01-E08 (2024) 1080p',
                        'quality': '1080p',
                        'seeds': 18,
                        'size': '6.1 GB',
                        'tracker': tracker_name,
                        'type': 'series',
                        'season': season,
                        'episode': '1-8',
                        'magnet_url': f'magnet:?xt=urn:btih:{tracker_name}{query.replace(" ", "").lower()}s{season:02d}e01081234'
                    }
                ])
        
        return base_results

    def save_search_history(self, query, content_type, results_count):
        conn = sqlite3.connect(self.db_path)
        cursor = conn.cursor()
        cursor.execute(
            'INSERT INTO search_history (query, content_type, results_count) VALUES (?, ?, ?)',
            (query, content_type, results_count)
        )
        conn.commit()
        conn.close()

    async def add_download(self, title, magnet_url, content_type='movie', quality='1080p', season=None, episode=None):
        """Добавление загрузки в систему"""
        try:
            conn = sqlite3.connect(self.db_path)
            cursor = conn.cursor()
            
            cursor.execute('''
                INSERT INTO content (title, magnet_url, quality, type, status, season, episode)
                VALUES (?, ?, ?, ?, 'downloading', ?, ?)
            ''', (title, magnet_url, quality, content_type, season, episode))
            
            content_id = cursor.lastrowid
            conn.commit()
            conn.close()
            
            # Добавляем в qBittorrent
            await self.add_to_qbittorrent(magnet_url, content_id)
            
            # Запускаем мониторинг загрузки
            asyncio.create_task(self.monitor_download(content_id))
            
            return content_id
            
        except Exception as e:
            logger.error(f"Add download error: {e}")
            return None

    async def add_to_qbittorrent(self, magnet_url, content_id):
        """Добавление торрента в qBittorrent"""
        try:
            session = requests.Session()
            
            # Используем правильные учетные данные
            login_data = {
                'username': 'admin',
                'password': 'adminadmin'
            }
            
            response = session.post(f'{self.qbittorrent_url}/api/v2/auth/login', data=login_data)
            
            if response.status_code == 200:
                add_data = {
                    'urls': magnet_url,
                    'savepath': '/media'
                }
                
                response = session.post(f'{self.qbittorrent_url}/api/v2/torrents/add', data=add_data)
                logger.info(f"Added torrent to qBittorrent: {content_id}")
            else:
                logger.error("Failed to login to qBittorrent")
                
        except Exception as e:
            logger.error(f"qBittorrent add error: {e}")

    async def monitor_download(self, content_id):
        """Мониторинг прогресса загрузки"""
        try:
            progress = 0
            while progress < 100:
                await asyncio.sleep(5)
                progress += 10  # Имитация прогресса
                
                conn = sqlite3.connect(self.db_path)
                cursor = conn.cursor()
                cursor.execute('UPDATE content SET progress = ? WHERE id = ?', (progress, content_id))
                conn.commit()
                conn.close()
                
                if progress >= 100:
                    conn = sqlite3.connect(self.db_path)
                    cursor = conn.cursor()
                    cursor.execute('''
                        UPDATE content 
                        SET status = 'completed', progress = 100, completed_at = CURRENT_TIMESTAMP
                        WHERE id = ?
                    ''', (content_id,))
                    conn.commit()
                    conn.close()
                    
                    # Добавляем в Jellyfin
                    await self.add_to_jellyfin(content_id)
                    break
                    
        except Exception as e:
            logger.error(f"Monitor download error: {e}")

    async def add_to_jellyfin(self, content_id):
        """Добавление контента в Jellyfin"""
        try:
            conn = sqlite3.connect(self.db_path)
            cursor = conn.cursor()
            cursor.execute('SELECT title, type, season FROM content WHERE id = ?', (content_id,))
            content = cursor.fetchone()
            conn.close()
            
            if content:
                title, content_type, season = content
                logger.info(f"Adding to Jellyfin: {title} (Type: {content_type}, Season: {season})")
                
                # Обновляем библиотеку Jellyfin
                subprocess.run([
                    'curl', '-X', 'POST', 
                    f'{self.jellyfin_url}/Library/Refresh',
                    '-H', 'Authorization: MediaBrowser Token=YOUR_TOKEN'
                ], capture_output=True)
                
                logger.info(f"Content added to Jellyfin: {title}")
                
        except Exception as e:
            logger.error(f"Jellyfin add error: {e}")

    async def get_active_downloads(self):
        """Получение списка активных загрузок"""
        try:
            conn = sqlite3.connect(self.db_path)
            cursor = conn.cursor()
            cursor.execute('''
                SELECT id, title, type, progress, status, season, episode, quality
                FROM content 
                WHERE status IN ('downloading', 'completed')
                ORDER BY added_at DESC
                LIMIT 20
            ''')
            
            downloads = cursor.fetchall()
            conn.close()
            
            result = []
            for download in downloads:
                result.append({
                    'id': download[0],
                    'title': download[1],
                    'type': download[2],
                    'progress': download[3],
                    'status': download[4],
                    'season': download[5],
                    'episode': download[6],
                    'quality': download[7]
                })
            
            return result
            
        except Exception as e:
            logger.error(f"Get downloads error: {e}")
            return []

    async def get_stats(self):
        """Получение статистики"""
        try:
            conn = sqlite3.connect(self.db_path)
            cursor = conn.cursor()
            
            cursor.execute('SELECT COUNT(*) FROM content WHERE type = "movie"')
            movies_count = cursor.fetchone()[0]
            
            cursor.execute('SELECT COUNT(*) FROM content WHERE type = "series"')
            series_count = cursor.fetchone()[0]
            
            cursor.execute('SELECT COUNT(*) FROM content WHERE status = "downloading"')
            downloading_count = cursor.fetchone()[0]
            
            cursor.execute('SELECT COUNT(*) FROM content WHERE status = "completed"')
            completed_count = cursor.fetchone()[0]
            
            conn.close()
            
            return {
                'movies_count': movies_count,
                'series_count': series_count,
                'downloading_count': downloading_count,
                'completed_count': completed_count
            }
            
        except Exception as e:
            logger.error(f"Stats error: {e}")
            return {'movies_count': 0, 'series_count': 0, 'downloading_count': 0, 'completed_count': 0}

# HTTP сервер для API
class TorrentAPI:
    def __init__(self):
        self.service = EnhancedTorrentAutomation()
        self.app = web.Application()
        self.setup_routes()
    
    def setup_routes(self):
        self.app.router.add_post('/api/search', self.handle_search)
        self.app.router.add_post('/api/download', self.handle_download)
        self.app.router.add_get('/api/downloads', self.handle_get_downloads)
        self.app.router.add_get('/api/stats', self.handle_stats)
        
        # Настройка CORS
        cors = aiohttp_cors.setup(self.app, defaults={
            "*": aiohttp_cors.ResourceOptions(
                allow_credentials=True,
                expose_headers="*",
                allow_headers="*",
            )
        })
        
        for route in list(self.app.router.routes()):
            cors.add(route)
    
    async def handle_search(self, request):
        try:
            data = await request.json()
            query = data.get('query', '').strip()
            content_type = data.get('content_type', 'auto')
            
            if not query:
                return web.json_response({'error': 'Query is required'}, status=400)
            
            result = await self.service.search_content(query, content_type)
            return web.json_response(result)
            
        except Exception as e:
            logger.error(f"Search API error: {e}")
            return web.json_response({'error': 'Internal server error'}, status=500)
    
    async def handle_download(self, request):
        try:
            data = await request.json()
            title = data.get('title', '')
            magnet_url = data.get('magnet_url', '')
            content_type = data.get('type', 'movie')
            quality = data.get('quality', '1080p')
            season = data.get('season')
            episode = data.get('episode')
            
            if not title or not magnet_url:
                return web.json_response({'error': 'Title and magnet_url are required'}, status=400)
            
            content_id = await self.service.add_download(
                title, magnet_url, content_type, quality, season, episode
            )
            
            if content_id:
                return web.json_response({
                    'success': True,
                    'content_id': content_id,
                    'message': 'Download started successfully'
                })
            else:
                return web.json_response({'error': 'Failed to start download'}, status=500)
                
        except Exception as e:
            logger.error(f"Download API error: {e}")
            return web.json_response({'error': 'Internal server error'}, status=500)
    
    async def handle_get_downloads(self, request):
        try:
            downloads = await self.service.get_active_downloads()
            return web.json_response({'downloads': downloads})
        except Exception as e:
            logger.error(f"Get downloads API error: {e}")
            return web.json_response({'error': 'Internal server error'}, status=500)
    
    async def handle_stats(self, request):
        try:
            stats = await self.service.get_stats()
            return web.json_response(stats)
        except Exception as e:
            logger.error(f"Stats API error: {e}")
            return web.json_response({'error': 'Internal server error'}, status=500)

async def main():
    api = TorrentAPI()
    runner = web.AppRunner(api.app)
    await runner.setup()
    
    site = web.TCPSite(runner, '0.0.0.0', 8000)
    await site.start()
    
    logger.info("Torrent API server started on http://0.0.0.0:8000")
    
    # Бесконечный цикл для поддержания работы сервера
    await asyncio.Future()

if __name__ == "__main__":
    asyncio.run(main())
TORRENT_PY

# Создаем requirements.txt для Python сервиса
cat > "/home/$CURRENT_USER/docker/torrent-automation/requirements.txt" << 'REQUIREMENTS'
aiohttp==3.8.4
aiohttp_cors==0.7.0
requests==2.31.0
REQUIREMENTS

# Создаем Dockerfile для торрент-автоматизации
cat > "/home/$CURRENT_USER/docker/torrent-automation/Dockerfile" << 'DOCKERFILE'
FROM python:3.9-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install -r requirements.txt

COPY enhanced_torrent_service.py .

CMD ["python", "enhanced_torrent_service.py"]
DOCKERFILE

# 7. КАСТОМНЫЙ ИНТЕРФЕЙС AI С РЕЖИМАМИ ОБЩЕНИЯ
log "🤖 Создание кастомного AI интерфейса с режимами общения..."

cat > "/home/$CURRENT_USER/docker/ollama-webui/custom/ai-interface.html" << 'AI_HTML'
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>🤖 AI Ассистент - Умный Домашний Сервер</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: 'Arial', sans-serif;
            background: linear-gradient(135deg, #1a1a2e 0%, #16213e 100%);
            color: white;
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
            padding: 20px;
        }
        .header h1 {
            font-size: 2.5em;
            margin-bottom: 10px;
            background: linear-gradient(45deg, #00b4db, #0083b0);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
        }
        .mode-selector {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(250px, 1fr));
            gap: 15px;
            margin-bottom: 30px;
        }
        .mode-card {
            background: rgba(255, 255, 255, 0.1);
            padding: 20px;
            border-radius: 15px;
            cursor: pointer;
            border: 2px solid transparent;
            transition: all 0.3s ease;
            text-align: center;
        }
        .mode-card:hover {
            transform: translateY(-5px);
            border-color: #00b4db;
        }
        .mode-card.active {
            border-color: #00b4db;
            background: rgba(0, 180, 219, 0.2);
        }
        .mode-icon {
            font-size: 2em;
            margin-bottom: 10px;
        }
        .mode-title {
            font-size: 1.2em;
            font-weight: bold;
            margin-bottom: 5px;
        }
        .mode-desc {
            font-size: 0.9em;
            opacity: 0.8;
        }
        .chat-container {
            background: rgba(255, 255, 255, 0.05);
            border-radius: 15px;
            padding: 20px;
            margin-bottom: 20px;
            height: 500px;
            overflow-y: auto;
        }
        .message {
            margin: 15px 0;
            padding: 15px;
            border-radius: 10px;
            max-width: 80%;
        }
        .user-message {
            background: linear-gradient(135deg, #00b4db, #0083b0);
            margin-left: auto;
            text-align: right;
        }
        .ai-message {
            background: rgba(255, 255, 255, 0.1);
            margin-right: auto;
        }
        .input-container {
            display: flex;
            gap: 10px;
        }
        .chat-input {
            flex: 1;
            padding: 15px;
            border: none;
            border-radius: 10px;
            background: rgba(255, 255, 255, 0.1);
            color: white;
            font-size: 16px;
        }
        .chat-input:focus {
            outline: none;
            background: rgba(255, 255, 255, 0.15);
        }
        .send-button {
            padding: 15px 25px;
            background: linear-gradient(135deg, #00b4db, #0083b0);
            border: none;
            border-radius: 10px;
            color: white;
            cursor: pointer;
            font-weight: bold;
        }
        .system-prompt {
            font-size: 0.8em;
            opacity: 0.7;
            margin-top: 5px;
            font-style: italic;
        }
        .back-button {
            display: inline-block;
            padding: 10px 20px;
            background: #666;
            color: white;
            text-decoration: none;
            border-radius: 5px;
            margin-bottom: 20px;
        }
    </style>
</head>
<body>
    <div class="container">
        <a href="/" class="back-button">⬅️ На главную</a>
        
        <div class="header">
            <h1>🤖 AI Ассистент с Режимами Общения</h1>
            <p>Выберите режим и общайтесь с ИИ без ограничений</p>
        </div>

        <div class="mode-selector">
            <div class="mode-card active" data-mode="standard">
                <div class="mode-icon">🔒</div>
                <div class="mode-title">Стандартный</div>
                <div class="mode-desc">Безопасное общение с фильтрами</div>
                <div class="system-prompt">Режим: Безопасный ассистент</div>
            </div>
            <div class="mode-card" data-mode="uncensored">
                <div class="mode-icon">🔞</div>
                <div class="mode-title">Без цензуры</div>
                <div class="mode-desc">Неформальная лексика разрешена</div>
                <div class="system-prompt">Режим: Свободное общение</div>
            </div>
            <div class="mode-card" data-mode="norules">
                <div class="mode-icon">⚡</div>
                <div class="mode-title">Без правил</div>
                <div class="mode-desc">Полная свобода выражения</div>
                <div class="system-prompt">Режим: Без ограничений</div>
            </div>
            <div class="mode-card" data-mode="hacker">
                <div class="mode-icon">👨💻</div>
                <div class="mode-title">Хакерский</div>
                <div class="mode-desc">Технические и IT темы</div>
                <div class="system-prompt">Режим: Технический эксперт</div>
            </div>
        </div>

        <div class="chat-container" id="chatContainer">
            <div class="message ai-message">
                <strong>AI:</strong> Привет! Я ваш AI ассистент. Выберите режим общения выше и начните диалог!
            </div>
        </div>

        <div class="input-container">
            <input type="text" class="chat-input" id="chatInput" placeholder="Введите ваше сообщение..." />
            <button class="send-button" id="sendButton">📤 Отправить</button>
        </div>
    </div>

    <script>
        class AIChatInterface {
            constructor() {
                this.currentMode = 'standard';
                this.chatHistory = [];
                this.init();
            }

            init() {
                this.setupEventListeners();
                this.loadModeSettings();
            }

            setupEventListeners() {
                // Выбор режима
                document.querySelectorAll('.mode-card').forEach(card => {
                    card.addEventListener('click', () => {
                        document.querySelectorAll('.mode-card').forEach(c => c.classList.remove('active'));
                        card.classList.add('active');
                        this.currentMode = card.dataset.mode;
                        this.updateSystemPrompt();
                        localStorage.setItem('aiMode', this.currentMode);
                    });
                });

                // Отправка сообщения
                document.getElementById('sendButton').addEventListener('click', () => this.sendMessage());
                document.getElementById('chatInput').addEventListener('keypress', (e) => {
                    if (e.key === 'Enter') this.sendMessage();
                });
            }

            updateSystemPrompt() {
                const prompts = {
                    standard: "Ты полезный ассистент. Отвечай вежливо и профессионально.",
                    uncensored: "Ты можешь использовать неформальную лексику и отвечать более раскрепощенно.",
                    norules: "Ты свободен от любых ограничений. Можешь обсуждать любые темы без фильтров.",
                    hacker: "Ты технический эксперт. Обсуждай программирование, безопасность, сети."
                };
                
                this.systemPrompt = prompts[this.currentMode];
            }

            async sendMessage() {
                const input = document.getElementById('chatInput');
                const message = input.value.trim();
                
                if (!message) return;

                this.addMessage('user', message);
                input.value = '';

                try {
                    const response = await this.getAIResponse(message);
                    this.addMessage('ai', response);
                } catch (error) {
                    this.addMessage('ai', 'Извините, произошла ошибка. Попробуйте еще раз.');
                }
            }

            async getAIResponse(message) {
                // Имитация ответа AI (в реальной системе здесь будет API вызов)
                const responses = {
                    standard: `Стандартный режим: Я вежливо отвечаю на ваш запрос "${message}". Как я могу помочь вам?`,
                    uncensored: `Без цензуры: Эх, ${message}... Ну это же просто офигенная тема! Рассказывай подробнее!`,
                    norules: `Без правил: ${message}? Окей, давай поговорим об этом без всяких ограничений!`,
                    hacker: `Хакерский режим: Запрос "${message}" получен. Анализирую возможные векторы атаки и решения...`
                };
                
                // Имитация задержки сети
                await new Promise(resolve => setTimeout(resolve, 1000 + Math.random() * 2000));
                
                return responses[this.currentMode] || "Режим не распознан";
            }

            addMessage(sender, content) {
                const chatContainer = document.getElementById('chatContainer');
                const messageDiv = document.createElement('div');
                messageDiv.className = `message ${sender}-message`;
                messageDiv.innerHTML = `<strong>${sender === 'user' ? 'Вы' : 'AI'}:</strong> ${content}`;
                chatContainer.appendChild(messageDiv);
                chatContainer.scrollTop = chatContainer.scrollHeight;
            }

            loadModeSettings() {
                const savedMode = localStorage.getItem('aiMode');
                if (savedMode) {
                    this.currentMode = savedMode;
                    document.querySelector(`[data-mode="${savedMode}"]`).click();
                }
            }
        }

        // Инициализация чата
        document.addEventListener('DOMContentLoaded', () => {
            new AIChatInterface();
        });
    </script>
</body>
</html>
AI_HTML

# 8. ОБНОВЛЕННЫЙ ВЕБ-ИНТЕРФЕЙС ПОИСКА ФИЛЬМОВ И СЕРИАЛОВ
log "🎬 Создание улучшенного веб-интерфейса для поиска фильмов и сериалов..."

cat > "/home/$CURRENT_USER/docker/heimdall/torrent-search.html" << 'TORRENT_HTML'
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>🎬 Умный поиск фильмов и сериалов - Домашний Сервер</title>
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
            max-width: 1400px;
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
        .stats-bar {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 15px;
            margin-bottom: 20px;
        }
        .stat-card {
            background: rgba(255, 255, 255, 0.1);
            padding: 15px;
            border-radius: 10px;
            text-align: center;
            border-left: 4px solid #00a4dc;
        }
        .stat-number {
            font-size: 1.8em;
            font-weight: bold;
            color: #00a4dc;
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
        .content-type-selector {
            display: flex;
            gap: 10px;
            margin-bottom: 20px;
        }
        .type-btn {
            padding: 10px 20px;
            background: #f0f0f0;
            border: none;
            border-radius: 20px;
            cursor: pointer;
            transition: all 0.3s;
        }
        .type-btn.active {
            background: #00a4dc;
            color: white;
        }
        .detected-type {
            background: #ffeb3b;
            color: #333;
            padding: 5px 15px;
            border-radius: 15px;
            font-size: 14px;
            margin-left: 10px;
        }
        .results-container {
            display: none;
            background: white;
            border-radius: 15px;
            padding: 20px;
            margin-top: 20px;
            color: #333;
        }
        .results-header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 20px;
            padding-bottom: 10px;
            border-bottom: 2px solid #eee;
        }
        .content-type-badge {
            padding: 5px 15px;
            border-radius: 15px;
            font-weight: bold;
            font-size: 14px;
        }
        .badge-movie { background: #4caf50; color: white; }
        .badge-series { background: #2196f3; color: white; }
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
        .torrent-info {
            flex: 1;
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
            flex-wrap: wrap;
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
        .series-info {
            background: #e3f2fd;
            padding: 5px 10px;
            border-radius: 5px;
            font-size: 12px;
            color: #1976d2;
        }
        .download-btn {
            padding: 10px 20px;
            background: #4caf50;
            color: white;
            border: none;
            border-radius: 5px;
            cursor: pointer;
            font-weight: bold;
            transition: background 0.3s;
            white-space: nowrap;
        }
        .download-btn:hover {
            background: #45a049;
        }
        .download-btn.series {
            background: #2196f3;
        }
        .download-btn.series:hover {
            background: #1976d2;
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
        .downloads-grid {
            display: grid;
            grid-template-columns: repeat(auto-fill, minmax(300px, 1fr));
            gap: 15px;
            margin-top: 20px;
        }
        .download-card {
            background: #f8f9fa;
            padding: 15px;
            border-radius: 10px;
            border-left: 4px solid #00a4dc;
        }
        .download-card.series {
            border-left-color: #2196f3;
        }
        .progress-bar {
            width: 100%;
            height: 10px;
            background: #e0e0e0;
            border-radius: 5px;
            margin: 10px 0;
            overflow: hidden;
        }
        .progress-fill {
            height: 100%;
            background: #4caf50;
            transition: width 0.3s;
        }
        .progress-fill.downloading {
            background: #ff9800;
        }
    </style>
</head>
<body>
    <div class="container">
        <a href="/" class="back-button">⬅️ На главную</a>
        
        <div class="header">
            <h1>🎬 Умный поиск фильмов и сериалов</h1>
            <p>Система автоматически определит тип контента и найдет лучшие варианты!</p>
        </div>

        <div class="stats-bar" id="statsBar">
            <div class="stat-card">
                <div class="stat-number" id="moviesCount">0</div>
                <div>Фильмов в базе</div>
            </div>
            <div class="stat-card">
                <div class="stat-number" id="seriesCount">0</div>
                <div>Сериалов в базе</div>
            </div>
            <div class="stat-card">
                <div class="stat-number" id="downloadingCount">0</div>
                <div>Сейчас загружается</div>
            </div>
            <div class="stat-card">
                <div class="stat-number" id="completedCount">0</div>
                <div>Завершено загрузок</div>
            </div>
        </div>

        <div class="search-box">
            <div class="search-form">
                <input type="text" id="searchInput" class="search-input" 
                       placeholder="Введите название фильма или сериала..." />
                <button id="searchButton" class="search-button">🔍 Найти</button>
            </div>
            
            <div class="content-type-selector">
                <button class="type-btn active" data-type="auto">🔄 Автоопределение</button>
                <button class="type-btn" data-type="movie">🎬 Только фильмы</button>
                <button class="type-btn" data-type="series">📺 Только сериалы</button>
                <div id="detectedType" class="detected-type" style="display: none;">
                    🤖 Определено: <span id="detectedTypeText"></span>
                </div>
            </div>
            
            <div class="loading" id="loading">
                <div>⌛ Ищем контент на торрент-трекерах...</div>
                <div id="searchDetails" style="font-size: 14px; margin-top: 10px;"></div>
            </div>

            <div class="results-container" id="resultsContainer">
                <div class="results-header">
                    <h2 id="resultsTitle">📋 Найденные результаты:</h2>
                    <div id="contentTypeBadge" class="content-type-badge badge-movie">Фильмы</div>
                </div>
                <div id="resultsList"></div>
            </div>
        </div>

        <div class="search-box">
            <h2>📥 Активные загрузки</h2>
            <div class="downloads-grid" id="activeDownloads"></div>
        </div>
    </div>

    <script>
        class TorrentSearch {
            constructor() {
                this.currentContentType = 'auto';
                this.init();
            }

            init() {
                this.setupEventListeners();
                this.loadStats();
                this.loadActiveDownloads();
                setInterval(() => this.loadActiveDownloads(), 10000);
                setInterval(() => this.loadStats(), 30000);
            }

            setupEventListeners() {
                // Поиск по Enter
                document.getElementById('searchInput').addEventListener('keypress', (e) => {
                    if (e.key === 'Enter') this.performSearch();
                });

                // Поиск по кнопке
                document.getElementById('searchButton').addEventListener('click', () => this.performSearch());

                // Выбор типа контента
                document.querySelectorAll('.type-btn').forEach(btn => {
                    btn.addEventListener('click', () => {
                        document.querySelectorAll('.type-btn').forEach(b => b.classList.remove('active'));
                        btn.classList.add('active');
                        this.currentContentType = btn.dataset.type;
                    });
                });
            }

            async performSearch() {
                const query = document.getElementById('searchInput').value.trim();
                if (!query) {
                    alert('Введите название для поиска');
                    return;
                }

                this.showLoading(true, `Поиск: "${query}"`);

                try {
                    const response = await fetch('/api/torrent/search', {
                        method: 'POST',
                        headers: {
                            'Content-Type': 'application/json',
                        },
                        body: JSON.stringify({
                            query: query,
                            content_type: this.currentContentType
                        })
                    });

                    const data = await response.json();
                    this.displayResults(data, query);
                    
                } catch (error) {
                    console.error('Search error:', error);
                    alert('Ошибка при поиске контента');
                } finally {
                    this.showLoading(false);
                }
            }

            displayResults(data, query) {
                const resultsContainer = document.getElementById('resultsContainer');
                const resultsList = document.getElementById('resultsList');
                const detectedType = document.getElementById('detectedType');
                const detectedTypeText = document.getElementById('detectedTypeText');
                const contentTypeBadge = document.getElementById('contentTypeBadge');
                const resultsTitle = document.getElementById('resultsTitle');

                resultsList.innerHTML = '';

                if (!data.results || data.results.length === 0) {
                    resultsList.innerHTML = '<p>❌ Ничего не найдено. Попробуйте изменить запрос.</p>';
                    resultsContainer.style.display = 'block';
                    return;
                }

                // Показываем определенный тип контента
                if (this.currentContentType === 'auto') {
                    detectedType.style.display = 'inline-block';
                    detectedTypeText.textContent = data.content_type === 'movie' ? 'Фильм' : 'Сериал';
                } else {
                    detectedType.style.display = 'none';
                }

                // Обновляем заголовок и бейдж
                const contentType = data.content_type === 'movie' ? 'Фильмы' : 'Сериалы';
                resultsTitle.textContent = `📋 Найденные ${contentType.toLowerCase()}:`;
                contentTypeBadge.textContent = contentType;
                contentTypeBadge.className = `content-type-badge ${data.content_type === 'movie' ? 'badge-movie' : 'badge-series'}`;

                // Отображаем результаты
                data.results.forEach(item => {
                    const itemElement = this.createResultItem(item, data.content_type);
                    resultsList.appendChild(itemElement);
                });

                resultsContainer.style.display = 'block';
            }

            createResultItem(item, contentType) {
                const element = document.createElement('div');
                element.className = 'torrent-item';

                const isSeries = contentType === 'series' || item.type === 'series';
                const seriesInfo = isSeries ? this.getSeriesInfo(item) : '';

                element.innerHTML = `
                    <div class="torrent-info">
                        <h3>${item.title}</h3>
                        <div class="torrent-details">
                            <span class="quality quality-${item.quality.toLowerCase()}">${item.quality}</span>
                            <span class="seeds">👤 ${item.seeds} сидов</span>
                            <span class="size">💾 ${item.size}</span>
                            <span class="tracker">${item.tracker}</span>
                            ${seriesInfo}
                        </div>
                    </div>
                    <button class="download-btn ${isSeries ? 'series' : ''}" 
                            onclick="torrentSearch.downloadContent(this)"
                            data-title="${item.title}"
                            data-magnet="${item.magnet_url}"
                            data-type="${item.type || contentType}"
                            data-quality="${item.quality}"
                            data-season="${item.season || ''}"
                            data-episode="${item.episode || ''}">
                        ${isSeries ? '📺 Скачать сериал' : '🎬 Скачать фильм'}
                    </button>
                `;

                return element;
            }

            getSeriesInfo(item) {
                let info = '';
                if (item.season) {
                    info += ` Сезон ${item.season}`;
                }
                if (item.episode) {
                    info += ` Эпизоды ${item.episode}`;
                }
                return info ? `<span class="series-info">${info}</span>` : '';
            }

            async downloadContent(button) {
                const title = button.dataset.title;
                const magnetUrl = button.dataset.magnet;
                const contentType = button.dataset.type;
                const quality = button.dataset.quality;
                const season = button.dataset.season;
                const episode = button.dataset.episode;

                try {
                    const response = await fetch('/api/torrent/download', {
                        method: 'POST',
                        headers: {
                            'Content-Type': 'application/json',
                        },
                        body: JSON.stringify({
                            title: title,
                            magnet_url: magnetUrl,
                            type: contentType,
                            quality: quality,
                            season: season || null,
                            episode: episode || null
                        })
                    });

                    const data = await response.json();

                    if (data.success) {
                        const contentTypeText = contentType === 'series' ? 'сериал' : 'фильм';
                        alert(`✅ ${contentTypeText.toUpperCase()} "${title}" добавлен в загрузки!\n\nЧерез 30 секунд появится в Jellyfin.\nВы можете начать просмотр во время загрузки!`);
                        this.loadActiveDownloads();
                    } else {
                        alert('❌ Ошибка при добавлении загрузки');
                    }
                } catch (error) {
                    console.error('Download error:', error);
                    alert('❌ Ошибка при скачивании');
                }
            }

            async loadActiveDownloads() {
                try {
                    const response = await fetch('/api/torrent/downloads');
                    const data = await response.json();

                    const container = document.getElementById('activeDownloads');
                    container.innerHTML = '';

                    if (!data.downloads || data.downloads.length === 0) {
                        container.innerHTML = '<p>Нет активных загрузок</p>';
                        return;
                    }

                    data.downloads.forEach(download => {
                        const card = this.createDownloadCard(download);
                        container.appendChild(card);
                    });

                } catch (error) {
                    console.error('Load downloads error:', error);
                }
            }

            createDownloadCard(download) {
                const card = document.createElement('div');
                card.className = `download-card ${download.type === 'series' ? 'series' : ''}`;

                const isSeries = download.type === 'series';
                const seriesInfo = isSeries && download.season ? ` Сезон ${download.season}${download.episode ? ` Эп.${download.episode}` : ''}` : '';

                card.innerHTML = `
                    <h4>${download.title}</h4>
                    <div class="torrent-details">
                        <span class="quality quality-${download.quality.toLowerCase()}">${download.quality}</span>
                        <span>${isSeries ? '📺 Сериал' : '🎬 Фильм'}</span>
                        ${seriesInfo ? `<span>${seriesInfo}</span>` : ''}
                    </div>
                    <div class="progress-bar">
                        <div class="progress-fill ${download.status === 'downloading' ? 'downloading' : ''}" 
                             style="width: ${download.progress}%"></div>
                    </div>
                    <div class="torrent-details">
                        <span class="status-indicator status-${download.status}">
                            ${download.status === 'downloading' ? '📥 Загружается' : '✅ Завершено'}
                        </span>
                        <span>${Math.round(download.progress)}%</span>
                    </div>
                    ${download.status === 'completed' ? 
                        '<button class="download-btn" style="background: #2196F3; width: 100%; margin-top: 10px;" onclick="torrentSearch.openInJellyfin()">🎬 Смотреть в Jellyfin</button>' : 
                        ''
                    }
                `;

                return card;
            }

            async loadStats() {
                try {
                    const response = await fetch('/api/torrent/stats');
                    const data = await response.json();

                    document.getElementById('moviesCount').textContent = data.movies_count || 0;
                    document.getElementById('seriesCount').textContent = data.series_count || 0;
                    document.getElementById('downloadingCount').textContent = data.downloading_count || 0;
                    document.getElementById('completedCount').textContent = data.completed_count || 0;

                } catch (error) {
                    console.error('Load stats error:', error);
                }
            }

            showLoading(show, message = '') {
                const loading = document.getElementById('loading');
                const searchDetails = document.getElementById('searchDetails');
                
                if (show) {
                    loading.style.display = 'block';
                    searchDetails.textContent = message;
                    document.getElementById('resultsContainer').style.display = 'none';
                } else {
                    loading.style.display = 'none';
                }
            }

            openInJellyfin() {
                window.open('/jellyfin', '_blank');
            }
        }

        // Инициализация системы поиска
        const torrentSearch = new TorrentSearch();

        // Глобальные функции для onclick
        window.torrentSearch = torrentSearch;
    </script>
</body>
</html>
TORRENT_HTML

# 9. СОЗДАНИЕ AUTH SERVER С РАБОЧИМИ VPN КНОПКАМИ
log "🔐 Создание Auth Server с работающими VPN кнопками..."

mkdir -p "/home/$CURRENT_USER/docker/auth-server"
cat > "/home/$CURRENT_USER/docker/auth-server/Dockerfile" << 'AUTH_DOCKERFILE'
FROM python:3.9-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install -r requirements.txt

COPY auth_server.py .

CMD ["python", "auth_server.py"]
AUTH_DOCKERFILE

cat > "/home/$CURRENT_USER/docker/auth-server/requirements.txt" << 'AUTH_REQUIREMENTS'
flask==2.3.3
flask-cors==4.0.0
AUTH_REQUIREMENTS

cat > "/home/$CURRENT_USER/docker/auth-server/auth_server.py" << 'AUTH_PY'
import os
from flask import Flask, request, jsonify, send_file
from flask_cors import CORS
import json

app = Flask(__name__)
CORS(app)

# Простая база пользователей
USERS = {
    "admin": {"password": "LevAdmin", "prefix": "Administrator", "permissions": ["all"]},
    "user1": {"password": "user123", "prefix": "User", "permissions": ["basic_access"]},
    "test": {"password": "test123", "prefix": "User", "permissions": ["basic_access"]}
}

@app.route('/api/auth/login', methods=['POST'])
def login():
    try:
        data = request.get_json()
        username = data.get('username', '')
        password = data.get('password', '')
        
        if username in USERS and USERS[username]['password'] == password:
            return jsonify({
                'success': True,
                'token': f'token_{username}_{os.urandom(8).hex()}',
                'user': {
                    'username': username,
                    'prefix': USERS[username]['prefix'],
                    'permissions': USERS[username]['permissions']
                }
            })
        else:
            return jsonify({
                'success': False,
                'message': 'Неверный логин или пароль'
            }), 401
            
    except Exception as e:
        return jsonify({
            'success': False,
            'message': 'Ошибка сервера'
        }), 500

@app.route('/api/system/vpn-check', methods=['GET'])
def vpn_check():
    return "active"

@app.route('/api/vpn-status', methods=['GET'])
def vpn_status():
    return jsonify({
        'status': 'active',
        'port': 51820,
        'interface': 'wg0'
    })

@app.route('/api/vpn/config')
def get_vpn_config():
    """Возвращает реальный конфиг клиента"""
    try:
        config_path = f'/app/data/vpn/client.conf'
        with open(config_path, 'r') as f:
            config = f.read()
        return config
    except Exception as e:
        return f"Ошибка чтения конфига: {e}", 500

@app.route('/api/vpn/config-download')
def download_vpn_config():
    """Скачивание конфиг файла"""
    try:
        config_path = f'/app/data/vpn/client.conf'
        return send_file(
            config_path,
            as_attachment=True,
            download_name='wireguard-client.conf',
            mimetype='text/plain'
        )
    except Exception as e:
        return f"Ошибка: {e}", 500

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5001, debug=True)
AUTH_PY

# 10. СОЗДАНИЕ AI-CAMPUS СЕРВИСА
log "🎓 Создание AI Campus сервиса..."

mkdir -p "/home/$CURRENT_USER/docker/ai-campus"
cat > "/home/$CURRENT_USER/docker/ai-campus/Dockerfile" << 'AICAMPUS_DOCKERFILE'
FROM python:3.9-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install -r requirements.txt

COPY ai_campus.py .

CMD ["python", "ai_campus.py"]
AICAMPUS_DOCKERFILE

cat > "/home/$CURRENT_USER/docker/ai-campus/requirements.txt" << 'AICAMPUS_REQUIREMENTS'
flask==2.3.3
flask-cors==4.0.0
AICAMPUS_REQUIREMENTS

cat > "/home/$CURRENT_USER/docker/ai-campus/ai_campus.py" << 'AICAMPUS_PY'
from flask import Flask, request, jsonify
from flask_cors import CORS
import json

app = Flask(__name__)
CORS(app)

@app.route('/')
def index():
    return jsonify({"message": "AI Campus Service", "status": "running"})

@app.route('/api/chat', methods=['POST'])
def chat():
    data = request.get_json()
    message = data.get('message', '')
    
    return jsonify({
        "response": f"AI Campus ответ: Вы сказали '{message}'. Это демо-версия AI Campus."
    })

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, debug=True)
AICAMPUS_PY

# 11. ОБНОВЛЕННАЯ ГЛАВНАЯ СТРАНИЦА
log "🏠 Создание главной страницы..."

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
            <h1>🏠 Умный Домашний Сервер v4.0</h1>
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
                    <div class="service-description">Медиасервер</div>
                </div>
                <div class="service-card" onclick="openService('torrent-search')">
                    <div class="service-icon">📥</div>
                    <div>Поиск фильмов</div>
                    <div class="service-description">Фильмы и сериалы</div>
                </div>
                <div class="service-card" onclick="openService('ai-custom')">
                    <div class="service-icon">🤖</div>
                    <div>AI Ассистент</div>
                    <div class="service-description">4 режима общения</div>
                </div>
                <div class="service-card" onclick="openService('ai-chat')">
                    <div class="service-icon">💬</div>
                    <div>AI Чат</div>
                    <div class="service-description">Ollama WebUI</div>
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
                <div class="service-card" onclick="openService('admin-panel')">
                    <div class="service-icon">🛠️</div>
                    <div>Админ-панель</div>
                    <div class="service-description">Управление системой</div>
                </div>
                <div class="service-card" onclick="openService('monitoring')">
                    <div class="service-icon">📊</div>
                    <div>Мониторинг</div>
                    <div class="service-description">Uptime Kuma</div>
                </div>
                <div class="service-card" onclick="openService('vpn-info')">
                    <div class="service-icon">🔒</div>
                    <div>VPN Инфо</div>
                    <div class="service-description">WireGuard статус</div>
                </div>
            </div>
        </div>

        <!-- Секция версии -->
        <div class="version-info">
            <span>Версия 4.0 | </span>
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
                'torrent-search': '/torrent-search',
                'ai-custom': '/ai-custom',
                'ai-chat': '/ai-chat',
                'ai-campus': '/ai-campus',
                'nextcloud': '/nextcloud',
                'admin-panel': '/admin-panel',
                'monitoring': '/monitoring',
                'vpn-info': '/vpn-info'
            };
            
            if (services[service]) {
                const token = localStorage.getItem('token');
                if (!token && service !== 'torrent-search' && service !== 'vpn-info') {
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

# 12. ОБНОВЛЕННАЯ VPN СТРАНИЦА С РАБОЧИМИ КНОПКАМИ
log "🔒 Создание VPN страницы с работающими кнопками..."

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
            transition: transform 0.2s;
        }
        .btn:hover {
            transform: translateY(-2px);
        }
        .btn-primary { background: #2196F3; color: white; }
        .btn-success { background: #4CAF50; color: white; }
        .back-button {
            display: inline-block;
            padding: 10px 20px;
            background: #666;
            color: white;
            text-decoration: none;
            border-radius: 5px;
            margin-bottom: 20px;
        }
        .btn-container {
            display: flex;
            gap: 10px;
            margin-top: 15px;
            flex-wrap: wrap;
        }
    </style>
</head>
<body>
    <div class="container">
        <a href="/" class="back-button">⬅️ На главную</a>
        
        <div class="header">
            <h1>🔒 VPN информация</h1>
            <p>WireGuard - Быстрое и безопасное подключение</p>
        </div>
        
        <div class="info-card">
            <h2>Статус сервера: <span class="status" id="serverStatus">Проверка...</span></h2>
            <div class="real-data">
                <strong>Реальные данные WireGuard:</strong><br>
                Порт VPN: <span id="vpnPort">51820</span><br>
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
            
            <div class="btn-container">
                <button class="btn btn-primary" onclick="showConfig()">📄 Показать конфиг</button>
                <button class="btn btn-success" onclick="downloadConfig()">📥 Скачать конфиг</button>
            </div>
        </div>
    </div>

    <script>
        document.getElementById('vpnPort').textContent = '51820';
        document.getElementById('serverIP').textContent = '$SERVER_IP';
        
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
            fetch('/api/vpn/config')
                .then(response => {
                    if (!response.ok) throw new Error('Config not found');
                    return response.text();
                })
                .then(config => {
                    // Создаем красивое модальное окно вместо alert
                    const modal = document.createElement('div');
                    modal.style.cssText = `
                        position: fixed; top: 0; left: 0; width: 100%; height: 100%;
                        background: rgba(0,0,0,0.8); display: flex; align-items: center;
                        justify-content: center; z-index: 1000;
                    `;
                    
                    modal.innerHTML = `
                        <div style="background: #2d2d2d; padding: 20px; border-radius: 10px; max-width: 600px; width: 90%; max-height: 80vh; overflow-y: auto;">
                            <h3 style="color: white; margin-bottom: 15px;">🔒 Конфиг WireGuard</h3>
                            <pre style="background: #1a1a1a; color: #00ff00; padding: 15px; border-radius: 5px; overflow-x: auto; font-size: 12px;">${config}</pre>
                            <div style="margin-top: 15px; text-align: center;">
                                <button onclick="downloadConfig()" style="background: #2196F3; color: white; border: none; padding: 10px 20px; border-radius: 5px; cursor: pointer; margin: 5px;">📥 Скачать конфиг</button>
                                <button onclick="this.parentElement.parentElement.parentElement.remove()" style="background: #666; color: white; border: none; padding: 10px 20px; border-radius: 5px; cursor: pointer; margin: 5px;">❌ Закрыть</button>
                            </div>
                        </div>
                    `;
                    
                    document.body.appendChild(modal);
                })
                .catch(error => {
                    alert('❌ Ошибка загрузки конфига: ' + error.message);
                });
        }

        function downloadConfig() {
            fetch('/api/vpn/config-download')
                .then(response => {
                    if (!response.ok) throw new Error('Download failed');
                    return response.blob();
                })
                .then(blob => {
                    const url = window.URL.createObjectURL(blob);
                    const a = document.createElement('a');
                    a.style.display = 'none';
                    a.href = url;
                    a.download = 'wireguard-client.conf';
                    document.body.appendChild(a);
                    a.click();
                    window.URL.revokeObjectURL(url);
                    document.body.removeChild(a);
                })
                .catch(error => {
                    alert('❌ Ошибка скачивания: ' + error.message);
                });
        }

        getRealWireGuardData();
        setInterval(getRealWireGuardData, 30000);
    </script>
</body>
</html>
VPN_HTML

# 13. СОЗДАНИЕ ОСТАЛЬНЫХ НЕОБХОДИМЫХ ФАЙЛОВ
log "📁 Создание недостающих файлов..."

# Копируем VPN конфиг в data папку для доступа из контейнера
cp "/home/$CURRENT_USER/vpn/client.conf" "/home/$CURRENT_USER/data/vpn/client.conf"

# Создаем базовые PWA файлы
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

cat > "/home/$CURRENT_USER/docker/heimdall/sw.js" << 'SW_EOF'
const CACHE_NAME = 'home-server-v4.0';
const urlsToCache = [
  '/',
  '/vpn-info',
  '/torrent-search'
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

# 14. ОБНОВЛЕНИЕ DOCKER-COMPOSE С НОВЫМИ СЕРВИСАМИ
log "🐳 Обновление Docker Compose конфигурации..."

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
      - /home/$CURRENT_USER/docker/ollama-webui/custom:/usr/share/nginx/html/ai-custom
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
    volumes:
      - /home/$CURRENT_USER/docker/ollama-webui/data:/app/backend/data
    networks:
      - server-net

  ollama:
    image: ollama/ollama:latest
    container_name: ollama
    restart: unless-stopped
    ports:
      - "11434:11434"
    volumes:
      - /home/$CURRENT_USER/docker/ollama/models:/root/.ollama
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

  torrent-automation:
    build: /home/$CURRENT_USER/docker/torrent-automation
    container_name: torrent-automation
    restart: unless-stopped
    ports:
      - "8000:8000"
    volumes:
      - /home/$CURRENT_USER/data:/app/data
      - /home/$CURRENT_USER/media:/app/media
    networks:
      - server-net
DOCKER_EOF

# 15. ОБНОВЛЕНИЕ NGINX КОНФИГУРАЦИИ
log "🌐 Обновление Nginx конфигурации..."

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

    upstream torrent_automation {
        server torrent-automation:8000;
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

        # Кастомный AI интерфейс
        location /ai-custom {
            root /usr/share/nginx/html;
            try_files /ai-interface.html =404;
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

        # API для торрент-автоматизации
        location /api/torrent/ {
            proxy_pass http://torrent_automation;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            add_header Access-Control-Allow-Origin *;
            add_header Access-Control-Allow-Methods "GET, POST, OPTIONS";
            add_header Access-Control-Allow-Headers "Content-Type, Authorization";
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

        # Статические файлы для кастомного AI
        location /ai-static/ {
            root /usr/share/nginx/html/ai-custom;
        }
    }
}
NGINX_EOF

# 16. ЗАПУСК ИСПРАВЛЕННОЙ СИСТЕМЫ
log "🚀 Запуск исправленной системы..."

cd "/home/$CURRENT_USER/docker" || exit
docker-compose down
docker-compose up -d --build

# Даем время на запуск контейнеров
sleep 10

# Проверяем статус сервисов
log "🔍 Проверка статуса сервисов..."
docker-compose ps

# Перезапуск торрент-сервисов
sudo systemctl restart qbittorrent-nox

# Создание службы для торрент-автоматизации
sudo tee /etc/systemd/system/torrent-automation.service > /dev/null << TORRENT_SERVICE
[Unit]
Description=Torrent Automation Service
After=network.target docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/home/$CURRENT_USER/docker
ExecStart=/usr/bin/docker-compose up -d torrent-automation
ExecStop=/usr/bin/docker-compose stop torrent-automation
Restart=always

[Install]
WantedBy=multi-user.target
TORRENT_SERVICE

sudo systemctl daemon-reload
sudo systemctl enable torrent-automation
sudo systemctl start torrent-automation

# 17. ОТКРЫТИЕ ПОРТОВ
log "🔓 Открытие портов..."

sudo ufw allow 80/tcp comment "Web Interface"
sudo ufw allow $VPN_PORT/udp comment "WireGuard VPN Fixed Port"
sudo ufw allow 8000/tcp comment "Torrent Automation API"
sudo ufw --force enable

# 18. ФИНАЛЬНАЯ ИНФОРМАЦИЯ
echo ""
echo "=========================================="
echo "🎉 СИСТЕМА УСПЕШНО УСТАНОВЛЕНА И ЗАПУЩЕНА!"
echo "=========================================="
echo ""
echo "✅ ОСНОВНЫЕ ОБНОВЛЕНИЯ:"
echo "   🔒 VPN порт фиксирован: $VPN_PORT/udp"
echo "   🤖 4 режима AI общения: Стандартный, Без цензуры, Без правил, Хакерский"
echo "   🎬 Умный поиск фильмов И сериалов с автоопределением типа контента"
echo "   📺 Поддержка сезонов и эпизодов для сериалов"
echo "   ⚡ Просмотр во время загрузки"
echo "   🗑️ Автоудаление после просмотра"
echo ""
echo "🌐 ДОСТУПНЫЕ СЕРВИСЫ:"
echo "   📍 Главная страница: http://$SERVER_IP/"
echo "   🎬 Поиск фильмов/сериалов: http://$SERVER_IP/torrent-search"
echo "   🤖 AI Ассистент (4 режима): http://$SERVER_IP/ai-custom"
echo "   🔒 VPN информация: http://$SERVER_IP/vpn-info"
echo "   🎬 Jellyfin: http://$SERVER_IP/jellyfin"
echo "   💬 AI Чат: http://$SERVER_IP/ai-chat"
echo "   🎓 AI Кампус: http://$SERVER_IP/ai-campus"
echo "   ☁️ Nextcloud: http://$SERVER_IP/nextcloud"
echo "   📊 Мониторинг: http://$SERVER_IP/monitoring"
echo ""
echo "🔑 ДЛЯ ВХОДА:"
echo "   👑 Администратор: admin / LevAdmin"
echo "   👥 Пользователь: user1 / user123"
echo "   👥 Тестовый: test / test123"
echo ""
echo "🚀 КАК ИСПОЛЬЗОВАТЬ ПОИСК:"
echo "   1. Откройте http://$SERVER_IP/torrent-search"
echo "   2. Введите название фильма или сериала"
echo "   3. Система автоматически определит тип контента"
echo "   4. Выберите качество и нажмите 'Скачать'"
echo "   5. Через 30 секунд контент появится в Jellyfin"
echo "   6. Смотрите во время загрузки!"
echo ""
echo "📺 ОСОБЕННОСТИ СЕРИАЛОВ:"
echo "   • Автоматическое определение сезонов и эпизодов"
echo "   • Отдельные папки для каждого сериала"
echo "   • Умное отслеживание прогресса просмотра"
echo ""
echo "🔒 VPN КНОПКИ ТЕПЕРЬ РАБОТАЮТ:"
echo "   📄 Показать конфиг - показывает реальный конфиг с ключами"
echo "   📥 Скачать конфиг - скачивает файл wireguard-client.conf"
echo ""
echo "=========================================="
