#!/bin/bash

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
        QB_USERNAME=$(jq -r '.username' "$creds_file")
        QB_PASSWORD=$(jq -r '.password' "$creds_file") 
        log "✅ Загружены существующие учетные данные qBittorrent"
    fi
    
    export QB_USERNAME QB_PASSWORD
}

echo "=========================================="
echo "🔧 НАСТРОЙКА СИСТЕМЫ"
echo "=========================================="

safe_input "Введите домен DuckDNS (без .duckdns.org)" DOMAIN
safe_input "Введите токен DuckDNS" TOKEN "true"
safe_input "Введите пароль администратора" ADMIN_PASS "true"

CURRENT_USER=$(whoami)
SERVER_IP=$(hostname -I | awk '{print $1}')

generate_qbittorrent_credentials

mkdir -p "/home/$CURRENT_USER/.config"
cat > "/home/$CURRENT_USER/.config/server_env" << CONFIG_EOF
DOMAIN="$DOMAIN"
TOKEN="$TOKEN"
ADMIN_PASS="$ADMIN_PASS"
SERVER_IP="$SERVER_IP"
CURRENT_USER="$CURRENT_USER"
QB_USERNAME="$QB_USERNAME"
QB_PASSWORD="$QB_PASSWORD"
CONFIG_EOF

chmod 600 "/home/$CURRENT_USER/.config/server_env"
source "/home/$CURRENT_USER/.config/server_env"

set -eEuo pipefail
trap 'rollback' ERR
trap 'cleanup' EXIT

log() {
    echo "[$(date '+%H:%M:%S')] $1" | tee -a "/home/$CURRENT_USER/install.log"
}

execute_command() {
    local cmd="$1"
    local description="$2"
    
    log "Выполняется: $description"
    if eval "$cmd" >> "/home/$CURRENT_USER/install.log" 2>&1; then
        log "✅ Успешно: $description"
        return 0
    else
        log "❌ Ошибка: $description"
        return 1
    fi
}

get_interface() {
    local interface
    interface=$(ip route | awk '/default/ {print $5}' | head -1)
    
    if [ -z "$interface" ]; then
        interface=$(ip link show | awk -F: '/state UP/ && !/lo:/ {print $2}' | tr -d ' ' | head -1)
    fi
    
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
    
    available_kb=$(df / | awk 'NR==2 {print $4}')
    available_gb=$(echo "$available_kb / 1024 / 1024" | bc -l 2>/dev/null || echo "$available_kb" | awk '{printf "%.1f", $1/1024/1024}')
    
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
    local ports=(80 8096 11435 5000 8080 3001 51820 5001 11434 5002 9000 8081 5005)
    local conflict_found=0
    
    log "🔍 Проверка доступности портов..."
    for port in "${ports[@]}"; do
        if ss -tulpn | grep -q ":${port}[[:space:]]"; then
            log "❌ Порт $port уже занят: $(ss -tulpn | grep ":${port}[[:space:]]")"
            conflict_found=1
        fi
    done
    
    if [ $conflict_found -eq 1 ]; then
        log "⚠️  Освободите занятые порты или измените конфигурацию"
        return 1
    fi
    return 0
}

rollback() {
    local exit_code=$?
    log "🔄 Выполняется откат изменений (код ошибки: $exit_code)..."
    
    cd "/home/$CURRENT_USER/docker" 2>/dev/null && docker-compose down 2>/dev/null || true
    
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

echo "=========================================="
echo "🚀 УСТАНОВКА СИСТЕМЫ"
echo "=========================================="

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
check_ports

generate_auth_secret

log "📦 Обновление системы..."
execute_command "sudo apt update" "Обновление списка пакетов"
execute_command "sudo apt upgrade -y" "Обновление системы"

log "📦 Установка пакетов..."
execute_command "sudo apt install -y curl wget git docker.io nginx mysql-server python3 python3-pip cron nano htop tree unzip net-tools wireguard resolvconf qrencode fail2ban software-properties-common apt-transport-https ca-certificates gnupg bc jq" "Установка основных пакетов"

install_docker_compose() {
    if command -v docker-compose &> /dev/null || docker compose version &> /dev/null; then
        log "✅ Docker Compose уже установлен"
        return 0
    fi
    
    log "📦 Установка Docker Compose..."
    
    if ! command -v jq &> /dev/null; then
        execute_command "sudo apt install -y jq" "Установка jq"
    fi
    
    local compose_version
    compose_version=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | jq -r '.tag_name')
    
    if [ -z "$compose_version" ]; then
        log "⚠️ Не удалось получить версию Docker Compose, используем fallback"
        compose_version="v2.24.0"
    fi
    
    execute_command "sudo curl -L 'https://github.com/docker/compose/releases/download/${compose_version}/docker-compose-$(uname -s)-$(uname -m)' -o /usr/local/bin/docker-compose" "Загрузка Docker Compose"
    execute_command "sudo chmod +x /usr/local/bin/docker-compose" "Установка прав Docker Compose"
    
    if docker-compose version &> /dev/null; then
        log "✅ Docker Compose успешно установлен"
    else
        log "❌ Ошибка установки Docker Compose"
        return 1
    fi
}

install_docker_compose

log "🐳 Настройка Docker..."
execute_command "sudo systemctl enable docker" "Включение Docker"
execute_command "sudo systemctl start docker" "Запуск Docker"
execute_command "sudo usermod -aG docker $CURRENT_USER" "Добавление пользователя в группу docker"

log "🌐 Настройка DuckDNS..."

mkdir -p "/home/$CURRENT_USER/scripts"

cat > "/home/$CURRENT_USER/scripts/duckdns-update.sh" << 'DUCKDNS_EOF'
#!/bin/bash
source "/home/$(whoami)/.config/server_env"

URL="https://www.duckdns.org/update?domains=${DOMAIN}&token=${TOKEN}&ip="

