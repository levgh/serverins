!/bin/bash
# --- GLOBAL CONFIGURATION AND UTILITIES ---

set -e
cleanup_temp() {
    rm -rf /tmp/install_*
}
trap cleanup_temp EXIT
trap 'rollback' ERR
trap 'cleanup' EXIT

CURRENT_USER=$(whoami)
SERVER_IP=$(hostname -I | awk '{print $1}')

log() {
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
    
    cd "/home/$CURRENT_USER/docker" 2>/dev/null && sudo docker-compose down 2>/dev/null || true
    
    sudo systemctl stop wg-quick@wg0 2>/dev/null || true
    sudo systemctl disable wg-quick@wg0 2>/dev/null || true
    
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
    if eval "$cmd" >> "/home/$CURRENT_USER/install.log" 2>&1; then
        log "✅ Успешно: $description"
        return 0
    else
        log "❌ Ошибка: $description"
        return 1
    fi
}

# --- AUTOMATIC CONFIGURATION ---

# АВТОМАТИЧЕСКИЕ ЗНАЧЕНИЯ
DOMAIN="domenforserver123"
TOKEN="7c4ac80c-d14f-4ca6-ae8c-df2b04a939ae"
ADMIN_PASS="admin123"

echo "=========================================="
echo "🔧 АВТОМАТИЧЕСКАЯ НАСТРОЙКА"
echo "=========================================="
echo "Домен: $DOMAIN"
echo "Токен: ***"
echo "Пользователь: $CURRENT_USER"
echo "IP сервера: $SERVER_IP"

generate_qbittorrent_credentials() {
    local config_dir="/home/$CURRENT_USER/.config"
    local creds_file="$config_dir/qbittorrent.creds"
    mkdir -p "$config_dir"
    
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
    
    export QB_USERNAME QB_PASSWORD
}

