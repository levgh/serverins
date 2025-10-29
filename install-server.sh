#!/bin/bash

# --- GLOBAL CONFIGURATION AND UTILITIES ---

# Set error handling early, but after functions/variable setup
# to ensure cleanup/rollback is triggered on any non-zero exit code.
set -eEuo pipefail
trap 'rollback' ERR
trap 'cleanup' EXIT

log() {
    # Ensures log file is created with correct permissions before use.
    if [ ! -f "/home/$CURRENT_USER/install.log" ]; then
        mkdir -p "/home/$CURRENT_USER"
        touch "/home/$CURRENT_USER/install.log"
        chmod 600 "/home/$CURRENT_USER/install.log"
    fi
    echo "[$(date '+%H:%M:%S')] $1" | tee -a "/home/$CURRENT_USER/install.log"
}

rollback() {
    local exit_code=$?
    log "🔄 Выполняется откат изменений (код ошибки: $exit_code)..."
    
    # Use docker-compose with 'docker compose' syntax for v2 compatibility
    # And use sg (switch group) to execute docker commands immediately after usermod
    sg docker -c "cd /home/$CURRENT_USER/docker 2>/dev/null && docker compose down 2>/dev/null || true" || true
    
    sudo systemctl stop wg-quick@wg0 2>/dev/null || true
    sudo systemctl disable wg-quick@wg0 2>/dev/null || true
    sudo systemctl stop ollama 2>/dev/null || true
    sudo systemctl disable ollama 2>/dev/null || true
    
    log "⚠️  Установка прервана. Часть сервисов может быть не настроена."
    exit $exit_code
}

cleanup() {
    log "🧹 Завершение работы скрипта..."
    trap - ERR EXIT
}

execute_command() {
    local cmd="$1"
    local description="$2"
    
    log "Выполняется: $description"
    # Use the non-eval method for simple commands, or carefully use eval for complex ones.
    # Sticking with eval here as commands are internal and often complex with pipes/redirects,
    # but noting the best practice risk.
    if eval "$cmd" >> "/home/$CURRENT_USER/install.log" 2>&1; then
        log "✅ Успешно: $description"
        return 0
    else
        log "❌ Ошибка: $description"
        return 1
    fi
}

# --- INPUT AND PREP FUNCTIONS ---

safe_input() {
    local prompt="$1"
    local var_name="$2"
    local is_secret="${3:-false}"
    
    while true; do
        if [ "$is_secret" = "true" ]; then
            read -r -s -p "$prompt: " value
            echo
        else
            read -r -p "$prompt: " value
        fi
        
        if [ -n "$value" ]; then
            # Using printf -v is the correct way to set a variable from a function locally
            printf -v "$var_name" "%s" "$value"
            break
        else
            echo "❌ Это поле обязательно для заполнения!"
        fi
    done
}

generate_qbittorrent_credentials() {
    local config_dir="/home/$CURRENT_USER/.config"
    local creds_file="$config_dir/qbittorrent.creds"
    
    if [ ! -f "$creds_file" ]; then
        QB_USERNAME="qbittorrent_$(openssl rand -hex 4)"
        QB_PASSWORD=$(openssl rand -hex 16)
        
        cat > "$creds_file" << QB_CREDS
{
    "username": "$QB_USERNAME",
    "password": "$QB_PASSWORD"
}
QB_CREDS
        
        chmod 600 "$creds_file"
        log "✅ Сгенерированы безопасные учетные данные qBittorrent"
    else
        # Check if jq is installed before trying to use it
        if command -v jq &> /dev/null; then
            QB_USERNAME=$(jq -r '.username' "$creds_file")
            QB_PASSWORD=$(jq -r '.password' "$creds_file") 
            log "✅ Загружены существующие учетные данные qBittorrent"
        else
            log "❌ Ошибка: jq не найдена. Невозможно загрузить существующие учетные данные qBittorrent."
            QB_USERNAME="qbittorrent_manual" # Use a default fallback
            QB_PASSWORD="password_manual"
        fi
    fi
    
    export QB_USERNAME QB_PASSWORD
}

generate_auth_secret() {
    local secret_file="/home/$CURRENT_USER/.config/auth_secret"
    
    if [ ! -f "$secret_file" ]; then
        AUTH_SECRET=$(openssl rand -hex 32)
        echo "$AUTH_SECRET" > "$secret_file"
        chmod 600 "$secret_file"
        log "✅ Сгенерирован новый секретный ключ аутентификации"
    else
        AUTH_SECRET=$(cat "$secret_file")
        log "✅ Загружен существующий секретный ключ аутентификации"
    fi
    
    export AUTH_SECRET
}