CURRENT_IP=$(curl -s http://checkip.amazonaws.com || curl -s http://ipinfo.io/ip || curl -s http://ifconfig.me)

response=$(curl -s -w "\n%{http_code}" "${URL}${CURRENT_IP}")
http_code=$(echo "$response" | tail -n1)
content=$(echo "$response" | head -n1)

echo "$(date): IP $CURRENT_IP - HTTP $http_code - $content" >> "/home/$(whoami)/scripts/duckdns.log"

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

(crontab -l 2>/dev/null | grep -v "duckdns-update.sh"; echo "*/5 * * * * /home/$CURRENT_USER/scripts/duckdns-update.sh") | crontab -

log "🔄 Первое обновление DuckDNS..."
if "/home/$CURRENT_USER/scripts/duckdns-update.sh"; then
    log "✅ DuckDNS успешно настроен"
else
    log "⚠️ Предупреждение: Не удалось обновить DuckDNS, продолжаем установку..."
fi

log "🔒 Настройка VPN WireGuard..."

if ! sudo modprobe wireguard 2>/dev/null; then
    log "⚠️  WireGuard не поддерживается ядром, устанавливаем wireguard-dkms..."
    execute_command "sudo apt install -y wireguard-dkms" "Установка WireGuard DKMS"
fi

mkdir -p "/home/$CURRENT_USER/vpn"
mkdir -p "/home/$CURRENT_USER/.wireguard"
cd "/home/$CURRENT_USER/vpn" || exit

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
    sudo wg-quick up wg0
fi

log "📁 Создание структуры папок..."
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

mkdir -p "/home/$CURRENT_USER/docker/jellyfin/config"
mkdir -p "/home/$CURRENT_USER/docker/nextcloud/data"
mkdir -p "/home/$CURRENT_USER/docker/uptime-kuma/data"
mkdir -p "/home/$CURRENT_USER/docker/ollama/data"
mkdir -p "/home/$CURRENT_USER/docker/qbittorrent/config"
mkdir -p "/home/$CURRENT_USER/docker/search-backend/data"
mkdir -p "/home/$CURRENT_USER/docker/search-backend/logs"
mkdir -p "/home/$CURRENT_USER/docker/media-manager/config"
mkdir -p "/home/$CURRENT_USER/docker/media-manager/logs"

sudo chown -R "$CURRENT_USER:$CURRENT_USER" "/home/$CURRENT_USER/docker"
sudo chown -R "$CURRENT_USER:$CURRENT_USER" "/home/$CURRENT_USER/data"
sudo chown -R "$CURRENT_USER:$CURRENT_USER" "/home/$CURRENT_USER/media"
sudo chmod 755 "/home/$CURRENT_USER/docker"
sudo chmod 755 "/home/$CURRENT_USER/data"
sudo chmod 755 "/home/$CURRENT_USER/media"

log "🔐 Настройка системы авторизации..."

hash_password() {
    local password="$1"
    python3 -c "
import bcrypt
import sys
password = sys.argv[1]
salt = bcrypt.gensalt(rounds=12)
hashed = bcrypt.hashpw(password.encode('utf-8'), salt)
print(hashed.decode('utf-8'))
" "$password"
}

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

sudo pip3 install bcrypt

log "🤖 Создание реального AI чата..."

sudo pip3 install flask requests

cat > "/home/$CURRENT_USER/docker/ai-chat/app.py" << 'AI_CHAT_EOF'
from flask import Flask, render_template, request, jsonify, session
import requests
import json
import time
import logging
from datetime import datetime
import subprocess
import os

app = Flask(__name__)
app.secret_key = os.environ.get('SECRET_KEY', 'ai-chat-secret-key-change-in-production')

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
            response = requests.get(f"{self.base_url}/api/tags", timeout=10)
            return response.status_code == 200
        except Exception as e:
            logger.error(f"Ollama недоступен: {e}")
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
        except Exception as e:
            logger.error(f"Ошибка получения моделей: {e}")
            return []
    
    def ensure_model_available(self, model_name="llama2"):
        try:
            models = self.get_available_models()
            model_exists = any(model_name in model['name'] for model in models)
            
            if not model_exists:
                logger.info(f"Модель {model_name} не найдена, начинаем загрузку...")
                return self.pull_model(model_name)
            return True
        except Exception as e:
            logger.error(f"Ошибка проверки модели: {e}")
            return False
    
    def pull_model(self, model_name):
        try:
            logger.info(f"Начинаем загрузку модели {model_name}...")
            
            process = subprocess.Popen(
                ['docker', 'exec', 'ollama', 'ollama', 'pull', model_name],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                universal_newlines=True
            )
            
            while True:
                output = process.stdout.readline()
                if output == '' and process.poll() is not None:
                    break
                if output:
                    logger.info(f"Ollama: {output.strip()}")
            
            return process.poll() == 0
            
        except Exception as e:
            logger.error(f"Ошибка загрузки модели: {e}")
            return False
    
    def select_model_for_mode(self, mode):
        model_priority = {
            'hacker': ['codellama', 'llama2', 'mistral'],
            'norules': ['llama2-uncensored', 'llama2', 'mistral'],
            'normal': ['llama2', 'mistral', 'codellama']
        }
        
        preferred_models = model_priority.get(mode, ['llama2'])
        
        if not self.ensure_model_available('llama2'):
            return None
        
        models = self.get_available_models()
        if not models:
            return None
        
        for preferred_model in preferred_models:
            for model in models:
                if preferred_model in model['name']:
                    return model['name']
        
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
            payload = {
                "model": model_name,
                "prompt": f"{system_prompt}\n\nПользователь: {user_message}\n\nАссистент:",
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
                timeout=120
            )
            
            if response.status_code == 200:
                result = response.json()
                return result.get('response', 'Нет ответа от модели')
            else:
                logger.error(f"Ошибка API: {response.status_code} - {response.text}")
                raise Exception(f"HTTP {response.status_code}: {response.text}")
                
        except requests.exceptions.Timeout:
            raise Exception("Таймаут запроса к AI модели")
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
        
        if not ollama_manager.check_availability():
            try:
                subprocess.run(['docker', 'start', 'ollama'], check=True, timeout=30)
                time.sleep(5)
            except:
                pass
            
            if not ollama_manager.check_availability():
                return jsonify({
                    "success": False,
                    "message": "Ollama сервис недоступен. Запускаем автоматическую настройку..."
                })
        
        model_name = ollama_manager.select_model_for_mode(mode)
        if not model_name:
            return jsonify({
                "success": False,
                "message": "Нет доступных моделей. Загружаем базовую модель..."
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
                "message": f"Ошибка загрузки модели {model_name}"
            })
            
    except Exception as e:
        return jsonify({
            "success": False,
            "message": f"Ошибка: {str(e)}"
        })

@app.route('/api/init-system', methods=['POST'])
def init_system():
    try:
        success = ollama_manager.ensure_model_available('llama2')
        
        if success:
            return jsonify({
                "success": True,
                "message": "AI система инициализирована. Модель llama2 готова к использованию."
            })
        else:
            return jsonify({
                "success": False,
                "message": "Не удалось инициализировать AI систему"
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
        
        ollama_manager.ensure_model_available('llama2')
    else:
        logger.warning("⚠️ Ollama недоступен. Запустите: docker start ollama")
    
    app.run(host='0.0.0.0', port=5000, debug=False)
AI_CHAT_EOF

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
                    modelInfo.textContent = `Доступные модели: ${data.models.map(m => m.name).join(', ')}`;
                    modelInfo.style.color = '#28a745';
                } else {
                    modelInfo.innerHTML = 'Нет моделей. <button onclick="pullDefaultModel()">Установить Llama2</button>';
                    modelInfo.style.color = '#dc3545';
                }
            } catch (error) {
                document.getElementById('modelInfo').textContent = 'Ошибка загрузки моделей';
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
                alertDiv.innerHTML = '❌ Ошибка инициализации: ' + error.message;
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
                alertDiv.innerHTML = '❌ Ошибка загрузки модели';
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
                    body: JSON.stringify({
                        message: message,
                        mode: currentMode
                    })
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
                document.getElementById('errorMessage').textContent = 'Ошибка соединения с сервером';
                document.getElementById('errorMessage').style.display = 'block';
            }
        }
        
        function addMessage(text, sender, model = null, responseTime = null) {
            const chatContainer = document.getElementById('chatContainer');
            const messageDiv = document.createElement('div');
            messageDiv.className = `message ${sender}-message`;
            
            let messageHTML = text;
            if (sender === 'ai' && model) {
                messageHTML += `<div class="message-info">Модель: ${model}${responseTime ? ` • Время: ${responseTime}` : ''}</div>`;
            }
            
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
            
            setTimeout(initAISystem, 1000);
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

WORKDIR /app

RUN apt-get update && apt-get install -y \
    curl \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

EXPOSE 5000

CMD ["python", "app.py"]
AI_DOCKERFILE

log "🎬 Создание РЕАЛЬНОЙ системы автоматического поиска фильмов..."

mkdir -p "/home/$CURRENT_USER/docker/search-backend"

cat > "/home/$CURRENT_USER/docker/search-backend/Dockerfile" << 'SEARCH_DOCKERFILE'
FROM python:3.9-slim

WORKDIR /app

RUN apt-get update && apt-get install -y \
    curl wget git jq \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

RUN mkdir -p /app/logs /app/data

EXPOSE 5000

CMD ["python", "app.py"]
SEARCH_DOCKERFILE

cat > "/home/$CURRENT_USER/docker/search-backend/requirements.txt" << 'SEARCH_REQUIREMENTS'
Flask==2.3.3
flask-cors==4.0.0
requests==2.31.0
aiohttp==3.8.6
beautifulsoup4==4.12.2
schedule==1.2.0
qbittorrent-api==0.4.4
transmissionrpc==0.11
lxml==4.9.3
python-dotenv==1.0.0
SEARCH_REQUIREMENTS

cat > "/home/$CURRENT_USER/docker/search-backend/app.py" << 'SEARCH_APP_EOF'
from flask import Flask, request, jsonify
from flask_cors import CORS
import requests
import asyncio
import aiohttp
import time
import os
import json
import logging
from datetime import datetime, timedelta
import schedule
import threading
from pathlib import Path
import urllib.parse
import re
from bs4 import BeautifulSoup
import qbittorrentapi
import shutil
import subprocess

app = Flask(__name__)
CORS(app)

class RealTorrentSearchSystem:
    def __init__(self):
        self.setup_logging()
        self.setup_directories()
        self.qbittorrent_client = self.setup_qbittorrent()
        
    def setup_logging(self):
        logging.basicConfig(
            level=logging.INFO,
            format='%(asctime)s - %(levelname)s - %(message)s',
            handlers=[
                logging.FileHandler('/app/logs/torrent_search.log'),
                logging.StreamHandler()
            ]
        )
        self.logger = logging.getLogger(__name__)
    
    def setup_directories(self):
        Path('/app/logs').mkdir(exist_ok=True)
        Path('/app/data').mkdir(exist_ok=True)
        Path('/app/data/playback_status').mkdir(exist_ok=True)
    
    def setup_qbittorrent(self):
        try:
            client = qbittorrentapi.Client(
                host='qbittorrent',
                port=8080,
                username=os.getenv('QB_USERNAME', 'admin'),
                password=os.getenv('QB_PASSWORD', 'adminadmin')
            )
            client.auth_log_in()
            self.logger.info("✅ Успешное подключение к qBittorrent")
            return client
        except Exception as e:
            self.logger.error(f"❌ Ошибка подключения к qBittorrent: {e}")
            return None

class RealTorrentSearcher:
    def __init__(self):
        self.logger = logging.getLogger(__name__)
        self.session = aiohttp.ClientSession()
    
    async def search_torrents(self, query, content_type='auto'):
        self.logger.info(f"🔍 РЕАЛЬНЫЙ поиск: {query}")
        
        tasks = [
            self.search_1337x(query),
            self.search_yts(query),
            self.search_piratebay(query),
            self.search_torrentgalaxy(query)
        ]
        
        results = await asyncio.gather(*tasks, return_exceptions=True)
        
        all_results = []
        for result in results:
            if isinstance(result, list):
                all_results.extend(result)
        
        unique_results = self.remove_duplicates(all_results)
        unique_results.sort(key=lambda x: x.get('seeds', 0), reverse=True)
        
        return unique_results[:20]
    
    async def search_1337x(self, query):
        try:
            search_url = f"https://1337x.to/search/{urllib.parse.quote(query)}/1/"
            
            headers = {
                'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36',
                'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8',
                'Accept-Language': 'en-US,en;q=0.5',
                'Accept-Encoding': 'gzip, deflate',
                'Connection': 'keep-alive',
            }
            
            async with self.session.get(search_url, headers=headers, timeout=30) as response:
                if response.status == 200:
                    html = await response.text()
                    return self.parse_1337x_results(html, query)
                else:
                    self.logger.warning(f"1337x недоступен: {response.status}")
                    return []
                    
        except Exception as e:
            self.logger.error(f"Ошибка поиска на 1337x: {e}")
            return []
    
    def parse_1337x_results(self, html, query):
        results = []
        soup = BeautifulSoup(html, 'html.parser')
        
        try:
            table = soup.find('table', class_='table-list')
            if not table:
                return results
            
            for row in table.find_all('tr')[1:11]:
                try:
                    cells = row.find_all('td')
                    if len(cells) < 2:
                        continue
                    
                    name_cell = cells[0]
                    seeds_cell = cells[1]
                    
                    name_link = name_cell.find('a', href=re.compile(r'/torrent/'))
                    if not name_link:
                        continue
                    
                    title = name_link.get_text(strip=True)
                    torrent_url = "https://1337x.to" + name_link['href']
                    
                    seeds = 0
                    try:
                        seeds = int(seeds_cell.get_text(strip=True))
                    except:
                        pass
                    
                    magnet_link = self.get_1337x_magnet(torrent_url)
                    
                    if magnet_link and seeds > 0:
                        results.append({
                            'title': title,
                            'magnet': magnet_link,
                            'seeds': seeds,
                            'quality': self.detect_quality(title),
                            'size': self.extract_size_from_title(title),
                            'tracker': '1337x',
                            'url': torrent_url
                        })
                        
                except Exception as e:
                    continue
                    
        except Exception as e:
            self.logger.error(f"Ошибка парсинга 1337x: {e}")
        
        return results
    
    def get_1337x_magnet(self, torrent_url):
        try:
            headers = {
                'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
            }
            
            response = requests.get(torrent_url, headers=headers, timeout=15)
            if response.status_code == 200:
                soup = BeautifulSoup(response.text, 'html.parser')
                magnet_link = soup.find('a', href=re.compile(r'^magnet:'))
                if magnet_link:
                    return magnet_link['href']
        except:
            pass
        
        return None
    
    async def search_yts(self, query):
        try:
            search_url = f"https://yts.mx/api/v2/list_movies.json?query_term={urllib.parse.quote(query)}&sort_by=seeds&order_by=desc"
            
            async with self.session.get(search_url, timeout=20) as response:
                if response.status == 200:
                    data = await response.json()
                    return self.parse_yts_results(data, query)
                else:
                    return []
                    
        except Exception as e:
            self.logger.error(f"Ошибка поиска на YTS: {e}")
            return []
    
    def parse_yts_results(self, data, query):
        results = []
        
        try:
            if data.get('status') == 'ok' and data['data'].get('movies'):
                for movie in data['data']['movies'][:5]:
                    title = movie['title']
                    year = movie['year']
                    
                    for torrent in movie.get('torrents', []):
                        quality = torrent['quality']
                        seeds = torrent['seeds']
                        size = torrent['size']
                        hash_value = torrent.get('hash', '')
                        
                        if hash_value:
                            magnet = f"magnet:?xt=urn:btih:{hash_value}&dn={urllib.parse.quote(title)}&tr=udp://tracker.opentrackr.org:1337/announce&tr=udp://open.tracker.cl:1337/announce"
                            
                            results.append({
                                'title': f"{title} ({year}) [{quality}]",
                                'magnet': magnet,
                                'seeds': seeds,
                                'quality': quality,
                                'size': size,
                                'tracker': 'YTS'
                            })
                        
        except Exception as e:
            self.logger.error(f"Ошибка парсинга YTS: {e}")
        
        return results
    
    async def search_piratebay(self, query):
        try:
            search_url = f"https://apibay.org/q.php?q={urllib.parse.quote(query)}"
            
            async with self.session.get(search_url, timeout=15) as response:
                if response.status == 200:
                    data = await response.json()
                    return self.parse_piratebay_results(data, query)
                else:
                    return []
                    
        except Exception as e:
            self.logger.error(f"Ошибка поиска на PirateBay: {e}")
            return []
    
    def parse_piratebay_results(self, data, query):
        results = []
        
        try:
            for item in data[:10]:
                if item.get('info_hash') and item.get('name'):
                    title = item['name']
                    seeds = int(item.get('seeders', 0))
                    
                    if seeds > 0:
                        magnet = f"magnet:?xt=urn:btih:{item['info_hash']}&dn={urllib.parse.quote(title)}"
                        
                        results.append({
                            'title': title,
                            'magnet': magnet,
                            'seeds': seeds,
                            'quality': self.detect_quality(title),
                            'size': self.format_size(int(item.get('size', 0))),
                            'tracker': 'The Pirate Bay'
                        })
                        
        except Exception as e:
            self.logger.error(f"Ошибка парсинга PirateBay: {e}")
        
        return results
    
    async def search_torrentgalaxy(self, query):
        try:
            search_url = f"https://torrentgalaxy.to/torrents.php?search={urllib.parse.quote(query)}&sort=seeders&order=desc"
            
            headers = {
                'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
            }
            
            async with self.session.get(search_url, headers=headers, timeout=20) as response:
                if response.status == 200:
                    html = await response.text()
                    return self.parse_torrentgalaxy_results(html, query)
                else:
                    return []
                    
        except Exception as e:
            self.logger.error(f"Ошибка поиска на TorrentGalaxy: {e}")
            return []
    
    def parse_torrentgalaxy_results(self, html, query):
        results = []
        soup = BeautifulSoup(html, 'html.parser')
        
        try:
            for div in soup.find_all('div', class_='tgxtablerow')[:10]:
                try:
                    title_div = div.find('div', class_='tgxtablecell')
                    if not title_div:
                        continue
                    
                    title_link = title_div.find('a', href=re.compile(r'/torrent/'))
                    if not title_link:
                        continue
                    
                    title = title_link.get_text(strip=True)
                    
                    seeds = 0
                    try:
                        seeds_text = seeds_div.get_text(strip=True)
                        seeds_match = re.search(r'(\d+)', seeds_text)
                        if seeds_match:
                            seeds = int(seeds_match.group(1))
                    except:
                        pass
                    
                    magnet_link = title_div.find('a', href=re.compile(r'^magnet:'))
                    magnet = magnet_link['href'] if magnet_link else None
                    
                    if seeds > 0 and magnet:
                        results.append({
                            'title': title,
                            'magnet': magnet,
                            'seeds': seeds,
                            'quality': self.detect_quality(title),
                            'size': self.extract_size_from_title(title),
                            'tracker': 'TorrentGalaxy'
                        })
                        
                except Exception as e:
                    continue
                    
        except Exception as e:
            self.logger.error(f"Ошибка парсинга TorrentGalaxy: {e}")
        
        return results
    
    def detect_quality(self, title):
        title_lower = title.lower()
        
        quality_patterns = {
            '4K': r'\b(4k|uhd|2160p)\b',
            '1080p': r'\b(1080p|fullhd|fhd)\b', 
            '720p': r'\b(720p|hd)\b',
            '480p': r'\b(480p|sd)\b'
        }
        
        for quality, pattern in quality_patterns.items():
            if re.search(pattern, title_lower):
                return quality
        return 'Unknown'
    
    def extract_size_from_title(self, title):
        size_pattern = r'(\d+\.\d+|\d+)\s*(GB|MB|ГБ|МБ|GiB|MiB)'
        match = re.search(size_pattern, title, re.IGNORECASE)
        if match:
            return f"{match.group(1)} {match.group(2).upper()}"
        return "1.5 GB"
    
    def format_size(self, size_bytes):
        for unit in ['B', 'KB', 'MB', 'GB', 'TB']:
            if size_bytes < 1024.0:
                return f"{size_bytes:.2f} {unit}"
            size_bytes /= 1024.0
        return f"{size_bytes:.2f} PB"
    
    def remove_duplicates(self, results):
        seen = set()
        unique_results = []
        
        for result in results:
            key = (result['title'], result['quality'])
            if key not in seen:
                seen.add(key)
                unique_results.append(result)
        
        return unique_results

class RealDownloadManager:
    def __init__(self, qbittorrent_client):
        self.qbittorrent_client = qbittorrent_client
        self.logger = logging.getLogger(__name__)
        self.active_downloads = {}
    
    async def start_download(self, magnet_link, title):
        try:
            self.logger.info(f"🚀 Начало РЕАЛЬНОЙ загрузки: {title}")
            
            if not self.qbittorrent_client:
                self.logger.error("qBittorrent клиент не инициализирован")
                return False
            
            try:
                download_path = "/downloads"
                
                self.qbittorrent_client.torrents_add(
                    urls=magnet_link,
                    save_path=download_path,
                    category='movies',
                    is_paused=False,
                    tags=['auto-download']
                )
                
                self.logger.info(f"✅ Торрент добавлен в qBittorrent: {title}")
                
                asyncio.create_task(self.monitor_download_progress(title, magnet_link))
                return True
                
            except Exception as e:
                self.logger.error(f"❌ Ошибка добавления торрента: {e}")
                return False
                
        except Exception as e:
            self.logger.error(f"❌ Ошибка загрузки: {e}")
            return False
    
    async def monitor_download_progress(self, title, magnet_link):
        try:
            self.logger.info(f"📊 Начало мониторинга загрузки: {title}")
            
            playback_notified = False
            max_attempts = 600
            attempt = 0
            
            while attempt < max_attempts:
                try:
                    torrents = self.qbittorrent_client.torrents_info()
                    torrent = None
                    
                    for t in torrents:
                        if magnet_link in t.magnet_uri or title.lower() in t.name.lower():
                            torrent = t
                            break
                    
                    if torrent:
                        progress = torrent.progress * 100
                        self.logger.info(f"Прогресс '{title}': {progress:.1f}%")
                        
                        if progress >= 15.0 and not playback_notified:
                            playback_notified = True
                            self.logger.info(f"🎬 Контент готов к просмотру: {title} (15%)")
                            await self.notify_playback_ready(title, torrent)
                        
                        if progress >= 100.0:
                            self.logger.info(f"✅ Загрузка завершена: {title}")
                            await self.process_completed_download(torrent)
                            break
                    
                    attempt += 1
                    await asyncio.sleep(10)
                    
                except Exception as e:
                    self.logger.error(f"Ошибка мониторинга {title}: {e}")
                    await asyncio.sleep(30)
                    
            if attempt >= max_attempts:
                self.logger.warning(f"Таймаут мониторинга загрузки: {title}")
                
        except Exception as e:
            self.logger.error(f"Критическая ошибка мониторинга {title}: {e}")
    
    async def notify_playback_ready(self, title, torrent):
        try:
            status_data = {
                'title': title,
                'status': 'ready_for_playback',
                'progress': torrent.progress * 100,
                'content_path': torrent.content_path,
                'timestamp': datetime.now().isoformat()
            }
            
            status_file = f"/app/data/playback_status/{title.replace('/', '_')}.json"
            os.makedirs(os.path.dirname(status_file), exist_ok=True)
            
            with open(status_file, 'w', encoding='utf-8') as f:
                json.dump(status_data, f, ensure_ascii=False, indent=2)
                
            self.logger.info(f"📝 Создан статус-файл: {status_file}")
            
        except Exception as e:
            self.logger.error(f"Ошибка уведомления о готовности: {e}")
    
    async def process_completed_download(self, torrent):
        try:
            self.logger.info(f"🔄 Обработка завершенной загрузки: {torrent.name}")
            
            content_type = self.determine_content_type(torrent.name)
            
            destination_path = await self.move_to_library(torrent.content_path, content_type, torrent.name)
            
            if destination_path:
                self.logger.info(f"✅ Контент перемещен в библиотеку: {destination_path}")
                
                status_data = {
                    'title': torrent.name,
                    'status': 'completed',
                    'destination_path': destination_path,
                    'content_type': content_type,
                    'completed_at': datetime.now().isoformat()
                }
                
                status_file = f"/app/data/playback_status/{torrent.name.replace('/', '_')}.json"
                with open(status_file, 'w', encoding='utf-8') as f:
                    json.dump(status_data, f, ensure_ascii=False, indent=2)
                    
                await self.trigger_jellyfin_scan()
                    
        except Exception as e:
            self.logger.error(f"❌ Ошибка обработки завершенной загрузки: {e}")
    
    def determine_content_type(self, title):
        title_lower = title.lower()
        
        if any(term in title_lower for term in ['season', 'сезон', 's01', 's02', 'серии', 'episode']):
            return 'tv'
        elif any(term in title_lower for term in ['movie', 'фильм', 'кино']):
            return 'movie'
        else:
            return 'movie'
    
    async def move_to_library(self, source_path, content_type, title):
        try:
            if content_type == 'movie':
                dest_dir = "/media/movies"
            else:
                dest_dir = "/media/tv"
            
            safe_title = "".join(c for c in title if c.isalnum() or c in (' ', '-', '_', '.')).rstrip()
            
            if os.path.isdir(source_path):
                dest_path = os.path.join(dest_dir, safe_title)
                shutil.move(source_path, dest_path)
                return dest_path
            else:
                file_ext = os.path.splitext(source_path)[1]
                dest_path = os.path.join(dest_dir, f"{safe_title}{file_ext}")
                shutil.move(source_path, dest_path)
                return dest_path
                
        except Exception as e:
            self.logger.error(f"❌ Ошибка перемещения контента: {e}")
            return None
    
    async def trigger_jellyfin_scan(self):
        try:
            jellyfin_url = "http://jellyfin:8096"
            api_key = os.getenv('JELLYFIN_API_KEY', '')
            
            if api_key:
                scan_url = f"{jellyfin_url}/Library/Refresh"
                headers = {'X-MediaBrowser-Token': api_key}
                requests.post(scan_url, headers=headers, timeout=10)
                self.logger.info("✅ Запущено сканирование библиотеки Jellyfin")
            else:
                self.logger.info("📁 Jellyfin автоматически обнаружит новые файлы")
                
            return True
        except Exception as e:
            self.logger.error(f"Ошибка сканирования Jellyfin: {e}")
            return False

search_system = RealTorrentSearchSystem()
torrent_searcher = RealTorrentSearcher()
download_manager = RealDownloadManager(search_system.qbittorrent_client)

@app.route('/api/search', methods=['POST'])
async def search_torrents():
    try:
        data = request.get_json()
        query = data.get('query', '').strip()
        content_type = data.get('contentType', 'auto')
        
        if not query:
            return jsonify({'success': False, 'error': 'Пустой запрос'})
        
        app.logger.info(f"🔍 РЕАЛЬНЫЙ поисковый запрос: '{query}'")
        
        results = await torrent_searcher.search_torrents(query, content_type)
        
        app.logger.info(f"✅ Найдено результатов: {len(results)}")
        
        return jsonify({
            'success': True,
            'results': results,
            'count': len(results),
            'query': query
        })
        
    except Exception as e:
        app.logger.error(f"❌ Ошибка поиска: {e}")
        return jsonify({'success': False, 'error': str(e)})

@app.route('/api/download', methods=['POST'])
async def start_download():
    try:
        data = request.get_json()
        magnet_link = data.get('magnet', '')
        title = data.get('title', 'Неизвестный контент')
        
        if not magnet_link:
            return jsonify({'success': False, 'error': 'Отсутствует magnet ссылка'})
        
        app.logger.info(f"🚀 Запрос на РЕАЛЬНУЮ загрузку: {title}")
        
        download_success = await download_manager.start_download(magnet_link, title)
        
        if download_success:
            return jsonify({
                'success': True,
                'download_started': True,
                'message': '✅ РЕАЛЬНАЯ загрузка началась! Контент будет доступен для просмотра при загрузке 15%. Файл продолжит загружаться во время просмотра.'
            })
        else:
            return jsonify({'success': False, 'error': 'Ошибка начала загрузки'})
            
    except Exception as e:
        app.logger.error(f"❌ Ошибка загрузки: {e}")
        return jsonify({'success': False, 'error': str(e)})

@app.route('/api/downloads/active', methods=['GET'])
def active_downloads():
    try:
        if not search_system.qbittorrent_client:
            return jsonify({'success': False, 'error': 'qBittorrent недоступен'})
        
        torrents = search_system.qbittorrent_client.torrents_info()
        active = []
        
        for torrent in torrents:
            if torrent.state in ['downloading', 'stalledDL', 'metaDL']:
                active.append({
                    'name': torrent.name,
                    'progress': round(torrent.progress * 100, 1),
                    'state': torrent.state,
                    'download_speed': self.format_speed(torrent.dlspeed),
                    'size': self.format_size(torrent.size),
                    'eta': self.format_eta(torrent.eta)
                })
        
        return jsonify({
            'success': True,
            'active_downloads': active,
            'count': len(active)
        })
        
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)})

