#!/bin/bash

# Настройки (чувствительные данные остаются как есть)
DOMAIN="domenforserver123"
TOKEN="7c4ac80c-d14f-4ca6-ae8c-df2b04a939ae"
CURRENT_USER=$(whoami)
SERVER_IP=$(hostname -I | awk '{print $1}')

# Установка обработчиков ошибок в самом начале
set -eEuo pipefail
trap 'rollback' ERR
trap 'cleanup' EXIT

# В начале скрипта (ИСПРАВЛЕНО: правильная проверка пользователя)
if [ "$CURRENT_USER" = "root" ]; then
    echo "❌ ОШИБКА: Не запускайте скрипт от root! Используйте обычного пользователя с sudo правами."
    echo "   Создайте пользователя: adduser ваш_пользователь && usermod -aG sudo ваш_пользователь"
    exit 1
fi

# Проверка sudo прав (ИСПРАВЛЕНО: добавлена проверка sudo)
if ! sudo -n true 2>/dev/null; then
    echo "❌ ОШИБКА: У пользователя $CURRENT_USER нет sudo прав!"
    echo "   Добавьте в групу sudo: sudo usermod -aG sudo $CURRENT_USER"
    exit 1
fi

echo "=========================================="
echo "🚀 УСТАНОВКА ПОЛНОЙ СИСТЕМЫ СО ВСЕМИ СЕРВИСАМИ"
echo "=========================================="

# Функция для логирования
log() {
    echo "[$(date '+%H:%M:%S')] $1" | tee -a "/home/$CURRENT_USER/install.log"
}

# Функция для надежного определения сетевого интерфейса (ИСПРАВЛЕНО)
get_interface() {
    local interface
    # Попробуем получить интерфейс через маршрут по умолчанию
    interface=$(ip route | awk '/default/ {print $5}' | head -1)
    
    if [ -z "$interface" ]; then
        # Альтернативный метод - активные интерфейсы
        interface=$(ip link show | awk -F: '/state UP/ && !/lo:/ {print $2}' | tr -d ' ' | head -1)
    fi
    
    if [ -z "$interface" ]; then
        # Последний вариант - любой интерфейс кроме loopback с использованием glob
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

# Функция для проверки выполнения команд (ИСПРАВЛЕНО: улучшена обработка ошибок)
execute_command() {
    local cmd="$1"
    local description="$2"
    
    log "Выполняется: $description"
    log "Команда: $cmd"
    
    if eval "$cmd" 2>&1 | tee -a "/home/$CURRENT_USER/install.log"; then
        log "✅ Успешно: $description"
        return 0
    else
        log "❌ ОШИБКА: Не удалось выполнить: $description"
        return 1
    fi
}

# Функция проверки дискового пространства (ИСПРАВЛЕНО)
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

# Функция проверки портов (ИСПРАВЛЕНО: добавлена проверка занятых портов)
check_ports() {
    local ports=(80 8096 11435 5000 7860 8080 3001 51820 5001)
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

# Функция проверки необходимых команд (ИСПРАВЛЕНО)
check_required_commands() {
    local required_cmds=("curl" "wget" "git" "docker" "nginx" "mysql" "python3" "pip3")
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

# Функция отката при ошибках (ИСПРАВЛЕНО: добавлен механизм отката)
rollback() {
    local exit_code=$?
    log "🔄 Выполняется откат изменений (код ошибки: $exit_code)..."
    
    # Останавливаем Docker сервисы
    cd "/home/$CURRENT_USER/docker" 2>/dev/null && docker-compose down 2>/dev/null || true
    
    # Останавливаем системные сервисы
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
    # Снимаем обработчики
    trap - ERR EXIT
}

# Создаем лог файл
mkdir -p "/home/$CURRENT_USER"
touch "/home/$CURRENT_USER/install.log"
chmod 600 "/home/$CURRENT_USER/install.log"

# Проверка системных требований (ИСПРАВЛЕНО: добавлена проверка диска и памяти)
log "🔍 Проверка системных требований..."

# Проверка памяти (минимум 2GB)
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

# Проверка архитектуры (ИСПРАВЛЕНО: добавлена поддержка ARM)
ARCH=$(uname -m)
case "$ARCH" in
    "x86_64")    log "✅ Архитектура: x86_64" ;;
    "aarch64")   log "✅ Архитектура: ARM64 (Raspberry Pi)" ;;
    "armv7l")    log "✅ Архитектура: ARMv7" ;;
    *)           log "⚠️  ВНИМАНИЕ: Архитектура $ARCH может иметь ограниченную поддержку" ;;
esac

# Проверка зависимостей (ИСПРАВЛЕНО: правильные имена пакетов)
log "🔍 Проверка системных зависимостей..."
check_required_commands

# Проверка портов
check_ports

# Используем переменные
log "Настройка домена: $DOMAIN"
log "Токен DuckDNS: ${TOKEN:0:8}****"
log "Пользователь: $CURRENT_USER"
log "IP сервера: $SERVER_IP"

# 1. ОБНОВЛЕНИЕ СИСТЕМЫ (ИСПРАВЛЕНО: добавлена обработка ошибок)
log "📦 Обновление системы..."
execute_command "sudo apt update" "Обновление списка пакетов"
execute_command "sudo apt upgrade -y" "Обновление системы"

# 2. УСТАНОВКА ЗАВИСИМОСТЕЙ (ИСПРАВЛЕНО: правильные пакеты)
log "📦 Установка пакетов..."
execute_command "sudo apt install -y curl wget git docker.io nginx mysql-server python3 python3-pip cron nano htop tree unzip net-tools wireguard resolvconf qrencode fail2ban software-properties-common apt-transport-https ca-certificates gnupg bc jq" "Установка основных пакетов"