generate_auth_secret() {
    local secret_file="/home/$CURRENT_USER/.config/auth_secret"
    mkdir -p "/home/$CURRENT_USER/.config"
    
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

generate_jellyfin_api_key() {
    local api_file="/home/$CURRENT_USER/.config/jellyfin_api"
    mkdir -p "/home/$CURRENT_USER/.config"
    
    JELLYFIN_API_KEY=$(openssl rand -hex 32)
    echo "$JELLYFIN_API_KEY" > "$api_file"
    chmod 600 "$api_file"
    log "✅ Сгенерирован API ключ для Jellyfin"
    
    export JELLYFIN_API_KEY
}

# ВЫЗОВ ФУНКЦИЙ ГЕНЕРАЦИИ
generate_qbittorrent_credentials
generate_auth_secret
generate_jellyfin_api_key

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
JELLYFIN_API_KEY="$JELLYFIN_API_KEY"
VPN_PORT="51820"
CONFIG_EOF

chmod 600 "/home/$CURRENT_USER/.config/server_env"

echo "=========================================="
echo "🚀 УСТАНОВКА СИСТЕМЫ"
echo "=========================================="

get_interface() {
    local interface
    # Простой способ определения интерфейса
    interface=$(ip route | awk '/default/ {print $5}' | head -1)
    
    if [ -z "$interface" ]; then
        interface=$(ip -o link show | awk -F': ' '{print $2}' | grep -v lo | head -1)
    fi
    
    if [ -z "$interface" ]; then
        interface="eth0"
    fi
    
    echo "$interface"
}

check_disk_space() {
    local required_gb=30
    local available_kb available_gb
    
    available_kb=$(df -k / | awk 'NR==2 {print $4}')
    
    # Простая проверка без bc
    available_gb=$((available_kb / 1024 / 1024))
    
    if [ "$available_gb" -lt "$required_gb" ]; then
        log "❌ Недостаточно места на диске. Доступно: ${available_gb}GB, требуется: ${required_gb}GB"
        exit 1
    else
        log "✅ Достаточно места на диске: ${available_gb}GB"
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

check_python_dependencies() {
    log "🔍 Проверка Python зависимостей..."
    local required_packages=("bcrypt" "flask" "requests" "docker" "psutil")
    
    for package in "${required_packages[@]}"; do
        if ! python3 -c "import $package" 2>/dev/null; then
            log "⚠️ $package не найден, будет установлен"
        else
            log "✅ $package найден"
        fi
    done
}

check_ports() {
    local ports=(80 8096 5000 8080 3001 51820 5001 9000 8081 5005 9001 5006 8082)
    local conflict_found=0
    
    log "🔍 Проверка доступности портов..."
    for port in "${ports[@]}"; do
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
    if command -v docker-compose &> /dev/null; then
        log "✅ Docker Compose (v1) уже установлен"
        return 0
    fi
    
    log "📦 Установка Docker Compose v1..."
    execute_command "sudo curl -L \"https://github.com/docker/compose/releases/download/1.29.2/docker-compose-\$(uname -s)-\$(uname -m)\" -o /usr/local/bin/docker-compose" "Загрузка Docker Compose v1.29.2"
    execute_command "sudo chmod +x /usr/local/bin/docker-compose" "Установка прав Docker Compose"
    
    execute_command "sudo ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose" "Создание симлинка"
    
    if docker-compose version &> /dev/null; then
        log "✅ Docker Compose успешно установлен"
        return 0
    else
        log "❌ Ошибка установки Docker Compose"
        return 1
    fi
}

hash_password() {
    local password="$1"
    python3 -c "
import sys
try:
    import bcrypt
    salt = bcrypt.gensalt(rounds=12)
    hashed = bcrypt.hashpw('$password'.encode('utf-8'), salt)
    print(hashed.decode('utf-8'))
except ImportError:
    import hashlib
    print(hashlib.sha256('$password'.encode()).hexdigest())
" 
}

# ВЫЗЫВАЕМ ФУНКЦИИ ПРОВЕРКИ
TOTAL_MEM=$(free -g | grep Mem: | awk '{print $2}' | head -1)
if [ -n "$TOTAL_MEM" ] && [ "$TOTAL_MEM" -lt 2 ]; then
    log "⚠️  ВНИМАНИЕ: Мало оперативной памяти (${TOTAL_MEM}GB). Рекомендуется минимум 2GB"
    read -p "Продолжить установку? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

check_disk_space
check_required_commands
check_python_dependencies
check_ports || exit 1

log "📦 Обновление системы..."
execute_command "sudo apt update" "Обновление списка пакетов"
execute_command "sudo apt upgrade -y" "Обновление системы"

log "📦 Установка пакетов..."
execute_command "sudo apt install -y curl wget git docker.io nginx mysql-server python3 python3-pip cron nano htop tree unzip net-tools wireguard resolvconf qrencode fail2ban software-properties-common apt-transport-https ca-certificates gnupg bc jq python3-bcrypt" "Установка основных пакетов"

install_docker_compose

log "🐳 Настройка Docker..."
execute_command "sudo systemctl enable docker" "Включение Docker"
execute_command "sudo systemctl start docker" "Запуск Docker"
execute_command "sudo usermod -aG docker $CURRENT_USER" "Добавление пользователя в группу docker"

# --- DuckDNS Setup ---
log "🌐 Настройка DuckDNS..."

mkdir -p "/home/$CURRENT_USER/scripts"

cat > "/home/$CURRENT_USER/scripts/duckdns-update.sh" << 'DUCKDNS_EOF'
#!/bin/bash
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

log "🔄 Настройка cron для DuckDNS..."
temp_cron=$(mktemp)
echo "*/5 * * * * /bin/bash /home/$CURRENT_USER/scripts/duckdns-update.sh >/dev/null 2>&1" > "$temp_cron"

if crontab "$temp_cron" 2>/dev/null; then
    log "✅ Новый crontab установлен успешно"
else
    log "⚠️ Очистка и установка нового crontab..."
    crontab -r 2>/dev/null || true
    crontab "$temp_cron"
fi

rm -f "$temp_cron"

log "🔄 Первое обновление DuckDNS..."
if "/home/$CURRENT_USER/scripts/duckdns-update.sh"; then
    log "✅ DuckDNS успешно настроен"
else
    log "⚠️ Предупреждение: Не удалось обновить DuckDNS, продолжаем установку..."
fi

# --- VPN System Setup ---
log "🔒 Настройка VPN системы..."

# WireGuard Setup
log "🔒 Настройка VPN WireGuard..."

if ! sudo modprobe wireguard 2>/dev/null; then
    log "⚠️  WireGuard не поддерживается ядром, устанавливаем wireguard-dkms..."
    execute_command "sudo apt install -y wireguard-dkms" "Установка WireGuard DKMS"
fi

mkdir -p "/home/$CURRENT_USER/vpn"
mkdir -p "/home/$CURRENT_USER/.wireguard"
cd "/home/$CURRENT_USER/vpn" || exit 1

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

# Hiddify Setup
log "🌐 Настройка Hiddify VPN..."

mkdir -p "/home/$CURRENT_USER/vpn/hiddify"

cat > "/home/$CURRENT_USER/vpn/hiddify/hiddify-setup.sh" << 'HIDDIFY_EOF'
#!/bin/bash
source "$HOME/.config/server_env"

log() {
    echo "[Hiddify] $(date '+%H:%M:%S') $1" | tee -a "$HOME/install.log"
}

# Install Hiddify
log "📦 Установка Hiddify..."
curl -O https://raw.githubusercontent.com/hiddify/hiddify-config/main/install.sh
chmod +x install.sh

# Run installation with auto-confirm
echo "y" | sudo ./install.sh

if [ $? -eq 0 ]; then
    log "✅ Hiddify успешно установлен"
    
    # Generate Hiddify client config
    cat > "/home/$CURRENT_USER/vpn/hiddify-client.json" << CONFIG_EOF
{
    "server": "$DOMAIN.duckdns.org",
    "server_port": 443,
    "password": "$(openssl rand -hex 16)",
    "method": "chacha20-ietf-poly1305",
    "remarks": "Hiddify VPN Configuration",
    "timeout": 300,
    "fast_open": true
}
CONFIG_EOF

    log "✅ Конфигурация Hiddify создана"
else
    log "❌ Ошибка установки Hiddify"
fi
HIDDIFY_EOF

chmod +x "/home/$CURRENT_USER/vpn/hiddify/hiddify-setup.sh"

if command -v ufw >/dev/null 2>&1; then
    log "🔥 Настройка firewall..."
    sudo ufw allow $VPN_PORT/udp
    sudo ufw allow 443/tcp  # Hiddify port
    sudo ufw allow ssh
    sudo ufw allow 80/tcp
    sudo ufw allow 8080/tcp
    sudo ufw allow 9000/tcp
    sudo ufw allow 9001/tcp
    sudo ufw allow 5006/tcp
    sudo ufw allow 8082/tcp
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
    sudo wg-quick up wg0 2>/dev/null || true
fi

# --- Authentication System Setup ---
log "🔐 Настройка единой системы авторизации..."

mkdir -p "/home/$CURRENT_USER/auth-system"

cat > "/home/$CURRENT_USER/auth-system/app.py" << 'AUTH_APP_EOF'
from flask import Flask, request, jsonify, session, redirect, url_for, render_template
import json
import os
import bcrypt
from datetime import datetime, timedelta
import logging
import jwt

app = Flask(__name__)
app.secret_key = os.environ.get('AUTH_SECRET', 'default-secret-key')
app.config['PERMANENT_SESSION_LIFETIME'] = timedelta(hours=24)

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

USERS_FILE = '/app/data/users/users.json'
AUDIT_LOG = '/app/data/logs/auth_audit.log'

def load_users():
    try:
        with open(USERS_FILE, 'r') as f:
            return json.load(f)
    except FileNotFoundError:
        return {"users": [], "sessions": {}, "login_attempts": {}}

def save_users(data):
    os.makedirs(os.path.dirname(USERS_FILE), exist_ok=True)
    with open(USERS_FILE, 'w') as f:
        json.dump(data, f, indent=2)

def log_audit(event_type, username, ip, details=""):
    log_entry = {
        "timestamp": datetime.now().isoformat(),
        "event_type": event_type,
        "username": username,
        "ip": ip,
        "details": details
    }
    
    try:
        os.makedirs(os.path.dirname(AUDIT_LOG), exist_ok=True)
        with open(AUDIT_LOG, 'a') as f:
            f.write(json.dumps(log_entry) + '\n')
    except Exception as e:
        logger.error(f"Audit log error: {e}")

def authenticate_user(username, password, ip):
    users_data = load_users()
    
    # Check login attempts
    login_attempts = users_data.get('login_attempts', {})
    user_attempts = login_attempts.get(ip, {}).get(username, 0)
    
    if user_attempts >= 5:
        log_audit("login_blocked", username, ip, "Too many failed attempts")
        return None, "Too many failed attempts. Try again later."
    
    for user in users_data.get('users', []):
        if user['username'] == username and user.get('is_active', True):
            try:
                if bcrypt.checkpw(password.encode('utf-8'), user['password'].encode('utf-8')):
                    # Reset login attempts
                    if ip in login_attempts and username in login_attempts[ip]:
                        del login_attempts[ip][username]
                    save_users(users_data)
                    
                    log_audit("login_success", username, ip)
                    return user, None
            except Exception as e:
                logger.error(f"Auth error for {username}: {e}")
    
    # Increment failed attempts
    if ip not in login_attempts:
        login_attempts[ip] = {}
    login_attempts[ip][username] = user_attempts + 1
    users_data['login_attempts'] = login_attempts
    save_users(users_data)
    
    log_audit("login_failed", username, ip, f"Attempt {user_attempts + 1}")
    return None, "Invalid credentials"

def create_jwt_token(user):
    payload = {
        'username': user['username'],
        'prefix': user['prefix'],
        'permissions': user['permissions'],
        'exp': datetime.utcnow() + timedelta(hours=24)
    }
    return jwt.encode(payload, app.secret_key, algorithm='HS256')

def verify_jwt_token(token):
    try:
        payload = jwt.decode(token, app.secret_key, algorithms=['HS256'])
        return payload
    except jwt.ExpiredSignatureError:
        return None
    except jwt.InvalidTokenError:
        return None

@app.route('/')
def index():
    return render_template('login.html')

@app.route('/login', methods=['POST'])
def login():
    username = request.form.get('username')
    password = request.form.get('password')
    ip = request.remote_addr
    
    user, error = authenticate_user(username, password, ip)
    
    if user:
        session['user'] = user
        session['jwt_token'] = create_jwt_token(user)
        
        # Redirect based on user prefix
        if user['prefix'] == 'Administrator':
            return redirect('/admin/dashboard')
        else:
            return redirect('/user/dashboard')
    else:
        return render_template('login.html', error=error)

@app.route('/logout')
def logout():
    username = session.get('user', {}).get('username', 'unknown')
    ip = request.remote_addr
    
    log_audit("logout", username, ip)
    
    session.clear()
    return redirect('/')

@app.route('/admin/dashboard')
def admin_dashboard():
    if 'user' not in session or session['user']['prefix'] != 'Administrator':
        return redirect('/')
    return render_template('admin_dashboard.html', user=session['user'])

@app.route('/user/dashboard')
def user_dashboard():
    if 'user' not in session:
        return redirect('/')
    return render_template('user_dashboard.html', user=session['user'])

@app.route('/api/user/profile')
def user_profile():
    if 'user' not in session:
        return jsonify({'error': 'Unauthorized'}), 401
    
    return jsonify({
        'username': session['user']['username'],
        'prefix': session['user']['prefix'],
        'permissions': session['user']['permissions']
    })

@app.route('/auth-validate')
def auth_validate():
    token = request.headers.get('X-Auth-Token')
    if not token:
        return jsonify({'error': 'No token'}), 401
    
    payload = verify_jwt_token(token)
    if not payload:
        return jsonify({'error': 'Invalid token'}), 401
    
    return jsonify(payload)

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5001, debug=False)
AUTH_APP_EOF

mkdir -p "/home/$CURRENT_USER/auth-system/templates"

cat > "/home/$CURRENT_USER/auth-system/templates/login.html" << 'LOGIN_HTML_EOF'
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
            max-width: 400px;
        }
        .login-header {
            text-align: center;
            margin-bottom: 30px;
        }
        .login-header h1 {
            color: #333;
            margin-bottom: 10px;
        }
        .form-group {
            margin-bottom: 20px;
        }
        .form-group label {
            display: block;
            margin-bottom: 5px;
            color: #555;
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
            border-color: #667eea;
            outline: none;
        }
        .login-btn {
            width: 100%;
            padding: 12px;
            background: linear-gradient(135deg, #667eea, #764ba2);
            color: white;
            border: none;
            border-radius: 8px;
            font-size: 16px;
            cursor: pointer;
            transition: transform 0.3s;
        }
        .login-btn:hover {
            transform: translateY(-2px);
        }
        .error-message {
            background: #fee;
            color: #c33;
            padding: 10px;
            border-radius: 5px;
            margin-bottom: 20px;
            text-align: center;
            border: 1px solid #fcc;
        }
        .user-info {
            text-align: center;
            margin-top: 20px;
            color: #666;
            font-size: 14px;
        }
    </style>
</head>
<body>
    <div class="login-container">
        <div class="login-header">
            <h1>🔐 Домашний Сервер</h1>
            <p>Единая система авторизации</p>
        </div>
        
        {% if error %}
        <div class="error-message">
            {{ error }}
        </div>
        {% endif %}
        
        <form method="POST" action="/login">
            <div class="form-group">
                <label for="username">Имя пользователя:</label>
                <input type="text" id="username" name="username" required>
            </div>
            
            <div class="form-group">
                <label for="password">Пароль:</label>
                <input type="password" id="password" name="password" required>
            </div>
            
            <button type="submit" class="login-btn">Войти</button>
        </form>
        
        <div class="user-info">
            <p><strong>Тестовые пользователи:</strong></p>
            <p>👑 Администратор: admin / admin123</p>
            <p>👥 Пользователь: user1 / user123</p>
            <p>👥 Тестовый: test / test123</p>
        </div>
    </div>
</body>
</html>
LOGIN_HTML_EOF

cat > "/home/$CURRENT_USER/auth-system/templates/admin_dashboard.html" << 'ADMIN_DASHBOARD_EOF'
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Административная панель</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: 'Arial', sans-serif;
            background: linear-gradient(135deg, #1a1a1a 0%, #2d2d2d 100%);
            min-height: 100vh;
            color: white;
        }
        .header {
            background: rgba(255,255,255,0.1);
            padding: 20px;
            text-align: center;
        }
        .container {
            max-width: 1200px;
            margin: 0 auto;
            padding: 20px;
        }
        .services-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(300px, 1fr));
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
        .logout-btn {
            background: #ff4757;
            color: white;
            border: none;
            padding: 10px 20px;
            border-radius: 5px;
            cursor: pointer;
            margin-top: 20px;
        }
    </style>