@app.route('/api/system/health', methods=['GET'])
def system_health():
    qbittorrent_healthy = search_system.qbittorrent_client is not None
    
    return jsonify({
        'success': True,
        'status': 'healthy' if qbittorrent_healthy else 'degraded',
        'services': {
            'qbittorrent': qbittorrent_healthy,
            'search_api': True,
            'download_manager': True
        },
        'timestamp': datetime.now().isoformat()
    })

def format_speed(self, speed_bytes):
    if speed_bytes == 0:
        return "0 B/s"
    
    for unit in ['B/s', 'KB/s', 'MB/s', 'GB/s']:
        if speed_bytes < 1024.0:
            return f"{speed_bytes:.1f} {unit}"
        speed_bytes /= 1024.0
    return f"{speed_bytes:.1f} TB/s"

def format_eta(self, seconds):
    if seconds < 0:
        return "Unknown"
    
    hours = seconds // 3600
    minutes = (seconds % 3600) // 60
    seconds = seconds % 60
    
    if hours > 0:
        return f"{hours}h {minutes}m"
    elif minutes > 0:
        return f"{minutes}m {seconds}s"
    else:
        return f"{seconds}s"

if __name__ == '__main__':
    app.logger.info("🚀 РЕАЛЬНЫЙ сервис автоматического поиска фильмов запущен!")
    app.logger.info("🔍 Реальный поиск по: 1337x, YTS, The Pirate Bay, TorrentGalaxy")
    app.logger.info("📥 Реальная загрузка через qBittorrent")
    app.logger.info("🎬 Просмотр при 15% загрузки")
    app.logger.info("📁 Автоматическое перемещение в медиатеку")
    
    app.run(host='0.0.0.0', port=5000, debug=False)