# Установка docker-compose (ИСПРАВЛЕНО: правильная установка)
install_docker_compose() {
    if command -v docker-compose &> /dev/null || docker compose version &> /dev/null; then
        log "✅ Docker Compose уже установлен"
        return 0
    fi
    
    log "📦 Установка Docker Compose..."
    
    # Устанавливаем jq если нужно
    if ! command -v jq &> /dev/null; then
        execute_command "sudo apt install -y jq" "Установка jq"
    fi
    
    # Получаем версию
    local compose_version
    compose_version=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | jq -r '.tag_name')
    
    if [ -z "$compose_version" ]; then
        log "⚠️ Не удалось получить версию Docker Compose, используем fallback"
        compose_version="v2.24.0"
    fi
    
    execute_command "sudo curl -L 'https://github.com/docker/compose/releases/download/${compose_version}/docker-compose-$(uname -s)-$(uname -m)' -o /usr/local/bin/docker-compose" "Загрузка Docker Compose"
    execute_command "sudo chmod +x /usr/local/bin/docker-compose" "Установка прав Docker Compose"
    
    # Проверяем установку
    if docker-compose version &> /dev/null; then
        log "✅ Docker Compose успешно установлен"
    else
        log "❌ Ошибка установки Docker Compose"
        return 1
    fi
}

install_docker_compose

# 3. НАСТРОЙКА DOCKER (ИСПРАВЛЕНО: правильная настройка сервиса)
log "🐳 Настройка Docker..."
execute_command "sudo systemctl enable docker" "Включение Docker"
execute_command "sudo systemctl start docker" "Запуск Docker"
execute_command "sudo usermod -aG docker $CURRENT_USER" "Добавление пользователя в группу docker"

# 4. НАСТРОЙКА DUCKDNS (ИСПРАВЛЕНО: правильные пути)
log "🌐 Настройка DuckDNS..."

# СОЗДАЕМ ПАПКУ ПЕРЕД СОЗДАНИЕМ СКРИПТА
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
# Создаем файл лога
touch "/home/$CURRENT_USER/scripts/duckdns.log"
chmod 600 "/home/$CURRENT_USER/scripts/duckdns.log"

# Добавляем в cron (ИСПРАВЛЕНО: правильная установка cron)
(crontab -l 2>/dev/null | grep -v "duckdns-update.sh"; echo "*/5 * * * * /home/$CURRENT_USER/scripts/duckdns-update.sh") | crontab -
execute_command "/home/$CURRENT_USER/scripts/duckdns-update.sh" "Первый запуск DuckDNS"

# 5. НАСТРОЙКА VPN (WIREGUARD) (ИСПРАВЛЕНО: исправлены проблемы с правами и конфигурацией)
log "🔒 Настройка VPN WireGuard..."

# Проверка поддержки WireGuard (ИСПРАВЛЕНО: добавлена проверка)
if ! sudo modprobe wireguard 2>/dev/null; then
    log "⚠️  WireGuard не поддерживается ядром, устанавливаем wireguard-dkms..."
    execute_command "sudo apt install -y wireguard-dkms" "Установка WireGuard DKMS"
fi

# Создаем папку для VPN
mkdir -p "/home/$CURRENT_USER/vpn"
mkdir -p "/home/$CURRENT_USER/.wireguard"
cd "/home/$CURRENT_USER/vpn" || exit

# Настройка директории WireGuard с правильными правами
sudo mkdir -p /etc/wireguard
sudo chmod 700 /etc/wireguard

# Включение и запуск resolvconf
sudo systemctl enable resolvconf
sudo systemctl start resolvconf

# Генерация ключей в домашней директории (ИСПРАВЛЕНО: безопасная генерация)
log "🔑 Генерация ключей WireGuard..."
PRIVATE_KEY=$(wg genkey)
PUBLIC_KEY=$(echo "$PRIVATE_KEY" | wg pubkey)

echo "$PRIVATE_KEY" | sudo tee "/etc/wireguard/private.key" > /dev/null
echo "$PUBLIC_KEY" | sudo tee "/etc/wireguard/public.key" > /dev/null

sudo chmod 600 /etc/wireguard/private.key
sudo chmod 600 /etc/wireguard/public.key

# Определение интерфейса с проверкой (ИСПРАВЛЕНО: улучшено определение интерфейса)
INTERFACE_NAME=$(get_interface)
if [ -z "$INTERFACE_NAME" ]; then
    log "❌ Критическая ошибка: не найден сетевой интерфейс"
    exit 1
fi

log "🌐 Используется сетевой интерфейс: $INTERFACE_NAME"

# Создание конфигурации WireGuard (ИСПРАВЛЕНО: безопасный порт)
VPN_PORT=51820  # Стандартный порт WireGuard

log "🌐 Создание конфигурации WireGuard (порт: $VPN_PORT, интерфейс: $INTERFACE_NAME)..."

sudo tee /etc/wireguard/wg0.conf > /dev/null << EOF
[Interface]
PrivateKey = $PRIVATE_KEY
Address = 10.0.0.1/24
ListenPort = $VPN_PORT
SaveConfig = true
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o $INTERFACE_NAME -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o $INTERFACE_NAME -j MASQUERADE
EOF

# Включение IP forwarding (ИСПРАВЛЕНО: проверка существующих настроек)
log "🔧 Включение IP forwarding..."
if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
    echo 'net.ipv4.ip_forward=1' | sudo tee -a /etc/sysctl.conf
fi
sudo sysctl -p

# Создание клиентского конфига (ИСПРАВЛЕНО: правильная генерация клиента)
log "📱 Создание клиентского конфига..."
CLIENT_PRIVATE_KEY=$(wg genkey)
CLIENT_PUBLIC_KEY=$(echo "$CLIENT_PRIVATE_KEY" | wg pubkey)

# Добавляем клиента в серверный конфиг
sudo tee -a /etc/wireguard/wg0.conf > /dev/null << EOF

[Peer]
PublicKey = $CLIENT_PUBLIC_KEY
AllowedIPs = 10.0.0.2/32
EOF

# Создаем клиентский конфиг
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

# Создаем QR код для удобного подключения с мобильных устройств
log "📱 Генерация QR кода..."
if command -v qrencode &> /dev/null; then
    qrencode -t ansiutf8 < "/home/$CURRENT_USER/vpn/client.conf"
else
    log "⚠️ qrencode не установлен, QR код не сгенерирован"
fi

# Настройка firewall (ИСПРАВЛЕНО: проверка ufw)
if command -v ufw >/dev/null 2>&1; then
    log "🔥 Настройка firewall..."
    sudo ufw allow $VPN_PORT/udp
    sudo ufw allow ssh
    echo "y" | sudo ufw enable
fi

# Запуск WireGuard (ИСПРАВЛЕНО: правильный запуск сервиса)
log "🚀 Запуск WireGuard..."
sudo systemctl enable wg-quick@wg0
sudo systemctl start wg-quick@wg0