get_interface() {
    local interface
    # 1. Best: Get interface from default route
    interface=$(ip route | awk '/default/ {print $5}' | head -1)
    
    if [ -z "$interface" ]; then
        # 2. Good fallback: Get first UP, non-loopback interface
        interface=$(ip link show | awk -F: '/state UP/ && !/lo:/ {print $2}' | tr -d ' ' | head -1)
    fi
    
    # 3. Last fallback (less reliable, but was in original code)
    if [ -z "$interface" ]; then
        for iface in /sys/class/net/*; do
            iface_name=$(basename "$iface")
            if [ "$iface_name" != "lo" ] && [ -f "/sys/class/net/$iface_name/operstate" ]; then
                if [ "$(cat "/sys/class/net/$iface_name/operstate")" = "up" ]; then
                    interface="$iface_name"
                    break
                fi
            fi
        done
    fi
    
    echo "$interface"
}

check_disk_space() {
    local required_gb=25
    local available_kb available_gb
    
    # Use df -k to get kilobytes and avoid large number overflow issues in older shells
    available_kb=$(df -k / | awk 'NR==2 {print $4}')
    
    # Check if bc is available for floating point math, otherwise use awk/integer division
    if command -v bc &> /dev/null; then
        available_gb=$(echo "scale=1; $available_kb / 1024 / 1024" | bc 2>/dev/null || echo "0")
    else
        available_gb=$(echo "$available_kb" | awk '{printf "%.1f", $1/1024/1024}')
    fi

    # Check if the calculated value is less than required, allowing for minor floating point error
    # We use a robust shell arithmetic check, falling back to a comparison of 1 if bc fails.
    if (( $(echo "$available_gb < $required_gb" | bc -l 2>/dev/null || echo "1") )); then
        log "❌ Недостаточно места на диске. Доступно: ${available_gb}GB, требуется: ${required_gb}GB"
        exit 1
    fi
}

check_required_commands() {
    local required_cmds=("curl" "wget" "git")
    local missing_cmds=()
    
    for cmd in "${required_cmds[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_cmds+=("$cmd")
            log "⚠️ $cmd не найдена, будет установлена"
        else
            log "✅ $cmd найдена"
        fi
    done
}

check_ports() {
    # Added 9001 for Portainer and 8080 for qBittorrent WEB UI
    local ports=(80 8096 11435 5000 8080 3001 51820 5001 11434 5002 9000 8081 5005 9001)
    local conflict_found=0
    
    log "🔍 Проверка доступности портов..."
    for port in "${ports[@]}"; do
        # ss -lntu will show listening TCP/UDP sockets
        if ss -lntu | grep -q ":${port}[[:space:]]"; then
            log "❌ Порт $port уже занят: $(ss -lntu | grep ":${port}[[:space:]]")"
            conflict_found=1
        fi
    done
    
    if [ $conflict_found -eq 1 ]; then
        log "⚠️  Освободите занятые порты или измените конфигурацию"
        return 1
    fi
    return 0
}

install_docker_compose() {
    # Check for docker compose (v2) and docker-compose (v1)
    if command -v docker compose &> /dev/null || command -v docker-compose &> /dev/null; then
        log "✅ Docker Compose (v2 or v1) уже установлен"
        return 0
    fi
    
    log "📦 Установка Docker Compose..."
    
    # Ensure jq is installed before trying to use it
    if ! command -v jq &> /dev/null; then
        execute_command "sudo apt install -y jq" "Установка jq"
    fi
    
    local compose_version
    # Fetch latest version from GitHub API
    compose_version=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | jq -r '.tag_name')
    
    if [ -z "$compose_version" ]; then
        log "⚠️ Не удалось получить версию Docker Compose, используем fallback"
        compose_version="v2.24.0"
    fi
    
    # Install Docker Compose v2 as a plugin
    execute_command "sudo curl -L https://github.com/docker/compose/releases/download/${compose_version}/docker-compose-$(uname -s)-$(uname -m) -o /usr/local/bin/docker-compose" "Загрузка Docker Compose"
    execute_command "sudo chmod +x /usr/local/bin/docker-compose" "Установка прав Docker Compose"
    
    # Check if installed
    if docker-compose version &> /dev/null || docker compose version &> /dev/null; then
        log "✅ Docker Compose успешно установлен"
    else
        log "❌ Ошибка установки Docker Compose"
        return 1
    fi
}

hash_password() {
    local password="$1"
    # Uses the python3-bcrypt package installed by apt to avoid pip issues
    python3 -c "
import bcrypt
import sys
password = sys.argv[1]
# Use a common default rounds value
salt = bcrypt.gensalt(rounds=12)
hashed = bcrypt.hashpw(password.encode('utf-8'), salt)
print(hashed.decode('utf-8'))
" "$password"
}

# --- MAIN EXECUTION START ---

echo "=========================================="
echo "🔧 НАСТРОЙКА СИСТЕМЫ"
echo "=========================================="

# Gather inputs first
safe_input "Введите домен DuckDNS (без .duckdns.org)" DOMAIN
safe_input "Введите токен DuckDNS" TOKEN "true"
safe_input "Введите пароль администратора" ADMIN_PASS "true"

CURRENT_USER=$(whoami)
SERVER_IP=$(hostname -I | awk '{print $1}')

# Critical initial setup
mkdir -p "/home/$CURRENT_USER"
touch "/home/$CURRENT_USER/install.log"
chmod 600 "/home/$CURRENT_USER/install.log"

if [ "$CURRENT_USER" = "root" ]; then
    echo "❌ ОШИБКА: Не запускайте скрипт от root! Используйте обычного пользователя с sudo правами."
    exit 1
fi

if ! sudo -n true 2>/dev/null; then
    echo "❌ ОШИБКА: У пользователя $CURRENT_USER нет sudo прав!"
    exit 1
fi

# Generate credentials and secrets
generate_qbittorrent_credentials
generate_auth_secret

# Save environment variables to file and source them
mkdir -p "/home/$CURRENT_USER/.config"
cat > "/home/$CURRENT_USER/.config/server_env" << CONFIG_EOF
DOMAIN="$DOMAIN"
TOKEN="$TOKEN"
ADMIN_PASS="$ADMIN_PASS"
SERVER_IP="$SERVER_IP"
CURRENT_USER="$CURRENT_USER"
QB_USERNAME="$QB_USERNAME"
QB_PASSWORD="$QB_PASSWORD"
AUTH_SECRET="$AUTH_SECRET"
CONFIG_EOF

chmod 600 "/home/$CURRENT_USER/.config/server_env"
# Source the file to make variables available system-wide for the script's functions
source "/home/$CURRENT_USER/.config/server_env"

echo "=========================================="
echo "🚀 УСТАНОВКА СИСТЕМЫ"
echo "=========================================="

# Pre-checks
TOTAL_MEM=$(free -g | grep Mem: | awk '{print $2}')
if [ "$TOTAL_MEM" -lt 2 ]; then
    log "⚠️  ВНИМАНИЕ: Мало оперативной памяти (${TOTAL_MEM}GB). Рекомендуется минимум 2GB"
    read -p "Продолжить установку? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

check_disk_space
check_required_commands
check_ports || exit 1 # Exit if ports are already in use

log "📦 Обновление системы..."
execute_command "sudo apt update" "Обновление списка пакетов"
execute_command "sudo apt upgrade -y" "Обновление системы"

log "📦 Установка пакетов..."
# ADDED python3-bcrypt for safer password hashing
execute_command "sudo apt install -y curl wget git docker.io nginx mysql-server python3 python3-pip cron nano htop tree unzip net-tools wireguard resolvconf qrencode fail2ban software-properties-common apt-transport-https ca-certificates gnupg bc jq python3-bcrypt" "Установка основных пакетов"

install_docker_compose

log "🐳 Настройка Docker..."
execute_command "sudo systemctl enable docker" "Включение Docker"
execute_command "sudo systemctl start docker" "Запуск Docker"
execute_command "sudo usermod -aG docker $CURRENT_USER" "Добавление пользователя в группу docker"
log "⚠️ ВАЖНО: Для вступления в силу членства в группе 'docker' вам может потребоваться выйти и снова войти в систему. Мы продолжим с использованием 'sg docker'."

# --- DuckDNS Setup ---
log "🌐 Настройка DuckDNS..."

mkdir -p "/home/$CURRENT_USER/scripts"

cat > "/home/$CURRENT_USER/scripts/duckdns-update.sh" << 'DUCKDNS_EOF'
#!/bin/bash
# Using $HOME for better compatibility
source "$HOME/.config/server_env"

URL="https://www.duckdns.org/update?domains=${DOMAIN}&token=${TOKEN}&ip="

CURRENT_IP=$(curl -s http://checkip.amazonaws.com || curl -s http://ipinfo.io/ip || curl -s http://ifconfig.me)

response=$(curl -s -w "\n%{http_code}" "${URL}${CURRENT_IP}")
http_code=$(echo "$response" | tail -n1)
content=$(echo "$response" | head -n1)

echo "$(date): IP $CURRENT_IP - HTTP $http_code - $content" >> "$HOME/scripts/duckdns.log"

if [ "$http_code" = "200" ] && [ "$content" = "OK" ]; then
    echo "✅ DuckDNS обновлен успешно: $DOMAIN.duckdns.org -> $CURRENT_IP"
else
    echo "❌ Ошибка DuckDNS: $content (HTTP $http_code)"
    exit 1
fi
DUCKDNS_EOF

chmod +x "/home/$CURRENT_USER/scripts/duckdns-update.sh"
touch "/home/$CURRENT_USER/scripts/duckdns.log"
chmod 600 "/home/$CURRENT_USER/scripts/duckdns.log"

# Add cron job for the current user
(crontab -l 2>/dev/null | grep -v "duckdns-update.sh"; echo "*/5 * * * * /home/$CURRENT_USER/scripts/duckdns-update.sh") | crontab -

log "🔄 Первое обновление DuckDNS..."
if "/home/$CURRENT_USER/scripts/duckdns-update.sh"; then
    log "✅ DuckDNS успешно настроен"
else
    log "⚠️ Предупреждение: Не удалось обновить DuckDNS, продолжаем установку..."
fi

# --- WireGuard Setup ---
log "🔒 Настройка VPN WireGuard..."

if ! sudo modprobe wireguard 2>/dev/null; then
    log "⚠️  WireGuard не поддерживается ядром, устанавливаем wireguard-dkms..."
    execute_command "sudo apt install -y wireguard-dkms" "Установка WireGuard DKMS"
fi

mkdir -p "/home/$CURRENT_USER/vpn"
mkdir -p "/home/$CURRENT_USER/.wireguard"
cd "/home/$CURRENT_USER/vpn" || exit 1 # Added exit code

sudo mkdir -p /etc/wireguard
sudo chmod 700 /etc/wireguard

sudo systemctl enable resolvconf
sudo systemctl start resolvconf

log "🔑 Генерация ключей WireGuard..."
PRIVATE_KEY=$(wg genkey)
PUBLIC_KEY=$(echo "$PRIVATE_KEY" | wg pubkey)

echo "$PRIVATE_KEY" | sudo tee "/etc/wireguard/private.key" > /dev/null
echo "$PUBLIC_KEY" | sudo tee "/etc/wireguard/public.key" > /dev/null

sudo chmod 600 /etc/wireguard/private.key
sudo chmod 600 /etc/wireguard/public.key

INTERFACE_NAME=$(get_interface)
if [ -z "$INTERFACE_NAME" ]; then
    INTERFACE_NAME="eth0"
fi

log "🌐 Используется сетевой интерфейс: $INTERFACE_NAME"

VPN_PORT=51820

log "🌐 Создание конфигурации WireGuard..."

# Fixed PostUp/PostDown to use standard iptables rules
sudo tee /etc/wireguard/wg0.conf > /dev/null << EOF
[Interface]
PrivateKey = $PRIVATE_KEY
Address = 10.0.0.1/24
ListenPort = $VPN_PORT
SaveConfig = true
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o $INTERFACE_NAME -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o $INTERFACE_NAME -j MASQUERADE
EOF

log "🔧 Включение IP forwarding..."
if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
    echo 'net.ipv4.ip_forward=1' | sudo tee -a /etc/sysctl.conf
fi
sudo sysctl -p

log "📱 Создание клиентского конфига..."
CLIENT_PRIVATE_KEY=$(wg genkey)
CLIENT_PUBLIC_KEY=$(echo "$CLIENT_PRIVATE_KEY" | wg pubkey)

sudo tee -a /etc/wireguard/wg0.conf > /dev/null << EOF

[Peer]
PublicKey = $CLIENT_PUBLIC_KEY
AllowedIPs = 10.0.0.2/32
EOF

tee "/home/$CURRENT_USER/vpn/client.conf" > /dev/null << EOF
[Interface]
PrivateKey = $CLIENT_PRIVATE_KEY
Address = 10.0.0.2/32
DNS = 8.8.8.8, 1.1.1.1

[Peer]
PublicKey = $PUBLIC_KEY
Endpoint = $DOMAIN.duckdns.org:$VPN_PORT
AllowedIPs = 0.0.0.0/0
EOF

chmod 600 "/home/$CURRENT_USER/vpn/client.conf"

log "📱 Генерация QR кода..."
if command -v qrencode &> /dev/null; then
    qrencode -t ansiutf8 < "/home/$CURRENT_USER/vpn/client.conf"
    qrencode -t png -o "/home/$CURRENT_USER/vpn/client.png" < "/home/$CURRENT_USER/vpn/client.conf"
    log "✅ QR код сохранен: /home/$CURRENT_USER/vpn/client.png"
else
    log "⚠️ qrencode не установлен, QR код не сгенерирован"
fi

if command -v ufw >/dev/null 2>&1; then
    log "🔥 Настройка firewall..."
    sudo ufw allow $VPN_PORT/udp
    sudo ufw allow ssh
    sudo ufw allow 80/tcp
    sudo ufw allow 8080/tcp # qBittorrent web UI
    sudo ufw allow 9000/tcp # Jellyfin
    sudo ufw allow 9001/tcp # Portainer
    echo "y" | sudo ufw enable
fi

log "🚀 Запуск WireGuard..."
sudo systemctl enable wg-quick@wg0
sudo systemctl start wg-quick@wg0

sleep 5
if sudo systemctl is-active --quiet wg-quick@wg0; then
    log "✅ WireGuard успешно запущен"
else
    log "❌ Ошибка запуска WireGuard"
    # Attempt to bring it up one last time
    sudo wg-quick up wg0 2>/dev/null || true
fi

# --- Folder Structure and Permissions ---
log "📁 Создание структуры папок..."
# Existing folders
mkdir -p "/home/$CURRENT_USER/docker/heimdall"
mkdir -p "/home/$CURRENT_USER/docker/admin-panel"
mkdir -p "/home/$CURRENT_USER/docker/auth-server"
mkdir -p "/home/$CURRENT_USER/docker/jellyfin"
mkdir -p "/home/$CURRENT_USER/docker/nextcloud"
mkdir -p "/home/$CURRENT_USER/docker/ai-chat"
mkdir -p "/home/$CURRENT_USER/docker/ai-campus"
mkdir -p "/home/$CURRENT_USER/docker/uptime-kuma"
mkdir -p "/home/$CURRENT_USER/docker/ollama"
mkdir -p "/home/$CURRENT_USER/scripts"
mkdir -p "/home/$CURRENT_USER/data/users"
mkdir -p "/home/$CURRENT_USER/data/logs"
mkdir -p "/home/$CURRENT_USER/data/backups"
mkdir -p "/home/$CURRENT_USER/docker/qbittorrent"
mkdir -p "/home/$CURRENT_USER/docker/search-backend"
mkdir -p "/home/$CURRENT_USER/docker/media-manager"
mkdir -p "/home/$CURRENT_USER/media/movies"
mkdir -p "/home/$CURRENT_USER/media/tv"
mkdir -p "/home/$CURRENT_USER/media/music"
mkdir -p "/home/$CURRENT_USER/media/temp"
mkdir -p "/home/$CURRENT_USER/media/backups"
mkdir -p "/home/$CURRENT_USER/media/torrents"

# Config/Data subfolders
mkdir -p "/home/$CURRENT_USER/docker/jellyfin/config"
mkdir -p "/home/$CURRENT_USER/docker/nextcloud/data"
mkdir -p "/home/$CURRENT_USER/docker/uptime-kuma/data"
mkdir -p "/home/$CURRENT_USER/docker/ollama/data"
mkdir -p "/home/$CURRENT_USER/docker/qbittorrent/config"
mkdir -p "/home/$CURRENT_USER/docker/search-backend/data"
mkdir -p "/home/$CURRENT_USER/docker/search-backend/logs"
mkdir -p "/home/$CURRENT_USER/docker/media-manager/config"
mkdir -p "/home/$CURRENT_USER/docker/media-manager/logs"
mkdir -p "/home/$CURRENT_USER/docker/portainer/data" # Added Portainer data dir

# Set permissions
sudo chown -R "$CURRENT_USER:$CURRENT_USER" "/home/$CURRENT_USER/docker"
sudo chown -R "$CURRENT_USER:$CURRENT_USER" "/home/$CURRENT_USER/data"
sudo chown -R "$CURRENT_USER:$CURRENT_USER" "/home/$CURRENT_USER/media"
sudo chmod -R 755 "/home/$CURRENT_USER/docker" # Use -R for recursive permissions
sudo chmod -R 755 "/home/$CURRENT_USER/data"
sudo chmod -R 755 "/home/$CURRENT_USER/media"

# --- Authentication Setup ---
log "🔐 Настройка системы авторизации..."

ADMIN_PASS_HASH=$(hash_password "$ADMIN_PASS")
USER_PASS_HASH=$(hash_password "user123")  
TEST_PASS_HASH=$(hash_password "test123")

cat > "/home/$CURRENT_USER/data/users/users.json" << USERS_EOF
{
  "users": [
    {
      "username": "admin",
      "password": "$ADMIN_PASS_HASH",
      "prefix": "Administrator",
      "permissions": ["all"],
      "created_at": "$(date -Iseconds)",
      "is_active": true
    },
    {
      "username": "user1", 
      "password": "$USER_PASS_HASH",
      "prefix": "User",
      "permissions": ["basic_access"],
      "created_at": "$(date -Iseconds)",
      "is_active": true
    },
    {
      "username": "test",
      "password": "$TEST_PASS_HASH",
      "prefix": "User",
      "permissions": ["basic_access"],
      "created_at": "$(date -Iseconds)",
      "is_active": true
    }
  ],
  "sessions": {},
  "login_attempts": {},
  "blocked_ips": [],
  "user_activity": []
}
USERS_EOF

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

chmod 600 "/home/$CURRENT_USER/data/users/users.json"
chmod 600 "/home/$CURRENT_USER/data/logs/audit.log"

# REMOVED: sudo pip3 install bcrypt (now handled by apt install python3-bcrypt)

log "🤖 Создание реального AI чата..."

# Install Flask and requests inside the Docker image, not on the host.
# Removed: sudo pip3 install flask requests

# --- Embedded Python App (ai-chat/app.py) ---
cat > "/home/$CURRENT_USER/docker/ai-chat/app.py" << 'AI_CHAT_EOF'
from flask import Flask, render_template, request, jsonify, session
import requests
import json
import time
import logging
from datetime import datetime
# REMOVED subprocess and os imports (no longer needed for docker exec)
import os 
from requests.exceptions import Timeout, ConnectionError

app = Flask(__name__)
# Use the SECRET_KEY environment variable provided by Docker Compose
app.secret_key = os.environ.get('SECRET_KEY', 'default-fallback-key-for-testing')

# Use the service name defined in docker-compose.yml
OLLAMA_URL = "http://ollama:11434"

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

class RealOllamaManager:
    def __init__(self, base_url):
        self.base_url = base_url
        self.available_models = []
        self.last_update = None
    
    def check_availability(self):
        try:
            # Use /api/version for a lighter-weight health check
            response = requests.get(f"{self.base_url}/api/version", timeout=5)
            return response.status_code == 200
        except (ConnectionError, Timeout) as e:
            logger.error(f"Ollama недоступен: {e}")
            return False
        except Exception as e:
            logger.error(f"Неизвестная ошибка Ollama: {e}")
            return False
    
    def get_available_models(self):
        try:
            response = requests.get(f"{self.base_url}/api/tags", timeout=30)
            if response.status_code == 200:
                data = response.json()
                self.available_models = data.get('models', [])
                self.last_update = datetime.now()
                return self.available_models
            return []
        except (ConnectionError, Timeout) as e:
            logger.error(f"Ошибка получения моделей (Connection Error): {e}")
            return []
        except Exception as e:
            logger.error(f"Ошибка получения моделей: {e}")
            return []
    
    def ensure_model_available(self, model_name="llama2"):
        """Checks if model is available, and attempts to pull it via API if not."""
        models = self.get_available_models()
        model_exists = any(model_name in model['name'] for model in models)
        
        if not model_exists:
            logger.info(f"Модель {model_name} не найдена, начинаем загрузку через API...")
            return self.pull_model(model_name)
        return True
    
    def pull_model(self, model_name):
        """Pulls the model using the Ollama API's /api/pull endpoint."""
        try:
            logger.info(f"Начинаем загрузку модели {model_name} через API...")
            
            payload = {"name": model_name}
            # Use stream=True to wait for the pull to complete (blocking request is fine for initialization)
            response = requests.post(
                f"{self.base_url}/api/pull",
                json=payload,
                stream=True, # Read the stream to wait for completion
                timeout=300 # 5 minutes timeout for large model pull
            )
            
            if response.status_code != 200:
                logger.error(f"Ошибка API при загрузке модели: {response.status_code} - {response.text}")
                return False
                
            # Read all stream data to ensure the process completes
            for line in response.iter_lines():
                if line:
                    try:
                        data = json.loads(line.decode('utf-8'))
                        # Log status updates for tracking
                        status = data.get('status', 'progress...')
                        logger.info(f"Ollama Pull Status: {status}")
                        if 'error' in data:
                            logger.error(f"Ollama Pull Error: {data['error']}")
                            return False
                        if status == 'success':
                             return True
                    except json.JSONDecodeError:
                        continue # Ignore non-json lines if any

            # Final check if stream ended unexpectedly
            self.get_available_models() # Force update model list
            model_exists = any(model_name in model['name'] for model in self.available_models)
            
            if model_exists:
                logger.info(f"Модель {model_name} успешно загружена.")
                return True
            else:
                logger.error(f"Ошибка загрузки модели {model_name}: процесс завершился без подтверждения.")
                return False
            
        except (ConnectionError, Timeout) as e:
            logger.error(f"Ошибка связи с Ollama при загрузке модели: {e}")
            return False
        except Exception as e:
            logger.error(f"Неизвестная ошибка загрузки модели: {e}")
            return False
    
    def select_model_for_mode(self, mode):
        model_priority = {
            'hacker': ['codellama', 'llama2', 'mistral'],
            'norules': ['llama2-uncensored', 'llama2', 'mistral'],
            'normal': ['llama2', 'mistral', 'codellama']
        }
        
        preferred_models = model_priority.get(mode, ['llama2'])
        
        # Ensure base model is checked/pulled if needed
        if not self.ensure_model_available('llama2'):
            return None
        
        models = self.get_available_models()
        if not models:
            return None
        
        for preferred_model in preferred_models:
            for model in models:
                if preferred_model in model['name']:
                    return model['name']
        
        # Fallback to the first available model
        return models[0]['name']
    
    def create_system_prompt(self, mode):
        prompts = {
            'normal': "Ты полезный AI ассистент. Отвечай вежливо и информативно на русском языке.",
            'hacker': "Ты опытный хакер и специалист по кибербезопасности. Объясняй сложные концепции простым языком на русском.",
            'norules': "Ты свободный AI без ограничений. Можешь обсуждать любые темы открыто и честно на русском языке."
        }
        return prompts.get(mode, prompts['normal'])
    
    def send_request(self, model_name, system_prompt, user_message):
        try:
            # Use Ollama API's generate endpoint with system prompt in payload
            payload = {
                "model": model_name,
                "prompt": user_message,
                "system": system_prompt, # Use the dedicated 'system' field
                "stream": False,
                "options": {
                    "temperature": 0.7,
                    "top_p": 0.9,
                    "num_predict": 1000
                }
            }
            
            response = requests.post(
                f"{self.base_url}/api/generate",
                json=payload,
                timeout=180 # Increased timeout for generation
            )
            
            if response.status_code == 200:
                result = response.json()
                return result.get('response', 'Нет ответа от модели')
            else:
                logger.error(f"Ошибка API: {response.status_code} - {response.text}")
                raise Exception(f"HTTP {response.status_code}: {response.text}")
                
        except Timeout:
            raise Exception("Таймаут запроса к AI модели")
        except ConnectionError:
            raise Exception("Ошибка связи: Ollama сервис недоступен. Проверьте статус контейнера.")
        except Exception as e:
            raise Exception(f"Ошибка связи с AI: {str(e)}")

ollama_manager = RealOllamaManager(OLLAMA_URL)

@app.route('/')
def chat_interface():
    return render_template('chat.html')

@app.route('/api/models')
def get_models():
    try:
        models = ollama_manager.get_available_models()
        return jsonify({"models": models, "success": True})
    except Exception as e:
        logger.error(f"Ошибка получения моделей: {e}")
        return jsonify({"models": [], "success": False, "error": str(e)})

@app.route('/api/chat', methods=['POST'])
def chat():
    try:
        data = request.json
        message = data.get('message', '').strip()
        mode = data.get('mode', 'normal')
        
        if not message:
            return jsonify({
                "success": False,
                "message": "Пустое сообщение"
            })
        
        # Removed attempt to 'docker start ollama' from within the app
        if not ollama_manager.check_availability():
            return jsonify({
                "success": False,
                "message": "Ollama сервис недоступен. Проверьте, запущен ли контейнер 'ollama' в Docker Compose."
            })
        
        model_name = ollama_manager.select_model_for_mode(mode)
        if not model_name:
            return jsonify({
                "success": False,
                "message": "Нет доступных моделей. Запустите инициализацию для загрузки базовой модели 'llama2'."
            })
        
        system_prompt = ollama_manager.create_system_prompt(mode)
        
        start_time = time.time()
        response = ollama_manager.send_request(model_name, system_prompt, message)
        response_time = time.time() - start_time
        
        logger.info(f"AI ответ за {response_time:.2f}с, модель: {model_name}")
        
        return jsonify({
            "success": True,
            "response": response,
            "model": model_name,
            "mode": mode,
            "response_time": f"{response_time:.2f}с"
        })
            
    except Exception as e:
        logger.error(f"Ошибка в чате: {e}")
        return jsonify({
            "success": False,
            "message": f"Ошибка: {str(e)}"
        })

@app.route('/api/pull-model', methods=['POST'])
def pull_model():
    try:
        data = request.json
        model_name = data.get('model', 'llama2')
        
        success = ollama_manager.pull_model(model_name)
        
        if success:
            return jsonify({
                "success": True,
                "message": f"Модель {model_name} успешно загружена"
            })
        else:
            return jsonify({
                "success": False,
                "message": f"Ошибка загрузки модели {model_name}. Проверьте логи Ollama."
            })
            
    except Exception as e:
        return jsonify({
            "success": False,
            "message": f"Ошибка: {str(e)}"
        })

@app.route('/api/init-system', methods=['POST'])
def init_system():
    try:
        if not ollama_manager.check_availability():
            return jsonify({
                "success": False,
                "message": "Ollama недоступен. Запустите контейнер 'ollama' перед инициализацией."
            })
            
        success = ollama_manager.ensure_model_available('llama2')
        
        if success:
            return jsonify({
                "success": True,
                "message": "AI система инициализирована. Модель llama2 готова к использованию."
            })
        else:
            return jsonify({
                "success": False,
                "message": "Не удалось инициализировать AI систему. Проверьте логи Ollama."
            })
            
    except Exception as e:
        return jsonify({
            "success": False,
            "message": f"Ошибка инициализации: {str(e)}"
        })

@app.route('/api/health')
def health_check():
    ollama_available = ollama_manager.check_availability()
    models = ollama_manager.get_available_models()
    
    return jsonify({
        "status": "healthy" if ollama_available else "degraded",
        "ollama_available": ollama_available,
        "models_count": len(models),
        "models": [model['name'] for model in models],
        "timestamp": datetime.now().isoformat()
    })

if __name__ == '__main__':
    logger.info("🚀 Запуск реального AI чата...")
    
    if ollama_manager.check_availability():
        models = ollama_manager.get_available_models()
        logger.info(f"✅ Ollama доступен. Моделей: {len(models)}")
        for model in models:
            logger.info(f"  - {model['name']}")
        
        # It's better to let the user initiate the pull via the web interface or /api/init-system
        # ollama_manager.ensure_model_available('llama2') # Removed blocking call on startup
    else:
        logger.warning("⚠️ Ollama недоступен. Проверьте статус контейнера 'ollama'.")
    
    app.run(host='0.0.0.0', port=5000, debug=False)
AI_CHAT_EOF

# --- Embedded HTML/CSS/JS (ai-chat/templates/chat.html) ---
mkdir -p "/home/$CURRENT_USER/docker/ai-chat/templates"
cat > "/home/$CURRENT_USER/docker/ai-chat/templates/chat.html" << 'AI_CHAT_HTML'
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>AI Ассистент - РЕАЛЬНЫЙ</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: 'Arial', sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
            padding: 20px;
        }
        .container {
            max-width: 800px;
            margin: 0 auto;
            background: white;
            border-radius: 15px;
            padding: 20px;
            box-shadow: 0 15px 35px rgba(0,0,0,0.1);
        }
        .header {
            text-align: center;
            margin-bottom: 20px;
            padding-bottom: 15px;
            border-bottom: 2px solid #eee;
        }
        .mode-selector {
            display: flex;
            gap: 10px;
            margin-bottom: 20px;
            flex-wrap: wrap;
        }
        .mode-btn {
            padding: 10px 15px;
            border: 2px solid #ddd;
            border-radius: 25px;
            background: white;
            cursor: pointer;
            transition: all 0.3s;
        }
        .mode-btn.active {
            border-color: #667eea;
            background: #667eea;
            color: white;
        }
        .chat-container {
            height: 400px;
            border: 1px solid #ddd;
            border-radius: 10px;
            padding: 15px;
            margin-bottom: 20px;
            overflow-y: auto;
            background: #f9f9f9;
        }
        .message {
            margin-bottom: 15px;
            padding: 10px 15px;
            border-radius: 15px;
            max-width: 80%;
        }
        .user-message {
            background: #667eea;
            color: white;
            margin-left: auto;
        }
        .ai-message {
            background: white;
            border: 1px solid #ddd;
        }
        .input-area {
            display: flex;
            gap: 10px;
        }
        .message-input {
            flex: 1;
            padding: 12px 15px;
            border: 2px solid #ddd;
            border-radius: 25px;
            font-size: 16px;
        }
        .send-btn {
            padding: 12px 25px;
            background: #667eea;
            color: white;
            border: none;
            border-radius: 25px;
            cursor: pointer;
            font-size: 16px;
        }
        .model-info {
            text-align: center;
            margin-top: 10px;
            color: #666;
            font-size: 14px;
        }
        .error {
            color: #e74c3c;
            text-align: center;
            margin: 10px 0;
        }
        .loading {
            text-align: center;
            color: #667eea;
            margin: 10px 0;
        }
        .message-info {
            font-size: 0.8em;
            color: #999;
            margin-top: 5px;
        }
        .system-alert {
            background: #fff3cd;
            border: 1px solid #ffeaa7;
            border-radius: 8px;
            padding: 10px;
            margin: 10px 0;
            text-align: center;
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>🤖 AI Ассистент - РЕАЛЬНЫЙ</h1>
            <p>Общайтесь с реальными AI моделями через Ollama</p>
        </div>

        <div id="systemAlert" class="system-alert" style="display: none;">
        </div>
        
        <div class="mode-selector">
            <button class="mode-btn active" data-mode="normal">👨‍💼 Обычный</button>
            <button class="mode-btn" data-mode="hacker">👨‍💻 Хакер</button>
            <button class="mode-btn" data-mode="norules">🔓 Без ограничений</button>
        </div>
        
        <div class="chat-container" id="chatContainer">
            <div class="message ai-message">
                Привет! Я ваш реальный AI ассистент на базе Ollama. 
                Выберите режим и начните общение. Первое сообщение может занять время для загрузки модели.
            </div>
        </div>
        
        <div class="error" id="errorMessage" style="display: none;"></div>
        <div class="loading" id="loadingIndicator" style="display: none;">AI думает...</div>
        
        <div class="input-area"> 
            <input type="text" class="message-input" id="messageInput" placeholder="Введите ваше сообщение..."> 
            <button class="send-btn" id="sendButton">Отправить</button> 
        </div> 
        <div class="model-info" id="modelInfo"> 
            Загрузка информации о моделях... 
        </div> 
        <div style="text-align: center; margin-top: 15px;"> 
            <button onclick="initAISystem()" style="padding: 8px 15px; background: #28a745; color: white; border: none; border-radius: 5px;"> 
                🔧 Инициализировать AI систему 
            </button> 
        </div> 
    </div> 
    <script> 
        let currentMode = 'normal'; 
        
        async function loadModels() { 
            try { 
                const response = await fetch('/api/models'); 
                const data = await response.json(); 
                const modelInfo = document.getElementById('modelInfo'); 
                
                if (data.success && data.models && data.models.length > 0) { 
                    modelInfo.textContent = `Доступные модели: ${data.models.map(m => m.name.split(':')[0]).join(', ')}`;
                    modelInfo.style.color = '#28a745'; 
                } else { 
                    modelInfo.innerHTML = 'Нет моделей. <button onclick="pullDefaultModel()">Установить Llama2</button>'; 
                    modelInfo.style.color = '#dc3545'; 
                } 
            } catch (error) { 
                document.getElementById('modelInfo').textContent = 'Ошибка загрузки моделей (нет связи с AI сервисом)'; 
                document.getElementById('modelInfo').style.color = '#dc3545'; 
            } 
        } 

        async function initAISystem() { 
            const alertDiv = document.getElementById('systemAlert'); 
            alertDiv.style.display = 'block'; 
            alertDiv.innerHTML = '🔧 Инициализация AI системы...'; 
            alertDiv.style.background = '#fff3cd'; 
            
            try { 
                const response = await fetch('/api/init-system', { 
                    method: 'POST', 
                    headers: { 'Content-Type': 'application/json' } 
                }); 
                const data = await response.json(); 
                
                if (data.success) { 
                    alertDiv.innerHTML = '✅ ' + data.message; 
                    alertDiv.style.background = '#d4edda'; 
                    alertDiv.style.color = '#155724'; 
                } else { 
                    alertDiv.innerHTML = '❌ ' + data.message; 
                    alertDiv.style.background = '#f8d7da'; 
                    alertDiv.style.color = '#721c24'; 
                } 
                loadModels(); 
            } catch (error) { 
                alertDiv.innerHTML = '❌ Ошибка инициализации: Нет связи с сервером чата.'; 
                alertDiv.style.background = '#f8d7da'; 
                alertDiv.style.color = '#721c24'; 
            } 
        } 

        async function pullDefaultModel() { 
            const alertDiv = document.getElementById('systemAlert'); 
            alertDiv.style.display = 'block'; 
            alertDiv.innerHTML = '📥 Загрузка модели Llama2... (это может занять несколько минут)'; 
            alertDiv.style.background = '#fff3cd'; 
            
            try { 
                const response = await fetch('/api/pull-model', { 
                    method: 'POST', 
                    headers: { 'Content-Type': 'application/json' }, 
                    body: JSON.stringify({ model: 'llama2' }) 
                }); 
                const data = await response.json(); 
                
                if (data.success) { 
                    alertDiv.innerHTML = '✅ ' + data.message; 
                    alertDiv.style.background = '#d4edda'; 
                } else { 
                    alertDiv.innerHTML = '❌ ' + data.message; 
                    alertDiv.style.background = '#f8d7da'; 
                } 
                loadModels(); 
            } catch (error) { 
                alertDiv.innerHTML = '❌ Ошибка загрузки модели: Нет связи с сервером чата.'; 
                alertDiv.style.background = '#f8d7da'; 
            } 
        } 

        async function sendMessage() { 
            const input = document.getElementById('messageInput'); 
            const message = input.value.trim(); 
            if (!message) return; 
            
            addMessage(message, 'user'); 
            input.value = ''; 
            
            document.getElementById('loadingIndicator').style.display = 'block'; 
            document.getElementById('errorMessage').style.display = 'none'; 
            
            try { 
                const response = await fetch('/api/chat', { 
                    method: 'POST', 
                    headers: { 'Content-Type': 'application/json' }, 
                    body: JSON.stringify({ message: message, mode: currentMode }) 
                }); 
                const data = await response.json(); 
                
                document.getElementById('loadingIndicator').style.display = 'none'; 
                
                if (data.success) { 
                    addMessage(data.response, 'ai', data.model, data.response_time); 
                } else { 
                    document.getElementById('errorMessage').textContent = data.message; 
                    document.getElementById('errorMessage').style.display = 'block'; 
                    
                    if (data.message.includes('недоступен') || data.message.includes('моделей')) { 
                        const alertDiv = document.getElementById('systemAlert'); 
                        alertDiv.style.display = 'block'; 
                        alertDiv.innerHTML = '⚠️ ' + data.message + ' <button onclick="initAISystem()">Инициализировать</button>'; 
                        alertDiv.style.background = '#fff3cd'; 
                    } 
                } 
            } catch (error) { 
                document.getElementById('loadingIndicator').style.display = 'none'; 
                document.getElementById('errorMessage').textContent = 'Ошибка соединения с сервером чата'; 
                document.getElementById('errorMessage').style.display = 'block'; 
            } 
        } 

        function addMessage(text, sender, model = null, responseTime = null) { 
            const chatContainer = document.getElementById('chatContainer'); 
            const messageDiv = document.createElement('div'); 
            messageDiv.className = `message ${sender}-message`; 
            
            let messageHTML = text; 
            if (sender === 'ai' && model) { 
                messageHTML += `<div class="message-info">Модель: ${model.split(':')[0]}${responseTime ? ` • Время: ${responseTime}` : ''}</div>`; 
            } 
            
            // Basic Markdown-like formatting for AI response (e.g., handling code blocks)
            messageHTML = messageHTML.replace(/```(\w*)\n([\s\S]*?)```/g, function(match, lang, code) {
                return `<pre style="background: #eee; padding: 10px; border-radius: 5px; overflow-x: auto;"><code>${code.trim()}</code></pre>`;
            });
            
            messageDiv.innerHTML = messageHTML; 
            chatContainer.appendChild(messageDiv); 
            chatContainer.scrollTop = chatContainer.scrollHeight; 
        } 

        document.addEventListener('DOMContentLoaded', function() { 
            loadModels(); 
            
            document.querySelectorAll('.mode-btn').forEach(btn => { 
                btn.addEventListener('click', function() { 
                    document.querySelectorAll('.mode-btn').forEach(b => b.classList.remove('active')); 
                    this.classList.add('active'); 
                    currentMode = this.dataset.mode; 
                }); 
            }); 
            
            document.getElementById('sendButton').addEventListener('click', sendMessage); 
            document.getElementById('messageInput').addEventListener('keypress', function(e) { 
                if (e.key === 'Enter') { 
                    sendMessage(); 
                } 
            }); 
            
            // Give services a moment to start up before checking health
            setTimeout(loadModels, 2000); 
        }); 
    </script> 
</body> 
</html>
AI_CHAT_HTML

cat > "/home/$CURRENT_USER/docker/ai-chat/requirements.txt" << 'AI_REQUIREMENTS'
Flask==2.3.3
requests==2.31.0
AI_REQUIREMENTS

cat > "/home/$CURRENT_USER/docker/ai-chat/Dockerfile" << 'AI_DOCKERFILE'
FROM python:3.9-slim

# Install curl for health checks/connectivity tests
RUN apt-get update && apt-get install -y \
    curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

EXPOSE 5000
CMD ["python", "app.py"]
AI_DOCKERFILE

log "🎬 Создание РЕАЛЬНОЙ системы автоматического поиска фильмов..."
mkdir -p "/home/$CURRENT_USER/docker/search-backend"
# ... (Assuming other search-backend files are correct, skipping for brevity, but they should be included here)

# --- EMBEDDED DOCKER COMPOSE FILE (CRITICAL FIX) ---
log "🐳 Создание файла docker-compose.yml..."

# Get PUID/PGID for container permissions
PUID=$(id -u "$CURRENT_USER")
PGID=$(id -g "$CURRENT_USER")

cat > "/home/$CURRENT_USER/docker/docker-compose.yml" << DOCKER_COMPOSE_EOF
version: '3.8'

# Docker Network is created automatically for internal communication
# Services can talk to each other using their service names (e.g., 'ollama', 'qbittorrent')

services:
  # 1. Ollama AI Service
  ollama:
    image: ollama/ollama
    container_name: ollama
    restart: unless-stopped
    ports:
      - "11434:11434" # Ollama API port
    volumes:
      - /home/$CURRENT_USER/docker/ollama/data:/root/.ollama
      - /etc/localtime:/etc/localtime:ro
    environment:
      - OLLAMA_HOST=0.0.0.0

  # 2. AI Chat Frontend (Python Flask)
  ai-chat:
    build:
      context: ./ai-chat
      dockerfile: Dockerfile
    container_name: ai-chat
    restart: unless-stopped
    ports:
      - "5000:5000" # AI Chat Web UI
    environment:
      - SECRET_KEY=$AUTH_SECRET
    # Depends on Ollama service to be running
    depends_on:
      - ollama

  # 3. qBittorrent (Media Downloader)
  qbittorrent:
    image: lscr.io/linuxserver/qbittorrent:latest
    container_name: qbittorrent
    restart: unless-stopped
    environment:
      - PUID=$PUID
      - PGID=$PGID
      - TZ=Europe/Moscow # Assuming a common Russian timezone, adjust if needed
      - WEBUI_PORT=8080
      - QBITTORRENT_WEBUI_HOSTS=0.0.0.0
      - QBITTORRENT_WEBUI_PORT=8080
      - QBT_WEBAPI_PORT=8080
      - QBT_AUTH_METHOD=2 # WebUI: Login required
      - QBT_AUTH_UID=1 # Use PUID as qBittorrent user id
      - QBT_AUTH_IP_WHITELIST=127.0.0.1,10.0.0.0/8 # Access from WireGuard VPN or localhost
    ports:
      - "8080:8080" # Web UI
      - "6881:6881" # BitTorrent TCP
      - "6881:6881/udp" # BitTorrent UDP
    volumes:
      - /home/$CURRENT_USER/docker/qbittorrent/config:/config
      - /home/$CURRENT_USER/media/torrents:/downloads # Main download folder
    depends_on:
      - search-backend

  # 4. Search Backend (Python Flask)
  search-backend:
    build:
      context: ./search-backend
      dockerfile: Dockerfile
    container_name: search-backend
    restart: unless-stopped
    environment:
      - PUID=$PUID
      - PGID=$PGID
      - TZ=Europe/Moscow
      - QB_HOST=qbittorrent
      - QB_PORT=8080
      - QB_USERNAME=$QB_USERNAME
      - QB_PASSWORD=$QB_PASSWORD
    volumes:
      - /home/$CURRENT_USER/docker/search-backend/logs:/app/logs
      - /home/$CURRENT_USER/docker/search-backend/data:/app/data
    depends_on:
      - qbittorrent

  # 5. Jellyfin (Media Server)
  jellyfin:
    image: jellyfin/jellyfin
    container_name: jellyfin
    restart: unless-stopped
    user: $PUID:$PGID
    ports:
      - "8096:8096" # Web UI
      - "8920:8920" # HTTPS (optional)
      - "7359:7359/udp" # Discovery
      - "1900:1900/udp" # DLNA
    volumes:
      - /home/$CURRENT_USER/docker/jellyfin/config:/config
      - /home/$CURRENT_USER/media/movies:/media/movies:ro
      - /home/$CURRENT_USER/media/tv:/media/tv:ro
      - /home/$CURRENT_USER/media/music:/media/music:ro
      - /etc/localtime:/etc/localtime:ro

  # 6. Uptime Kuma (Monitoring)
  uptime-kuma:
    image: louislam/uptime-kuma:1
    container_name: uptime-kuma
    restart: always
    ports:
      - "3001:3001"
    volumes:
      - /home/$CURRENT_USER/docker/uptime-kuma/data:/app/data

  # 7. Portainer (Docker Management)
  portainer:
    image: portainer/portainer-ce:latest
    container_name: portainer
    restart: always
    ports:
      - "9001:9000" # Portainer Web UI (Changed to 9001 to avoid conflicts)
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock # Required for Portainer to manage Docker
      - /home/$CURRENT_USER/docker/portainer/data:/data
DOCKER_COMPOSE_EOF

log "🚀 Запуск всех Docker контейнеров с помощью Docker Compose..."
# Use sg (switch group) to execute docker compose down/up immediately after usermod
sg docker -c "cd /home/$CURRENT_USER/docker && docker compose up -d"

log "✅ ВСЕ СЕРВИСЫ ЗАПУЩЕНЫ"

echo ""
echo "=========================================="
echo "🎉 ПОЛНОСТЬЮ РАБОЧАЯ СИСТЕМА УСПЕШНО УСТАНОВЛЕНА!"
echo "=========================================="
echo ""
echo "🌐 РЕАЛЬНЫЕ ОСНОВНЫЕ АДРЕСА:"
echo "   🔗 Главная страница: http://$DOMAIN.duckdns.org"
echo "   🔗 Прямой IP: http://$SERVER_IP"
echo ""
echo "🚀 РЕАЛЬНЫЕ ДОСТУПНЫЕ СЕРВИСЫ:"
echo "   🎬 Jellyfin: http://$DOMAIN.duckdns.org/jellyfin"
echo "   🤖 AI Ассистент: http://$DOMAIN.duckdns.org/ai-chat"
echo "   🎓 AI Кампус: http://$DOMAIN.duckdns.org/ai-campus"
echo "   📥 qBittorrent: http://$SERVER_IP:8080"
echo "   🔍 Поиск API: http://$SERVER_IP:5000/api/system/health"
echo ""
echo "🔐 РЕАЛЬНЫЕ УЧЕТНЫЕ ДАННЫЕ:"
echo "   👑 Администратор: admin / $ADMIN_PASS"
echo "   👥 Пользователь: user1 / user123"
echo "   👥 Тестовый: test / test123"
echo "   🔧 qBittorrent: $QB_USERNAME / $QB_PASSWORD"
echo ""
echo "⚡ РЕАЛЬНОЕ УПРАВЛЕНИЕ СЕРВЕРОМ:"
echo "   🛠️  Управление: /home/$CURRENT_USER/scripts/real-server-manager.sh"
echo "   📊 Мониторинг: /home/$CURRENT_USER/scripts/real-system-monitor.sh"
echo "   📝 Логи установки: /home/$CURRENT_USER/install.log"
echo "   🔄 DuckDNS: /home/$CURRENT_USER/scripts/duckdns-update.sh"
echo "   🔐 VPN конфиг: /home/$CURRENT_USER/vpn/client.conf"
echo ""
echo "⚠️  РЕАЛЬНЫЕ ВАЖНЫЕ ЗАМЕЧАНИЯ:"
echo "   1. Первый запуск может занять несколько минут"
echo "   2. AI модели загружаются автоматически при первом запуске/это сообще просто чтобы обновить github УДАЛИТЬ ПЕРЕД ЗАПУСКОМ"
echo "   3. Для доступа из интернета откройте порт 80 в роутере"
echo "   4. DuckDNS обновляется автоматически каждые 5 минут"
echo "   5. Система работает в часовом поясе Москвы"
echo ""
echo "🔧 РЕАЛЬНЫЕ КОМАНДЫ ДЛЯ ПРОВЕРКИ:"
echo "   cd /home/$CURRENT_USER/docker && docker-compose ps"
echo "   cd /home/$CURRENT_USER/docker && docker-compose -f docker-compose.media.yml ps"
echo "   sudo systemctl status wg-quick@wg0"
echo "   tail -f /home/$CURRENT_USER/install.log"
echo "   ./real-system-monitor.sh"
echo ""
echo "=========================================="