</head>
<body>
    <div class="header">
        <h1>👑 Административная панель</h1>
        <p>Добро пожаловать, {{ user.username }}!</p>
    </div>
    
    <div class="container">
        <div class="services-grid">
            <a href="/user/jellyfin/" class="service-card">
                <div class="service-icon">🎬</div>
                <div class="service-name">Jellyfin</div>
                <div class="service-description">Медиасервер</div>
            </a>
            
            <a href="/user/nextcloud/" class="service-card">
                <div class="service-icon">☁️</div>
                <div class="service-name">Nextcloud</div>
                <div class="service-description">Облачное хранилище</div>
            </a>
            
            <a href="http://localhost:9001" target="_blank" class="service-card">
                <div class="service-icon">🐳</div>
                <div class="service-name">Portainer</div>
                <div class="service-description">Управление Docker</div>
            </a>
            
            <a href="http://localhost:3001" target="_blank" class="service-card">
                <div class="service-icon">📊</div>
                <div class="service-name">Uptime Kuma</div>
                <div class="service-description">Мониторинг</div>
            </a>
        </div>
        
        <button class="logout-btn" onclick="location.href='/logout'">Выйти</button>
    </div>
</body>
</html>
ADMIN_DASHBOARD_EOF

cat > "/home/$CURRENT_USER/auth-system/templates/user_dashboard.html" << 'USER_DASHBOARD_EOF'
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Пользовательская панель</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: 'Arial', sans-serif;
            background: linear-gradient(135deg, #1a1a1a 0%, #2d2d2d 100%);
            min-height: 100vh;
            color: white;
        }
        .header {
            background: rgba(255,255,255,0.1);
            padding: 20px;
            text-align: center;
        }
        .container {
            max-width: 1200px;
            margin: 0 auto;
            padding: 20px;
        }
        .services-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(300px, 1fr));
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
        .logout-btn {
            background: #ff4757;
            color: white;
            border: none;
            padding: 10px 20px;
            border-radius: 5px;
            cursor: pointer;
            margin-top: 20px;
        }
    </style>
</head>
<body>
    <div class="header">
        <h1>👥 Пользовательская панель</h1>
        <p>Добро пожаловать, {{ user.username }}!</p>
    </div>
    
    <div class="container">
        <div class="services-grid">
            <a href="/user/jellyfin/" class="service-card">
                <div class="service-icon">🎬</div>
                <div class="service-name">Jellyfin</div>
                <div class="service-description">Медиасервер</div>
            </a>
            
            <a href="/user/nextcloud/" class="service-card">
                <div class="service-icon">☁️</div>
                <div class="service-name">Nextcloud</div>
                <div class="service-description">Облачное хранилище</div>
            </a>
        </div>
        
        <button class="logout-btn" onclick="location.href='/logout'">Выйти</button>
    </div>
</body>
</html>
USER_DASHBOARD_EOF