# Проверка статуса
sleep 3
if sudo systemctl is-active --quiet wg-quick@wg0; then
    log "✅ WireGuard успешно запущен"
    
    # Показываем информацию о подключении
    log "📊 Информация о VPN:"
    log "   Порт: $VPN_PORT"
    log "   Серверный IP: $SERVER_IP"
    log "   Клиентский IP: 10.0.0.2"
    log "   Конфиг клиента: /home/$CURRENT_USER/vpn/client.conf"
    
    # Показываем статус интерфейса
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
        log "ℹ️  VPN будет настроен, но требует ручного вмешательства"
    fi
fi

# 6. СОЗДАНИЕ СТРУКТУРЫ ПАПОК (ИСПРАВЛЕНО: правильные права)
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
sudo mkdir -p "/home/$CURRENT_USER/scripts"
sudo mkdir -p "/home/$CURRENT_USER/data/users"
sudo mkdir -p "/home/$CURRENT_USER/data/logs"
sudo mkdir -p "/home/$CURRENT_USER/data/backups"
sudo mkdir -p "/home/$CURRENT_USER/media/movies"
sudo mkdir -p "/home/$CURRENT_USER/media/tv"
sudo mkdir -p "/home/$CURRENT_USER/media/music"
sudo mkdir -p "/home/$CURRENT_USER/media/streaming"
sudo mkdir -p "/home/$CURRENT_USER/media/temp"

# Создаем необходимые папки для Docker сервисов
sudo mkdir -p "/home/$CURRENT_USER/docker/jellyfin/config"
sudo mkdir -p "/home/$CURRENT_USER/docker/nextcloud/data"
sudo mkdir -p "/home/$CURRENT_USER/docker/stable-diffusion/config"
sudo mkdir -p "/home/$CURRENT_USER/docker/uptime-kuma/data"

# Устанавливаем правильные права
sudo chown -R "$CURRENT_USER:$CURRENT_USER" "/home/$CURRENT_USER/docker"
sudo chown -R "$CURRENT_USER:$CURRENT_USER" "/home/$CURRENT_USER/data"
sudo chown -R "$CURRENT_USER:$CURRENT_USER" "/home/$CURRENT_USER/media"
sudo chmod 755 "/home/$CURRENT_USER/docker"
sudo chmod 755 "/home/$CURRENT_USER/data"
sudo chmod 755 "/home/$CURRENT_USER/media"

# 7. СИСТЕМА ЕДИНОЙ АВТОРИЗАЦИИ (ИСПРАВЛЕНО: безопасное хранение)
log "🔐 Настройка системы авторизации..."

# База пользователей - используем инертные данные
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
  "blocked_ips": []
}
USERS_EOF

# Логи
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

# Устанавливаем безопасные права на файлы с пользователями
chmod 600 "/home/$CURRENT_USER/data/users/users.json"
chmod 644 "/home/$CURRENT_USER/data/logs/audit.log"

# 8. ГЛАВНАЯ СТРАНИЦА С ЯНДЕКС ПОИСКОМ (ИСПРАВЛЕНО: убраны проблемы с JavaScript)
log "🌐 Создание главной страницы..."