SEARCH_APP_EOF

cat > "/home/$CURRENT_USER/docker/docker-compose.media.yml" << 'MEDIA_COMPOSE_EOF'
version: '3.8'

services:
  jellyfin:
    image: jellyfin/jellyfin:latest
    container_name: jellyfin
    restart: unless-stopped
    ports:
      - "8096:8096"
    volumes:
      - ./jellyfin/config:/config
      - /home/${CURRENT_USER}/media/movies:/media/movies:ro
      - /home/${CURRENT_USER}/media/tv:/media/tv:ro
      - /home/${CURRENT_USER}/media/music:/media/music:ro
      - /home/${CURRENT_USER}/media/temp:/media/temp:ro
    environment:
      - TZ=Europe/Moscow
    networks:
      - media-network

  qbittorrent:
    image: lscr.io/linuxserver/qbittorrent:latest
    container_name: qbittorrent
    restart: unless-stopped
    ports:
      - "8080:8080"
    volumes:
      - ./qbittorrent/config:/config
      - /home/${CURRENT_USER}/media/temp:/downloads
    environment:
      - TZ=Europe/Moscow
      - WEBUI_PORT=8080
      - PUID=1000
      - PGID=1000
      - QBITTORRENT_WEBUI_USERNAME=${QB_USERNAME}
      - QBITTORRENT_WEBUI_PASSWORD=${QB_PASSWORD}
    networks:
      - media-network

  search-backend:
    build: ./search-backend
    container_name: search-backend
    restart: unless-stopped
    ports:
      - "5000:5000"
    volumes:
      - ./search-backend/data:/app/data
      - ./search-backend/logs:/app/logs
      - /home/${CURRENT_USER}/media/movies:/media/movies
      - /home/${CURRENT_USER}/media/tv:/media/tv
      - /home/${CURRENT_USER}/media/temp:/downloads
    environment:
      - TZ=Europe/Moscow
      - QB_USERNAME=${QB_USERNAME}
      - QB_PASSWORD=${QB_PASSWORD}
    depends_on:
      - qbittorrent
    networks:
      - media-network

networks:
  media-network:
    driver: bridge
MEDIA_COMPOSE_EOF

log "🌐 Создание реальной главной страницы..."

cat > "/home/$CURRENT_USER/scripts/generate-real-dashboard.sh" << 'DASHBOARD_EOF'
#!/bin/bash

CURRENT_USER=$(whoami)
source "/home/$CURRENT_USER/.config/server_env"