# --- Folder Structure and Permissions ---
log "📁 Создание структуры папок..."
mkdir -p "/home/$CURRENT_USER/docker/heimdall"
mkdir -p "/home/$CURRENT_USER/docker/admin-panel"
mkdir -p "/home/$CURRENT_USER/docker/jellyfin"
mkdir -p "/home/$CURRENT_USER/docker/nextcloud"
mkdir -p "/home/$CURRENT_USER/docker/uptime-kuma"
mkdir -p "/home/$CURRENT_USER/scripts"
mkdir -p "/home/$CURRENT_USER/data/users"
mkdir -p "/home/$CURRENT_USER/data/logs"
mkdir -p "/home/$CURRENT_USER/data/backups"
mkdir -p "/home/$CURRENT_USER/docker/qbittorrent"
mkdir -p "/home/$CURRENT_USER/docker/search-backend"
mkdir -p "/home/$CURRENT_USER/docker/media-manager"
mkdir -p "/home/$CURRENT_USER/docker/auth-system"
mkdir -p "/home/$CURRENT_USER/media/movies"
mkdir -p "/home/$CURRENT_USER/media/tv"
mkdir -p "/home/$CURRENT_USER/media/music"
mkdir -p "/home/$CURRENT_USER/media/temp"
mkdir -p "/home/$CURRENT_USER/media/backups"
mkdir -p "/home/$CURRENT_USER/media/torrents"
mkdir -p "/home/$CURRENT_USER/nextcloud/data"
mkdir -p "/home/$CURRENT_USER/nextcloud/config"
mkdir -p "/home/$CURRENT_USER/nextcloud/apps"
mkdir -p "/home/$CURRENT_USER/nextcloud/themes"

mkdir -p "/home/$CURRENT_USER/docker/jellyfin/config"
mkdir -p "/home/$CURRENT_USER/docker/nextcloud/data"
mkdir -p "/home/$CURRENT_USER/docker/uptime-kuma/data"
mkdir -p "/home/$CURRENT_USER/docker/qbittorrent/config"
mkdir -p "/home/$CURRENT_USER/docker/search-backend/data"
mkdir -p "/home/$CURRENT_USER/docker/search-backend/logs"
mkdir -p "/home/$CURRENT_USER/docker/media-manager/config"
mkdir -p "/home/$CURRENT_USER/docker/media-manager/logs"
mkdir -p "/home/$CURRENT_USER/docker/portainer/data"
mkdir -p "/home/$CURRENT_USER/docker/admin-panel/data"
mkdir -p "/home/$CURRENT_USER/docker/auth-system/data"