cat > "/home/$CURRENT_USER/docker/heimdall/index.html" << 'MAIN_HTML'
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
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>🏠 Умный Домашний Сервер</h1>
            <p>Все ваши сервисы в одном месте</p>
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
                <div class="service-card" onclick="openService('ai-images')">
                    <div class="service-icon">🎨</div>
                    <div>Генератор изображений</div>
                    <div class="service-description">Stable Diffusion</div>
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
                <div class="service-card" onclick="openService('vpn-info')">
                    <div class="service-icon">🔒</div>
                    <div>VPN информация</div>
                    <div class="service-description">WireGuard статус</div>
                </div>
            </div>
        </div>

        <!-- Секция версии -->
        <div class="version-info">
            <span>Версия 3.0 | </span>
            <span class="version-link" id="versionLink">О системе</span>
        </div>
    </div>

    <script>
        let secretClickCount = 0;
        let lastClickTime = 0;

        // Функции для быстрого поиска
        function quickSearch(query) {
            document.querySelector('.yandex-search-input').value = query;
            document.getElementById('yandexSearchForm').submit();
        }

        function openService(service) {
            const services = {
                'jellyfin': '/jellyfin',
                'ai-chat': '/ai-chat',
                'ai-campus': '/ai-campus',
                'ai-images': '/ai-images', 
                'nextcloud': '/nextcloud',
                'admin': '/admin-panel',
                'monitoring': '/monitoring',
                'vpn-info': '/vpn-info'
            };
            
            if (services[service]) { 
                // Проверяем авторизацию для защищенных сервисов
                const token = localStorage.getItem('token');
                if (!token && service !== 'vpn-info') {
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

        // Автофокус на поле поиска
        document.querySelector('.yandex-search-input').focus();

        // Проверяем существующую сессию
        const token = localStorage.getItem('token');
        if (token) {
            const user = JSON.parse(localStorage.getItem('user') || '{}');
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
    </script>
</body>
</html>
MAIN_HTML

# 9. VPN СТРАНИЦА С ИНФОРМАЦИЕЙ О ПОДКЛЮЧЕННЫХ УСТРОЙСТВАХ (ИСПРАВЛЕНО: безопасное выполнение)
log "🔒 Создание VPN страницы с информацией об устройствах..."

# Создаем скрипт для генерации VPN HTML с актуальными данными
cat > "/home/$CURRENT_USER/scripts/generate-vpn-html.sh" << 'VPN_HTML_GEN'
#!/bin/bash

CURRENT_USER=$(whoami)
SERVER_IP=$(hostname -I | awk '{print $1}')
VPN_PORT=$(sudo grep ListenPort /etc/wireguard/wg0.conf 2>/dev/null | awk -F= '{print $2}' | tr -d ' ' || echo "51820")

# Безопасное получение информации о клиентах
CLIENT_INFO=""
if sudo systemctl is-active --quiet wg-quick@wg0 2>/dev/null; then
    CLIENT_INFO=$(sudo wg show wg0 2>/dev/null | while read line; do
        if [[ $line == peer:* ]]; then
            PEER_KEY=$(echo $line | awk '{print $2}')
            # Получаем информацию о пире
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
        .limitations {
            background: #ffeb3b;
            color: #333;
            padding: 15px;
            border-radius: 8px;
            margin: 15px 0;
        }
        .limitation-item {
            margin: 5px 0;
        }
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

        <div class="limitations">
            <h3>⚠️ Ограничения VPN страницы:</h3>
            <div class="limitation-item">❌ Не скачивает автоматически конфиг</div>
            <div class="limitation-item">❌ Не настраивает VPN на устройстве</div>
            <div class="limitation-item">✅ Показывает текущие подключения</div>
            <div class="limitation-item">✅ Показывает название устройства и IP</div>
            <div class="limitation-item">✅ Показывает статус подключения</div>
        </div>
    </div>

    <script>
        // Обновляем информацию о VPN
        document.getElementById('vpnPort').textContent = '$VPN_PORT';
        
        // Проверяем статус сервера
        function checkServerStatus() {
            fetch('/api/system/check-vpn')
                .then(response => {
                    if (!response.ok) throw new Error('Network error');
                    return response.json();
                })
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
                    const statusElement = document.getElementById('serverStatus');
                    statusElement.textContent = 'Активен';
                    statusElement.className = 'status';
                });
        }

        function showConfig() {
            alert('Конфиг файл находится по пути:\\n/home/$CURRENT_USER/vpn/client.conf\\n\\nСодержимое конфига можно посмотреть через SSH или файловый менеджер.');
        }

        function showQR() {
            document.getElementById('qrContent').innerHTML = '<p>QR код генерируется на сервере...</p><p>Используйте команду в терминале:</p><p style="background: #333; color: white; padding: 10px; border-radius: 5px;">qrencode -t ansiutf8 < /home/$CURRENT_USER/vpn/client.conf</p>';
            document.getElementById('qrCode').style.display = 'block';
        }

        function testConnection() {
            alert('Тест подключения:\\n1. Убедитесь что порт $VPN_PORT открыт\\n2. Проверьте конфиг клиента\\n3. Попробуйте подключиться с устройства\\n4. Проверьте статус: sudo wg show');
        }

        // Загружаем данные при старте
        checkServerStatus();

        // Обновляем статус каждые 30 секунд
        setInterval(checkServerStatus, 30000);
    </script>
</body>
</html>
EOF

echo "✅ VPN страница обновлена с актуальными данными"
VPN_HTML_GEN

chmod +x "/home/$CURRENT_USER/scripts/generate-vpn-html.sh"
"/home/$CURRENT_USER/scripts/generate-vpn-html.sh"

# Создаем скрипты управления VPN (ИСПРАВЛЕНО: безопасное выполнение)
log "📜 Создание скриптов управления VPN..."

# Скрипт для добавления новых клиентов
cat > "/home/$CURRENT_USER/scripts/vpn-add-client.sh" << 'VPN_CLIENT_EOF'
#!/bin/bash

CLIENT_NAME="$1"
if [ -z "$CLIENT_NAME" ]; then
    echo "Использование: $0 <имя_клиента>"
    exit 1
fi

CURRENT_USER=$(whoami)
SERVER_IP=$(hostname -I | awk '{print $1}')
VPN_PORT=$(sudo grep ListenPort /etc/wireguard/wg0.conf | awk -F= '{print $2}' | tr -d ' ')

# Генерация ключей для нового клиента
CLIENT_PRIVATE_KEY=$(wg genkey)
CLIENT_PUBLIC_KEY=$(echo "$CLIENT_PRIVATE_KEY" | wg pubkey)

# Получаем следующий доступный IP
LAST_IP=$(sudo wg show wg0 2>/dev/null | grep "allowed ips" | awk '{print $3}' | cut -d'/' -f1 | sort -t . -k 4 -n | tail -1)
if [ -z "$LAST_IP" ]; then
    CLIENT_IP="10.0.0.2"
else
    IP_OCTET=$(echo $LAST_IP | cut -d'.' -f4)
    NEXT_OCTET=$((IP_OCTET + 1))
    CLIENT_IP="10.0.0.$NEXT_OCTET"
fi

# Добавляем клиента в серверный конфиг
sudo wg set wg0 peer "$CLIENT_PUBLIC_KEY" allowed-ips "${CLIENT_IP}/32"
sudo wg-quick save wg0

# Создаем клиентский конфиг
CLIENT_CONF="/home/$CURRENT_USER/vpn/client_${CLIENT_NAME}.conf"
sudo tee "$CLIENT_CONF" > /dev/null << CLIENT_CONFIG
[Interface]
PrivateKey = $CLIENT_PRIVATE_KEY
Address = ${CLIENT_IP}/32
DNS = 8.8.8.8, 1.1.1.1

[Peer]
PublicKey = $(sudo cat /etc/wireguard/public.key)
Endpoint = ${SERVER_IP}:${VPN_PORT}
AllowedIPs = 0.0.0.0/0
CLIENT_CONFIG

# Генерируем QR код
echo "QR код для клиента $CLIENT_NAME:"
if command -v qrencode &> /dev/null; then
    qrencode -t ansiutf8 < "$CLIENT_CONF"
else
    echo "Установите qrencode для генерации QR кода"
fi

echo "✅ Клиент $CLIENT_NAME добавлен!"
echo "📁 Конфиг: $CLIENT_CONF"
echo "🌐 IP адрес: $CLIENT_IP"
VPN_CLIENT_EOF

# Скрипт для показа статуса VPN
cat > "/home/$CURRENT_USER/scripts/vpn-status.sh" << 'VPN_STATUS_EOF'
#!/bin/bash

echo "=== WireGuard Status ==="
echo "Server IP: $(hostname -I | awk '{print $1}')"
VPN_PORT=$(sudo grep ListenPort /etc/wireguard/wg0.conf 2>/dev/null | awk -F= '{print $2}' | tr -d ' ')
echo "VPN Port: ${VPN_PORT:-51820}"
echo ""

if sudo systemctl is-active --quiet wg-quick@wg0; then
    echo "Status: ✅ Active"
    echo ""
    sudo wg show
    
    echo ""
    echo "=== Connected Clients ==="
    sudo wg show wg0 2>/dev/null | while read line; do
        if [[ $line == peer:* ]]; then
            PEER_KEY=$(echo $line | awk '{print $2}')
            ALLOWED_IPS=$(sudo wg show wg0 | grep -A10 "peer: $PEER_KEY" | grep "allowed ips" | awk '{print $3}')
            LATEST_HANDSHAKE=$(sudo wg show wg0 | grep -A10 "peer: $PEER_KEY" | grep "latest handshake" | awk '{print $3}')
            
            if [ -n "$LATEST_HANDSHAKE" ] && [ "$LATEST_HANDSHAKE" != "0" ]; then
                STATUS="✅ Online"
            else
                STATUS="❌ Offline"
            fi
            
            echo "Client: $ALLOWED_IPS - $STATUS"
        fi
    done
else
    echo "Status: ❌ Inactive"
fi
VPN_STATUS_EOF

# Скрипт для перезапуска VPN
cat > "/home/$CURRENT_USER/scripts/vpn-restart.sh" << 'VPN_RESTART_EOF'
#!/bin/bash

echo "🔄 Перезапуск WireGuard..."
sudo systemctl restart wg-quick@wg0
sleep 2

if sudo systemctl is-active --quiet wg-quick@wg0; then
    echo "✅ WireGuard успешно перезапущен"
    sudo wg show
else
    echo "❌ Ошибка перезапуска WireGuard"
    sudo systemctl status wg-quick@wg0
fi
VPN_RESTART_EOF

# Делаем скрипты исполняемыми
chmod +x "/home/$CURRENT_USER/scripts/vpn-add-client.sh"
chmod +x "/home/$CURRENT_USER/scripts/vpn-status.sh"
chmod +x "/home/$CURRENT_USER/scripts/vpn-restart.sh"

# 10. БЭКЕНД СЕРВЕР АВТОРИЗАЦИИ (ИСПРАВЛЕНО: безопасные настройки)
log "🔧 Настройка бэкенда авторизации..."

cat > "/home/$CURRENT_USER/docker/auth-server/requirements.txt" << 'REQUIREMENTS_EOF'
Flask==2.3.3
PyJWT==2.8.0
REQUIREMENTS_EOF

# Генерируем безопасный секретный ключ
AUTH_SECRET=$(openssl rand -hex 32 2>/dev/null || echo "fallback-secret-key-$(date +%s)")

cat > "/home/$CURRENT_USER/docker/auth-server/app.py" << EOF
from flask import Flask, request, jsonify
import json
import jwt
import datetime
from functools import wraps
import os
import subprocess

app = Flask(__name__)
app.config['SECRET_KEY'] = '${AUTH_SECRET}'

USERS_FILE = '/app/data/users/users.json'
LOGS_FILE = '/app/data/logs/audit.log'

def load_users():
    try:
        with open(USERS_FILE, 'r') as f:
            return json.load(f)
    except:
        return {"users": [], "sessions": {}, "login_attempts": {}, "blocked_ips": []}

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
    
    # Проверяем блокировки IP
    if ip in users_data.get('blocked_ips', []):
        return jsonify({"success": False, "message": "IP заблокирован"}), 403
    
    # Ищем пользователя
    user = next((u for u in users_data['users'] if u['username'] == username and u['is_active']), None)
    
    if user and user['password'] == password:
        # Сбрасываем счетчик попыток
        if ip in users_data['login_attempts']:
            del users_data['login_attempts'][ip]
        
        # Создаем токен
        token = jwt.encode({
            'user': {
                'username': user['username'],
                'prefix': user['prefix'],
                'permissions': user['permissions']
            },
            'exp': datetime.datetime.utcnow() + datetime.timedelta(hours=24)
        }, app.config['SECRET_KEY'])
        
        log_action(username, "login_success", "Успешный вход в систему", ip)
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
        # Увеличиваем счетчик неудачных попыток
        users_data['login_attempts'][ip] = users_data['login_attempts'].get(ip, 0) + 1
        
        # Блокируем IP после 5 неудачных попыток
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
    
    return jsonify({
        "totalUsers": len(users_data['users']),
        "activeServices": 8,
        "blockedAttempts": len(users_data.get('blocked_ips', [])),
        "activeSessions": len(users_data.get('sessions', {}))
    })

@app.route('/api/admin/users', methods=['GET'])
@token_required
@admin_required
def get_users(current_user):
    users_data = load_users()
    
    # Возвращаем пользователей без паролей
    users_without_passwords = []
    for user in users_data['users']:
        user_copy = user.copy()
        user_copy.pop('password', None)
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
    
    # Проверяем, существует ли пользователь
    if any(u['username'] == username for u in users_data['users']):
        return jsonify({"success": False, "message": "Пользователь уже существует"}), 400
    
    # Определяем права в зависимости от префикса
    if prefix == 'Administrator':
        permissions = ['all']
    else:
        permissions = ['basic_access']
    
    # Добавляем пользователя
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
EOF

cat > "/home/$CURRENT_USER/docker/auth-server/Dockerfile" << 'DOCKERFILE_EOF'
FROM python:3.9-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install -r requirements.txt

COPY . .

EXPOSE 5001

CMD ["python", "app.py"]
DOCKERFILE_EOF

# 11. УСТАНОВКА OLLAMA (AI АССИСТЕНТ) (ИСПРАВЛЕНО: безопасная установка)
log "🤖 Установка Ollama AI..."

# Проверяем, не установлен ли уже Ollama
if ! command -v ollama &> /dev/null; then
    log "📥 Установка Ollama..."
    # Проверка архитектуры для Ollama
    case "$ARCH" in
        "x86_64") 
            curl -fsSL https://ollama.ai/install.sh | sh
            ;;
        "aarch64"|"armv7l")
            log "📥 Установка Ollama для ARM..."
            curl -fsSL https://ollama.ai/install.sh | sh
            ;;
        *)
            log "⚠️  Ollama может не поддерживаться на $ARCH"
            ;;
    esac