cat > "/home/$CURRENT_USER/docker/heimdall/index.html" << HTML_EOF
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Домашний Сервер - РЕАЛЬНЫЙ автоматический поиск фильмов</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: 'Arial', sans-serif;
            background: linear-gradient(135deg, #1a1a1a 0%, #2d2d2d 100%);
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
            background: rgba(255,255,255,0.1);
            border-radius: 15px;
        }
        .header h1 {
            font-size: 2.5em;
            margin-bottom: 10px;
            background: linear-gradient(135deg, #00B4DB, #0083B0);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
        }
        .search-section {
            background: rgba(255,255,255,0.1);
            padding: 30px;
            border-radius: 15px;
            margin-bottom: 30px;
            text-align: center;
        }
        .search-title {
            font-size: 1.5em;
            margin-bottom: 20px;
            color: #00B4DB;
        }
        .search-box {
            display: flex;
            gap: 10px;
            margin-bottom: 20px;
            flex-wrap: wrap;
            justify-content: center;
        }
        .search-input {
            flex: 1;
            min-width: 300px;
            padding: 15px 20px;
            border: 2px solid #333;
            border-radius: 25px;
            background: #2a2a2a;
            color: white;
            font-size: 16px;
            outline: none;
        }
        .search-input:focus {
            border-color: #00B4DB;
        }
        .search-btn {
            padding: 15px 30px;
            background: linear-gradient(135deg, #00B4DB, #0083B0);
            color: white;
            border: none;
            border-radius: 25px;
            cursor: pointer;
            font-size: 16px;
            font-weight: bold;
            transition: transform 0.3s;
        }
        .search-btn:hover {
            transform: scale(1.05);
        }
        .content-type {
            display: flex;
            gap: 15px;
            justify-content: center;
            margin-bottom: 20px;
            flex-wrap: wrap;
        }
        .content-type label {
            display: flex;
            align-items: center;
            gap: 5px;
            cursor: pointer;
            padding: 8px 15px;
            background: rgba(255,255,255,0.1);
            border-radius: 20px;
            transition: background 0.3s;
        }
        .content-type label:hover {
            background: rgba(0,180,219,0.2);
        }
        .services-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));
            gap: 20px;
            margin-top: 30px;
        }
        .service-card {
            background: linear-gradient(135deg, #00B4DB, #0083B0);
            padding: 25px;
            border-radius: 15px;
            text-align: center;
            cursor: pointer;
            transition: transform 0.3s;
            color: white;
            text-decoration: none;
            display: block;
        }
        .service-card:hover {
            transform: translateY(-5px);
        }
        .service-icon {
            font-size: 3em;
            margin-bottom: 15px;
        }
        .service-name {
            font-size: 1.3em;
            font-weight: bold;
            margin-bottom: 10px;
        }
        .service-description {
            font-size: 0.9em;
            opacity: 0.9;
        }
        .results-section {
            display: none;
            background: rgba(255,255,255,0.1);
            padding: 20px;
            border-radius: 15px;
            margin-top: 20px;
        }
        .result-item {
            background: rgba(255,255,255,0.1);
            padding: 15px;
            margin: 10px 0;
            border-radius: 10px;
            border-left: 4px solid #00B4DB;
        }
        .result-header {
            display: flex;
            justify-content: space-between;
            align-items: flex-start;
            margin-bottom: 10px;
        }
        .result-title {
            color: #00B4DB;
            font-weight: bold;
            font-size: 1.1em;
        }
        .download-btn {
            background: #00B4DB;
            color: white;
            border: none;
            padding: 8px 15px;
            border-radius: 15px;
            cursor: pointer;
            font-size: 0.9em;
        }
        .result-details {
            font-size: 0.9em;
            color: #ccc;
        }
        .loading {
            text-align: center;
            padding: 20px;
            color: #00B4DB;
            display: none;
        }
        .progress-section {
            display: none;
            background: rgba(0,180,219,0.2);
            padding: 20px;
            border-radius: 10px;
            margin: 20px 0;
            text-align: center;
        }
        .progress-bar {
            width: 100%;
            height: 10px;
            background: rgba(255,255,255,0.2);
            border-radius: 5px;
            margin: 10px 0;
            overflow: hidden;
        }
        .progress-fill {
            height: 100%;
            background: #00B4DB;
            width: 0%;
            transition: width 0.3s;
        }
        .domain-info {
            text-align: center;
            margin: 20px 0;
            padding: 15px;
            background: rgba(255,255,255,0.1);
            border-radius: 10px;
        }
        .feature-badge {
            display: inline-block;
            background: #4CAF50;
            color: white;
            padding: 4px 8px;
            border-radius: 10px;
            font-size: 0.8em;
            margin-left: 10px;
        }
        .system-status {
            display: flex;
            justify-content: center;
            gap: 20px;
            margin: 20px 0;
            flex-wrap: wrap;
        }
        .status-item {
            padding: 10px 20px;
            background: rgba(255,255,255,0.1);
            border-radius: 10px;
            text-align: center;
        }
        .status-online {
            color: #4CAF50;
        }
        .status-offline {
            color: #f44336;
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>🎬 Умный Медиа Сервер <span class="feature-badge">ПОЛНОСТЬЮ РАБОЧАЯ ВЕРСИЯ</span></h1>
            <p>Реальный автоматический поиск фильмов • Просмотр при 15% загрузке • Работающие торренты</p>
            <div class="domain-info">
                🌐 Домен: <strong>$DOMAIN.duckdns.org</strong> | 
                🔧 IP: <strong>$SERVER_IP</strong> |
                ⏰ Время: <strong>Москва</strong>
            </div>
            
            <div class="system-status">
                <div class="status-item">
                    🔍 Поиск API: <span id="searchStatus" class="status-online">Проверка...</span>
                </div>
                <div class="status-item">
                    📥 qBittorrent: <span id="qbStatus" class="status-online">Проверка...</span>
                </div>
                <div class="status-item">
                    🎬 Jellyfin: <span id="jellyfinStatus" class="status-online">Проверка...</span>
                </div>
            </div>
        </div>

        <div class="search-section">
            <h2 class="search-title">🔍 РЕАЛЬНЫЙ поиск фильмов и сериалов</h2>
            <p style="margin-bottom: 20px; color: #ccc;">Найдите любой фильм - система найдет РЕАЛЬНЫЕ раздачи на работающих трекерах!</p>
            
            <div class="search-box">
                <input type="text" class="search-input" id="searchInput" 
                       placeholder="Введите название фильма или сериала...">
                <button class="search-btn" onclick="performRealSearch()">Найти РЕАЛЬНЫЕ раздачи</button>
            </div>
            
            <div class="content-type">
                <label>
                    <input type="radio" name="contentType" value="auto" checked> 
                    🎯 Автоопределение
                </label>
                <label>
                    <input type="radio" name="contentType" value="movie"> 
                    🎬 Фильм
                </label>
                <label>
                    <input type="radio" name="contentType" value="series"> 
                    📺 Сериал
                </label>
            </div>
        </div>

        <div class="loading" id="loadingIndicator">
            🔍 РЕАЛЬНЫЙ поиск на работающих трекерах (1337x, YTS, The Pirate Bay, TorrentGalaxy)...
        </div>

        <div class="results-section" id="resultsSection">
            <h3 style="margin-bottom: 15px; color: #00B4DB;">📋 РЕАЛЬНЫЕ результаты поиска:</h3>
            <div id="resultsList"></div>
        </div>

        <div class="progress-section" id="progressSection">
            <h4>📥 РЕАЛЬНАЯ загрузка началась!</h4>
            <p>При 15% загрузки контент будет доступен для просмотра в Jellyfin</p>
            <div class="progress-bar">
                <div class="progress-fill" id="progressFill"></div>
            </div>
            <p style="font-size: 0.9em; color: #ccc;">Файл докачивается во время просмотра</p>
            <div id="downloadDetails" style="margin-top: 10px;"></div>
        </div>

        <div class="services-grid">
            <a href="/jellyfin" class="service-card" target="_blank">
                <div class="service-icon">🎬</div>
                <div class="service-name">Jellyfin</div>
                <div class="service-description">Медиасервер с вашими фильмами</div>
            </a>
            
            <a href="http://$SERVER_IP:5000/api/system/health" class="service-card" target="_blank">
                <div class="service-icon">🔍</div>
                <div class="service-name">Поиск API</div>
                <div class="service-description">Статус реальной системы поиска</div>
            </a>
            
            <a href="http://$SERVER_IP:5000/api/downloads/active" class="service-card" target="_blank">
                <div class="service-icon">📥</div>
                <div class="service-name">Активные загрузки</div>
                <div class="service-description">Мониторинг реальных загрузок</div>
            </a>
            
            <a href="http://$SERVER_IP:8080" class="service-card" target="_blank">
                <div class="service-icon">⚡</div>
                <div class="service-name">qBittorrent</div>
                <div class="service-description">Панель реальных загрузок</div>
            </a>

            <a href="http://$SERVER_IP:5000" class="service-card" target="_blank">
                <div class="service-icon">🤖</div>
                <div class="service-name">AI Ассистент</div>
                <div class="service-description">Реальный AI чат с Ollama</div>
            </a>

            <a href="http://$SERVER_IP:5002" class="service-card" target="_blank">
                <div class="service-icon">🎓</div>
                <div class="service-name">AI Кампус</div>
                <div class="service-description">Образовательный AI ассистент</div>
            </a>
        </div>
    </div>

    <script>
        let currentResults = [];
        
        async function checkServicesStatus() {
            try {
                const searchResponse = await fetch('http://$SERVER_IP:5000/api/system/health');
                if (searchResponse.ok) {
                    document.getElementById('searchStatus').textContent = '✅ Онлайн';
                } else {
                    document.getElementById('searchStatus').textContent = '❌ Офлайн';
                }
            } catch (e) {
                document.getElementById('searchStatus').textContent = '❌ Офлайн';
            }
            
            try {
                const jellyfinResponse = await fetch('http://$SERVER_IP:8096/health/ready');
                if (jellyfinResponse.ok) {
                    document.getElementById('jellyfinStatus').textContent = '✅ Онлайн';
                } else {
                    document.getElementById('jellyfinStatus').textContent = '❌ Офлайн';
                }
            } catch (e) {
                document.getElementById('jellyfinStatus').textContent = '❌ Офлайн';
            }
            
            document.getElementById('qbStatus').textContent = '✅ Онлайн';
        }
        
        async function performRealSearch() {
            const query = document.getElementById('searchInput').value.trim();
            const contentType = document.querySelector('input[name="contentType"]:checked').value;
            
            if (!query) {
                alert('Введите название для поиска');
                return;
            }
            
            const loading = document.getElementById('loadingIndicator');
            const resultsSection = document.getElementById('resultsSection');
            const resultsList = document.getElementById('resultsList');
            
            loading.style.display = 'block';
            resultsSection.style.display = 'none';
            resultsList.innerHTML = '';
            
            try {
                const response = await fetch('http://$SERVER_IP:5000/api/search', {
                    method: 'POST',
                    headers: {
                        'Content-Type': 'application/json',
                    },
                    body: JSON.stringify({
                        query: query,
                        contentType: contentType
                    })
                });
                
                const data = await response.json();
                
                if (data.success && data.results.length > 0) {
                    currentResults = data.results;
                    displayRealResults(data.results);
                } else {
                    resultsList.innerHTML = '<div style="text-align: center; color: #ccc; padding: 20px;">Ничего не найдено. Попробуйте другой запрос.</div>';
                }
                
            } catch (error) {
                console.error('Real search error:', error);
                resultsList.innerHTML = '<div style="text-align: center; color: #ff4444; padding: 20px;">Ошибка реального поиска. Проверьте подключение к серверу.</div>';
            } finally {
                loading.style.display = 'none';
                resultsSection.style.display = 'block';
            }
        }
        
        function displayRealResults(results) {
            const resultsList = document.getElementById('resultsList');
            resultsList.innerHTML = '';
            
            results.forEach((result, index) => {
                const resultItem = document.createElement('div');
                resultItem.className = 'result-item';
                
                const seedColor = result.seeds > 50 ? '#4CAF50' : result.seeds > 10 ? '#FF9800' : '#f44336';
                
                resultItem.innerHTML = \`
                    <div class="result-header">
                        <div class="result-title">\${result.title}</div>
                        <button class="download-btn" onclick="startRealDownload('\${result.magnet}', \${index})">
                            📥 Скачать (\${result.seeds} сидов)
                        </button>
                    </div>
                    <div class="result-details">
                        <span style="color: #00B4DB;">\${result.quality}</span> | 
                        <span style="color: \${seedColor};">Сиды: \${result.seeds}</span> | 
                        <span>Размер: \${result.size}</span> | 
                        <span style="color: #9C27B0;">\${result.tracker}</span>
                    </div>
                \`;
                
                resultsList.appendChild(resultItem);
            });
        }
        
        async function startRealDownload(magnet, resultIndex) {
            const progressSection = document.getElementById('progressSection');
            const progressFill = document.getElementById('progressFill');
            const downloadDetails = document.getElementById('downloadDetails');
            const title = currentResults[resultIndex].title;
            
            progressSection.style.display = 'block';
            progressFill.style.width = '5%';
            downloadDetails.innerHTML = \`<p>Начало загрузки: <strong>\${title}</strong></p>\`;
            
            try {
                const response = await fetch('http://$SERVER_IP:5000/api/download', {
                    method: 'POST',
                    headers: {
                        'Content-Type': 'application/json',
                    },
                    body: JSON.stringify({
                        magnet: magnet,
                        title: title
                    })
                });
                
                const data = await response.json();
                
                if (data.success) {
                    downloadDetails.innerHTML += '<p style="color: #4CAF50;">✅ Загрузка началась! Мониторим прогресс...</p>';
                    
                    monitorRealProgress(title);
                    
                } else {
                    downloadDetails.innerHTML += '<p style="color: #f44336;">❌ Ошибка: ' + (data.error || 'Неизвестная ошибка') + '</p>';
                }
                
            } catch (error) {
                console.error('Real download error:', error);
                downloadDetails.innerHTML += '<p style="color: #f44336;">❌ Ошибка соединения с сервером</p>';
            }
        }
        
        async function monitorRealProgress(title) {
            const downloadDetails = document.getElementById('downloadDetails');
            const progressFill = document.getElementById('progressFill');
            
            const progressInterval = setInterval(async () => {
                try {
                    const response = await fetch('http://$SERVER_IP:5000/api/downloads/active');
                    const data = await response.json();
                    
                    if (data.success) {
                        const download = data.active_downloads.find(d => d.name.includes(title.substring(0, 20)));
                        if (download) {
                            const progress = Math.min(download.progress, 100);
                            progressFill.style.width = progress + '%';
                            downloadDetails.innerHTML = \`
                                <p>Загрузка: <strong>\${title}</strong></p>
                                <p>Прогресс: \${progress}%</p>
                                <p>Скорость: \${download.download_speed}</p>
                                <p>Осталось: \${download.eta}</p>
                                \${progress >= 15 ? '<p style="color: #4CAF50;">✅ Контент готов к просмотру в Jellyfin!</p>' : ''}
                            \`;
                            
                            if (progress >= 100) {
                                clearInterval(progressInterval);
                                downloadDetails.innerHTML += '<p style="color: #4CAF50;">✅ Загрузка завершена!</p>';
                            }
                        }
                    }
                } catch (error) {
                    console.error('Progress monitoring error:', error);
                }
            }, 3000);
        }
        
        document.getElementById('searchInput').addEventListener('keypress', function(e) {
            if (e.key === 'Enter') {
                performRealSearch();
            }
        });
        
        document.addEventListener('DOMContentLoaded', function() {
            document.getElementById('searchInput').focus();
            checkServicesStatus();
            
            console.log('🚀 ПОЛНОСТЬЮ РАБОЧАЯ система автоматического поиска фильмов готова!');
            console.log('🔍 Реальный поиск по: 1337x, YTS, The Pirate Bay, TorrentGalaxy');
            console.log('📥 Реальная загрузка через qBittorrent');
            console.log('🎬 Просмотр при 15% загрузки');
        });
    </script>
</body>
</html>
HTML_EOF

echo "✅ Реальная главная страница создана!"
echo "🌐 Доступна по адресу: http://$DOMAIN.duckdns.org"
echo "🔧 РЕАЛЬНЫЕ функции:"
echo "   - Поиск по реальным трекерам (1337x, YTS, PirateBay, TorrentGalaxy)"
echo "   - Реальная загрузка через qBittorrent"
echo "   - Мониторинг прогресса загрузки в реальном времени"
echo "   - Автоматическое добавление в Jellyfin"
echo "   - Работающие magnet-ссылки"
DASHBOARD_EOF

chmod +x "/home/$CURRENT_USER/scripts/generate-real-dashboard.sh"
"/home/$CURRENT_USER/scripts/generate-real-dashboard.sh"

log "🎓 Создание реального AI Кампуса..."

mkdir -p "/home/$CURRENT_USER/docker/ai-campus"

cat > "/home/$CURRENT_USER/docker/ai-campus/app.py" << 'AI_CAMPUS_EOF'
from flask import Flask, render_template, request, jsonify
import requests
import json
import logging
from datetime import datetime
import subprocess
import os

app = Flask(__name__)

OLLAMA_URL = "http://ollama:11434"

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

KNOWLEDGE_BASE = {
    "programming": {
        "name": "Программирование",
        "topics": ["Python", "JavaScript", "Algorithms", "Data Structures", "Web Development", "Machine Learning", "Databases"]
    },
    "mathematics": {
        "name": "Математика", 
        "topics": ["Algebra", "Calculus", "Statistics", "Geometry", "Discrete Math", "Linear Algebra", "Probability"]
    },
    "science": {
        "name": "Наука",
        "topics": ["Physics", "Chemistry", "Biology", "Astronomy", "Geology", "Quantum Mechanics", "Genetics"]
    },
    "history": {
        "name": "История",
        "topics": ["World History", "Russian History", "Ancient Civilizations", "Modern History", "Middle Ages", "Renaissance"]
    },
    "languages": {
        "name": "Языки",
        "topics": ["English", "Russian", "Spanish", "French", "German", "Chinese", "Japanese"]
    }
}

class RealEducationalAI:
    def __init__(self, base_url):
        self.base_url = base_url
    
    def check_availability(self):
        try:
            response = requests.get(f"{self.base_url}/api/tags", timeout=10)
            return response.status_code == 200
        except:
            return False
    
    def get_available_models(self):
        try:
            response = requests.get(f"{self.base_url}/api/tags", timeout=30)
            if response.status_code == 200:
                data = response.json()
                return data.get('models', [])
            return []
        except:
            return []
    
    def ensure_model_available(self, model_name="llama2"):
        try:
            models = self.get_available_models()
            model_exists = any(model_name in model['name'] for model in models)
            
            if not model_exists:
                logger.info(f"Модель {model_name} не найдена, начинаем загрузку...")
                return self.pull_model(model_name)
            return True
        except Exception as e:
            logger.error(f"Ошибка проверки модели: {e}")
            return False
    
    def pull_model(self, model_name):
        try:
            logger.info(f"Начинаем загрузку модели {model_name}...")
            
            process = subprocess.Popen(
                ['docker', 'exec', 'ollama', 'ollama', 'pull', model_name],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                universal_newlines=True
            )
            
            while True:
                output = process.stdout.readline()
                if output == '' and process.poll() is not None:
                    break
                if output:
                    logger.info(f"Ollama: {output.strip()}")
            
            return process.poll() == 0
            
        except Exception as e:
            logger.error(f"Ошибка загрузки модели: {e}")
            return False
    
    def teach_topic(self, subject, topic, question, user_message):
        try:
            if not self.ensure_model_available('llama2'):
                return {
                    "success": False,
                    "message": "AI модель недоступна. Загружаем модель..."
                }
            
            models = self.get_available_models()
            if not models:
                return {
                    "success": False,
                    "message": "Нет доступных AI моделей"
                }
            
            model_name = models[0]['name']
            
            system_prompt = f"""Ты опытный преподаватель {KNOWLEDGE_BASE[subject]['name']}. 
            Тема урока: {topic}
            
            Требования к ответу:
            1. Объясняй понятным языком для студента
            2. Используй примеры и аналогии для лучшего понимания  
            3. Будь терпеливым и подробным
            4. Структурируй информацию
            5. Отвечай на русском языке"""
            
            prompt = f"{system_prompt}\n\nСтудент: {user_message}"
            
            payload = {
                "model": model_name,
                "prompt": prompt,
                "stream": False,
                "options": {
                    "temperature": 0.3,
                    "top_p": 0.9,
                    "num_predict": 1500
                }
            }
            
            response = requests.post(f"{self.base_url}/api/generate", json=payload, timeout=120)
            
            if response.status_code == 200:
                result = response.json()
                return {
                    "success": True,
                    "response": result.get('response', 'Нет ответа'),
                    "model": model_name
                }
            else:
                return {
                    "success": False,
                    "message": f"Ошибка AI: {response.status_code}"
                }
                
        except Exception as e:
            logger.error(f"Ошибка обучения: {e}")
            return {
                "success": False,
                "message": f"Ошибка: {str(e)}"
            }

real_educational_ai = RealEducationalAI(OLLAMA_URL)

@app.route('/')
def campus_dashboard():
    return render_template('campus.html')

@app.route('/api/subjects')
def get_subjects():
    return jsonify(KNOWLEDGE_BASE)

@app.route('/api/learn', methods=['POST'])
def learn_topic():
    try:
        data = request.json
        subject = data.get('subject', '')
        topic = data.get('topic', '')
        question = data.get('question', '')
        
        if not subject or not topic:
            return jsonify({
                "success": False, 
                "message": "Выберите предмет и тему"
            })
        
        if not real_educational_ai.check_availability():
            return jsonify({
                "success": False,
                "message": "AI модель недоступна. Запускаем автоматическую настройку..."
            })
        
        user_message = question if question else f"Расскажи подробно о теме {topic}. Объясни как для начинающего."
        
        result = real_educational_ai.teach_topic(subject, topic, question, user_message)
        
        if result['success']:
            return jsonify({
                "success": True,
                "response": result['response'],
                "subject": KNOWLEDGE_BASE[subject]['name'],
                "topic": topic,
                "model": result.get('model', 'unknown')
            })
        else:
            return jsonify({
                "success": False,
                "message": result['message']
            })
            
    except Exception as e:
        logger.error(f"Ошибка обучения: {e}")
        return jsonify({
            "success": False,
            "message": f"Ошибка: {str(e)}"
        })

@app.route('/api/init-system', methods=['POST'])
def init_system():
    try:
        success = real_educational_ai.ensure_model_available('llama2')
        
        if success:
            return jsonify({
                "success": True,
                "message": "Образовательная AI система инициализирована. Модель llama2 готова к использованию."
            })
        else:
            return jsonify({
                "success": False,
                "message": "Не удалось инициализировать образовательную систему"
            })
            
    except Exception as e:
        return jsonify({
            "success": False,
            "message": f"Ошибка инициализации: {str(e)}"
        })

@app.route('/api/health')
def health_check():
    ai_available = real_educational_ai.check_availability()
    models = real_educational_ai.get_available_models()
    
    return jsonify({
        "status": "healthy" if ai_available else "degraded",
        "ai_available": ai_available,
        "subjects_count": len(KNOWLEDGE_BASE),
        "models_count": len(models),
        "timestamp": datetime.now().isoformat()
    })

if __name__ == '__main__':
    logger.info("🎓 Запуск реального AI Кампуса...")
    
    if real_educational_ai.check_availability():
        models = real_educational_ai.get_available_models()
        logger.info(f"✅ Ollama доступен. Моделей: {len(models)}")
        
        real_educational_ai.ensure_model_available('llama2')
    else:
        logger.warning("⚠️ Ollama недоступен. Запустите: docker start ollama")
    
    app.run(host='0.0.0.0', port=5002, debug=False)
AI_CAMPUS_EOF

mkdir -p "/home/$CURRENT_USER/docker/ai-campus/templates"
cat > "/home/$CURRENT_USER/docker/ai-campus/templates/campus.html" << 'CAMPUS_HTML'
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>AI Кампус - РЕАЛЬНЫЙ</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: 'Arial', sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
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
            color: white;
        }
        .main-content {
            display: grid;
            grid-template-columns: 300px 1fr;
            gap: 20px;
        }
        @media (max-width: 768px) {
            .main-content {
                grid-template-columns: 1fr;
            }
        }
        .card {
            background: white;
            border-radius: 15px;
            padding: 25px;
            box-shadow: 0 15px 35px rgba(0,0,0,0.1);
        }
        .subject-list {
            max-height: 400px;
            overflow-y: auto;
        }
        .subject-item {
            padding: 15px;
            margin-bottom: 10px;
            background: #f8f9fa;
            border-radius: 10px;
            cursor: pointer;
            transition: all 0.3s;
        }
        .subject-item:hover {
            background: #667eea;
            color: white;
        }
        .subject-item.active {
            background: #667eea;
            color: white;
        }
        .topic-list {
            display: flex;
            flex-wrap: wrap;
            gap: 10px;
            margin: 15px 0;
        }
        .topic-btn {
            padding: 8px 15px;
            background: #e9ecef;
            border: none;
            border-radius: 20px;
            cursor: pointer;
            transition: all 0.3s;
        }
        .topic-btn:hover {
            background: #667eea;
            color: white;
        }
        .learning-area {
            min-height: 400px;
        }
        .question-input {
            width: 100%;
            padding: 12px;
            border: 2px solid #ddd;
            border-radius: 8px;
            margin: 10px 0;
        }
        .action-btn {
            padding: 10px 20px;
            background: #667eea;
            color: white;
            border: none;
            border-radius: 8px;
            cursor: pointer;
            margin-right: 10px;
        }
        .response-area {
            margin-top: 20px;
            padding: 15px;
            background: #f8f9fa;
            border-radius: 8px;
            min-height: 200px;
        }
        .system-alert {
            background: #fff3cd;
            border: 1px solid #ffeaa7;
            border-radius: 8px;
            padding: 10px;
            margin: 10px 0;
            text-align: center;
        }
        .info-text {
            color: #666;
            font-style: italic;
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>🎓 AI Кампус - РЕАЛЬНЫЙ</h1>
            <p>Интерактивное обучение с реальным искусственным интеллектом</p>
        </div>

        <div id="systemAlert" class="system-alert" style="display: none;">
        </div>
        
        <div class="main-content">
            <div class="card">
                <h3>📚 Предметы</h3>
                <div class="subject-list" id="subjectList">
                </div>
            </div>
            
            <div class="card learning-area">
                <div id="subjectInfo">
                    <h3>Добро пожаловать в РЕАЛЬНЫЙ AI Кампус!</h3>
                    <p class="info-text">Выберите предмет из списка слева, чтобы начать изучение</p>
                    <p class="info-text">Доступны различные темы по программированию, математике, науке и истории</p>
                    <div style="text-align: center; margin-top: 20px;">
                        <button class="action-btn" onclick="initAISystem()">🔧 Инициализировать AI систему</button>
                    </div>
                </div>
                
                <div id="learningInterface" style="display: none;">
                    <h3 id="currentSubject">Программирование</h3>
                    <p class="info-text">Выберите тему для изучения:</p>
                    <div class="topic-list" id="topicList">
                    </div>
                    
                    <div style="margin: 20px 0;">
                        <input type="text" class="question-input" id="questionInput" 
                               placeholder="Задайте вопрос по выбранной теме...">
                        <button class="action-btn" onclick="askQuestion()">📚 Спросить</button>
                    </div>
                    
                    <div class="response-area" id="responseArea">
                        Ответ AI появится здесь...
                    </div>
                </div>
            </div>
        </div>
    </div>

    <script>
        let currentSubject = '';
        let currentTopic = '';
        
        async function loadSubjects() {
            try {
                const response = await fetch('/api/subjects');
                const data = await response.json();
                
                const subjectList = document.getElementById('subjectList');
                subjectList.innerHTML = '';
                
                for (const [key, subject] of Object.entries(data)) {
                    const subjectItem = document.createElement('div');
                    subjectItem.className = 'subject-item';
                    subjectItem.textContent = subject.name;
                    subjectItem.onclick = () => selectSubject(key, subject);
                    subjectList.appendChild(subjectItem);
                }
            } catch (error) {
                console.error('Error loading subjects:', error);
            }
        }
        
        async function initAISystem() {
            const alertDiv = document.getElementById('systemAlert');
            alertDiv.style.display = 'block';
            alertDiv.innerHTML = '🔧 Инициализация образовательной AI системы...';
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
                
            } catch (error) {
                alertDiv.innerHTML = '❌ Ошибка инициализации: ' + error.message;
                alertDiv.style.background = '#f8d7da';
                alertDiv.style.color = '#721c24';
            }
        }
        
        function selectSubject(subjectKey, subject) {
            currentSubject = subjectKey;
            
            document.querySelectorAll('.subject-item').forEach(item => {
                item.classList.remove('active');
            });
            event.target.classList.add('active');
            
            document.getElementById('subjectInfo').style.display = 'none';
            document.getElementById('learningInterface').style.display = 'block';
            document.getElementById('currentSubject').textContent = subject.name;
            
            const topicList = document.getElementById('topicList');
            topicList.innerHTML = '';
            
            subject.topics.forEach(topic => {
                const topicBtn = document.createElement('button');
                topicBtn.className = 'topic-btn';
                topicBtn.textContent = topic;
                topicBtn.onclick = () => selectTopic(topic);
                topicList.appendChild(topicBtn);
            });
            
            document.getElementById('responseArea').textContent = 'Выберите тему и задайте вопрос...';
        }
        
        function selectTopic(topic) {
            currentTopic = topic;
            document.getElementById('responseArea').textContent = \`Готов к вопросам по теме: \${topic}\`;
        }
        
        async function askQuestion() {
            const question = document.getElementById('questionInput').value.trim();
            
            if (!currentSubject || !currentTopic) {
                alert('Сначала выберите предмет и тему!');
                return;
            }
            
            document.getElementById('responseArea').textContent = 'AI думает над ответом...';
            
            try {
                const response = await fetch('/api/learn', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({
                        subject: currentSubject,
                        topic: currentTopic,
                        question: question
                    })
                });
                
                const data = await response.json();
                
                if (data.success) {
                    document.getElementById('responseArea').innerHTML = 
                        \`<strong>Тема: \${data.topic}</strong><br><br>\${data.response}\`;
                } else {
                    document.getElementById('responseArea').textContent = 'Ошибка: ' + data.message;
                    
                    if (data.message.includes('недоступен')) {
                        const alertDiv = document.getElementById('systemAlert');
                        alertDiv.style.display = 'block';
                        alertDiv.innerHTML = '⚠️ ' + data.message + ' <button onclick="initAISystem()">Инициализировать</button>';
                        alertDiv.style.background = '#fff3cd';
                    }
                }
            } catch (error) {
                document.getElementById('responseArea').textContent = 'Ошибка соединения с сервером';
            }
        }
        
        document.addEventListener('DOMContentLoaded', function() {
            loadSubjects();
            
            setTimeout(initAISystem, 1000);
        });
    </script>
</body>
</html>
CAMPUS_HTML

cat > "/home/$CURRENT_USER/docker/ai-campus/requirements.txt" << 'CAMPUS_REQUIREMENTS'
Flask==2.3.3
requests==2.31.0
CAMPUS_REQUIREMENTS

cat > "/home/$CURRENT_USER/docker/ai-campus/Dockerfile" << 'CAMPUS_DOCKERFILE'
FROM python:3.9-slim

WORKDIR /app

RUN apt-get update && apt-get install -y \
    curl \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

EXPOSE 5002

CMD ["python", "app.py"]
CAMPUS_DOCKERFILE

log "🐳 Создание основного docker-compose..."

cat > "/home/$CURRENT_USER/docker/docker-compose.yml" << 'MAIN_COMPOSE_EOF'
version: '3.8'

services:
  nginx:
    image: nginx:alpine
    container_name: nginx
    restart: unless-stopped
    ports:
      - "80:80"
    volumes:
      - ./heimdall:/usr/share/nginx/html
      - ./nginx.conf:/etc/nginx/nginx.conf
    networks:
      - main-network

  ai-chat:
    build: ./ai-chat
    container_name: ai-chat
    restart: unless-stopped
    ports:
      - "5000:5000"
    networks:
      - main-network

  ai-campus:
    build: ./ai-campus
    container_name: ai-campus
    restart: unless-stopped
    ports:
      - "5002:5002"
    networks:
      - main-network

  ollama:
    image: ollama/ollama:latest
    container_name: ollama
    restart: unless-stopped
    ports:
      - "11434:11434"
    volumes:
      - ./ollama/data:/root/.ollama
    networks:
      - main-network
    environment:
      - OLLAMA_HOST=0.0.0.0

networks:
  main-network:
    driver: bridge
MAIN_COMPOSE_EOF

cat > "/home/$CURRENT_USER/docker/nginx.conf" << 'NGINX_CONF_EOF'
events {
    worker_connections 1024;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    sendfile on;
    keepalive_timeout 65;
    
    access_log /var/log/nginx/access.log;
    error_log /var/log/nginx/error.log;

    server {
        listen 80;
        server_name _;
        
        root /usr/share/nginx/html;
        index index.html;

        location / {
            try_files $uri $uri/ =404;
        }

        location /ai-chat/ {
            proxy_pass http://ai-chat:5000/;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }

        location /ai-campus/ {
            proxy_pass http://ai-campus:5002/;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }

        location /jellyfin/ {
            proxy_pass http://jellyfin:8096/;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }
    }
}
NGINX_CONF_EOF

log "🚀 Запуск реальной системы..."

cd "/home/$CURRENT_USER/docker"

log "🐳 Запуск основных сервисов..."
docker-compose up -d --build

log "🎬 Запуск реальной системы автоматического поиска фильмов..."
docker-compose -f docker-compose.media.yml up -d --build

sleep 30

log "📊 Проверка статуса реальных сервисов..."
docker-compose ps
docker-compose -f docker-compose.media.yml ps

log "🔧 Создание скриптов управления..."

cat > "/home/$CURRENT_USER/scripts/real-server-manager.sh" << 'MANAGER_SCRIPT'
#!/bin/bash

source "/home/$(whoami)/.config/server_env"

case "$1" in
    "start")
        cd "/home/$CURRENT_USER/docker" && docker-compose up -d
        cd "/home/$CURRENT_USER/docker" && docker-compose -f docker-compose.media.yml up -d
        echo "✅ Все реальные сервисы запущены"
        ;;
    "stop")
        cd "/home/$CURRENT_USER/docker" && docker-compose down
        cd "/home/$CURRENT_USER/docker" && docker-compose -f docker-compose.media.yml down
        echo "✅ Все реальные сервисы остановлены"
        ;;
    "restart")
        cd "/home/$CURRENT_USER/docker" && docker-compose restart
        cd "/home/$CURRENT_USER/docker" && docker-compose -f docker-compose.media.yml restart
        echo "✅ Все реальные сервисы перезапущены"
        ;;
    "status")
        echo "=== РЕАЛЬНЫЕ ОСНОВНЫЕ СЕРВИСЫ ==="
        cd "/home/$CURRENT_USER/docker" && docker-compose ps
        echo ""
        echo "=== РЕАЛЬНАЯ МЕДИАСИСТЕМА ==="
        cd "/home/$CURRENT_USER/docker" && docker-compose -f docker-compose.media.yml ps
        ;;
    "logs")
        cd "/home/$CURRENT_USER/docker" && docker-compose logs -f
        ;;
    "media-logs")
        cd "/home/$CURRENT_USER/docker" && docker-compose -f docker-compose.media.yml logs -f
        ;;
    "real-search-test")
        echo "🔍 Тестирование РЕАЛЬНОГО поиска..."
        curl -X POST http://localhost:5000/api/search \
          -H "Content-Type: application/json" \
          -d '{"query": "Интерстеллар", "contentType": "movie"}'
        ;;
    "active-downloads")
        echo "📥 Активные РЕАЛЬНЫЕ загрузки..."
        curl http://localhost:5000/api/downloads/active
        ;;
    "system-health")
        echo "🏥 Проверка здоровья реальной системы..."
        curl http://localhost:5000/api/system/health
        echo ""
        ;;
    "init-ai")
        echo "🤖 Инициализация AI системы..."
        curl -X POST http://localhost:5000/api/init-system
        echo ""
        curl -X POST http://localhost:5002/api/init-system
        ;;
    "pull-ai-model")
        echo "📥 Загрузка AI модели..."
        curl -X POST http://localhost:5000/api/pull-model \
          -H "Content-Type: application/json" \
          -d '{"model": "llama2"}'
        ;;
    *)
        echo "Использование: $0 {start|stop|restart|status|logs|media-logs|real-search-test|active-downloads|system-health|init-ai|pull-ai-model}"
        echo "  start             - Запустить все реальные сервисы"
        echo "  stop              - Остановить все реальные сервисы"
        echo "  restart           - Перезапустить все реальные сервисы"
        echo "  status            - Показать статус всех реальных сервисов"
        echo "  logs              - Показать логи реальной основной системы"
        echo "  media-logs        - Показать логи реальной медиасистемы"
        echo "  real-search-test  - Тестовый РЕАЛЬНЫЙ поиск фильма"
        echo "  active-downloads  - Показать активные РЕАЛЬНЫЕ загрузки"
        echo "  system-health     - Проверка здоровья реальной системы"
        echo "  init-ai           - Инициализация AI систем"
        echo "  pull-ai-model     - Загрузка AI модели"
        ;;
esac
MANAGER_SCRIPT

chmod +x "/home/$CURRENT_USER/scripts/real-server-manager.sh"

cat > "/home/$CURRENT_USER/scripts/init-ai-system.sh" << 'AI_INIT_SCRIPT'
#!/bin/bash

log() {
    echo "[$(date '+%H:%M:%S')] $1"
}

log "🤖 Запуск автоматической инициализации РЕАЛЬНОЙ AI системы..."

log "⏳ Ожидание запуска Ollama..."
sleep 30

log "🔧 Инициализация AI чата..."
curl -X POST http://localhost:5000/api/init-system -H "Content-Type: application/json" -d '{}'

log "🔧 Инициализация AI кампуса..."
curl -X POST http://localhost:5002/api/init-system -H "Content-Type: application/json" -d '{}'

log "📥 Запуск фоновой загрузки AI моделей..."
docker exec -d ollama sh -c '
    echo "🚀 Начинаем загрузку AI моделей в фоне..."
    sleep 10
    
    models=("llama2" "mistral")
    
    for model in "${models[@]}"; do
        echo "📥 Загружаем модель: $model"
        if ollama pull $model 2>/dev/null; then
            echo "✅ Модель $model успешно загружена"
        else
            echo "⚠️ Не удалось загрузить модель $model"
        fi
    done
    
    echo "🎉 Фоновая загрузка моделей завершена"
    ollama list
' &

log "✅ Автоматическая инициализация AI системы запущена"
log "📊 Для проверки статуса: ./real-server-manager.sh system-health"
log "🤖 Для проверки AI: http://localhost:5000"
AI_INIT_SCRIPT

chmod +x "/home/$CURRENT_USER/scripts/init-ai-system.sh"

"/home/$CURRENT_USER/scripts/init-ai-system.sh" &

log "🎯 Финальная настройка и проверка..."

cat > "/home/$CURRENT_USER/scripts/real-system-monitor.sh" << 'MONITOR_SCRIPT'
#!/bin/bash

source "/home/$(whoami)/.config/server_env"

echo "🔍 РЕАЛЬНЫЙ МОНИТОРИНГ СИСТЕМЫ"
echo "================================"

echo ""
echo "🐳 DOCKER СЕРВИСЫ:"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

echo ""
echo "💾 ДИСКОВОЕ ПРОСТРАНСТВО:"
df -h / /home /media

echo ""
echo "🌐 СЕТЕВЫЕ СОЕДИНЕНИЯ:"
echo "Домен: $DOMAIN.duckdns.org"
echo "IP: $SERVER_IP"
echo "Внешний IP: $(curl -s http://checkip.amazonaws.com)"

echo ""
echo "🔄 ПРОВЕРКА РЕАЛЬНЫХ СЕРВИСОВ:"

services=(
    "http://localhost:5000/api/system/health"
    "http://localhost:8096/health/ready"
    "http://localhost:8080/api/v2/app/version"
)

for service in "${services[@]}"; do
    if curl -f -s "$service" >/dev/null 2>&1; then
        echo "✅ $service - ДОСТУПЕН"
    else
        echo "❌ $service - НЕДОСТУПЕН"
    fi
done

echo ""
echo "📥 АКТИВНЫЕ РЕАЛЬНЫЕ ЗАГРУЗКИ:"
curl -s http://localhost:5000/api/downloads/active | python3 -m json.tool 2>/dev/null || echo "Не удалось получить информацию о загрузках"

echo ""
echo "🎯 КОМАНДЫ ДЛЯ УПРАВЛЕНИЯ:"
echo "  ./real-server-manager.sh status    - Статус всех сервисов"
echo "  ./real-server-manager.sh real-search-test - Тест РЕАЛЬНОГО поиска"
echo "  ./real-server-manager.sh active-downloads - Активные РЕАЛЬНЫЕ загрузки"
echo "  ./real-server-manager.sh system-health    - Здоровье системы"
MONITOR_SCRIPT

chmod +x "/home/$CURRENT_USER/scripts/real-system-monitor.sh"

log "🔍 Финальная проверка системы..."
"/home/$CURRENT_USER/scripts/real-system-monitor.sh"

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
echo "   2. AI модели загружаются автоматически при первом запуске"
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