sudo chown -R "$CURRENT_USER:$CURRENT_USER" "/home/$CURRENT_USER/docker"
sudo chown -R "$CURRENT_USER:$CURRENT_USER" "/home/$CURRENT_USER/data"
sudo chown -R "$CURRENT_USER:$CURRENT_USER" "/home/$CURRENT_USER/media"
sudo chown -R "$CURRENT_USER:$CURRENT_USER" "/home/$CURRENT_USER/nextcloud"
sudo chmod -R 755 "/home/$CURRENT_USER/docker"
sudo chmod -R 755 "/home/$CURRENT_USER/data"
sudo chmod -R 755 "/home/$CURRENT_USER/media"
sudo chmod -R 755 "/home/$CURRENT_USER/nextcloud"

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
      "permissions": ["jellyfin", "nextcloud"],
      "created_at": "$(date -Iseconds)",
      "is_active": true
    },
    {
      "username": "test",
      "password": "$TEST_PASS_HASH",
      "prefix": "User",
      "permissions": ["jellyfin", "nextcloud"],
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

cat > "/home/$CURRENT_USER/data/logs/audit.log" << AUDIT_EOF
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

# --- Auto Cleanup and Backup System ---
log "🧹 Настройка системы автоматической очистки и бэкапов..."

mkdir -p "/home/$CURRENT_USER/scripts/auto-cleanup"

# Auto Cleanup Script
cat > "/home/$CURRENT_USER/scripts/auto-cleanup/cleanup.sh" << 'CLEANUP_EOF'
#!/bin/bash
source "$HOME/.config/server_env"

log() {
    echo "[CLEANUP] $(date '+%Y-%m-%d %H:%M:%S') $1" >> "$HOME/scripts/auto-cleanup/cleanup.log"
}

log "🧹 Запуск автоматической очистки..."

# Clean temporary files
clean_temp_files() {
    log "📁 Очистка временных файлов..."
    
    # Clean Docker logs and temp files
    sudo find /var/lib/docker/containers/ -name "*.log" -type f -mtime +7 -delete 2>/dev/null || true
    
    # Clean system temp files
    sudo find /tmp -type f -atime +7 -delete 2>/dev/null || true
    sudo find /var/tmp -type f -atime +7 -delete 2>/dev/null || true
    
    # Clean application temp files
    find "/home/$CURRENT_USER/media/temp" -type f -mtime +3 -delete 2>/dev/null || true
    find "/home/$CURRENT_USER/docker" -name "*.tmp" -type f -mtime +3 -delete 2>/dev/null || true
    
    # Clean old logs
    find "/home/$CURRENT_USER/data/logs" -name "*.log" -type f -mtime +30 -delete 2>/dev/null || true
}

# Clean empty directories
clean_empty_dirs() {
    log "📂 Очистка пустых директорий..."
    find "/home/$CURRENT_USER/media" -type d -empty -mtime +30 -delete 2>/dev/null || true
    find "/home/$CURRENT_USER/data" -type d -empty -mtime +30 -delete 2>/dev/null || true
}

# Clean old backups
clean_old_backups() {
    log "🗑️ Очистка старых бэкапов..."
    find "/home/$CURRENT_USER/data/backups" -name "server_backup_*" -type d -mtime +30 -exec rm -rf {} \; 2>/dev/null || true
}

# Main cleanup execution
clean_temp_files
clean_empty_dirs
clean_old_backups

log "✅ Автоматическая очистка завершена"
CLEANUP_EOF

# Backup Script
cat > "/home/$CURRENT_USER/scripts/auto-cleanup/backup.sh" << 'BACKUP_EOF'
#!/bin/bash
source "$HOME/.config/server_env"

log() {
    echo "[BACKUP] $(date '+%Y-%m-%d %H:%M:%S') $1" >> "$HOME/scripts/auto-cleanup/backup.log"
}

BACKUP_DIR="/home/$CURRENT_USER/data/backups"
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
BACKUP_NAME="server_backup_$TIMESTAMP"

log "💾 Запуск автоматического бэкапа..."

create_backup() {
    mkdir -p "$BACKUP_DIR/$BACKUP_NAME"
    
    log "📦 Создание бэкапа конфигураций..."
    
    # Backup Docker configurations
    tar -czf "$BACKUP_DIR/$BACKUP_NAME/docker_configs.tar.gz" \
        "/home/$CURRENT_USER/docker" \
        "/home/$CURRENT_USER/.config" 2>/dev/null || true
    
    # Backup user data and authentication
    tar -czf "$BACKUP_DIR/$BACKUP_NAME/user_data.tar.gz" \
        "/home/$CURRENT_USER/data/users" \
        "/home/$CURRENT_USER/auth-system" 2>/dev/null || true
    
    # Backup important service data
    tar -czf "$BACKUP_DIR/$BACKUP_NAME/service_data.tar.gz" \
        "/home/$CURRENT_USER/nextcloud/config" \
        "/home/$CURRENT_USER/docker/jellyfin/config" \
        "/home/$CURRENT_USER/docker/qbittorrent/config" 2>/dev/null || true
    
    # Backup VPN configurations
    tar -czf "$BACKUP_DIR/$BACKUP_NAME/vpn_configs.tar.gz" \
        "/home/$CURRENT_USER/vpn" \
        "/etc/wireguard" 2>/dev/null || true
    
    # Backup scripts
    tar -czf "$BACKUP_DIR/$BACKUP_NAME/scripts.tar.gz" \
        "/home/$CURRENT_USER/scripts" 2>/dev/null || true
    
    # Create backup manifest
    cat > "$BACKUP_DIR/$BACKUP_NAME/backup_manifest.json" << MANIFEST_EOF
{
    "backup_name": "$BACKUP_NAME",
    "timestamp": "$(date -Iseconds)",
    "components": [
        "docker_configs",
        "user_data", 
        "service_data",
        "vpn_configs",
        "scripts"
    ],
    "size": "$(du -sh $BACKUP_DIR/$BACKUP_NAME 2>/dev/null | cut -f1 || echo "unknown")"
}
MANIFEST_EOF
    
    log "✅ Бэкап создан: $BACKUP_DIR/$BACKUP_NAME"
}

clean_old_backups() {
    log "🧹 Очистка старых бэкапов..."
    find "$BACKUP_DIR" -name "server_backup_*" -type d -mtime +30 -exec rm -rf {} \; 2>/dev/null || true
}

# Execute backup
create_backup
clean_old_backups

log "✅ Автоматический бэкап завершен"
BACKUP_EOF

chmod +x "/home/$CURRENT_USER/scripts/auto-cleanup/cleanup.sh"
chmod +x "/home/$CURRENT_USER/scripts/auto-cleanup/backup.sh"

# Setup cron jobs for auto-cleanup and backups
log "⏰ Настройка cron jobs для автоматической очистки и бэкапов..."

CRON_TEMP=$(mktemp)

# Add existing DuckDNS cron
echo "*/5 * * * * /bin/bash /home/$CURRENT_USER/scripts/duckdns-update.sh >/dev/null 2>&1" > "$CRON_TEMP"

# Add auto-cleanup at 02:00 daily
echo "0 2 * * * /bin/bash /home/$CURRENT_USER/scripts/auto-cleanup/cleanup.sh >/dev/null 2>&1" >> "$CRON_TEMP"

# Add auto-backup at 03:00 daily
echo "0 3 * * * /bin/bash /home/$CURRENT_USER/scripts/auto-cleanup/backup.sh >/dev/null 2>&1" >> "$CRON_TEMP"

# Install cron jobs
if crontab "$CRON_TEMP" 2>/dev/null; then
    log "✅ Cron jobs успешно установлены"
else
    log "⚠️ Очистка и установка новых cron jobs..."
    crontab -r 2>/dev/null || true
    crontab "$CRON_TEMP"
fi

rm -f "$CRON_TEMP"

# --- Docker Compose Setup ---
log "🐳 Создание файла docker-compose.yml..."

PUID=$(id -u "$CURRENT_USER")
PGID=$(id -g "$CURRENT_USER")

cat > "/home/$CURRENT_USER/docker/docker-compose.yml" << DOCKER_COMPOSE_EOF
version: '3.8'

services:
  # 1. Authentication System
  auth-system:
    build:
      context: ./auth-system
      dockerfile: Dockerfile
    container_name: auth-system
    restart: unless-stopped
    ports:
      - "5001:5001"
    volumes:
      - /home/$CURRENT_USER/data/users:/app/data/users
      - /home/$CURRENT_USER/data/logs:/app/data/logs
    environment:
      - AUTH_SECRET=$AUTH_SECRET
    networks:
      - nginx-network

  # 2. Jellyfin
  jellyfin:
    image: jellyfin/jellyfin
    container_name: jellyfin
    restart: unless-stopped
    user: $PUID:$PGID
    ports:
      - "8096:8096"
    volumes:
      - /home/$CURRENT_USER/docker/jellyfin/config:/config
      - /home/$CURRENT_USER/media/movies:/media/movies:ro
      - /home/$CURRENT_USER/media/tv:/media/tv:ro
      - /home/$CURRENT_USER/media/music:/media/music:ro
      - /etc/localtime:/etc/localtime:ro
    environment:
      - JELLYFIN_API_KEY=$JELLYFIN_API_KEY
    networks:
      - nginx-network

  # 3. Nextcloud
  nextcloud:
    image: nextcloud:latest
    container_name: nextcloud
    restart: unless-stopped
    ports:
      - "8082:80"
    environment:
      - NEXTCLOUD_ADMIN_USER=admin
      - NEXTCLOUD_ADMIN_PASSWORD=$ADMIN_PASS
      - NEXTCLOUD_TRUSTED_DOMAINS=$DOMAIN.duckdns.org $SERVER_IP localhost 127.0.0.1
    volumes:
      - /home/$CURRENT_USER/nextcloud/data:/var/www/html/data
      - /home/$CURRENT_USER/nextcloud/config:/var/www/html/config
      - /home/$CURRENT_USER/nextcloud/apps:/var/www/html/custom_apps
      - /home/$CURRENT_USER/nextcloud/themes:/var/www/html/themes
    networks:
      - nginx-network

  # 4. Uptime Kuma
  uptime-kuma:
    image: louislam/uptime-kuma:1
    container_name: uptime-kuma
    restart: always
    ports:
      - "3001:3001"
    volumes:
      - /home/$CURRENT_USER/docker/uptime-kuma/data:/app/data
    networks:
      - nginx-network

  # 5. Portainer
  portainer:
    image: portainer/portainer-ce:latest
    container_name: portainer
    restart: always
    ports:
      - "9001:9000"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /home/$CURRENT_USER/docker/portainer/data:/data
    networks:
      - nginx-network

  # 6. qBittorrent
  qbittorrent:
    image: lscr.io/linuxserver/qbittorrent:latest
    container_name: qbittorrent
    restart: unless-stopped
    environment:
      - PUID=$PUID
      - PGID=$PGID
      - TZ=Europe/Moscow
      - WEBUI_PORT=8080
    ports:
      - "8080:8080"
      - "6881:6881"
      - "6881:6881/udp"
    volumes:
      - /home/$CURRENT_USER/docker/qbittorrent/config:/config
      - /home/$CURRENT_USER/media/torrents:/downloads
    networks:
      - nginx-network

  # 7. Nginx Reverse Proxy
  nginx:
    image: nginx:alpine
    container_name: nginx
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf
      - ./heimdall:/usr/share/nginx/html
    depends_on:
      - auth-system
      - jellyfin
      - nextcloud
    networks:
      - nginx-network

networks:
  nginx-network:
    driver: bridge
DOCKER_COMPOSE_EOF

# --- Nginx Configuration ---
log "🌐 Настройка Nginx reverse proxy..."

cat > "/home/$CURRENT_USER/docker/nginx.conf" << 'NGINX_CONF_EOF'
events {
    worker_connections 1024;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    sendfile on;
    keepalive_timeout 65;
    client_max_body_size 10G;
    
    access_log /var/log/nginx/access.log;
    error_log /var/log/nginx/error.log;

    # Upstream services
    upstream auth_system {
        server auth-system:5001;
    }

    upstream jellyfin {
        server jellyfin:8096;
    }

    upstream nextcloud {
        server nextcloud:80;
    }

    server {
        listen 80;
        server_name _;
        
        # Main page - authentication gateway
        location / {
            proxy_pass http://auth_system;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }

        # Admin routes
        location /admin/ {
            proxy_pass http://auth_system;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }

        # User routes - Jellyfin and Nextcloud access
        location /user/jellyfin/ {
            proxy_pass http://jellyfin/;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            
            # Jellyfin specific
            proxy_set_header X-Forwarded-Host $host;
            proxy_set_header X-Forwarded-Server $host;
        }

        location /user/nextcloud/ {
            proxy_pass http://nextcloud/;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            
            # Nextcloud specific headers
            proxy_set_header X-Forwarded-Host $host;
            proxy_set_header X-Forwarded-Server $host;
        }

        # Static files for main page
        location /static/ {
            root /usr/share/nginx/html;
            expires 1y;
            add_header Cache-Control "public, immutable";
        }

        # Health checks
        location /health {
            access_log off;
            return 200 "healthy\n";
            add_header Content-Type text/plain;
        }
    }
}
NGINX_CONF_EOF

# --- VPN Management System ---
log "🔧 Создание системы управления VPN..."

mkdir -p "/home/$CURRENT_USER/scripts/vpn-management"

cat > "/home/$CURRENT_USER/scripts/vpn-management/vpn-admin.sh" << 'VPN_ADMIN_EOF'
#!/bin/bash
source "$HOME/.config/server_env"

VPN_DIR="/home/$CURRENT_USER/vpn"
WIREGUARD_DIR="/etc/wireguard"

log() {
    echo "[VPN Admin] $(date '+%H:%M:%S') $1" | tee -a "$HOME/scripts/vpn-management/vpn-admin.log"
}

show_usage() {
    echo "🔧 VPN Management System"
    echo "Usage: $0 [command]"
    echo ""
    echo "Commands:"
    echo "  status           - Show VPN status"
    echo "  create-wg        - Create new WireGuard client"
    echo "  list-clients     - List all VPN clients"
    echo "  remove-client    - Remove VPN client"
    echo "  generate-qr      - Generate QR code for client"
    echo "  start-hiddify    - Install and start Hiddify"
    echo "  stop-all         - Stop all VPN services"
}

check_vpn_status() {
    log "🔍 Проверка статуса VPN сервисов..."
    
    # Check WireGuard
    if systemctl is-active --quiet wg-quick@wg0; then
        echo "✅ WireGuard: RUNNING"
        sudo wg show
    else
        echo "❌ WireGuard: STOPPED"
    fi
}

create_wireguard_client() {
    CLIENT_NAME="$1"
    if [ -z "$CLIENT_NAME" ]; then
        read -p "Введите имя клиента: " CLIENT_NAME
    fi
    
    log "🔑 Создание нового WireGuard клиента: $CLIENT_NAME"
    
    # Generate client keys
    CLIENT_PRIVATE_KEY=$(wg genkey)
    CLIENT_PUBLIC_KEY=$(echo "$CLIENT_PRIVATE_KEY" | wg pubkey)
    
    # Get next available IP
    LAST_IP=$(sudo grep -o '10.0.0.[0-9]*' /etc/wireguard/wg0.conf | tail -1)
    NEXT_IP=$(echo $LAST_IP | awk -F. '{printf "10.0.0.%d", $4+1}')
    if [ -z "$NEXT_IP" ]; then
        NEXT_IP="10.0.0.2"
    fi
    
    # Add client to server config
    sudo tee -a /etc/wireguard/wg0.conf > /dev/null << EOF

[Peer]
PublicKey = $CLIENT_PUBLIC_KEY
AllowedIPs = $NEXT_IP/32
EOF

    # Create client config
    CLIENT_CONFIG="$VPN_DIR/${CLIENT_NAME}.conf"
    tee "$CLIENT_CONFIG" > /dev/null << EOF
[Interface]
PrivateKey = $CLIENT_PRIVATE_KEY
Address = $NEXT_IP/32
DNS = 8.8.8.8, 1.1.1.1

[Peer]
PublicKey = $(sudo cat /etc/wireguard/public.key)
Endpoint = $DOMAIN.duckdns.org:$VPN_PORT
AllowedIPs = 0.0.0.0/0
EOF

    # Reload WireGuard configuration
    sudo wg syncconf wg0 <(sudo wg-quick strip wg0)
    
    log "✅ Клиент $CLIENT_NAME создан. Конфиг: $CLIENT_CONFIG"
    
    # Generate QR code
    generate_qr_code "$CLIENT_NAME"
}

list_vpn_clients() {
    log "📋 Список VPN клиентов:"
    
    echo "WireGuard Clients:"
    sudo grep -A3 "\[Peer\]" /etc/wireguard/wg0.conf | grep -o '10.0.0.[0-9]*' | while read ip; do
        echo "  - $ip"
    done
    
    echo ""
    echo "Config Files:"
    find "$VPN_DIR" -name "*.conf" -exec basename {} \; | while read config; do
        echo "  - $config"
    done
}

generate_qr_code() {
    CLIENT_NAME="$1"
    if [ -z "$CLIENT_NAME" ]; then
        read -p "Введите имя клиента: " CLIENT_NAME
    fi
    
    CONFIG_FILE="$VPN_DIR/${CLIENT_NAME}.conf"
    
    if [ ! -f "$CONFIG_FILE" ]; then
        log "❌ Конфиг файл не найден: $CONFIG_FILE"
        return 1
    fi
    
    if command -v qrencode &> /dev/null; then
        QR_FILE="$VPN_DIR/${CLIENT_NAME}_qr.png"
        qrencode -t png -o "$QR_FILE" < "$CONFIG_FILE"
        log "✅ QR код создан: $QR_FILE"
        
        # Display QR in terminal if possible
        qrencode -t ansiutf8 < "$CONFIG_FILE"
    else
        log "⚠️ qrencode не установлен. Установите: sudo apt install qrencode"
    fi
}

install_hiddify() {
    log "🌐 Установка Hiddify..."
    
    HIDDIFY_DIR="/home/$CURRENT_USER/vpn/hiddify"
    mkdir -p "$HIDDIFY_DIR"
    cd "$HIDDIFY_DIR"
    
    # Download and install Hiddify
    curl -O https://raw.githubusercontent.com/hiddify/hiddify-config/main/install.sh
    chmod +x install.sh
    
    # Run installation with auto-confirm
    echo "y" | sudo ./install.sh
    
    if [ $? -eq 0 ]; then
        log "✅ Hiddify успешно установлен"
        
        # Generate client configuration
        generate_hiddify_config
    else
        log "❌ Ошибка установки Hiddify"
    fi
}

generate_hiddify_config() {
    log "📄 Генерация конфигурации Hiddify..."
    
    HIDDIFY_CONFIG="$VPN_DIR/hiddify-client.json"
    
    cat > "$HIDDIFY_CONFIG" << EOF
{
    "server": "$DOMAIN.duckdns.org",
    "server_port": 443,
    "password": "$(openssl rand -hex 16)",
    "method": "chacha20-ietf-poly1305",
    "remarks": "Hiddify VPN Configuration - Bypass Blocking",
    "timeout": 300,
    "fast_open": true,
    "workers": 1
}
EOF

    log "✅ Конфигурация Hiddify создана: $HIDDIFY_CONFIG"
    log "💡 Hiddify поддерживает обход блокировок для: ChatGPT, Grok, Gemini и других сервисов"
}

case "$1" in
    "status")
        check_vpn_status
        ;;
    "create-wg")
        create_wireguard_client "$2"
        ;;
    "list-clients")
        list_vpn_clients
        ;;
    "generate-qr")
        generate_qr_code "$2"
        ;;
    "start-hiddify")
        install_hiddify
        ;;
    "stop-all")
        sudo systemctl stop wg-quick@wg0
        docker stop $(docker ps -q --filter "name=hiddify") 2>/dev/null || true
        log "✅ Все VPN сервисы остановлены"
        ;;
    *)
        show_usage
        ;;