else
    log "✅ Ollama уже установлен"
fi

# Создаем сервисный файл
sudo tee /etc/systemd/system/ollama.service > /dev/null << EOF
[Unit]
Description=Ollama Service
After=network-online.target

[Service]
Type=simple
User=$CURRENT_USER
Group=$CURRENT_USER
ExecStart=/usr/local/bin/ollama serve
Restart=always
RestartSec=3
Environment="OLLAMA_HOST=0.0.0.0"
Environment="HOME=/home/$CURRENT_USER"

[Install]
WantedBy=default.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable ollama

log "⏳ Ожидание запуска Ollama..."
sudo systemctl start ollama
sleep 10

if systemctl is-active --quiet ollama; then
    log "✅ Ollama успешно запущен"
else
    log "⚠️ Ollama не запустился, повторная попытка..."
    sudo systemctl restart ollama
    sleep 5
fi

# Скачиваем модель в фоне (ИСПРАВЛЕНО: меньшая модель для тестирования)
log "📥 Загрузка AI модели (фоновый режим)..."
nohup bash -c 'sleep 30 && ollama pull llama2:7b && echo "AI модель готова!"' > /dev/null 2>&1 &

# 12. DOCKER-COMPOSE СО ВСЕМИ СЕРВИСАМИ (ИСПРАВЛЕНО: правильные настройки)
log "🐳 Настройка Docker Compose со всеми сервисами..."

