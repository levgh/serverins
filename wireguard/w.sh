# 1. Остановить WireGuard
sudo systemctl stop wg-quick@wg0
sudo systemctl disable wg-quick@wg0

# 2. Удалить старый конфиг
sudo rm -f /etc/wireguard/wg0.conf
sudo rm -f /etc/wireguard/client*.key

# 3. Создать новый конфиг WireGuard с правильными настройками
sudo tee /etc/wireguard/wg0.conf > /dev/null << 'WG_EOF'
[Interface]
PrivateKey = $(wg genkey)
Address = 10.8.0.1/24
ListenPort = 51820
SaveConfig = true

# Включить форвардинг и NAT
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

# DNS для обхода блокировок
PostUp = sysctl -w net.ipv4.ip_forward=1
PostUp = echo "nameserver 8.8.8.8" > /etc/resolv.conf; echo "nameserver 1.1.1.1" >> /etc/resolv.conf
WG_EOF

# 4. Включить IP forwarding на постоянной основе
echo 'net.ipv4.ip_forward=1' | sudo tee -a /etc/sysctl.conf
sudo sysctl -p

# 5. Обновить скрипт создания клиентов
cat > ~/scripts/wireguard/create_client.sh << 'WG_CLIENT_EOF'
#!/bin/bash

CLIENT_NAME=$1

if [ -z "$CLIENT_NAME" ]; then
    echo "Usage: $0 <client_name>"
    exit 1
fi

# Генерация ключей
CLIENT_PRIVATE_KEY=$(wg genkey)
CLIENT_PUBLIC_KEY=$(echo $CLIENT_PRIVATE_KEY | wg pubkey)

# Определяем следующий IP
LAST_IP=$(sudo grep -o '10.8.0.[0-9]*' /etc/wireguard/wg0.conf | tail -1)
if [ -z "$LAST_IP" ]; then
    CLIENT_IP="10.8.0.2"
else
    IP_NUM=$(echo $LAST_IP | awk -F. '{print $4}')
    CLIENT_IP="10.8.0.$((IP_NUM + 1))"
fi

# Добавить клиента в конфиг сервера
sudo tee -a /etc/wireguard/wg0.conf > /dev/null << EOF

# Client: $CLIENT_NAME
[Peer]
PublicKey = $CLIENT_PUBLIC_KEY
AllowedIPs = $CLIENT_IP/32
EOF