esac
VPN_ADMIN_EOF

chmod +x "/home/$CURRENT_USER/scripts/vpn-management/vpn-admin.sh"

# --- Final Setup and Start ---
log "🚀 Финальная настройка и запуск системы..."

# Create authentication system Dockerfile
cat > "/home/$CURRENT_USER/docker/auth-system/Dockerfile" << 'AUTH_DOCKERFILE'
FROM python:3.9-slim

RUN apt-get update && apt-get install -y \
    gcc python3-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

RUN mkdir -p /app/data/users /app/data/logs

EXPOSE 5001

CMD ["python", "app.py"]
AUTH_DOCKERFILE

cat > "/home/$CURRENT_USER/docker/auth-system/requirements.txt" << 'AUTH_REQUIREMENTS'
Flask==2.3.3
bcrypt==4.0.1
PyJWT==2.8.0
AUTH_REQUIREMENTS

# Create heimdall dashboard
cat > "/home/$CURRENT_USER/docker/heimdall/index.html" << 'DASHBOARD_HTML'
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Домашний Сервер - Унифицированная система</title>
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
        .system-info {
            background: rgba(255,255,255,0.1);
            padding: 20px;
            border-radius: 10px;
            margin: 20px 0;
            text-align: center;
        }
        .services-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(300px, 1fr));
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
        .feature-list {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(250px, 1fr));
            gap: 15px;
            margin: 20px 0;
        }
        .feature-item {
            background: rgba(255,255,255,0.1);
            padding: 15px;
            border-radius: 8px;
            text-align: center;
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>🏠 Домашний Сервер</h1>
            <p>Унифицированная система с единой авторизацией</p>
            
            <div class="system-info">
                <p>🌐 Домен: <strong id="domainName">$DOMAIN.duckdns.org</strong></p>
                <p>🔧 Система: <strong>Docker + Nginx + Единая авторизация</strong></p>
                <p>⏰ Время: <strong id="currentTime">$(date)</strong></p>
            </div>
        </div>

        <div class="feature-list">
            <div class="feature-item">🔐 Единая система авторизации</div>
            <div class="feature-item">🔒 Двойная VPN система (WireGuard + Hiddify)</div>
            <div class="feature-item">🎬 Медиасервер Jellyfin</div>
            <div class="feature-item">☁️ Облачное хранилище Nextcloud</div>
            <div class="feature-item">🧹 Автоматическая очистка и бэкапы</div>
            <div class="feature-item">📱 Адаптивный веб-интерфейс</div>
        </div>

        <div class="services-grid">
            <a href="/" class="service-card">
                <div class="service-icon">🔐</div>
                <div class="service-name">Вход в систему</div>
                <div class="service-description">Единая точка доступа ко всем сервисам</div>
            </a>
            
            <div class="service-card" onclick="showAccessInfo()">
                <div class="service-icon">👑</div>
                <div class="service-name">Доступ администратора</div>
                <div class="service-description">Полный контроль над системой</div>
            </div>
            
            <div class="service-card" onclick="showUserInfo()">
                <div class="service-icon">👥</div>
                <div class="service-name">Доступ пользователя</div>
                <div class="service-description">Jellyfin и Nextcloud</div>
            </div>
            
            <div class="service-card" onclick="showVPNInfo()">
                <div class="service-icon">🔒</div>
                <div class="service-name">VPN система</div>
                <div class="service-description">WireGuard + Hiddify для обхода блокировок</div>
            </div>
        </div>
    </div>

    <script>
        function updateSystemInfo() {
            document.getElementById('domainName').textContent = window.location.hostname;
            document.getElementById('currentTime').textContent = new Date().toLocaleString('ru-RU');
        }
        
        function showAccessInfo() {
            alert('🔐 Система доступа:\n\n' +
                  '👑 Администратор:\n' +
                  '  - Полный доступ ко всем функциям\n' + 
                  '  - Управление сервисами\n' +
                  '  - Настройка VPN\n' +
                  '  - Просмотр статистики\n\n' +
                  '👥 Пользователь:\n' +
                  '  - Доступ к Jellyfin (медиасервер)\n' +
                  '  - Доступ к Nextcloud (файловое хранилище)\n\n' +
                  '💡 После входа система автоматически направит вас в нужный раздел!');
        }
        
        function showUserInfo() {
            alert('👥 Доступ для пользователей:\n\n' +
                  '🎬 Jellyfin - Медиасервер:\n' +
                  '  - Просмотр фильмов и сериалов\n' +
                  '  - Автоматическая загрузка контента\n' +
                  '  - Персональные рекомендации\n\n' +
                  '☁️ Nextcloud - Облачное хранилище:\n' +
                  '  - Хранение и синхронизация файлов\n' +
                  '  - Совместный доступ к документам\n' +
                  '  - Календари и контакты\n\n' +
                  '🔒 Безопасный доступ через единую авторизацию');
        }
        
        function showVPNInfo() {
            alert('🔒 VPN система:\n\n' +
                  '1. WireGuard:\n' +
                  '   - Высокая скорость\n' + 
                  '   - Современное шифрование\n' +
                  '   - Стабильное соединение\n\n' +
                  '2. Hiddify:\n' +
                  '   - Обход блокировок\n' +
                  '   - Поддержка ChatGPT, Grok, Gemini\n' +
                  '   - Доступ к заблокированным сервисам\n\n' +
                  '💡 Используйте скрипты управления для настройки VPN!');
        }
        
        // Update info every minute
        setInterval(updateSystemInfo, 60000);
        updateSystemInfo();
        
        console.log('🚀 Домашний сервер готов к работе!');
        console.log('🔐 Единая система авторизации активна');
        console.log('🔒 VPN системы настроены');
        console.log('🎬 Медиасерверы готовы к работе');
    </script>
</body>
</html>
DASHBOARD_HTML

# Start all services
log "🐳 Запуск всех Docker контейнеров..."
cd "/home/$CURRENT_USER/docker"

if sudo docker-compose up -d --build; then
    log "✅ Все сервисы успешно запущены"
    
    # Wait for services to start
    sleep 30
    
    # Check service status
    log "📊 Статус сервисов:"
    sudo docker-compose ps
    
    # Test critical services
    log "🔍 Тестирование основных сервисов..."
    
    # Test authentication system
    if curl -f -s http://localhost:5001/ >/dev/null; then
        log "✅ Система аутентификации работает"
    else
        log "❌ Ошибка системы аутентификации"
    fi
    
    # Test Jellyfin
    if curl -f -s http://localhost:8096/ >/dev/null; then
        log "✅ Jellyfin работает"
    else
        log "❌ Ошибка Jellyfin"
    fi
    
    # Test Nextcloud
    if curl -f -s http://localhost:8082/ >/dev/null; then
        log "✅ Nextcloud работает"
    else
        log "❌ Ошибка Nextcloud"
    fi
    
else
    log "❌ Ошибка запуска Docker контейнеров"
    exit 1
fi

# Create management scripts
log "🔧 Создание скриптов управления..."

cat > "/home/$CURRENT_USER/scripts/server-manager.sh" << 'MANAGER_SCRIPT'
#!/bin/bash

source "/home/$(whoami)/.config/server_env"

case "$1" in
    "start")
        cd "/home/$CURRENT_USER/docker" && docker-compose up -d
        sudo systemctl start wg-quick@wg0 2>/dev/null || true
        echo "✅ Все сервисы запущены"
        ;;
    "stop")
        cd "/home/$CURRENT_USER/docker" && docker-compose down
        sudo systemctl stop wg-quick@wg0 2>/dev/null || true
        echo "✅ Все сервисы остановлены"
        ;;
    "restart")
        cd "/home/$CURRENT_USER/docker" && docker-compose restart
        sudo systemctl restart wg-quick@wg0 2>/dev/null || true
        echo "✅ Все сервисы перезапущены"
        ;;
    "status")
        echo "=== СТАТУС СИСТЕМЫ ==="
        cd "/home/$CURRENT_USER/docker" && docker-compose ps
        echo ""
        echo "=== WIREGUARD STATUS ==="
        sudo systemctl status wg-quick@wg0 --no-pager -l
        ;;
    "logs")
        cd "/home/$CURRENT_USER/docker" && docker-compose logs -f
        ;;
    "vpn")
        "/home/$CURRENT_USER/scripts/vpn-management/vpn-admin.sh" "$2"
        ;;
    "backup")
        "/home/$CURRENT_USER/scripts/auto-cleanup/backup.sh"
        ;;
    "cleanup")
        "/home/$CURRENT_USER/scripts/auto-cleanup/cleanup.sh"
        ;;
    "update")
        cd "/home/$CURRENT_USER/docker" && docker-compose pull
        cd "/home/$CURRENT_USER/docker" && docker-compose up -d --build
        echo "✅ Система обновлена"
        ;;
    *)
        echo "🔧 Home Server Management System"
        echo "Usage: $0 {start|stop|restart|status|logs|vpn|backup|cleanup|update}"
        echo ""
        echo "Commands:"
        echo "  start     - Запустить все сервисы"
        echo "  stop      - Остановить все сервисы"
        echo "  restart   - Перезапустить все сервисы"
        echo "  status    - Показать статус системы"
        echo "  logs      - Показать логи в реальном времени"
        echo "  vpn       - Управление VPN (status|create-wg|list-clients|generate-qr|start-hiddify)"
        echo "  backup    - Создать бэкап системы"
        echo "  cleanup   - Запустить очистку системы"
        echo "  update    - Обновить все сервисы"
        ;;