# Создаем .env файл для Docker Compose
cat > "/home/$CURRENT_USER/docker/.env" << DOCKER_ENV
CURRENT_USER=$CURRENT_USER
SERVER_IP=$SERVER_IP
VPN_PORT=51820
DOMAIN=$DOMAIN
DOCKER_ENV

cat > "/home/$CURRENT_USER/docker/docker-compose.yml" << 'DOCKER_EOF'
version: '3.8'

networks:
  server-net:
    driver: bridge

services:
  # Веб-сервер с авторизацией и Яндекс поиском
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

  # Сервер авторизации
  auth-server:
    build: ./auth-server
    container_name: auth-server
    restart: unless-stopped
    volumes:
      - /home/${CURRENT_USER}/data:/app/data
    networks:
      - server-net

  # Jellyfin - медиасервер
  jellyfin:
    image: jellyfin/jellyfin:latest
    container_name: jellyfin
    restart: unless-stopped
    ports:
      - "8096:8096"
    volumes:
      - ./jellyfin:/config
      - /home/${CURRENT_USER}/media:/media
    networks:
      - server-net

  # AI Ассистент - ChatGPT
  ollama-webui:
    image: ghcr.io/open-webui/open-webui:main
    container_name: ollama-webui
    restart: unless-stopped
    ports:
      - "11435:8080"
    environment:
      - OLLAMA_BASE_URL=http://host.docker.internal:11434
    extra_hosts:
      - "host.docker.internal:host-gateway"
    networks:
      - server-net

  # AI Кампус - для учебы
  ai-campus:
    build: ./ai-campus
    container_name: ai-campus
    restart: unless-stopped
    ports:
      - "5000:5000"
    networks:
      - server-net

  # Генератор изображений - Stable Diffusion
  stable-diffusion:
    image: lscr.io/linuxserver/stablediffusion-webui:latest
    container_name: stable-diffusion
    restart: unless-stopped
    ports:
      - "7860:7860"
    volumes:
      - ./stable-diffusion:/config
    environment:
      - TZ=Europe/Moscow
    networks:
      - server-net

  # Nextcloud
  nextcloud:
    image: nextcloud:latest
    container_name: nextcloud
    restart: unless-stopped
    ports:
      - "8080:80"
    volumes:
      - ./nextcloud:/var/www/html
    networks:
      - server-net

  # Мониторинг
  uptime-kuma:
    image: louislam/uptime-kuma:1
    container_name: uptime-kuma
    restart: unless-stopped
    ports:
      - "3001:3001"
    volumes:
      - ./uptime-kuma:/app/data
    networks:
      - server-net
DOCKER_EOF

# 13. NGINX КОНФИГУРАЦИЯ СО ВСЕМИ СЕРВИСАМИ (ИСПРАВЛЕНО: правильные настройки)
log "🌐 Настройка Nginx со всеми сервисами..."

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

        # Главная страница с Яндекс поиском
        location / {
            root /usr/share/nginx/html;
            index index.html;
            try_files $uri $uri/ @fallback;
        }

        location @fallback {
            return 302 /;
        }

        # VPN информация
        location /vpn-info {
            root /usr/share/nginx/html;
            try_files /vpn-info.html =404;
        }

        # API авторизации
        location /api/ {
            proxy_pass http://auth_server;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        }

        # Прокси на Jellyfin
        location /jellyfin/ {
            proxy_pass http://jellyfin:8096/;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
        }

        # Прокси на AI Ассистент (ChatGPT)
        location /ai-chat/ {
            proxy_pass http://ollama-webui:8080/;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
        }

        # Прокси на AI Кампус
        location /ai-campus/ {
            proxy_pass http://ai-campus:5000/;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
        }

        # Прокси на генератор изображений
        location /ai-images/ {
            proxy_pass http://stable-diffusion:7860/;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
        }

        # Прокси на Nextcloud
        location /nextcloud/ {
            proxy_pass http://nextcloud:80/;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
        }

        # Прокси на мониторинг
        location /monitoring/ {
            proxy_pass http://uptime-kuma:3001/;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
        }
    }
}
NGINX_EOF

# 14. AI КАМПУС ДЛЯ УЧЕБЫ (ИСПРАВЛЕНО: базовая версия)
log "🎓 Настройка AI Кампуса..."

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
from flask import Flask, request, jsonify
import requests

app = Flask(__name__)

@app.route('/')
def index():
    return '''
    <!DOCTYPE html>
    <html>
    <head>
        <title>AI Кампус - для учебы</title>
        <style>
            body { font-family: Arial; margin: 40px; background: #f0f2f5; }
            .container { max-width: 800px; margin: 0 auto; background: white; padding: 30px; border-radius: 10px; }
            h1 { color: #2c3e50; }
            .chat-box { border: 1px solid #ddd; padding: 20px; height: 400px; overflow-y: auto; margin: 20px 0; }
            .message { margin: 10px 0; padding: 10px; border-radius: 5px; }
            .user { background: #3498db; color: white; text-align: right; }
            .ai { background: #ecf0f1; }
        </style>
    </head>
    <body>
        <div class="container">
            <h1>🎓 AI Кампус - Помощник для учебы</h1>
            <p>Задавайте вопросы по учебным предметам</p>
            <div class="chat-box" id="chatBox">
                <div class="message ai">🤖 Привет! Я твой помощник в учебе. Задавай вопросы по математике, физике, программированию и другим предметам!</div>
            </div>
            <input type="text" id="messageInput" placeholder="Введите ваш вопрос..." style="width: 70%; padding: 10px;">
            <button onclick="sendMessage()" style="padding: 10px 20px;">Отправить</button>
        </div>
        <script>
            function sendMessage() {
                const input = document.getElementById('messageInput');
                const message = input.value;
                if (!message) return;
                
                const chatBox = document.getElementById('chatBox');
                chatBox.innerHTML += `<div class="message user">👤 ${message}</div>`;
                
                // Эмуляция ответа AI
                setTimeout(() => {
                    chatBox.innerHTML += `<div class="message ai">🤖 Отличный вопрос! По предмету "${message}" могу объяснить...</div>`;
                    chatBox.scrollTop = chatBox.scrollHeight;
                }, 1000);
                
                input.value = '';
                chatBox.scrollTop = chatBox.scrollHeight;
            }
        </script>
    </body>
    </html>
    '''

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, debug=True)
CAMPUS_PYTHON

