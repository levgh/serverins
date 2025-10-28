#!/bin/bash

# Настройки
DOMAIN="domenforserver123"
TOKEN="7c4ac80c-d14f-4ca6-ae8c-df2b04a939ae"
CURRENT_USER=$(whoami)
SERVER_IP=$(hostname -I | awk '{print $1}')

# Установка обработчиков ошибок
set -eEuo pipefail
trap 'rollback' ERR
trap 'cleanup' EXIT

# Проверка пользователя
if [ "$CURRENT_USER" = "root" ]; then
    echo "❌ ОШИБКА: Не запускайте скрипт от root! Используйте обычного пользователя с sudo правами."
    exit 1
fi

# Проверка sudo прав
if ! sudo -n true 2>/dev/null; then
    echo "❌ ОШИБКА: У пользователя $CURRENT_USER нет sudo прав!"
    exit 1
fi

echo "=========================================="
echo "🚀 УСТАНОВКА ПОЛНОЙ СИСТЕМЫ СО ВСЕМИ СЕРВИСАМИ"
echo "=========================================="

# Функция для логирования
log() {
    echo "[$(date '+%H:%M:%S')] $1" | tee -a "/home/$CURRENT_USER/install.log"
}

# Функция для надежного определения сетевого интерфейса
get_interface() {
    local interface
    interface=$(ip route | awk '/default/ {print $5}' | head -1)
    
    if [ -z "$interface" ]; then
        interface=$(ip link show | awk -F: '/state UP/ && !/lo:/ {print $2}' | tr -d ' ' | head -1)
    fi
    
    if [ -z "$interface" ]; then
        for iface in /sys/class/net/*; do
            iface_name=$(basename "$iface")
            if [ "$iface_name" != "lo" ]; then
                interface="$iface_name"
                break
            fi
        done
    fi
    
    echo "$interface"
}

# Функция для проверки выполнения команд
execute_command() {
    local cmd="$1"
    local description="$2"
    
    log "Выполняется: $description"
    
    if eval "$cmd" >> "/home/$CURRENT_USER/install.log" 2>&1; then
        log "✅ Успешно: $description"
        return 0
    else
        log "❌ ОШИБКА: Не удалось выполнить: $description"
        return 1
    fi
}

# Функция проверки дискового пространства
check_disk_space() {
    local required_gb=20
    local available_kb available_gb
    
    available_kb=$(df / | awk 'NR==2 {print $4}')
    available_gb=$(echo "$available_kb / 1024 / 1024" | bc -l 2>/dev/null || echo "$available_kb" | awk '{printf "%.1f", $1/1024/1024}')
    
    if (( $(echo "$available_gb < $required_gb" | bc -l 2>/dev/null || echo "1") )); then
        log "❌ Недостаточно места на диске. Доступно: ${available_gb}GB, требуется: ${required_gb}GB"
        exit 1
    fi
}

# Функция проверки портов
check_ports() {
    local ports=(80 8096 11435 5000 7860 8080 3001 51820 5001 11434 5002 9000 8081)
    local conflict_found=0
    local port process_info
    
    log "🔍 Проверка доступности портов..."
    for port in "${ports[@]}"; do
        if ss -tulpn | grep ":$port " > /dev/null; then
            process_info=$(ss -tulpn | grep ":$port " | awk '{print $6}' | head -1)
            log "❌ Порт $port уже занят процессом: $process_info"
            conflict_found=1
        fi
    done
    
    if [ $conflict_found -eq 1 ]; then
        log "⚠️  Освободите занятые порты перед продолжением установки"
        read -p "Продолжить установку несмотря на занятые порты? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
}

# Функция проверки необходимых команд
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

# Функция отката при ошибках
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

# Функция очистки при выходе
cleanup() {
    log "🧹 Завершение работы скрипта..."
    trap - ERR EXIT
}

# Создаем лог файл
mkdir -p "/home/$CURRENT_USER"
touch "/home/$CURRENT_USER/install.log"
chmod 600 "/home/$CURRENT_USER/install.log"

# Проверка системных требований
log "🔍 Проверка системных требований..."

# Проверка памяти
TOTAL_MEM=$(free -g | grep Mem: | awk '{print $2}')
if [ "$TOTAL_MEM" -lt 2 ]; then
    log "⚠️  ВНИМАНИЕ: Мало оперативной памяти (${TOTAL_MEM}GB). Рекомендуется минимум 2GB"
    read -p "Продолжить установку? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Проверка дискового пространства
check_disk_space

# Проверка архитектуры
ARCH=$(uname -m)
case "$ARCH" in
    "x86_64")    log "✅ Архитектура: x86_64" ;;
    "aarch64")   log "✅ Архитектура: ARM64 (Raspberry Pi)" ;;
    "armv7l")    log "✅ Архитектура: ARMv7" ;;
    *)           log "⚠️  ВНИМАНИЕ: Архитектура $ARCH может иметь ограниченную поддержку" ;;
esac

# Проверка зависимостей
log "🔍 Проверка системных зависимостей..."
check_required_commands

# Проверка портов
check_ports

# Используем переменные
log "Настройка домена: $DOMAIN"
log "Токен DuckDNS: ${TOKEN:0:8}****"
log "Пользователь: $CURRENT_USER"
log "IP сервера: $SERVER_IP"

# 1. ОБНОВЛЕНИЕ СИСТЕМЫ
log "📦 Обновление системы..."
execute_command "sudo apt update" "Обновление списка пакетов"
execute_command "sudo apt upgrade -y" "Обновление системы"

# 2. УСТАНОВКА ЗАВИСИМОСТЕЙ
log "📦 Установка пакетов..."
execute_command "sudo apt install -y curl wget git docker.io nginx mysql-server python3 python3-pip cron nano htop tree unzip net-tools wireguard resolvconf qrencode fail2ban software-properties-common apt-transport-https ca-certificates gnupg bc jq" "Установка основных пакетов"

# Установка docker-compose
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

# 3. НАСТРОЙКА DOCKER
log "🐳 Настройка Docker..."
execute_command "sudo systemctl enable docker" "Включение Docker"
execute_command "sudo systemctl start docker" "Запуск Docker"
execute_command "sudo usermod -aG docker $CURRENT_USER" "Добавление пользователя в группу docker"

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
touch "/home/$CURRENT_USER/scripts/duckdns.log"
chmod 600 "/home/$CURRENT_USER/scripts/duckdns.log"

(crontab -l 2>/dev/null | grep -v "duckdns-update.sh"; echo "*/5 * * * * /home/$CURRENT_USER/scripts/duckdns-update.sh") | crontab -
execute_command "/home/$CURRENT_USER/scripts/duckdns-update.sh" "Первый запуск DuckDNS"

# 5. НАСТРОЙКА VPN (WIREGUARD)
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
    log "❌ Критическая ошибка: не найден сетевой интерфейс"
    exit 1
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
Endpoint = $SERVER_IP:$VPN_PORT
AllowedIPs = 0.0.0.0/0
EOF

chmod 600 "/home/$CURRENT_USER/vpn/client.conf"

log "📱 Генерация QR кода..."
if command -v qrencode &> /dev/null; then
    qrencode -t ansiutf8 < "/home/$CURRENT_USER/vpn/client.conf"
else
    log "⚠️ qrencode не установлен, QR код не сгенерирован"
fi

if command -v ufw >/dev/null 2>&1; then
    log "🔥 Настройка firewall..."
    sudo ufw allow $VPN_PORT/udp
    sudo ufw allow ssh
    echo "y" | sudo ufw enable
fi

log "🚀 Запуск WireGuard..."
sudo systemctl enable wg-quick@wg0
sudo systemctl start wg-quick@wg0

sleep 3
if sudo systemctl is-active --quiet wg-quick@wg0; then
    log "✅ WireGuard успешно запущен"
    log "📊 Информация о VPN:"
    log "   Порт: $VPN_PORT"
    log "   Серверный IP: $SERVER_IP"
    log "   Клиентский IP: 10.0.0.2"
    log "   Конфиг клиента: /home/$CURRENT_USER/vpn/client.conf"
    sudo wg show
else
    log "❌ Ошибка запуска WireGuard"
    sudo systemctl status wg-quick@wg0
    log "⚠️ Пробуем альтернативный запуск..."
    sudo wg-quick up wg0
    sleep 2
    if sudo wg show wg0 >/dev/null 2>&1; then
        log "✅ WireGuard запущен альтернативным методом"
    else
        log "❌ Не удалось запустить WireGuard"
    fi
fi

# 6. СОЗДАНИЕ СТРУКТУРЫ ПАПОК
log "📁 Создание структуры папок..."
sudo mkdir -p "/home/$CURRENT_USER/docker/heimdall"
sudo mkdir -p "/home/$CURRENT_USER/docker/admin-panel"
sudo mkdir -p "/home/$CURRENT_USER/docker/auth-server"
sudo mkdir -p "/home/$CURRENT_USER/docker/jellyfin"
sudo mkdir -p "/home/$CURRENT_USER/docker/nextcloud"
sudo mkdir -p "/home/$CURRENT_USER/docker/ollama-webui"
sudo mkdir -p "/home/$CURRENT_USER/docker/stable-diffusion"
sudo mkdir -p "/home/$CURRENT_USER/docker/ai-campus"
sudo mkdir -p "/home/$CURRENT_USER/docker/uptime-kuma"
sudo mkdir -p "/home/$CURRENT_USER/docker/ollama"
sudo mkdir -p "/home/$CURRENT_USER/scripts"
sudo mkdir -p "/home/$CURRENT_USER/data/users"
sudo mkdir -p "/home/$CURRENT_USER/data/logs"
sudo mkdir -p "/home/$CURRENT_USER/data/backups"
sudo mkdir -p "/home/$CURRENT_USER/media/movies"
sudo mkdir -p "/home/$CURRENT_USER/media/tv"
sudo mkdir -p "/home/$CURRENT_USER/media/music"
sudo mkdir -p "/home/$CURRENT_USER/media/streaming"
sudo mkdir -p "/home/$CURRENT_USER/media/temp"

sudo mkdir -p "/home/$CURRENT_USER/docker/jellyfin/config"
sudo mkdir -p "/home/$CURRENT_USER/docker/nextcloud/data"
sudo mkdir -p "/home/$CURRENT_USER/docker/stable-diffusion/config"
sudo mkdir -p "/home/$CURRENT_USER/docker/uptime-kuma/data"
sudo mkdir -p "/home/$CURRENT_USER/docker/ollama/data"

sudo chown -R "$CURRENT_USER:$CURRENT_USER" "/home/$CURRENT_USER/docker"
sudo chown -R "$CURRENT_USER:$CURRENT_USER" "/home/$CURRENT_USER/data"
sudo chown -R "$CURRENT_USER:$CURRENT_USER" "/home/$CURRENT_USER/media"
sudo chmod 755 "/home/$CURRENT_USER/docker"
sudo chmod 755 "/home/$CURRENT_USER/data"
sudo chmod 755 "/home/$CURRENT_USER/media"

# 7. СИСТЕМА ЕДИНОЙ АВТОРИЗАЦИИ С АКТИВНОСТЬЮ ПОЛЬЗОВАТЕЛЕЙ
log "🔐 Настройка системы авторизации с отслеживанием активности..."

cat > "/home/$CURRENT_USER/data/users/users.json" << 'USERS_EOF'
{
  "users": [
    {
      "username": "admin",
      "password": "LevAdmin",
      "prefix": "Administrator",
      "permissions": ["all"],
      "created_at": "2024-01-01T00:00:00",
      "is_active": true
    },
    {
      "username": "user1", 
      "password": "user123",
      "prefix": "User",
      "permissions": ["basic_access"],
      "created_at": "2024-01-01T00:00:00",
      "is_active": true
    },
    {
      "username": "test",
      "password": "test123",
      "prefix": "User",
      "permissions": ["basic_access"],
      "created_at": "2024-01-01T00:00:00",
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
    "timestamp": "2024-01-01T00:00:00",
    "username": "system",
    "action": "system_start",
    "details": "Система авторизации инициализирована",
    "ip": "127.0.0.1"
  }
]
AUDIT_EOF

chmod 600 "/home/$CURRENT_USER/data/users/users.json"
chmod 644 "/home/$CURRENT_USER/data/logs/audit.log"

# 8. ГЛАВНАЯ СТРАНИЦА С АВТОМАТИЧЕСКИМИ ВИДЖЕТАМИ (БЕЗ STABLE DIFFUSION)
log "🌐 Создание главной страницы с автоматическими виджетами..."

# Создаем скрипт для генерации главной страницы с виджетами
cat > "/home/$CURRENT_USER/scripts/generate-dashboard.sh" << 'DASHBOARD_EOF'
#!/bin/bash

CURRENT_USER=$(whoami)
SERVER_IP=$(hostname -I | awk '{print $1}')

# Определяем доступные сервисы (БЕЗ STABLE DIFFUSION)
SERVICES=(
    "jellyfin:🎬:Jellyfin:Медиасервер с фильмами:/jellyfin"
    "ai-chat:🤖:AI Ассистент:ChatGPT без ограничений:/ai-chat" 
    "ai-campus:🎓:AI Кампус:Для учебы:/ai-campus"
    "nextcloud:☁️:Nextcloud:Файловое хранилище:/nextcloud"
    "admin-panel:🛠️:Админ-панель:Управление системой:/admin-panel"
    "monitoring:📊:Мониторинг:Uptime Kuma:/monitoring"
    "vpn-info:🔒:VPN информация:WireGuard статус:/vpn-info"
    "portainer:🐳:Portainer:Управление Docker:/portainer"
    "filebrowser:📁:Файловый менеджер:Управление файлами:/filebrowser"
)

# Генерируем HTML для сервисов
SERVICES_HTML=""
for service in "${SERVICES[@]}"; do
    IFS=':' read -r id icon name description path <<< "$service"
    SERVICES_HTML+="<div class=\"service-card\" onclick=\"openService('$id')\">
        <div class=\"service-icon\">$icon</div>
        <div>$name</div>
        <div class=\"service-description\">$description</div>
    </div>"
done

# Генерируем JavaScript для сервисов
SERVICES_JS=""
for service in "${SERVICES[@]}"; do
    IFS=':' read -r id icon name description path <<< "$service"
    SERVICES_JS+="    '$id': '$path',\n"
done

cat > "/home/$CURRENT_USER/docker/heimdall/index.html" << HTML_EOF
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Домашний Сервер - Умный хаб</title>
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
        .status-indicator {
            display: inline-block;
            width: 8px;
            height: 8px;
            border-radius: 50%;
            margin-right: 5px;
        }
        .status-online {
            background: #27ae60;
        }
        .status-offline {
            background: #e74c3c;
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>🏠 Умный Домашний Сервер</h1>
            <p>Все ваши сервисы в одном месте | IP: $SERVER_IP</p>
        </div>
        
        <div class="main-content">
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
                    💡 Секретный раздел: 5 быстрых нажатий на "О системе"
                </div>
            </div>

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

        <div class="card" style="margin-top: 30px;">
            <h2 style="text-align: center; margin-bottom: 20px;">🚀 Все сервисы (автоматические виджеты)</h2>
            <div class="services-grid" id="servicesGrid">
                $SERVICES_HTML
            </div>
        </div>

        <div class="version-info">
            <span>Версия 5.0 | Автоматические виджеты | Сервер: $SERVER_IP | </span>
            <span class="version-link" id="versionLink">О системе</span>
        </div>
    </div>

    <script>
        const services = {
$(echo -e "$SERVICES_JS")
        };

        let secretClickCount = 0;
        let lastClickTime = 0;

        function quickSearch(query) {
            document.querySelector('.yandex-search-input').value = query;
            document.getElementById('yandexSearchForm').submit();
        }

        function openService(service) {
            if (services[service]) { 
                const token = localStorage.getItem('token');
                if (!token && service !== 'vpn-info' && service !== 'monitoring') {
                    alert('Для доступа к сервису необходимо войти в систему');
                    return;
                }
                window.location.href = services[service];
            } else {
                alert('Сервис временно недоступен');
            }
        }

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
                
                if (!response.ok) {
                    throw new Error('Ошибка сети');
                }
                
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
                    showError(data.message || 'Неверный логин или пароль');
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

        document.querySelector('.yandex-search-input').focus();

        const token = localStorage.getItem('token');
        if (token) {
            const user = JSON.parse(localStorage.getItem('user') || '{}');
            if (user.prefix === 'Administrator') {
                window.location.href = '/admin-panel';
            } else {
                window.location.href = '/user-dashboard';
            }
        }

        document.querySelector('.yandex-search-input').addEventListener('keypress', function(e) {
            if (e.key === 'Enter') {
                document.getElementById('yandexSearchForm').submit();
            }
        });

        // Проверка статуса сервисов
        async function checkServicesStatus() {
            const servicesToCheck = ['jellyfin', 'ai-chat', 'nextcloud', 'monitoring'];
            
            for (const service of servicesToCheck) {
                try {
                    const response = await fetch(services[service], { method: 'HEAD', timeout: 5000 });
                    const indicator = document.querySelector(\`[onclick="openService('\${service}')"] .status-indicator\`);
                    if (indicator) {
                        indicator.className = 'status-indicator status-online';
                    }
                } catch (error) {
                    const indicator = document.querySelector(\`[onclick="openService('\${service}')"] .status-indicator\`);
                    if (indicator) {
                        indicator.className = 'status-indicator status-offline';
                    }
                }
            }
        }

        // checkServicesStatus(); // Можно раскомментировать для проверки статуса
    </script>
</body>
</html>
HTML_EOF

echo "✅ Главная страница с автоматическими виджетами создана (без Stable Diffusion)!"
DASHBOARD_EOF

chmod +x "/home/$CURRENT_USER/scripts/generate-dashboard.sh"
"/home/$CURRENT_USER/scripts/generate-dashboard.sh"

# 9. VPN СТРАНИЦА
log "🔒 Создание VPN страницы..."

cat > "/home/$CURRENT_USER/scripts/generate-vpn-html.sh" << 'VPN_HTML_GEN'
#!/bin/bash

CURRENT_USER=$(whoami)
SERVER_IP=$(hostname -I | awk '{print $1}')
VPN_PORT=$(sudo grep ListenPort /etc/wireguard/wg0.conf 2>/dev/null | awk -F= '{print $2}' | tr -d ' ' || echo "51820")

CLIENT_INFO=""
if sudo systemctl is-active --quiet wg-quick@wg0 2>/dev/null; then
    CLIENT_INFO=$(sudo wg show wg0 2>/dev/null | while read line; do
        if [[ $line == peer:* ]]; then
            PEER_KEY=$(echo $line | awk '{print $2}')
            ALLOWED_IPS=$(sudo wg show wg0 | grep -A10 "peer: $PEER_KEY" | grep "allowed ips" | awk '{print $3}')
            LATEST_HANDSHAKE=$(sudo wg show wg0 | grep -A10 "peer: $PEER_KEY" | grep "latest handshake" | awk '{print $3}')
            
            if [ -n "$LATEST_HANDSHAKE" ] && [ "$LATEST_HANDSHAKE" != "0" ]; then
                STATUS="online"
                STATUS_TEXT="Online"
            else
                STATUS="offline" 
                STATUS_TEXT="Offline"
            fi
            
            CLIENT_NAME=$(echo "$ALLOWED_IPS" | cut -d'.' -f4)
            echo "<div class=\"device-item\">
                <span class=\"device-name\">Клиент $CLIENT_NAME</span>
                <span class=\"device-status $STATUS\">$STATUS_TEXT</span>
                <div class=\"device-ip\">IP: $ALLOWED_IPS</div>
                <div>Статус: $STATUS_TEXT</div>
            </div>"
        fi
    done)
fi

if [ -z "$CLIENT_INFO" ]; then
    CLIENT_INFO='<div class="device-item">
        <span class="device-name">Сервер WireGuard</span>
        <span class="device-status online">Online</span>
        <div class="device-ip">IP: 10.0.0.1</div>
        <div>Устройство: '$(hostname)'</div>
    </div>'
fi

cat > "/home/$CURRENT_USER/docker/heimdall/vpn-info.html" << EOF
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
        .section-title {
            color: #ffdb4d;
            margin-bottom: 15px;
            border-bottom: 2px solid #ffdb4d;
            padding-bottom: 5px;
        }
        .device-list {
            margin-top: 15px;
        }
        .device-item {
            background: #3d3d3d;
            padding: 15px;
            margin: 10px 0;
            border-radius: 8px;
            border-left: 4px solid #4CAF50;
        }
        .device-name {
            font-weight: bold;
            color: #ffdb4d;
        }
        .device-ip {
            color: #4CAF50;
        }
        .device-status {
            float: right;
            padding: 3px 8px;
            border-radius: 12px;
            font-size: 0.8em;
        }
        .online { background: #4CAF50; color: white; }
        .offline { background: #f44336; color: white; }
        .btn {
            padding: 10px 20px;
            border: none;
            border-radius: 5px;
            cursor: pointer;
            margin: 5px;
            font-weight: bold;
        }
        .btn-primary { background: #2196F3; color: white; }
        .btn-warning { background: #ff9800; color: white; }
        .btn-success { background: #4CAF50; color: white; }
        .config-info {
            background: #4CAF50;
            color: white;
            padding: 10px;
            border-radius: 5px;
            margin: 10px 0;
            word-break: break-all;
        }
        .qr-code {
            background: white;
            padding: 20px;
            border-radius: 10px;
            margin: 15px 0;
            text-align: center;
        }
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
            <p>Порт VPN: <strong id="vpnPort">$VPN_PORT</strong></p>
            <p>Тип: WireGuard</p>
            <p>Сервер: <strong>$(hostname)</strong></p>
            <p>IP адрес: <strong>$SERVER_IP</strong></p>
        </div>

        <div class="info-card">
            <h3 class="section-title">📱 Подключенные устройства</h3>
            <div class="device-list" id="deviceList">
                $CLIENT_INFO
            </div>
        </div>

        <div class="info-card">
            <h3 class="section-title">📋 Как подключиться</h3>
            <div class="config-info">
                <strong>Конфиг файл:</strong> /home/$CURRENT_USER/vpn/client.conf
            </div>
            <p>1. Установите WireGuard на ваше устройство</p>
            <p>2. Импортируйте конфиг файл выше</p>
            <p>3. Активируйте подключение в приложении WireGuard</p>
            
            <button class="btn btn-primary" onclick="showConfig()">📄 Показать конфиг</button>
            <button class="btn btn-success" onclick="showQR()">📱 Показать QR код</button>
            <button class="btn btn-warning" onclick="testConnection()">🧪 Тест подключения</button>
            
            <div class="qr-code" id="qrCode" style="display: none;">
                <h4>QR код для подключения:</h4>
                <div id="qrContent"></div>
            </div>
        </div>
    </div>

    <script>
        document.getElementById('vpnPort').textContent = '$VPN_PORT';
        
        function checkServerStatus() {
            fetch('/api/system/check-vpn')
                .then(response => response.json())
                .then(data => {
                    const statusElement = document.getElementById('serverStatus');
                    if (data.active) {
                        statusElement.textContent = 'Активен';
                        statusElement.className = 'status';
                    } else {
                        statusElement.textContent = 'Неактивен';
                        statusElement.className = 'status offline';
                    }
                })
                .catch(() => {
                    document.getElementById('serverStatus').textContent = 'Активен';
                });
        }

        function showConfig() {
            alert('Конфиг файл: /home/$CURRENT_USER/vpn/client.conf');
        }

        function showQR() {
            document.getElementById('qrContent').innerHTML = '<p>QR код генерируется на сервере...</p><p>Используйте команду в терминале:</p><p style="background: #333; color: white; padding: 10px; border-radius: 5px;">qrencode -t ansiutf8 < /home/$CURRENT_USER/vpn/client.conf</p>';
            document.getElementById('qrCode').style.display = 'block';
        }

        function testConnection() {
            alert('Тест подключения:\\nПорт: $VPN_PORT\\nIP: $SERVER_IP');
        }

        checkServerStatus();
        setInterval(checkServerStatus, 30000);
    </script>
</body>
</html>
EOF

echo "✅ VPN страница создана!"
VPN_HTML_GEN

chmod +x "/home/$CURRENT_USER/scripts/generate-vpn-html.sh"
"/home/$CURRENT_USER/scripts/generate-vpn-html.sh"

# 10. БЭКЕНД СЕРВЕР АВТОРИЗАЦИИ С ОТСЛЕЖИВАНИЕМ АКТИВНОСТИ
log "🔧 Настройка бэкенда авторизации с отслеживанием активности..."

cat > "/home/$CURRENT_USER/docker/auth-server/requirements.txt" << 'REQUIREMENTS_EOF'
Flask==2.3.3
PyJWT==2.8.0
REQUIREMENTS_EOF

AUTH_SECRET=$(openssl rand -hex 32 2>/dev/null || echo "fallback-secret-key-$(date +%s)")

cat > "/home/$CURRENT_USER/docker/auth-server/app.py" << 'AUTH_PYTHON'
from flask import Flask, request, jsonify
import json
import jwt
import datetime
from functools import wraps
import subprocess

app = Flask(__name__)
app.config['SECRET_KEY'] = 'AUTH_SECRET_KEY_REPLACE'

USERS_FILE = '/app/data/users/users.json'
LOGS_FILE = '/app/data/logs/audit.log'

def load_users():
    try:
        with open(USERS_FILE, 'r') as f:
            return json.load(f)
    except:
        return {"users": [], "sessions": {}, "login_attempts": {}, "blocked_ips": [], "user_activity": []}

def save_users(data):
    with open(USERS_FILE, 'w') as f:
        json.dump(data, f, indent=2)

def log_action(username, action, details, ip):
    try:
        with open(LOGS_FILE, 'r') as f:
            logs = json.load(f)
    except:
        logs = []
    
    logs.append({
        "timestamp": datetime.datetime.now().isoformat(),
        "username": username,
        "action": action,
        "details": details,
        "ip": ip
    })
    
    with open(LOGS_FILE, 'w') as f:
        json.dump(logs, f, indent=2)

def log_user_activity(username, action, service=None, duration=None):
    users_data = load_users()
    
    activity_entry = {
        "timestamp": datetime.datetime.now().isoformat(),
        "username": username,
        "action": action,
        "service": service,
        "duration": duration,
        "ip": request.remote_addr
    }
    
    users_data['user_activity'].append(activity_entry)
    
    # Сохраняем только последние 1000 записей активности
    if len(users_data['user_activity']) > 1000:
        users_data['user_activity'] = users_data['user_activity'][-1000:]
    
    save_users(users_data)

def token_required(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        token = request.headers.get('Authorization')
        
        if not token:
            return jsonify({"success": False, "message": "Токен отсутствует"}), 401
        
        try:
            data = jwt.decode(token, app.config['SECRET_KEY'], algorithms=["HS256"])
            current_user = data['user']
        except:
            return jsonify({"success": False, "message": "Неверный токен"}), 401
        
        return f(current_user, *args, **kwargs)
    
    return decorated

def admin_required(f):
    @wraps(f)
    def decorated(current_user, *args, **kwargs):
        if current_user.get('prefix') != 'Administrator':
            return jsonify({"success": False, "message": "Требуются права администратора"}), 403
        return f(current_user, *args, **kwargs)
    return decorated

@app.route('/api/auth/login', methods=['POST'])
def login():
    data = request.json
    username = data.get('username')
    password = data.get('password')
    ip = request.remote_addr
    
    users_data = load_users()
    
    if ip in users_data.get('blocked_ips', []):
        return jsonify({"success": False, "message": "IP заблокирован"}), 403
    
    user = next((u for u in users_data['users'] if u['username'] == username and u['is_active']), None)
    
    if user and user['password'] == password:
        if ip in users_data['login_attempts']:
            del users_data['login_attempts'][ip]
        
        token = jwt.encode({
            'user': {
                'username': user['username'],
                'prefix': user['prefix'],
                'permissions': user['permissions']
            },
            'exp': datetime.datetime.utcnow() + datetime.timedelta(hours=24)
        }, app.config['SECRET_KEY'])
        
        log_action(username, "login_success", "Успешный вход в систему", ip)
        log_user_activity(username, "login")
        save_users(users_data)
        
        return jsonify({
            "success": True,
            "token": token,
            "user": {
                "username": user['username'],
                "prefix": user['prefix'],
                "permissions": user['permissions']
            }
        })
    else:
        users_data['login_attempts'][ip] = users_data['login_attempts'].get(ip, 0) + 1
        
        if users_data['login_attempts'][ip] >= 5:
            users_data['blocked_ips'].append(ip)
            log_action("system", "ip_blocked", f"IP {ip} заблокирован после 5 неудачных попыток входа", ip)
        
        log_action(username, "login_failed", "Неудачная попытка входа", ip)
        save_users(users_data)
        
        return jsonify({"success": False, "message": "Неверный логин или пароль"}), 401

@app.route('/api/auth/verify', methods=['GET'])
@token_required
def verify_token(current_user):
    return jsonify({"success": True, "user": current_user})

@app.route('/api/system/check-vpn', methods=['GET'])
def check_vpn_status():
    try:
        result = subprocess.run(['systemctl', 'is-active', 'wg-quick@wg0'], capture_output=True, text=True)
        is_active = result.stdout.strip() == 'active'
        
        return jsonify({
            "active": is_active,
            "service": "wireguard"
        })
    except:
        return jsonify({"active": False, "service": "wireguard"})

@app.route('/api/admin/stats', methods=['GET'])
@token_required
@admin_required
def get_stats(current_user):
    users_data = load_users()
    
    # Статистика активности
    today = datetime.datetime.now().date()
    today_activity = [a for a in users_data.get('user_activity', []) 
                     if datetime.datetime.fromisoformat(a['timestamp']).date() == today]
    
    return jsonify({
        "totalUsers": len(users_data['users']),
        "activeServices": 8,
        "blockedAttempts": len(users_data.get('blocked_ips', [])),
        "activeSessions": len(users_data.get('sessions', {})),
        "todayLogins": len([a for a in today_activity if a['action'] == 'login']),
        "totalActivity": len(users_data.get('user_activity', []))
    })

@app.route('/api/admin/activity', methods=['GET'])
@token_required
@admin_required
def get_user_activity(current_user):
    users_data = load_users()
    
    # Возвращаем последние 100 записей активности
    activity = users_data.get('user_activity', [])[-100:]
    
    # Добавляем информацию о пользователях
    for entry in activity:
        user = next((u for u in users_data['users'] if u['username'] == entry['username']), None)
        if user:
            entry['user_prefix'] = user.get('prefix', 'User')
        else:
            entry['user_prefix'] = 'Unknown'
    
    return jsonify(activity)

@app.route('/api/admin/users', methods=['GET'])
@token_required
@admin_required
def get_users(current_user):
    users_data = load_users()
    
    users_without_passwords = []
    for user in users_data['users']:
        user_copy = user.copy()
        user_copy.pop('password', None)
        
        # Добавляем статистику активности
        user_activity = [a for a in users_data.get('user_activity', []) 
                        if a['username'] == user['username']]
        user_copy['login_count'] = len([a for a in user_activity if a['action'] == 'login'])
        user_copy['last_activity'] = user_activity[-1]['timestamp'] if user_activity else None
        
        users_without_passwords.append(user_copy)
    
    return jsonify(users_without_passwords)

@app.route('/api/admin/users', methods=['POST'])
@token_required
@admin_required
def add_user(current_user):
    data = request.json
    username = data.get('username')
    password = data.get('password')
    prefix = data.get('prefix', 'User')
    
    users_data = load_users()
    
    if any(u['username'] == username for u in users_data['users']):
        return jsonify({"success": False, "message": "Пользователь уже существует"}), 400
    
    if prefix == 'Administrator':
        permissions = ['all']
    else:
        permissions = ['basic_access']
    
    users_data['users'].append({
        "username": username,
        "password": password,
        "prefix": prefix,
        "permissions": permissions,
        "created_at": datetime.datetime.now().isoformat(),
        "is_active": True
    })
    
    save_users(users_data)
    log_action(current_user['username'], "user_created", f"Создан пользователь {username} с префиксом {prefix}", request.remote_addr)
    log_user_activity(current_user['username'], "user_created", f"Создан пользователь {username}")
    
    return jsonify({"success": True, "message": "Пользователь создан"})

@app.route('/api/admin/logs', methods=['GET'])
@token_required
@admin_required
def get_logs(current_user):
    try:
        with open(LOGS_FILE, 'r') as f:
            logs = json.load(f)
        return jsonify(logs[-100:])
    except:
        return jsonify([])

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5001, debug=False)
AUTH_PYTHON

# Заменяем секретный ключ в auth-server
sed -i "s/AUTH_SECRET_KEY_REPLACE/$AUTH_SECRET/" "/home/$CURRENT_USER/docker/auth-server/app.py"

cat > "/home/$CURRENT_USER/docker/auth-server/Dockerfile" << 'DOCKERFILE_EOF'
FROM python:3.9-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install -r requirements.txt

COPY . .

EXPOSE 5001

CMD ["python", "app.py"]
DOCKERFILE_EOF

# 11. НАСТРОЙКА OLLAMA И AI СЕРВИСОВ
log "🤖 Настройка AI сервисов..."

# Создаем правильный docker-compose.yml
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
      - ./heimdall:/usr/share/nginx/html
      - ./nginx.conf:/etc/nginx/nginx.conf
    networks:
      - server-net

  auth-server:
    build: ./auth-server
    container_name: auth-server
    restart: unless-stopped
    volumes:
      - /home/${CURRENT_USER}/data:/app/data
    networks:
      - server-net

  jellyfin:
    image: jellyfin/jellyfin:latest
    container_name: jellyfin
    restart: unless-stopped
    ports:
      - "8096:8096"
    volumes:
      - ./jellyfin/config:/config
      - /home/${CURRENT_USER}/media:/media
    networks:
      - server-net

  ollama:
    image: ollama/ollama:latest
    container_name: ollama
    restart: unless-stopped
    ports:
      - "11434:11434"
    volumes:
      - ./ollama/data:/root/.ollama
    networks:
      - server-net

  ollama-webui:
    image: ghcr.io/open-webui/open-webui:main
    container_name: ollama-webui
    restart: unless-stopped
    ports:
      - "11435:8080"
    environment:
      - OLLAMA_BASE_URL=http://ollama:11434
    depends_on:
      - ollama
    networks:
      - server-net

  ai-campus:
    build: ./ai-campus
    container_name: ai-campus
    restart: unless-stopped
    ports:
      - "5000:5000"
    environment:
      - OLLAMA_URL=http://ollama:11434
    depends_on:
      - ollama
    networks:
      - server-net

  nextcloud:
    image: nextcloud:latest
    container_name: nextcloud
    restart: unless-stopped
    ports:
      - "8080:80"
    volumes:
      - ./nextcloud/data:/var/www/html
    networks:
      - server-net

  uptime-kuma:
    image: louislam/uptime-kuma:1
    container_name: uptime-kuma
    restart: unless-stopped
    ports:
      - "3001:3001"
    volumes:
      - ./uptime-kuma/data:/app/data
    networks:
      - server-net

  admin-panel:
    build: ./admin-panel
    container_name: admin-panel
    restart: unless-stopped
    ports:
      - "5002:5000"
    volumes:
      - /home/${CURRENT_USER}/data:/app/data
      - /var/run/docker.sock:/var/run/docker.sock
    networks:
      - server-net

  portainer:
    image: portainer/portainer-ce:latest
    container_name: portainer
    restart: unless-stopped
    ports:
      - "9000:9000"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./portainer/data:/data
    networks:
      - server-net

  filebrowser:
    image: filebrowser/filebrowser:latest
    container_name: filebrowser
    restart: unless-stopped
    ports:
      - "8081:80"
    volumes:
      - /home/${CURRENT_USER}:/srv
    networks:
      - server-net
DOCKER_EOF

# 12. AI КАМПУС (БЕЗ ПРЕДМЕТНЫХ КНОПОК)
log "🎓 Настройка AI Кампуса без предметных кнопок..."

cat > "/home/$CURRENT_USER/docker/ai-campus/Dockerfile" << 'CAMPUS_DOCKERFILE'
FROM python:3.9-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install -r requirements.txt

COPY . .

EXPOSE 5000

CMD ["python", "app.py"]
CAMPUS_DOCKERFILE

cat > "/home/$CURRENT_USER/docker/ai-campus/requirements.txt" << 'CAMPUS_REQUIREMENTS'
Flask==2.3.3
requests==2.31.0
CAMPUS_REQUIREMENTS

cat > "/home/$CURRENT_USER/docker/ai-campus/app.py" << 'CAMPUS_PYTHON'
from flask import Flask, request, jsonify, render_template_string
import requests
import json
import time

app = Flask(__name__)

OLLAMA_URL = "http://ollama:11434/api/generate"

HTML_TEMPLATE = '''
<!DOCTYPE html>
<html>
<head>
    <title>AI Кампус - умный помощник</title>
    <style>
        body { 
            font-family: 'Arial', sans-serif; 
            margin: 0; 
            padding: 0; 
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
        }
        .container { 
            max-width: 900px; 
            margin: 0 auto; 
            background: white; 
            min-height: 100vh;
            box-shadow: 0 0 20px rgba(0,0,0,0.1);
        }
        .header {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            padding: 30px;
            text-align: center;
        }
        .header h1 {
            margin: 0;
            font-size: 2.5em;
        }
        .header p {
            margin: 10px 0 0 0;
            opacity: 0.9;
        }
        .chat-container {
            padding: 20px;
            height: calc(100vh - 200px);
            display: flex;
            flex-direction: column;
        }
        .chat-box { 
            flex: 1; 
            border: 2px solid #e0e0e0; 
            padding: 20px; 
            overflow-y: auto; 
            margin-bottom: 20px; 
            background: #fafafa;
            border-radius: 15px;
        }
        .message { 
            margin: 15px 0; 
            padding: 15px; 
            border-radius: 15px; 
            max-width: 80%; 
            line-height: 1.5;
            animation: fadeIn 0.3s ease-in;
        }
        .user { 
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); 
            color: white; 
            margin-left: auto; 
            text-align: right;
            box-shadow: 0 4px 15px rgba(102, 126, 234, 0.3);
        }
        .ai { 
            background: white; 
            color: #333; 
            border: 2px solid #e0e0e0;
            box-shadow: 0 4px 15px rgba(0,0,0,0.1);
        }
        .loading { 
            color: #7f8c8d; 
            font-style: italic; 
            text-align: center;
        }
        .input-container { 
            display: flex; 
            gap: 10px; 
            background: white;
            padding: 15px;
            border-radius: 15px;
            border: 2px solid #e0e0e0;
        }
        input { 
            flex: 1; 
            padding: 15px 20px; 
            border: 2px solid #ddd; 
            border-radius: 25px; 
            font-size: 16px;
            outline: none;
            transition: border-color 0.3s;
        }
        input:focus {
            border-color: #667eea;
            box-shadow: 0 0 0 3px rgba(102, 126, 234, 0.1);
        }
        button { 
            padding: 15px 30px; 
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); 
            color: white; 
            border: none; 
            border-radius: 25px; 
            cursor: pointer; 
            font-size: 16px;
            font-weight: bold;
            transition: transform 0.2s;
        }
        button:hover {
            transform: translateY(-2px);
            box-shadow: 0 6px 20px rgba(102, 126, 234, 0.4);
        }
        .error { 
            color: #e74c3c; 
            text-align: center;
            margin: 10px 0;
        }
        .success { 
            color: #27ae60; 
            text-align: center;
            margin: 10px 0;
        }
        .message-header {
            font-weight: bold;
            margin-bottom: 5px;
            font-size: 0.9em;
            opacity: 0.8;
        }
        @keyframes fadeIn {
            from { opacity: 0; transform: translateY(10px); }
            to { opacity: 1; transform: translateY(0); }
        }
        .welcome-message {
            text-align: center;
            color: #666;
            font-style: italic;
            margin: 20px 0;
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>🎓 AI Кампус</h1>
            <p>Умный помощник для любых вопросов</p>
        </div>
        
        <div class="chat-container">
            <div class="chat-box" id="chatBox">
                <div class="welcome-message">
                    🤖 Привет! Я твой AI помощник. Задавай любые вопросы - по учебе, программированию, 
                    или просто поболтаем! Я использую реальную модель Llama 2 для ответов.
                </div>
                <div class="message ai">
                    <div class="message-header">AI Помощник</div>
                    Привет! Я готов помочь тебе с любыми вопросами. Что ты хочешь узнать?
                </div>
            </div>
            
            <div class="input-container">
                <input type="text" id="messageInput" placeholder="Задайте любой вопрос..." onkeypress="handleKeyPress(event)">
                <button onclick="sendMessage()">Отправить</button>
            </div>
            
            <div id="statusMessage"></div>
        </div>
    </div>

    <script>
        function handleKeyPress(event) {
            if (event.key === 'Enter') {
                sendMessage();
            }
        }

        function showStatus(message, type) {
            const statusElement = document.getElementById('statusMessage');
            statusElement.textContent = message;
            statusElement.className = type;
            setTimeout(() => statusElement.textContent = '', 5000);
        }

        async function sendMessage() {
            const input = document.getElementById('messageInput');
            const message = input.value.trim();
            if (!message) return;
            
            const chatBox = document.getElementById('chatBox');
            
            // Добавляем сообщение пользователя
            chatBox.innerHTML += \`
                <div class="message user">
                    <div class="message-header">Вы</div>
                    \${message}
                </div>
            \`;
            
            // Показываем индикатор загрузки
            const loadingId = 'loading-' + Date.now();
            chatBox.innerHTML += \`<div class="message ai loading" id="\${loadingId}">🤖 Думаю над ответом...</div>\`;
            chatBox.scrollTop = chatBox.scrollHeight;
            
            input.value = '';
            
            try {
                const response = await fetch('/api/ask', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ question: message })
                });
                
                const data = await response.json();
                
                // Убираем индикатор загрузки
                document.getElementById(loadingId).remove();
                
                if (data.answer) {
                    chatBox.innerHTML += \`
                        <div class="message ai">
                            <div class="message-header">AI Помощник</div>
                            \${data.answer}
                        </div>
                    \`;
                    showStatus('Ответ получен успешно!', 'success');
                } else {
                    chatBox.innerHTML += \`
                        <div class="message ai">
                            <div class="message-header">AI Помощник</div>
                            ❌ Ошибка: \${data.error || 'Не удалось получить ответ'}
                        </div>
                    \`;
                    showStatus('Ошибка при получении ответа', 'error');
                }
            } catch (error) {
                document.getElementById(loadingId).remove();
                chatBox.innerHTML += \`
                    <div class="message ai">
                        <div class="message-header">AI Помощник</div>
                        ❌ Ошибка соединения с сервером
                    </div>
                \`;
                showStatus('Ошибка сети', 'error');
            }
            
            chatBox.scrollTop = chatBox.scrollHeight;
        }

        // Автофокус на поле ввода
        document.getElementById('messageInput').focus();
    </script>
</body>
</html>
'''

@app.route('/')
def index():
    return render_template_string(HTML_TEMPLATE)

@app.route('/api/ask', methods=['POST'])
def ask_question():
    try:
        data = request.json
        question = data.get('question', '').strip()
        
        if not question:
            return jsonify({"error": "Вопрос не может быть пустым"}), 400
        
        # Проверяем доступность Ollama
        try:
            models_response = requests.get("http://ollama:11434/api/tags", timeout=10)
            if models_response.status_code != 200:
                return jsonify({"error": "Ollama сервер недоступен"}), 503
                
            models_data = models_response.json()
            if not models_data.get('models'):
                return jsonify({"error": "Нет доступных моделей. Загрузите модель: docker exec ollama ollama pull llama2"}), 503
                
        except requests.exceptions.RequestException as e:
            return jsonify({"error": f"Не могу подключиться к Ollama: {str(e)}"}), 503
        
        # Отправляем запрос к Ollama
        payload = {
            "model": "llama2",
            "prompt": f"Ты полезный AI помощник. Ответь на русском языке на вопрос: {question}. Давай развернутый и полезный ответ.",
            "stream": False,
            "options": {
                "temperature": 0.7,
                "top_p": 0.9,
                "num_predict": 500
            }
        }
        
        response = requests.post(OLLAMA_URL, json=payload, timeout=120)
        
        if response.status_code == 200:
            result = response.json()
            answer = result.get('response', '').strip()
            
            if not answer or len(answer) < 10:
                answer = "Извините, я не могу дать качественный ответ на этот вопрос. Попробуйте переформулировать его или задать другой вопрос."
            
            return jsonify({
                "question": question,
                "answer": answer,
                "model": result.get('model', 'llama2')
            })
        else:
            return jsonify({"error": f"Ошибка Ollama: {response.status_code} - {response.text}"}), 500
            
    except requests.exceptions.Timeout:
        return jsonify({"error": "Таймаут запроса к AI модели. Попробуйте еще раз."}), 504
    except Exception as e:
        return jsonify({"error": f"Внутренняя ошибка: {str(e)}"}), 500

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, debug=False)
CAMPUS_PYTHON

# 13. АДМИН-ПАНЕЛЬ С АКТИВНОСТЬЮ ПОЛЬЗОВАТЕЛЕЙ
log "🛠️ Настройка админ-панели с отслеживанием активности..."

cat > "/home/$CURRENT_USER/docker/admin-panel/Dockerfile" << 'ADMIN_DOCKERFILE'
FROM python:3.9-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install -r requirements.txt

COPY . .

EXPOSE 5000

CMD ["python", "app.py"]
ADMIN_DOCKERFILE

cat > "/home/$CURRENT_USER/docker/admin-panel/requirements.txt" << 'ADMIN_REQUIREMENTS'
Flask==2.3.3
docker==6.1.3
psutil==5.9.5
requests==2.31.0
ADMIN_REQUIREMENTS

cat > "/home/$CURRENT_USER/docker/admin-panel/app.py" << 'ADMIN_PYTHON'
from flask import Flask, request, jsonify, render_template_string
import docker
import psutil
import requests
import os
import json
from datetime import datetime

app = Flask(__name__)

client = docker.from_env()

HTML_TEMPLATE = '''
<!DOCTYPE html>
<html>
<head>
    <title>Админ-панель сервера</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: Arial; background: #1a1a1a; color: white; }
        .container { max-width: 1400px; margin: 0 auto; padding: 20px; }
        .header { text-align: center; margin-bottom: 30px; }
        .stats-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(250px, 1fr)); gap: 20px; margin-bottom: 30px; }
        .stat-card { background: #2d2d2d; padding: 20px; border-radius: 10px; border-left: 4px solid #3498db; }
        .stat-value { font-size: 2em; font-weight: bold; color: #3498db; }
        .stat-label { font-size: 0.9em; color: #bbb; }
        .tabs { display: flex; gap: 10px; margin-bottom: 20px; }
        .tab { padding: 10px 20px; background: #2d2d2d; border: none; color: white; border-radius: 5px; cursor: pointer; }
        .tab.active { background: #3498db; }
        .tab-content { display: none; }
        .tab-content.active { display: block; }
        .services-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); gap: 15px; margin-bottom: 30px; }
        .service-card { background: #2d2d2d; padding: 15px; border-radius: 8px; }
        .service-name { font-weight: bold; margin-bottom: 10px; }
        .service-status { padding: 3px 8px; border-radius: 12px; font-size: 0.8em; }
        .status-running { background: #27ae60; color: white; }
        .status-stopped { background: #e74c3c; color: white; }
        .status-exited { background: #f39c12; color: white; }
        .action-btn { padding: 5px 10px; margin: 2px; border: none; border-radius: 4px; cursor: pointer; }
        .btn-start { background: #27ae60; color: white; }
        .btn-stop { background: #e74c3c; color: white; }
        .btn-restart { background: #3498db; color: white; }
        .activity-table { width: 100%; background: #2d2d2d; border-radius: 8px; overflow: hidden; }
        .activity-table th, .activity-table td { padding: 12px; text-align: left; border-bottom: 1px solid #444; }
        .activity-table th { background: #3498db; color: white; }
        .activity-table tr:hover { background: #3d3d3d; }
        .user-badge { padding: 2px 8px; border-radius: 10px; font-size: 0.8em; }
        .badge-admin { background: #e74c3c; color: white; }
        .badge-user { background: #3498db; color: white; }
        .logs { background: #000; color: #0f0; padding: 15px; border-radius: 5px; font-family: monospace; height: 200px; overflow-y: auto; margin-top: 20px; }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>🛠️ Админ-панель сервера</h1>
            <p>Управление системой и мониторинг активности</p>
        </div>
        
        <div class="stats-grid">
            <div class="stat-card">
                <div class="stat-label">CPU Использование</div>
                <div class="stat-value" id="cpuUsage">0%</div>
            </div>
            <div class="stat-card">
                <div class="stat-label">Память</div>
                <div class="stat-value" id="memoryUsage">0%</div>
            </div>
            <div class="stat-card">
                <div class="stat-label">Диск</div>
                <div class="stat-value" id="diskUsage">0%</div>
            </div>
            <div class="stat-card">
                <div class="stat-label">Контейнеры</div>
                <div class="stat-value" id="containerCount">0</div>
            </div>
            <div class="stat-card">
                <div class="stat-label">Активность сегодня</div>
                <div class="stat-value" id="todayActivity">0</div>
            </div>
        </div>

        <div class="tabs">
            <button class="tab active" onclick="showTab('services')">🚀 Сервисы</button>
            <button class="tab" onclick="showTab('activity')">📊 Активность</button>
            <button class="tab" onclick="showTab('users')">👥 Пользователи</button>
            <button class="tab" onclick="showTab('logs')">📋 Логи</button>
        </div>

        <div id="services-tab" class="tab-content active">
            <h2>🚀 Управление сервисами</h2>
            <div class="services-grid" id="servicesGrid">
                <!-- Сервисы будут здесь -->
            </div>
        </div>

        <div id="activity-tab" class="tab-content">
            <h2>📊 Активность пользователей</h2>
            <div class="activity-table-container">
                <table class="activity-table" id="activityTable">
                    <thead>
                        <tr>
                            <th>Время</th>
                            <th>Пользователь</th>
                            <th>Действие</th>
                            <th>Сервис</th>
                            <th>IP</th>
                        </tr>
                    </thead>
                    <tbody id="activityTableBody">
                        <!-- Активность будет здесь -->
                    </tbody>
                </table>
            </div>
        </div>

        <div id="users-tab" class="tab-content">
            <h2>👥 Управление пользователями</h2>
            <div class="activity-table-container">
                <table class="activity-table" id="usersTable">
                    <thead>
                        <tr>
                            <th>Логин</th>
                            <th>Роль</th>
                            <th>Создан</th>
                            <th>Входов</th>
                            <th>Последняя активность</th>
                        </tr>
                    </thead>
                    <tbody id="usersTableBody">
                        <!-- Пользователи будут здесь -->
                    </tbody>
                </table>
            </div>
        </div>

        <div id="logs-tab" class="tab-content">
            <h2>📋 Системные логи</h2>
            <div class="logs" id="systemLogs">
                Загрузка логов...
            </div>
        </div>
    </div>

    <script>
        let currentTab = 'services';

        function showTab(tabName) {
            // Скрываем все вкладки
            document.querySelectorAll('.tab-content').forEach(tab => {
                tab.classList.remove('active');
            });
            document.querySelectorAll('.tab').forEach(tab => {
                tab.classList.remove('active');
            });
            
            // Показываем выбранную вкладку
            document.getElementById(tabName + '-tab').classList.add('active');
            event.target.classList.add('active');
            currentTab = tabName;
            
            // Загружаем данные для вкладки
            if (tabName === 'activity') {
                loadActivity();
            } else if (tabName === 'users') {
                loadUsers();
            } else if (tabName === 'logs') {
                loadLogs();
            }
        }

        async function loadStats() {
            try {
                const response = await fetch('/api/stats');
                const data = await response.json();
                
                document.getElementById('cpuUsage').textContent = data.cpu_percent + '%';
                document.getElementById('memoryUsage').textContent = data.memory_percent + '%';
                document.getElementById('diskUsage').textContent = data.disk_percent + '%';
                document.getElementById('containerCount').textContent = data.container_count;
                document.getElementById('todayActivity').textContent = data.today_activity || 0;
                
                // Обновляем сервисы
                let servicesHtml = '';
                data.services.forEach(service => {
                    servicesHtml += \`
                        <div class="service-card">
                            <div class="service-name">\${service.name}</div>
                            <div>
                                <span class="service-status status-\${service.status}">\${service.status}</span>
                                \${service.actions.includes('start') ? '<button class="action-btn btn-start" onclick="controlService(\\'' + service.name + '\\', \\'start\\')">Start</button>' : ''}
                                \${service.actions.includes('stop') ? '<button class="action-btn btn-stop" onclick="controlService(\\'' + service.name + '\\', \\'stop\\')">Stop</button>' : ''}
                                \${service.actions.includes('restart') ? '<button class="action-btn btn-restart" onclick="controlService(\\'' + service.name + '\\', \\'restart\\')">Restart</button>' : ''}
                            </div>
                        </div>
                    \`;
                });
                document.getElementById('servicesGrid').innerHTML = servicesHtml;
                
            } catch (error) {
                console.error('Error loading stats:', error);
            }
        }

        async function loadActivity() {
            try {
                const response = await fetch('/api/activity');
                const activity = await response.json();
                
                let activityHtml = '';
                activity.reverse().forEach(item => {
                    const time = new Date(item.timestamp).toLocaleString();
                    activityHtml += \`
                        <tr>
                            <td>\${time}</td>
                            <td>
                                <span class="user-badge badge-\${item.user_prefix?.toLowerCase() || 'user'}">
                                    \${item.username}
                                </span>
                            </td>
                            <td>\${item.action}</td>
                            <td>\${item.service || '-'}</td>
                            <td>\${item.ip}</td>
                        </tr>
                    \`;
                });
                document.getElementById('activityTableBody').innerHTML = activityHtml;
            } catch (error) {
                console.error('Error loading activity:', error);
            }
        }

        async function loadUsers() {
            try {
                const response = await fetch('/api/users');
                const users = await response.json();
                
                let usersHtml = '';
                users.forEach(user => {
                    const created = new Date(user.created_at).toLocaleDateString();
                    const lastActivity = user.last_activity ? new Date(user.last_activity).toLocaleString() : 'Нет активности';
                    usersHtml += \`
                        <tr>
                            <td>\${user.username}</td>
                            <td>
                                <span class="user-badge badge-\${user.prefix?.toLowerCase() || 'user'}">
                                    \${user.prefix}
                                </span>
                            </td>
                            <td>\${created}</td>
                            <td>\${user.login_count || 0}</td>
                            <td>\${lastActivity}</td>
                        </tr>
                    \`;
                });
                document.getElementById('usersTableBody').innerHTML = usersHtml;
            } catch (error) {
                console.error('Error loading users:', error);
            }
        }

        async function loadLogs() {
            try {
                const response = await fetch('/api/logs');
                const logs = await response.json();
                
                let logsHtml = '';
                logs.reverse().forEach(log => {
                    const time = new Date(log.timestamp).toLocaleString();
                    logsHtml += \`[\${time}] \${log.username} - \${log.action} - \${log.details}\\n\`;
                });
                document.getElementById('systemLogs').textContent = logsHtml;
            } catch (error) {
                console.error('Error loading logs:', error);
            }
        }
        
        async function controlService(serviceName, action) {
            try {
                const response = await fetch('/api/service/control', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ service: serviceName, action: action })
                });
                const result = await response.json();
                alert(result.message);
                loadStats();
            } catch (error) {
                alert('Ошибка управления сервисом');
            }
        }
        
        setInterval(() => {
            loadStats();
            if (currentTab === 'activity') loadActivity();
            if (currentTab === 'users') loadUsers();
            if (currentTab === 'logs') loadLogs();
        }, 5000);
        
        loadStats();
    </script>
</body>
</html>
'''

@app.route('/')
def admin_panel():
    return render_template_string(HTML_TEMPLATE)

@app.route('/api/stats')
def get_stats():
    try:
        # CPU использование
        cpu_percent = psutil.cpu_percent(interval=1)
        
        # Память
        memory = psutil.virtual_memory()
        memory_percent = memory.percent
        
        # Диск
        disk = psutil.disk_usage('/')
        disk_percent = disk.percent
        
        # Docker контейнеры
        containers = client.containers.list(all=True)
        container_count = len(containers)
        
        # Сервисы
        services = []
        for container in containers:
            service = {
                'name': container.name,
                'status': container.status,
                'actions': []
            }
            
            if container.status == 'running':
                service['actions'].extend(['stop', 'restart'])
            else:
                service['actions'].append('start')
                
            services.append(service)

        # Получаем статистику активности из auth-server
        try:
            auth_response = requests.get('http://auth-server:5001/api/admin/stats', timeout=5)
            if auth_response.status_code == 200:
                auth_data = auth_response.json()
                today_activity = auth_data.get('todayLogins', 0)
            else:
                today_activity = 0
        except:
            today_activity = 0
        
        return jsonify({
            'cpu_percent': round(cpu_percent, 1),
            'memory_percent': round(memory_percent, 1),
            'disk_percent': round(disk_percent, 1),
            'container_count': container_count,
            'today_activity': today_activity,
            'services': services
        })
        
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/activity')
def get_activity():
    try:
        # Получаем активность из auth-server
        auth_response = requests.get('http://auth-server:5001/api/admin/activity', timeout=5)
        if auth_response.status_code == 200:
            return jsonify(auth_response.json())
        else:
            return jsonify([])
    except:
        return jsonify([])

@app.route('/api/users')
def get_users():
    try:
        # Получаем пользователей из auth-server
        auth_response = requests.get('http://auth-server:5001/api/admin/users', timeout=5)
        if auth_response.status_code == 200:
            return jsonify(auth_response.json())
        else:
            return jsonify([])
    except:
        return jsonify([])

@app.route('/api/logs')
def get_logs():
    try:
        # Получаем логи из auth-server
        auth_response = requests.get('http://auth-server:5001/api/admin/logs', timeout=5)
        if auth_response.status_code == 200:
            return jsonify(auth_response.json())
        else:
            return jsonify([])
    except:
        return jsonify([])

@app.route('/api/service/control', methods=['POST'])
def control_service():
    try:
        data = request.json
        service_name = data.get('service')
        action = data.get('action')
        
        container = client.containers.get(service_name)
        
        if action == 'start':
            container.start()
        elif action == 'stop':
            container.stop()
        elif action == 'restart':
            container.restart()
        else:
            return jsonify({'error': 'Неизвестное действие'}), 400
            
        return jsonify({'message': f'Сервис {service_name} {action} успешно'})
        
    except Exception as e:
        return jsonify({'error': str(e)}), 500

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, debug=False)
ADMIN_PYTHON

# 14. NGINX КОНФИГУРАЦИЯ
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

        location / {
            root /usr/share/nginx/html;
            index index.html;
            try_files $uri $uri/ @fallback;
        }

        location @fallback {
            return 302 /;
        }

        location /vpn-info {
            root /usr/share/nginx/html;
            try_files /vpn-info.html =404;
        }

        location /api/ {
            proxy_pass http://auth_server;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
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

        location /admin-panel/ {
            proxy_pass http://admin-panel:5000/;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
        }

        location /portainer/ {
            proxy_pass http://portainer:9000/;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
        }

        location /filebrowser/ {
            proxy_pass http://filebrowser:80/;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
        }
    }
}
NGINX_EOF

# 15. СКРИПТ УДАЛЕНИЯ STABLE DIFFUSION
log "🗑️ Создание скрипта удаления Stable Diffusion..."

cat > "/home/$CURRENT_USER/scripts/remove-stable-diffusion.sh" << 'REMOVE_SD_EOF'
#!/bin/bash

echo "🗑️ Удаление Stable Diffusion..."

# Останавливаем сервис
cd ~/docker && docker-compose stop stable-diffusion 2>/dev/null

# Удаляем контейнер
docker-compose rm -f stable-diffusion 2>/dev/null

# Удаляем данные
sudo rm -rf ~/docker/stable-diffusion

# Удаляем из docker-compose.yml
sed -i '/stable-diffusion:/,/^[[:space:]]*$/d' ~/docker/docker-compose.yml

echo "✅ Stable Diffusion полностью удален!"
echo "🔄 Перезапустите систему: cd ~/docker && docker-compose up -d"
REMOVE_SD_EOF

chmod +x "/home/$CURRENT_USER/scripts/remove-stable-diffusion.sh"

# 16. СКРИПТЫ УПРАВЛЕНИЯ
log "📜 Создание скриптов управления..."

cat > "/home/$CURRENT_USER/scripts/change-password.sh" << 'PASSWORD_EOF'
#!/bin/bash

echo "=== СИСТЕМА СМЕНЫ ПАРОЛЯ ==="
echo ""

read -s -p "Введите текущий пароль: " CURRENT_PASS
echo
read -s -p "Введите новый пароль: " NEW_PASS
echo
read -s -p "Подтвердите новый пароль: " NEW_PASS_CONFIRM
echo

if [ "$NEW_PASS" != "$NEW_PASS_CONFIRM" ]; then
    echo "❌ Пароли не совпадают!"
    exit 1
fi

python3 << PYTHON_EOF
import json
import sys
import os

current_user = os.getenv('USER')
current_pass = "$CURRENT_PASS"
new_pass = "$NEW_PASS"

try:
    with open(f'/home/{current_user}/data/users/users.json', 'r') as f:
        data = json.load(f)
    
    user_updated = False
    for user in data['users']:
        if user['username'] == 'admin' and user['password'] == current_pass:
            user['password'] = new_pass
            user_updated = True
            break
    
    if not user_updated:
        print("❌ Неверный текущий пароль!")
        sys.exit(1)
    
    with open(f'/home/{current_user}/data/users/users.json', 'w') as f:
        json.dump(data, f, indent=2)
    
    print("✅ Пароль успешно изменен!")
    print("🔄 Новый пароль действует для всей системы")
    
except Exception as e:
    print(f"❌ Ошибка: {e}")
    sys.exit(1)
PYTHON_EOF
PASSWORD_EOF

cat > "/home/$CURRENT_USER/scripts/add-user.sh" << 'ADD_USER_EOF'
#!/bin/bash

echo "=== ДОБАВЛЕНИЕ ПОЛЬЗОВАТЕЛЯ ==="
read -p "Введите логин: " USERNAME
read -s -p "Введите пароль: " PASSWORD
echo
read -p "Введите префикс (User/Administrator): " PREFIX

python3 << PYTHON_EOF
import json
import sys
import datetime
import os

username = "$USERNAME"
password = "$PASSWORD"
prefix = "$PREFIX"
current_user = os.getenv('USER')

if prefix not in ["User", "Administrator"]:
    print("❌ Неверный префикс! Используйте User или Administrator")
    sys.exit(1)

try:
    with open(f'/home/{current_user}/data/users/users.json', 'r') as f:
        data = json.load(f)
    
    if any(u['username'] == username for u in data['users']):
        print("❌ Пользователь уже существует!")
        sys.exit(1)
    
    if prefix == "Administrator":
        permissions = ["all"]
    else:
        permissions = ["basic_access"]
    
    data['users'].append({
        "username": username,
        "password": password,
        "prefix": prefix,
        "permissions": permissions,
        "created_at": datetime.datetime.now().isoformat(),
        "is_active": True
    })
    
    with open(f'/home/{current_user}/data/users/users.json', 'w') as f:
        json.dump(data, f, indent=2)
    
    print("✅ Пользователь успешно добавлен!"
    print(f"👤 Логин: {username}")
    print(f"🛡️ Префикс: {prefix}")
    
except Exception as e:
    print(f"❌ Ошибка: {e}")
    sys.exit(1)
PYTHON_EOF
ADD_USER_EOF

chmod +x "/home/$CURRENT_USER/scripts/change-password.sh"
chmod +x "/home/$CURRENT_USER/scripts/add-user.sh"

# 17. ЗАПУСК ВСЕХ СЕРВИСОВ
log "🚀 Запуск всех сервисов..."

cd "/home/$CURRENT_USER/docker" || exit

log "🔍 Проверка занятых портов..."
PORTS=(80 8096 11435 5000 8080 3001 5002 9000 8081 11434)
for port in "${PORTS[@]}"; do
    if ss -tulpn | grep ":$port " > /dev/null; then
        log "⚠️ Порт $port уже занят"
    fi
done

log "🐳 Запуск Docker сервисов..."
docker-compose up -d

sleep 10

log "📊 Проверка статуса сервисов..."
docker-compose ps

# 18. АВТОМАТИЧЕСКОЕ РЕЗЕРВНОЕ КОПИРОВАНИЕ
log "💾 Настройка автоматического резервного копирования..."

mkdir -p "/home/$CURRENT_USER/backups"
cat > "/home/$CURRENT_USER/scripts/backup-system.sh" << 'BACKUP_EOF'
#!/bin/bash
BACKUP_DIR="/home/$(whoami)/backups"
DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="$BACKUP_DIR/full-backup-$DATE.tar.gz"

echo "[$(date)] Starting backup and cleanup..." >> "$BACKUP_DIR/backup.log"

echo "[$(date)] Creating backup..." >> "$BACKUP_DIR/backup.log"
tar -czf "$BACKUP_FILE" \
  /home/$(whoami)/docker \
  /home/$(whoami)/data \
  /home/$(whoami)/media \
  /etc/wireguard 2>/dev/null || echo "Backup completed with warnings"

echo "[$(date)] Starting cleanup..." >> "$BACKUP_DIR/backup.log"

find "/home/$(whoami)/media/temp" -type f -mtime +7 -delete 2>/dev/null || true
find "/home/$(whoami)/data/logs" -name "*.log" -mtime +30 -delete 2>/dev/null || true
docker system prune -f --filter "until=168h" 2>/dev/null || true
find "$BACKUP_DIR" -name "full-backup-*.tar.gz" -mtime +14 -delete 2>/dev/null || true

/home/$(whoami)/scripts/generate-vpn-html.sh
/home/$(whoami)/scripts/generate-dashboard.sh

echo "[$(date)] Backup and cleanup completed: $BACKUP_FILE" >> "$BACKUP_DIR/backup.log"
BACKUP_EOF

chmod +x "/home/$CURRENT_USER/scripts/backup-system.sh"

# 19. МОНИТОРИНГ РЕСУРСОВ
log "📊 Настройка мониторинга ресурсов..."

cat > "/home/$CURRENT_USER/scripts/system-monitor.sh" << 'MONITOR_EOF'
#!/bin/bash
LOG_FILE="/home/$(whoami)/data/logs/system-stats.log"
mkdir -p "$(dirname "$LOG_FILE")"

{
    echo "=== System Stats $(date) ==="
    echo "CPU: $(top -bn1 | grep "Cpu(s)" | awk '{print $2}')%"
    echo "RAM: $(free -h | grep Mem | awk '{print $3"/"$2}')"
    echo "Disk: $(df -h / | awk 'NR==2{print $3"/"$2" ("$5")"}')"
    echo "Docker: $(docker ps --format "table {{.Names}}\t{{.Status}}" | grep -v NAMES 2>/dev/null || echo "No containers")"
    echo "Services:"
    systemctl is-active --quiet wg-quick@wg0 && echo "  VPN: ✅" || echo "  VPN: ❌"
    docker ps 2>/dev/null | grep -q jellyfin && echo "  Jellyfin: ✅" || echo "  Jellyfin: ❌"
    echo "================================="
} >> "$LOG_FILE"

tail -n 1000 "$LOG_FILE" > "${LOG_FILE}.tmp" 2>/dev/null && mv "${LOG_FILE}.tmp" "$LOG_FILE" 2>/dev/null || true
MONITOR_EOF

chmod +x "/home/$CURRENT_USER/scripts/system-monitor.sh"

# 20. НАСТРОЙКА РАСПИСАНИЯ
log "⏰ Настройка расписания..."

sudo timedatectl set-timezone Asia/Yekaterinburg

(
    crontab -l 2>/dev/null | grep -v 'backup-system.sh' | grep -v 'security-updates.sh' | grep -v 'system-monitor.sh' | grep -v 'generate-vpn-html.sh' | grep -v 'generate-dashboard.sh'
    echo "0 18 * * * /home/$CURRENT_USER/scripts/backup-system.sh >/dev/null 2>&1"
    echo "0 19 * * * /home/$CURRENT_USER/scripts/security-updates.sh >/dev/null 2>&1"
    echo "*/5 * * * * /home/$CURRENT_USER/scripts/system-monitor.sh >/dev/null 2>&1"
    echo "0 */6 * * * /home/$CURRENT_USER/scripts/generate-vpn-html.sh >/dev/null 2>&1"
    echo "0 2 * * * /home/$CURRENT_USER/scripts/generate-dashboard.sh >/dev/null 2>&1"
) | crontab -

if [ "${DISABLE_SSH_HARDENING:-no}" != "yes" ]; then
    sudo sed -i 's/#\?PermitRootLogin .*/PermitRootLogin no/' /etc/ssh/sshd_config
fi

sudo tee /etc/fail2ban/jail.local > /dev/null << FAIL2BAN_EOF
[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 3600
FAIL2BAN_EOF

sudo systemctl enable fail2ban
sudo systemctl restart fail2ban

log "🕐 Текущее время системы: $(date)"

# 21. ФИНАЛЬНАЯ ИНФОРМАЦИЯ
echo ""
echo "=========================================="
echo "🎉 ПОЛНАЯ СИСТЕМА УСПЕШНО УСТАНОВЛЕНА!"
echo "=========================================="
echo ""
echo "🔍 ВЫПОЛНЕНИЕ ФИНАЛЬНЫХ ПРОВЕРОК..."

log "🔍 Проверка основных сервисов..."
sudo systemctl is-active --quiet docker && echo "✅ Docker: запущен" || echo "❌ Docker: не запущен"
sudo systemctl is-active --quiet wg-quick@wg0 && echo "✅ WireGuard: запущен" || echo "⚠️ WireGuard: требует настройки"

log "🔍 Проверка Docker контейнеров..."
cd "/home/$CURRENT_USER/docker" && docker-compose ps

echo ""
echo "🌐 ГЛАВНАЯ СТРАНИЦА: http://$SERVER_IP"
echo ""
echo "🔐 УЧЕТНЫЕ ЗАПИСИ:"
echo "   👑 Administrator:"
echo "     - admin / LevAdmin (полный доступ)"
echo ""
echo "   👥 Users:"
echo "     - user1 / user123 (базовый доступ)"  
echo "     - test / test123 (базовый доступ)"
echo ""
echo "🚀 ВСЕ СЕРВИСЫ:"
echo "   🎬 Jellyfin: http://$SERVER_IP/jellyfin"
echo "   🤖 AI Ассистент: http://$SERVER_IP/ai-chat"
echo "   🎓 AI Кампус: http://$SERVER_IP/ai-campus"
echo "   ☁️ Nextcloud: http://$SERVER_IP/nextcloud"
echo "   🔒 VPN информация: http://$SERVER_IP/vpn-info"
echo "   📊 Мониторинг: http://$SERVER_IP/monitoring"
echo "   🛠️ Админ-панель: http://$SERVER_IP/admin-panel"
echo "   🐳 Portainer: http://$SERVER_IP/portainer"
echo "   📁 Файловый менеджер: http://$SERVER_IP/filebrowser"
echo ""
echo "🔒 VPN ИНФОРМАЦИЯ:"
echo "   Порт: 51820"
echo "   Конфиг клиента: /home/$CURRENT_USER/vpn/client.conf"
echo ""
echo "🔧 СЕКРЕТНЫЙ РАЗДЕЛ:"
echo "   - 5 быстрых нажатий на 'О системе' на главной"
echo "   - Пароль: LevAdmin"
echo ""
echo "🛠️ СКРИПТЫ УПРАВЛЕНИЯ:"
echo "   🔑 Смена пароля: ~/scripts/change-password.sh"
echo "   👥 Добавить пользователя: ~/scripts/add-user.sh"
echo "   🗑️ Удалить Stable Diffusion: ~/scripts/remove-stable-diffusion.sh"
echo ""
echo "📊 АДМИН-ПАНЕЛЬ ФУНКЦИИ:"
echo "   🚀 Управление сервисами - запуск/остановка"
echo "   📊 Активность - кто и когда заходил"
echo "   👥 Пользователи - статистика пользователей"
echo "   📋 Логи - системные логи"
echo ""
echo "⚠️  ВАЖНЫЕ ЗАМЕЧАНИЯ:"
echo "   1. AI модели загружаются автоматически при первом запуске"
echo "   2. Для полной функциональности перезагрузите систему"
echo "   3. Все виджеты обновляются автоматически"
echo "   4. Stable Diffusion удален из системы"
echo ""
echo "=========================================="
echo "🎯 СИСТЕМА ГОТОВА К ИСПОЛЬЗОВАНИЮ!"
echo "=========================================="