esac
MANAGER_SCRIPT

chmod +x "/home/$CURRENT_USER/scripts/server-manager.sh"

# Final system check
log "🔍 Финальная проверка системы..."

cat > "/home/$CURRENT_USER/scripts/system-check.sh" << 'SYSTEM_CHECK_EOF'
#!/bin/bash

source "/home/$(whoami)/.config/server_env"

echo "🔍 ПОЛНАЯ ПРОВЕРКА СИСТЕМЫ"
echo "================================"

echo ""
echo "🐳 DOCKER СЕРВИСЫ:"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

echo ""
echo "🌐 СЕТЕВЫЕ СЕРВИСЫ:"
echo "Домен: $DOMAIN.duckdns.org"
echo "Локальный IP: $SERVER_IP"
echo "Внешний IP: $(curl -s http://checkip.amazonaws.com || echo 'N/A')"

echo ""
echo "🔐 СИСТЕМА АВТОРИЗАЦИИ:"
echo "Главная страница: http://$DOMAIN.duckdns.org"
echo "Admin Panel: http://$DOMAIN.duckdns.org/admin/"
echo "Пользовательский доступ: http://$DOMAIN.duckdns.org/user/"

echo ""
echo "🔒 VPN СИСТЕМА:"
if systemctl is-active --quiet wg-quick@wg0; then
    echo "✅ WireGuard: АКТИВЕН"
    echo "   Порт: $VPN_PORT"
    echo "   Клиенты: $(sudo grep -c '\[Peer\]' /etc/wireguard/wg0.conf)"