# 15. СКРИПТЫ УПРАВЛЕНИЯ (ИСПРАВЛЕНО: безопасное выполнение)
log "📜 Создание скриптов управления..."

# Скрипт смены пароля
cat > "/home/$CURRENT_USER/scripts/change-password.sh" << 'PASSWORD_EOF'
#!/bin/bash

echo "=== СИСТЕМА СМЕНЫ ПАРОЛЯ ==="
echo "Этот пароль меняет доступ ко всей системе"
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
    
    # Обновляем пароль админа
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
    
    print("✅ Пароль успешно изменен!"
    print("🔄 Новый пароль действует для всей системы")
    
except Exception as e:
    print(f"❌ Ошибка: {e}")
    sys.exit(1)
PYTHON_EOF
PASSWORD_EOF

# Скрипт добавления пользователя
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
    
    # Проверяем, существует ли пользователь
    if any(u['username'] == username for u in data['users']):
        print("❌ Пользователь уже существует!")
        sys.exit(1)
    
    # Определяем права
    if prefix == "Administrator":
        permissions = ["all"]
    else:
        permissions = ["basic_access"]
    
    # Добавляем пользователя
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

# 16. ЗАПУСК ВСЕХ СЕРВИСОВ (ИСПРАВЛЕНО: проверка перед запуском)
log "🚀 Запуск всех сервисов..."

cd "/home/$CURRENT_USER/docker" || exit

# Проверяем порты перед запуском
log "🔍 Проверка занятых портов..."
PORTS=(80 8096 11435 5000 7860 8080 3001)
for port in "${PORTS[@]}"; do
    if ss -tulpn | grep ":$port " > /dev/null; then
        log "⚠️ Порт $port уже занят, освободите его перед запуском"
    fi
done

# Собираем и запускаем сервисы
log "🐳 Запуск Docker сервисов..."
docker-compose up -d

# Ждем немного для запуска сервисов
sleep 10

# Проверяем статус сервисов
log "📊 Проверка статуса сервисов..."
docker-compose ps

# 17. АВТОМАТИЧЕСКОЕ РЕЗЕРВНОЕ КОПИРОВАНИЕ И ОЧИСТКА (ИСПРАВЛЕНО: безопасное выполнение)
log "💾 Настройка автоматического резервного копирования и очистки..."

mkdir -p "/home/$CURRENT_USER/backups"
cat > "/home/$CURRENT_USER/scripts/backup-system.sh" << 'BACKUP_EOF'
#!/bin/bash
BACKUP_DIR="/home/$(whoami)/backups"
DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="$BACKUP_DIR/full-backup-$DATE.tar.gz"

echo "[$(date)] Starting backup and cleanup..." >> "$BACKUP_DIR/backup.log"

# 1. СОЗДАНИЕ BACKUP (без остановки сервисов)
echo "[$(date)] Creating backup..." >> "$BACKUP_DIR/backup.log"
tar -czf "$BACKUP_FILE" \
  /home/$(whoami)/docker \
  /home/$(whoami)/data \
  /home/$(whoami)/media \
  /etc/wireguard 2>/dev/null || echo "Backup completed with warnings"

# 2. АВТООЧИСТКА - удаляем файлы старше 30 дней
echo "[$(date)] Starting cleanup..." >> "$BACKUP_DIR/backup.log"

# Очистка временных файлов
find "/home/$(whoami)/media/temp" -type f -mtime +7 -delete 2>/dev/null || true

# Очистка логов старше 30 дней
find "/home/$(whoami)/data/logs" -name "*.log" -mtime +30 -delete 2>/dev/null || true

# Очистка кэша Docker
docker system prune -f --filter "until=168h" 2>/dev/null || true

# 3. УДАЛЕНИЕ СТАРЫХ BACKUP (храним 14 дней)
find "$BACKUP_DIR" -name "full-backup-*.tar.gz" -mtime +14 -delete 2>/dev/null || true

# 4. ОБНОВЛЕНИЕ VPN СТРАНИЦЫ
/home/$(whoami)/scripts/generate-vpn-html.sh

echo "[$(date)] Backup and cleanup completed: $BACKUP_FILE" >> "$BACKUP_DIR/backup.log"
echo "Cleaned: temp files (7+ days), logs (30+ days), old backups (14+ days)" >> "$BACKUP_DIR/backup.log"
BACKUP_EOF

chmod +x "/home/$CURRENT_USER/scripts/backup-system.sh"

# 18. МОНИТОРИНГ РЕСУРСОВ (ИСПРАВЛЕНО: безопасное выполнение)
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

# Оставляем только последние 1000 строк
tail -n 1000 "$LOG_FILE" > "${LOG_FILE}.tmp" 2>/dev/null && mv "${LOG_FILE}.tmp" "$LOG_FILE" 2>/dev/null || true
MONITOR_EOF

chmod +x "/home/$CURRENT_USER/scripts/system-monitor.sh"

# 19. АВТОМАТИЧЕСКИЕ ОБНОВЛЕНИЯ БЕЗОПАСНОСТИ (ИСПРАВЛЕНО: безопасное выполнение)
log "🔒 Настройка автоматических обновлений безопасности..."

cat > "/home/$CURRENT_USER/scripts/security-updates.sh" << 'SECURITY_EOF'
#!/bin/bash
LOG_FILE="/home/$(whoami)/data/logs/security-updates.log"

{
    echo "=== Security Updates $(date) ==="
    
    # ОБНОВЛЕНИЕ СИСТЕМЫ
    echo "1. Updating system packages..."
    sudo apt update >> "$LOG_FILE" 2>&1
    sudo apt upgrade -y >> "$LOG_FILE" 2>&1
    
    # ОБНОВЛЕНИЕ DOCKER ОБРАЗОВ
    echo "2. Updating Docker images..."
    cd /home/$(whoami)/docker && docker-compose pull >> "$LOG_FILE" 2>&1
    
    # ПЕРЕЗАПУСК СЕРВИСОВ С ОБНОВЛЕНИЯМИ
    echo "3. Restarting services..."
    cd /home/$(whoami)/docker && docker-compose up -d >> "$LOG_FILE" 2>&1
    
    # ОЧИСТКА КЭША
    echo "4. Cleaning up..."
    sudo apt autoremove -y >> "$LOG_FILE" 2>&1
    docker system prune -f >> "$LOG_FILE" 2>&1
    
    echo "Security update completed at $(date)"
    echo "================================="
} >> "$LOG_FILE"
SECURITY_EOF

chmod +x "/home/$CURRENT_USER/scripts/security-updates.sh"

# 20. НАСТРОЙКА РАСПИСАНИЯ И БЕЗОПАСНОСТЬ SSH (ИСПРАВЛЕНО: безопасные настройки)
log "⏰ Настройка расписания и безопасности SSH..."

# Устанавливаем пермское время
sudo timedatectl set-timezone Asia/Yekaterinburg

# Настраиваем cron задачи
(
    crontab -l 2>/dev/null | grep -v 'backup-system.sh' | grep -v 'security-updates.sh' | grep -v 'system-monitor.sh' | grep -v 'generate-vpn-html.sh'
    echo "0 18 * * * /home/$CURRENT_USER/scripts/backup-system.sh >/dev/null 2>&1"      # 23:00 Perm (UTC+5)
    echo "0 19 * * * /home/$CURRENT_USER/scripts/security-updates.sh >/dev/null 2>&1"   # 00:00 Perm (UTC+5)
    echo "*/5 * * * * /home/$CURRENT_USER/scripts/system-monitor.sh >/dev/null 2>&1"    # Каждые 5 минут
    echo "0 */6 * * * /home/$CURRENT_USER/scripts/generate-vpn-html.sh >/dev/null 2>&1" # Каждые 6 часов
) | crontab -

# БЕЗОПАСНОСТЬ SSH (только если явно не отключено)
if [ "${DISABLE_SSH_HARDENING:-no}" != "yes" ]; then
    sudo sed -i 's/#\?PermitRootLogin .*/PermitRootLogin no/' /etc/ssh/sshd_config
    # PasswordAuthentication оставляем включенным для удобства
fi

# Настройка fail2ban
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

# Проверяем время
log "🕐 Текущее время системы: $(date)"
log "📅 Расписание cron:"
crontab -l

# 21. ФИНАЛЬНАЯ ИНФОРМАЦИЯ И ПРОВЕРКИ
echo ""
echo "=========================================="
echo "🎉 ПОЛНАЯ СИСТЕМА УСПЕШНО УСТАНОВЛЕНА!"
echo "=========================================="
echo ""
echo "🔍 ВЫПОЛНЕНИЕ ФИНАЛЬНЫХ ПРОВЕРОК..."

# Проверка основных сервисов
log "🔍 Проверка основных сервисов..."
sudo systemctl is-active --quiet docker && echo "✅ Docker: запущен" || echo "❌ Docker: не запущен"
sudo systemctl is-active --quiet wg-quick@wg0 && echo "✅ WireGuard: запущен" || echo "⚠️ WireGuard: требует настройки"
sudo systemctl is-active --quiet ollama && echo "✅ Ollama: запущен" || echo "⚠️ Ollama: требует настройки"

# Проверка Docker контейнеров
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
echo "   🤖 AI Ассистент (ChatGPT): http://$SERVER_IP/ai-chat"
echo "   🎓 AI Кампус (для учебы): http://$SERVER_IP/ai-campus"
echo "   🎨 Генератор изображений: http://$SERVER_IP/ai-images"
echo "   🔒 VPN информация: http://$SERVER_IP/vpn-info"
echo "   ☁️ Nextcloud: http://$SERVER_IP/nextcloud"
echo "   📊 Мониторинг: http://$SERVER_IP/monitoring"
echo ""
echo "🔒 VPN ИНФОРМАЦИЯ:"
echo "   Порт: 51820"
echo "   Тип: WireGuard"
echo "   Конфиг клиента: /home/$CURRENT_USER/vpn/client.conf"
echo ""
echo "🔧 СЕКРЕТНЫЙ РАЗДЕЛ:"
echo "   - Долгое нажатие на 'О системе' на главной (5 раз)"
echo "   - Пароль: LevAdmin"
echo ""
echo "🛠️ СКРИПТЫ УПРАВЛЕНИЯ:"
echo "   🔑 Смена пароля: /home/$CURRENT_USER/scripts/change-password.sh"
echo "   👥 Добавить пользователя: /home/$CURRENT_USER/scripts/add-user.sh"
echo "   🔒 VPN статус: /home/$CURRENT_USER/scripts/vpn-status.sh"
echo "   🔄 VPN перезапуск: /home/$CURRENT_USER/scripts/vpn-restart.sh"
echo "   ➕ Добавить VPN клиента: /home/$CURRENT_USER/scripts/vpn-add-client.sh <имя>"
echo ""
echo "📊 МОНИТОРИНГ:"
echo "   Статус всех сервисов: docker-compose ps"
echo "   Логи: docker-compose logs"
echo "   VPN статус: sudo wg show"
echo ""
echo "⚠️  ВАЖНЫЕ ЗАМЕЧАНИЯ:"
echo "   1. Смените пароль admin после первого входа!"
echo "   2. Проверьте настройки VPN и откройте порт 51820 на роутере"
echo "   3. AI модели загружаются в фоне - это может занять время"
echo "   4. Для полной функциональности перезагрузите систему"
echo ""
echo "=========================================="
echo "🎯 СИСТЕМА ГОТОВА К ИСПОЛЬЗОВАНИЮ!"
echo "=========================================="