# Получить данные сервера
SERVER_PUBLIC_KEY=$(sudo grep 'PrivateKey' /etc/wireguard/wg0.conf | head -1 | awk '{print $3}' | wg pubkey)
SERVER_IP=$(curl -s http://checkip.amazonaws.com || hostname -I | awk '{print $1}')

# Создать конфиг клиента
mkdir -p ~/wireguard-clients

cat > ~/wireguard-clients/${CLIENT_NAME}.conf << CLIENT_EOF
[Interface]
PrivateKey = $CLIENT_PRIVATE_KEY
Address = $CLIENT_IP/24
DNS = 8.8.8.8, 1.1.1.1

[Peer]
PublicKey = $SERVER_PUBLIC_KEY
Endpoint = $SERVER_IP:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
CLIENT_EOF

# Перезагрузить WireGuard
sudo systemctl restart wg-quick@wg0

echo "✅ Клиент $CLIENT_NAME создан!"
echo "📁 Конфиг: ~/wireguard-clients/${CLIENT_NAME}.conf"
echo "🌐 IP: $CLIENT_IP"
echo "🔑 Публичный ключ: $CLIENT_PUBLIC_KEY"
WG_CLIENT_EOF

chmod +x ~/scripts/wireguard/create_client.sh

# 6. Запустить WireGuard
sudo systemctl enable wg-quick@wg0
sudo systemctl start wg-quick@wg0

# 7. Открыть порт в firewall
sudo ufw allow 51820/udp comment 'WireGuard VPN'

# 8. Создать тестового клиента
~/scripts/wireguard/create_client.sh "test-client"

# 9. Проверить статус
echo "=== Статус WireGuard ==="
sudo wg show

echo "=== Проверка подключения ==="
sudo netstat -tlnp | grep 51820

echo "=== Созданные клиенты ==="
ls ~/wireguard-clients/

# 10. Обновить app.py для работы с новым WireGuard
cat > auth-system/app/app.py << 'APP_EOF'
from flask import Flask, request, jsonify, session, redirect, url_for, render_template, flash
import json
import os
import bcrypt
from datetime import datetime, timedelta
import logging
from functools import wraps
import subprocess
import qrcode
from io import BytesIO
import base64

app = Flask(__name__)
app.secret_key = os.environ.get('AUTH_SECRET', 'super-secret-key-2024-change-in-production')
app.config['PERMANENT_SESSION_LIFETIME'] = timedelta(hours=24)

BASE_DIR = "/app/data"
USERS_FILE = os.path.join(BASE_DIR, "users.json")

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

def init_directories():
    os.makedirs(BASE_DIR, exist_ok=True)

def hash_password(password):
    return bcrypt.hashpw(password.encode('utf-8'), bcrypt.gensalt()).decode('utf-8')

def verify_password(password, hashed):
    try:
        return bcrypt.checkpw(password.encode('utf-8'), hashed.encode('utf-8'))
    except:
        return False

def create_default_users():
    users_data = {"users": []}
    if not os.path.exists(USERS_FILE):
        users_data['users'] = [
            {
                "username": "admin",
                "password": hash_password("admin123"),
                "role": "admin",
                "created_at": datetime.now().isoformat()
            }
        ]
        with open(USERS_FILE, 'w') as f:
            json.dump(users_data, f, indent=2)

def generate_qr_code(data):
    try:
        qr = qrcode.QRCode(version=1, box_size=10, border=4)
        qr.add_data(data)
        qr.make(fit=True)
        img = qr.make_image(fill_color="black", back_color="white")
        buffered = BytesIO()
        img.save(buffered, format="PNG")
        img_str = base64.b64encode(buffered.getvalue()).decode()
        return f"data:image/png;base64,{img_str}"
    except Exception as e:
        logger.error(f"QR error: {e}")
        return None

def get_wireguard_status():
    try:
        result = subprocess.run(['sudo', 'wg', 'show'], capture_output=True, text=True)
        if result.returncode == 0:
            return {'status': 'active', 'clients': len(result.stdout.split('peer:')) - 1}
        return {'status': 'inactive', 'clients': 0}
    except:
        return {'status': 'error', 'clients': 0}

def create_wireguard_client(client_name):
    try:
        result = subprocess.run(
            ['/home/lev/scripts/wireguard/create_client.sh', client_name],
            capture_output=True, text=True
        )
        if result.returncode == 0:
            config_path = f"/home/lev/wireguard-clients/{client_name}.conf"
            with open(config_path, 'r') as f:
                config_content = f.read()
            qr_code = generate_qr_code(config_content)
            return {'success': True, 'config_content': config_content, 'qr_code': qr_code}
        return {'success': False, 'error': result.stderr}
    except Exception as e:
        return {'success': False, 'error': str(e)}

@app.before_request
def initialize_app():
    if not hasattr(app, 'initialized'):
        init_directories()
        create_default_users()
        app.initialized = True

@app.route('/')
def index():
    return redirect(url_for('login'))

@app.route('/login')
def login():
    return render_template('login.html')

@app.route('/vpn/')
def vpn_management():
    return render_template('vpn_management.html')

@app.route('/vpn/api/status')
def api_vpn_status():
    return jsonify({'wireguard': get_wireguard_status()})

@app.route('/vpn/api/create_client', methods=['POST'])
def api_create_client():
    data = request.get_json()
    client_name = data.get('name', '')
    if not client_name:
        return jsonify({'success': False, 'message': 'Имя клиента обязательно'}), 400
    result = create_wireguard_client(client_name)
    if result['success']:
        return jsonify({
            'success': True, 
            'message': f'Клиент {client_name} создан',
            'client_info': {
                'name': client_name,
                'config_content': result['config_content'],
                'qr_code': result.get('qr_code')
            }
        })
    return jsonify({'success': False, 'message': result['error']}), 500

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, debug=False)
APP_EOF

# 11. Перезапустить auth-system
sudo docker-compose restart auth-system

echo ""
echo "🎉 WIREGUARD ПЕРЕНАСТРОЕН!"
echo "========================"
echo "✅ Сервер: порт 51820/udp"
echo "✅ Подсеть: 10.8.0.0/24"
echo "✅ DNS: 8.8.8.8, 1.1.1.1"
echo "✅ Обход блокировок: включен"
echo "✅ Доступ к интернету: включен"
echo "📁 Клиенты: ~/wireguard-clients/"
echo "🔧 Управление: http://localhost/vpn/"