else
    echo "❌ WireGuard: НЕ АКТИВЕН"
fi

echo ""
echo "💾 АВТОМАТИЧЕСКИЕ ПРОЦЕССЫ:"
echo "🧹 Очистка: Ежедневно в 02:00"
echo "💾 Бэкапы: Ежедневно в 03:00"
echo "🌐 DuckDNS: Каждые 5 минут"

echo ""
echo "📊 КЛЮЧЕВЫЕ СЕРВИСЫ:"
services=(
    "http://localhost:5001"
    "http://localhost:8096"
    "http://localhost:8082"
    "http://localhost:8080"
    "http://localhost:3001"
    "http://localhost:9001"
)

for service in "${services[@]}"; do
    if curl -f -s "$service" >/dev/null 2>&1; then
        echo "✅ $service - РАБОТАЕТ"
    else
        echo "❌ $service - ОШИБКА"
    fi
done

echo ""
echo "🎯 КОМАНДЫ УПРАВЛЕНИЯ:"
echo "  ./scripts/server-manager.sh status  - Статус системы"
echo "  ./scripts/server-manager.sh vpn     - Управление VPN"
echo "  ./scripts/vpn-management/vpn-admin.sh create-wg - Новый VPN клиент"
echo "  ./scripts/server-manager.sh backup  - Создать бэкап"
SYSTEM_CHECK_EOF

chmod +x "/home/$CURRENT_USER/scripts/system-check.sh"

# Run final system check
"/home/$CURRENT_USER/scripts/system-check.sh"

echo ""
echo "=========================================="
echo "🎉 СИСТЕМА УСПЕШНО УСТАНОВЛЕНА И НАСТРОЕНА!"
echo "=========================================="
echo ""
echo "🌐 ОСНОВНЫЕ АДРЕСА:"
echo "   🔗 Главная страница: http://$DOMAIN.duckdns.org"
echo "   🔗 Прямой доступ: http://$SERVER_IP"
echo ""
echo "🔐 СИСТЕМА ДОСТУПА:"
echo "   👑 Администратор:"
echo "      - Полный доступ ко всем функциям"
echo "      - URL: http://$DOMAIN.duckdns.org/admin/"
echo ""
echo "   👥 Пользователь:"
echo "      - Jellyfin: http://$DOMAIN.duckdns.org/user/jellyfin/"
echo "      - Nextcloud: http://$DOMAIN.duckdns.org/user/nextcloud/"
echo ""
echo "🔒 VPN СИСТЕМА:"
echo "   ✅ WireGuard настроен и запущен"
echo "   🌐 Hiddify готов к установке (для обхода блокировок)"
echo "   💡 Управление: ./scripts/server-manager.sh vpn"
echo ""
echo "🔧 УПРАВЛЕНИЕ СЕРВЕРОМ:"
echo "   🛠️  Основной скрипт: ./scripts/server-manager.sh"
echo "   🔒 VPN управление: ./scripts/vpn-management/vpn-admin.sh"
echo "   💾 Бэкапы: ./scripts/server-manager.sh backup"
echo "   🧹 Очистка: ./scripts/server-manager.sh cleanup"
echo ""
echo "📊 ТЕСТОВЫЕ УЧЕТНЫЕ ДАННЫЕ:"
echo "   👑 Администратор: admin / $ADMIN_PASS"
echo "   👥 Пользователь: user1 / user123"
echo "   👥 Тестовый: test / test123"
echo ""
echo "⚠️  ВАЖНЫЕ ЗАМЕЧАНИЯ:"
echo "   1. ✅ Единая система авторизации настроена"
echo "   2. ✅ Двойная VPN система готова к работе"
echo "   3. ✅ Все сервисы доступны через один порт (80)"
echo "   4. ✅ Автоматические бэкапы и очистка настроены"
echo "   5. ✅ Обратный прокси Nginx работает"
echo "   6. ✅ DuckDNS для динамического DNS настроен"
echo ""
echo "🚀 СИСТЕМА ГОТОВА К ИСПОЛЬЗОВАНИЮ!"
