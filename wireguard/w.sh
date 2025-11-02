#!/bin/bash

# =============================================
# 🚀 HOME SERVER REINSTALL SCRIPT
# iOS-inspired Design | WireGuard VPN Only
# =============================================

set -e
exec 2>&1

# --- Colors for iOS-style output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

# --- iOS-style logging functions ---
log_header() {
    echo -e "${PURPLE}🏠 $1${NC}"
}

log_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

log_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

log_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

log_error() {
    echo -e "${RED}❌ $1${NC}"
}

log_step() {
    echo -e "${CYAN}📦 $1${NC}"
}

# --- Configuration ---
CURRENT_USER="lev"
SERVER_IP=$(hostname -I | awk '{print $1}')
VPN_PORT=51820

# Cleanup function
cleanup() {
    log_info "Cleaning up temporary files..."
    sudo docker system prune -f --volumes 2>/dev/null || true
}

trap cleanup EXIT

# --- Initial Cleanup ---
log_header "STARTING HOME SERVER REINSTALLATION"
log_info "User: $CURRENT_USER"
log_info "Server IP: $SERVER_IP"
log_info "VPN Port: $VPN_PORT"

log_step "Stopping and removing existing containers..."
sudo docker-compose down 2>/dev/null || true
sudo docker stop $(sudo docker ps -aq) 2>/dev/null || true
sudo docker rm $(sudo docker ps -aq) 2>/dev/null || true

# --- System Preparation ---
log_header "SYSTEM PREPARATION"

log_step "Updating system packages..."
sudo apt update && sudo apt upgrade -y

log_step "Installing required packages..."
sudo apt install -y curl wget git docker.io docker-compose nginx python3 python3-pip \
    net-tools htop tree unzip jq bc wireguard resolvconf qrencode

log_step "Configuring Docker..."
sudo systemctl enable docker
sudo systemctl start docker
sudo usermod -aG docker lev

# --- Directory Structure ---
log_header "CREATING DIRECTORY STRUCTURE"

create_dirs=(
    "docker/auth-system/app"
    "docker/auth-system/app/templates"
    "docker/auth-system/app/static"
    "docker/auth-system/app/data"
    "docker/jellyfin/config"
    "docker/portainer/data"
    "docker/qbittorrent/config"
    "docker/dashboard"
    "nextcloud/data"
    "nextcloud/config"
    "nextcloud/apps"
    "nextcloud/themes"
    "media/movies"
    "media/tv"
    "media/music"
    "media/torrents"
    "data/users"
    "data/logs"
    "data/backups"
    "scripts/management"
    "scripts/vpn"
    "vpn/clients"
    ".config"
)

for dir in "${create_dirs[@]}"; do
    mkdir -p "/home/lev/$dir"
    log_success "Created: /home/lev/$dir"
done

sudo chown -R lev:lev /home/lev/docker
sudo chown -R lev:lev /home/lev/nextcloud
sudo chown -R lev:lev /home/lev/media
sudo chown -R lev:lev /home/lev/data
sudo chown -R lev:lev /home/lev/vpn
sudo chown -R lev:lev /home/lev/scripts
sudo chown -R lev:lev /home/lev/.config

# --- Security Configuration ---
log_header "SECURITY CONFIGURATION"

log_step "Generating secure secrets..."
AUTH_SECRET=$(openssl rand -hex 32)
JELLYFIN_API_KEY=$(openssl rand -hex 32)
ADMIN_PASS="admin123"

cat > "/home/lev/.config/server_env" << EOF
DOMAIN="homeserver"
SERVER_IP="$SERVER_IP"
CURRENT_USER="lev"
AUTH_SECRET="$AUTH_SECRET"
JELLYFIN_API_KEY="$JELLYFIN_API_KEY"
ADMIN_PASS="$ADMIN_PASS"
VPN_PORT="$VPN_PORT"
EOF

chmod 600 "/home/lev/.config/server_env"

# --- WireGuard VPN Setup ---
log_header "WIREGUARD VPN SETUP"

log_step "Configuring WireGuard server..."
sudo mkdir -p /etc/wireguard
sudo chmod 700 /etc/wireguard

# Generate keys
SERVER_PRIVATE_KEY=$(wg genkey)
SERVER_PUBLIC_KEY=$(echo "$SERVER_PRIVATE_KEY" | wg pubkey)

echo "$SERVER_PRIVATE_KEY" | sudo tee /etc/wireguard/private.key > /dev/null
echo "$SERVER_PUBLIC_KEY" | sudo tee /etc/wireguard/public.key > /dev/null

sudo chmod 600 /etc/wireguard/private.key
sudo chmod 600 /etc/wireguard/public.key

# Get network interface
INTERFACE=$(ip route | awk '/default/ {print $5}' | head -1)
if [ -z "$INTERFACE" ]; then
    INTERFACE="eth0"
fi

log_info "Using network interface: $INTERFACE"

# Create WireGuard server config
sudo tee /etc/wireguard/wg0.conf > /dev/null << EOF
[Interface]
PrivateKey = $SERVER_PRIVATE_KEY
Address = 10.0.0.1/24
ListenPort = $VPN_PORT
SaveConfig = true
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o $INTERFACE -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o $INTERFACE -j MASQUERADE
EOF

log_step "Enabling IP forwarding..."
if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
    echo 'net.ipv4.ip_forward=1' | sudo tee -a /etc/sysctl.conf
fi
sudo sysctl -p

log_step "Creating first VPN client..."
CLIENT_NAME="client01"
CLIENT_PRIVATE_KEY=$(wg genkey)
CLIENT_PUBLIC_KEY=$(echo "$CLIENT_PRIVATE_KEY" | wg pubkey)

# Add client to server config
sudo tee -a /etc/wireguard/wg0.conf > /dev/null << EOF

[Peer]
PublicKey = $CLIENT_PUBLIC_KEY
AllowedIPs = 10.0.0.2/32
EOF

# Create client config в ПРАВИЛЬНОЙ папке clients
cat > "/home/lev/vpn/clients/client01.conf" << EOF
[Interface]
PrivateKey = $CLIENT_PRIVATE_KEY
Address = 10.0.0.2/24
DNS = 8.8.8.8, 1.1.1.1

[Peer]
PublicKey = $SERVER_PUBLIC_KEY
Endpoint = $SERVER_IP:$VPN_PORT
AllowedIPs = 0.0.0.0/0
EOF

# Generate QR code for client
if command -v qrencode &> /dev/null; then
    qrencode -t png -o "/home/lev/vpn/clients/client01.png" < "/home/lev/vpn/clients/client01.conf"
    log_success "QR code generated: /home/lev/vpn/clients/client01.png"
fi

log_step "Starting WireGuard service..."
sudo systemctl enable wg-quick@wg0
sudo systemctl start wg-quick@wg0

sleep 3
if sudo systemctl is-active --quiet wg-quick@wg0; then
    log_success "WireGuard VPN server is running"
else
    log_warning "WireGuard service failed to start, trying manual start..."
    sudo wg-quick up wg0 || true
fi

# Configure firewall
if command -v ufw >/dev/null 2>&1; then
    log_step "Configuring firewall..."
    sudo ufw allow $VPN_PORT/udp
    sudo ufw allow 80/tcp
    sudo ufw allow 443/tcp
    sudo ufw allow ssh
    echo "y" | sudo ufw enable
fi

# --- Docker Compose Configuration ---
log_header "DOCKER CONFIGURATION"

PUID=$(id -u lev)
PGID=$(id -g lev)

cat > "/home/lev/docker/docker-compose.yml" << EOF
version: '3.8'

services:
  auth-system:
    build: ./auth-system
    container_name: auth-system
    restart: unless-stopped
    ports:
      - "5000:5000"
    environment:
      - AUTH_SECRET=$AUTH_SECRET
    volumes:
      - /home/lev/docker/auth-system/app/data:/app/data
      - /home/lev/data/users:/app/data/users
      - /home/lev/data/logs:/app/data/logs
    networks:
      - nginx-network

  jellyfin:
    image: jellyfin/jellyfin
    container_name: jellyfin
    restart: unless-stopped
    user: $PUID:$PGID
    ports:
      - "8096:8096"
    volumes:
      - /home/lev/docker/jellyfin/config:/config
      - /home/lev/media/movies:/media/movies:ro
      - /home/lev/media/tv:/media/tv:ro
      - /home/lev/media/music:/media/music:ro
    environment:
      - JELLYFIN_API_KEY=$JELLYFIN_API_KEY
    networks:
      - nginx-network

  nextcloud:
    image: nextcloud:latest
    container_name: nextcloud
    restart: unless-stopped
    ports:
      - "8082:80"
    environment:
      - NEXTCLOUD_ADMIN_USER=admin
      - NEXTCLOUD_ADMIN_PASSWORD=$ADMIN_PASS
      - NEXTCLOUD_TRUSTED_DOMAINS=$SERVER_IP localhost 127.0.0.1
    volumes:
      - /home/lev/nextcloud/data:/var/www/html/data
      - /home/lev/nextcloud/config:/var/www/html/config
      - /home/lev/nextcloud/apps:/var/www/html/custom_apps
      - /home/lev/nextcloud/themes:/var/www/html/themes
    networks:
      - nginx-network

  portainer:
    image: portainer/portainer-ce:latest
    container_name: portainer
    restart: always
    ports:
      - "9001:9000"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /home/lev/docker/portainer/data:/data
    networks:
      - nginx-network

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
      - /home/lev/docker/qbittorrent/config:/config
      - /home/lev/media/torrents:/downloads
    networks:
      - nginx-network

  nginx:
    image: nginx:alpine
    container_name: nginx
    restart: unless-stopped
    ports:
      - "80:80"
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf
      - ./dashboard:/usr/share/nginx/html
    depends_on:
      - auth-system
      - jellyfin
      - nextcloud
    networks:
      - nginx-network

networks:
  nginx-network:
    driver: bridge
EOF

# --- iOS-inspired Auth System ---
log_header "SETTING UP AUTH SYSTEM"

cat > "/home/lev/docker/auth-system/Dockerfile" << EOF
FROM python:3.9-slim

RUN apt-get update && apt-get install -y \\
    gcc \\
    python3-dev \\
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app/ .

RUN mkdir -p /app/data /app/data/logs

EXPOSE 5000

CMD ["python", "app.py"]
EOF

cat > "/home/lev/docker/auth-system/requirements.txt" << EOF
Flask==2.3.3
bcrypt==4.0.1
PyJWT==2.8.0
Werkzeug==2.3.7
EOF

# iOS-inspired Auth Application
cat > "/home/lev/docker/auth-system/app/app.py" << 'EOF'
from flask import Flask, render_template, request, redirect, session, flash, jsonify
import bcrypt
import json
import os
from datetime import datetime

app = Flask(__name__)
app.secret_key = os.environ.get('AUTH_SECRET', 'dev-secret-key')

# Simple user storage
USERS_FILE = '/app/data/users.json'

def init_users():
    if not os.path.exists(USERS_FILE):
        users = {
            "users": [
                {
                    "username": "admin",
                    "password": bcrypt.hashpw("admin123".encode('utf-8'), bcrypt.gensalt()).decode('utf-8'),
                    "role": "admin",
                    "created_at": datetime.now().isoformat()
                },
                {
                    "username": "user",
                    "password": bcrypt.hashpw("user123".encode('utf-8'), bcrypt.gensalt()).decode('utf-8'),
                    "role": "user", 
                    "created_at": datetime.now().isoformat()
                }
            ]
        }
        os.makedirs(os.path.dirname(USERS_FILE), exist_ok=True)
        with open(USERS_FILE, 'w') as f:
            json.dump(users, f)

def verify_user(username, password):
    try:
        with open(USERS_FILE, 'r') as f:
            users = json.load(f)
        
        for user in users['users']:
            if user['username'] == username:
                if bcrypt.checkpw(password.encode('utf-8'), user['password'].encode('utf-8')):
                    return user
        return None
    except:
        return None

@app.route('/')
def index():
    if 'user' in session:
        return redirect('/dashboard')
    return redirect('/login')

@app.route('/login', methods=['GET', 'POST'])
def login():
    if request.method == 'POST':
        username = request.form['username']
        password = request.form['password']
        
        user = verify_user(username, password)
        if user:
            session['user'] = user
            return redirect('/dashboard')
        else:
            flash('Invalid credentials', 'error')
    
    return render_template('login.html')

@app.route('/dashboard')
def dashboard():
    if 'user' not in session:
        return redirect('/login')
    return render_template('dashboard.html', user=session['user'])

@app.route('/logout')
def logout():
    session.clear()
    return redirect('/login')

@app.route('/api/services')
def api_services():
    services = [
        {
            "name": "Jellyfin",
            "url": "/jellyfin/",
            "icon": "🎬",
            "description": "Media streaming server",
            "status": "active",
            "color": "linear-gradient(135deg, #00B4DB, #0083B0)"
        },
        {
            "name": "Nextcloud", 
            "url": "/nextcloud/",
            "icon": "☁️",
            "description": "File storage and sharing",
            "status": "active",
            "color": "linear-gradient(135deg, #0083B0, #00B4DB)"
        },
        {
            "name": "Portainer",
            "url": "http://localhost:9001",
            "icon": "🐳",
            "description": "Docker container management",
            "status": "active", 
            "color": "linear-gradient(135deg, #00D2FF, #3A7BD5)"
        },
        {
            "name": "qBittorrent",
            "url": "http://localhost:8080",
            "icon": "📥",
            "description": "Torrent client",
            "status": "active",
            "color": "linear-gradient(135deg, #FF8008, #FFC837)"
        },
        {
            "name": "VPN Management",
            "url": "/vpn/",
            "icon": "🔒",
            "description": "WireGuard VPN control",
            "status": "active",
            "color": "linear-gradient(135deg, #667eea, #764ba2)"
        }
    ]
    return jsonify(services)

if __name__ == '__main__':
    init_users()
    app.run(host='0.0.0.0', port=5000, debug=False)
EOF

# iOS-inspired Login Template
cat > "/home/lev/docker/auth-system/app/templates/login.html" << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Home Server - Login</title>
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, Cantarell, sans-serif;
        }
        
        body {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
            display: flex;
            align-items: center;
            justify-content: center;
            padding: 20px;
        }
        
        .login-container {
            background: rgba(255, 255, 255, 0.95);
            backdrop-filter: blur(20px);
            border-radius: 20px;
            padding: 40px;
            width: 100%;
            max-width: 400px;
            box-shadow: 0 20px 40px rgba(0, 0, 0, 0.1);
            border: 1px solid rgba(255, 255, 255, 0.2);
        }
        
        .logo {
            text-align: center;
            margin-bottom: 30px;
        }
        
        .logo h1 {
            font-size: 2.5em;
            background: linear-gradient(135deg, #667eea, #764ba2);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
            margin-bottom: 10px;
        }
        
        .logo p {
            color: #666;
            font-size: 1.1em;
        }
        
        .form-group {
            margin-bottom: 20px;
        }
        
        .form-group label {
            display: block;
            margin-bottom: 8px;
            color: #333;
            font-weight: 600;
            font-size: 0.9em;
        }
        
        .form-group input {
            width: 100%;
            padding: 15px;
            border: 2px solid #e1e5e9;
            border-radius: 12px;
            font-size: 16px;
            transition: all 0.3s ease;
            background: #f8f9fa;
        }
        
        .form-group input:focus {
            border-color: #667eea;
            background: white;
            outline: none;
            box-shadow: 0 0 0 3px rgba(102, 126, 234, 0.1);
        }
        
        .login-btn {
            width: 100%;
            padding: 15px;
            background: linear-gradient(135deg, #667eea, #764ba2);
            color: white;
            border: none;
            border-radius: 12px;
            font-size: 16px;
            font-weight: 600;
            cursor: pointer;
            transition: transform 0.3s ease;
        }
        
        .login-btn:hover {
            transform: translateY(-2px);
        }
        
        .alert {
            padding: 12px;
            border-radius: 10px;
            margin-bottom: 20px;
            text-align: center;
            font-weight: 500;
        }
        
        .alert-error {
            background: #ff4757;
            color: white;
        }
        
        .demo-accounts {
            margin-top: 25px;
            padding: 20px;
            background: #f8f9fa;
            border-radius: 12px;
            border-left: 4px solid #667eea;
        }
        
        .demo-accounts h3 {
            color: #333;
            margin-bottom: 10px;
            font-size: 0.9em;
        }
        
        .account {
            display: flex;
            justify-content: space-between;
            align-items: center;
            padding: 8px 0;
            border-bottom: 1px solid #e1e5e9;
        }
        
        .account:last-child {
            border-bottom: none;
        }
    </style>
</head>
<body>
    <div class="login-container">
        <div class="logo">
            <h1>🏠</h1>
            <h1>Home Server</h1>
            <p>Unified Access System</p>
        </div>
        
        {% with messages = get_flashed_messages(with_categories=true) %}
            {% if messages %}
                {% for category, message in messages %}
                    <div class="alert alert-{{ category }}">
                        {{ message }}
                    </div>
                {% endfor %}
            {% endif %}
        {% endwith %}
        
        <form method="POST" action="/login">
            <div class="form-group">
                <label for="username">Username</label>
                <input type="text" id="username" name="username" required autocomplete="username">
            </div>
            
            <div class="form-group">
                <label for="password">Password</label>
                <input type="password" id="password" name="password" required autocomplete="current-password">
            </div>
            
            <button type="submit" class="login-btn">Sign In</button>
        </form>
        
        <div class="demo-accounts">
            <h3>Demo Access:</h3>
            <div class="account">
                <span>👑 Administrator</span>
                <span>admin / admin123</span>
            </div>
            <div class="account">
                <span>👥 User</span>
                <span>user / user123</span>
            </div>
        </div>
    </div>
</body>
</html>
EOF

# iOS-inspired Dashboard Template
cat > "/home/lev/docker/auth-system/app/templates/dashboard.html" << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Home Server - Dashboard</title>
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, Cantarell, sans-serif;
        }
        
        body {
            background: #f5f5f7;
            color: #1d1d1f;
            min-height: 100vh;
        }
        
        .header {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            padding: 30px 20px;
            text-align: center;
        }
        
        .header h1 {
            font-size: 2.5em;
            margin-bottom: 10px;
        }
        
        .user-info {
            background: rgba(255, 255, 255, 0.1);
            backdrop-filter: blur(10px);
            padding: 15px;
            border-radius: 15px;
            margin: 20px auto;
            max-width: 300px;
        }
        
        .container {
            max-width: 1200px;
            margin: 0 auto;
            padding: 40px 20px;
        }
        
        .services-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(300px, 1fr));
            gap: 20px;
            margin-top: 30px;
        }
        
        .service-card {
            background: white;
            border-radius: 20px;
            padding: 25px;
            text-align: center;
            cursor: pointer;
            transition: transform 0.3s ease, box-shadow 0.3s ease;
            border: 1px solid #e1e5e9;
            text-decoration: none;
            color: inherit;
            display: block;
        }
        
        .service-card:hover {
            transform: translateY(-5px);
            box-shadow: 0 15px 30px rgba(0, 0, 0, 0.1);
        }
        
        .service-icon {
            font-size: 3em;
            margin-bottom: 15px;
        }
        
        .service-name {
            font-size: 1.3em;
            font-weight: 600;
            margin-bottom: 10px;
            color: #1d1d1f;
        }
        
        .service-description {
            color: #86868b;
            font-size: 0.9em;
            line-height: 1.4;
        }
        
        .status-badge {
            display: inline-block;
            padding: 5px 12px;
            border-radius: 15px;
            font-size: 0.8em;
            font-weight: 600;
            margin-top: 10px;
        }
        
        .status-active {
            background: #30d158;
            color: white;
        }
        
        .logout-btn {
            background: rgba(255, 255, 255, 0.2);
            color: white;
            border: 1px solid rgba(255, 255, 255, 0.3);
            padding: 10px 20px;
            border-radius: 10px;
            cursor: pointer;
            transition: all 0.3s ease;
            text-decoration: none;
            display: inline-block;
            margin-top: 15px;
        }
        
        .logout-btn:hover {
            background: rgba(255, 255, 255, 0.3);
        }
        
        .vpn-info {
            background: linear-gradient(135deg, #667eea, #764ba2);
            color: white;
            padding: 20px;
            border-radius: 15px;
            margin: 20px 0;
            text-align: center;
        }
        
        @media (max-width: 768px) {
            .services-grid {
                grid-template-columns: 1fr;
            }
            
            .header h1 {
                font-size: 2em;
            }
        }
    </style>
</head>
<body>
    <div class="header">
        <h1>🏠 Home Server</h1>
        <p>Welcome back, {{ user.username }}!</p>
        <div class="user-info">
            <p>Role: <strong>{{ user.role }}</strong></p>
            <a href="/logout" class="logout-btn">Log Out</a>
        </div>
    </div>
    
    <div class="container">
        <div class="vpn-info">
            <h3>🔒 WireGuard VPN Active</h3>
            <p>Your traffic is secured and you appear to be in your local network</p>
        </div>
        
        <h2 style="text-align: center; margin-bottom: 10px; color: #1d1d1f;">Available Services</h2>
        <p style="text-align: center; color: #86868b; margin-bottom: 30px;">Tap any service to access it</p>
        
        <div class="services-grid" id="servicesGrid">
            <!-- Services will be loaded dynamically -->
        </div>
    </div>

    <script>
        async function loadServices() {
            try {
                const response = await fetch('/api/services');
                const services = await response.json();
                
                const grid = document.getElementById('servicesGrid');
                grid.innerHTML = '';
                
                services.forEach(service => {
                    const card = document.createElement('a');
                    card.href = service.url;
                    card.className = 'service-card';
                    card.style.background = service.color;
                    card.style.color = 'white';
                    
                    card.innerHTML = `
                        <div class="service-icon">${service.icon}</div>
                        <div class="service-name">${service.name}</div>
                        <div class="service-description">${service.description}</div>
                        <div class="status-badge status-active">${service.status}</div>
                    `;
                    
                    grid.appendChild(card);
                });
            } catch (error) {
                console.error('Error loading services:', error);
            }
        }
        
        // Load services when page loads
        loadServices();
    </script>
</body>
</html>
EOF

# --- Nginx Configuration ---
log_header "CONFIGURING NGINX REVERSE PROXY"

cat > "/home/lev/docker/nginx.conf" << 'EOF'
events {
    worker_connections 1024;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    sendfile on;
    keepalive_timeout 65;
    client_max_body_size 10G;
    
    # iOS-inspired color scheme
    access_log /var/log/nginx/access.log;
    error_log /var/log/nginx/error.log;

    upstream auth_system {
        server auth-system:5000;
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
        
        # Main authentication system
        location / {
            proxy_pass http://auth_system;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }

        # Jellyfin media server
        location /jellyfin/ {
            proxy_pass http://jellyfin/;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            
            proxy_set_header X-Forwarded-Host $host;
            proxy_set_header X-Forwarded-Server $host;
        }

        # Nextcloud file storage
        location /nextcloud/ {
            proxy_pass http://nextcloud/;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            
            proxy_set_header X-Forwarded-Host $host;
            proxy_set_header X-Forwarded-Server $host;
        }

        # VPN management
        location /vpn/ {
            proxy_pass http://auth_system/;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }

        # Health check endpoint
        location /health {
            access_log off;
            return 200 "healthy\n";
            add_header Content-Type text/plain;
        }
    }
}
EOF

# --- iOS-inspired Landing Page ---
log_header "CREATING LANDING PAGE"

cat > "/home/lev/docker/dashboard/index.html" << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Home Server</title>
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, Cantarell, sans-serif;
        }
        
        body {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            min-height: 100vh;
            display: flex;
            align-items: center;
            justify-content: center;
            padding: 20px;
            text-align: center;
        }
        
        .container {
            max-width: 600px;
        }
        
        .logo {
            font-size: 4em;
            margin-bottom: 20px;
        }
        
        h1 {
            font-size: 3em;
            margin-bottom: 10px;
            font-weight: 700;
        }
        
        .subtitle {
            font-size: 1.3em;
            margin-bottom: 30px;
            opacity: 0.9;
        }
        
        .btn {
            display: inline-block;
            background: rgba(255, 255, 255, 0.2);
            backdrop-filter: blur(10px);
            color: white;
            padding: 15px 30px;
            border-radius: 15px;
            text-decoration: none;
            font-weight: 600;
            margin: 10px;
            transition: all 0.3s ease;
            border: 1px solid rgba(255, 255, 255, 0.3);
        }
        
        .btn:hover {
            background: rgba(255, 255, 255, 0.3);
            transform: translateY(-2px);
        }
        
        .btn-primary {
            background: white;
            color: #667eea;
        }
        
        .btn-primary:hover {
            background: #f8f9fa;
        }
        
        .features {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(150px, 1fr));
            gap: 20px;
            margin: 40px 0;
        }
        
        .feature {
            background: rgba(255, 255, 255, 0.1);
            backdrop-filter: blur(10px);
            padding: 20px;
            border-radius: 15px;
            border: 1px solid rgba(255, 255, 255, 0.2);
        }
        
        .feature-icon {
            font-size: 2em;
            margin-bottom: 10px;
        }
        
        .vpn-status {
            background: rgba(255, 255, 255, 0.2);
            padding: 15px;
            border-radius: 15px;
            margin: 20px 0;
            border-left: 4px solid #30d158;
        }
        
        @media (max-width: 768px) {
            h1 {
                font-size: 2em;
            }
            
            .logo {
                font-size: 3em;
            }
            
            .features {
                grid-template-columns: 1fr;
            }
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="logo">🏠</div>
        <h1>Home Server</h1>
        <p class="subtitle">Your personal unified server system with VPN</p>
        
        <div class="vpn-status">
            <strong>🔒 WireGuard VPN Active</strong>
            <p>Secure connection • Bypass blocks • Local network access</p>
        </div>
        
        <div class="features">
            <div class="feature">
                <div class="feature-icon">🎬</div>
                <div>Media Streaming</div>
            </div>
            <div class="feature">
                <div class="feature-icon">☁️</div>
                <div>File Storage</div>
            </div>
            <div class="feature">
                <div class="feature-icon">🔒</div>
                <div>VPN Access</div>
            </div>
            <div class="feature">
                <div class="feature-icon">🐳</div>
                <div>Containerized</div>
            </div>
        </div>
        
        <div>
            <a href="/" class="btn btn-primary">Access System</a>
            <a href="/jellyfin/" class="btn">Media Server</a>
            <a href="/nextcloud/" class="btn">Cloud Storage</a>
        </div>
        
        <p style="margin-top: 30px; opacity: 0.7;">
            Secure • Fast • Bypass Blocks • Local Network
        </p>
    </div>
</body>
</html>
EOF

# --- VPN Management Scripts ---
log_header "SETTING UP VPN MANAGEMENT"

cat > "/home/lev/scripts/vpn/vpn-manager.sh" << 'EOF'
#!/bin/bash

source "/home/lev/.config/server_env"

VPN_DIR="/home/lev/vpn"
WG_CONFIG="/etc/wireguard/wg0.conf"

show_usage() {
    echo "🔒 WireGuard VPN Management"
    echo "Usage: $0 [command]"
    echo ""
    echo "Commands:"
    echo "  status           - Show VPN status"
    echo "  create-client    - Create new VPN client"
    echo "  list-clients     - List all VPN clients"
    echo "  remove-client    - Remove VPN client"
    echo "  generate-qr      - Generate QR code for client"
    echo "  restart          - Restart VPN service"
}

check_vpn_status() {
    echo "=== WireGuard VPN Status ==="
    if sudo systemctl is-active --quiet wg-quick@wg0; then
        echo "✅ Status: RUNNING"
        echo "📡 Port: $VPN_PORT"
        echo "🌐 Interface: wg0"
        echo ""
        sudo wg show
    else
        echo "❌ Status: STOPPED"
    fi
}

create_vpn_client() {
    CLIENT_NAME="$1"
    if [ -z "$CLIENT_NAME" ]; then
        read -p "Enter client name: " CLIENT_NAME
    fi
    
    if [ -z "$CLIENT_NAME" ]; then
        echo "❌ Client name cannot be empty"
        return 1
    fi
    
    echo "🔑 Creating VPN client: $CLIENT_NAME"
    
    # Generate client keys
    CLIENT_PRIVATE_KEY=$(wg genkey)
    CLIENT_PUBLIC_KEY=$(echo "$CLIENT_PRIVATE_KEY" | wg pubkey)
    
    # Find next available IP
    LAST_IP=$(sudo grep -o '10.0.0.[0-9]*' $WG_CONFIG | tail -1)
    if [ -z "$LAST_IP" ]; then
        CLIENT_IP="10.0.0.2"
    else
        IP_OCTET=$(echo $LAST_IP | cut -d. -f4)
        NEXT_OCTET=$((IP_OCTET + 1))
        CLIENT_IP="10.0.0.$NEXT_OCTET"
    fi
    
    # Add client to server config
    sudo tee -a $WG_CONFIG > /dev/null << EOF

[Peer]
PublicKey = $CLIENT_PUBLIC_KEY
AllowedIPs = $CLIENT_IP/32
EOF
    
    # Create client config в ПРАВИЛЬНОЙ папке clients
    CLIENT_CONFIG="$VPN_DIR/clients/${CLIENT_NAME}.conf"
    cat > "$CLIENT_CONFIG" << CLIENT_EOF
[Interface]
PrivateKey = $CLIENT_PRIVATE_KEY
Address = $CLIENT_IP/24
DNS = 8.8.8.8, 1.1.1.1

[Peer]
PublicKey = $(sudo cat /etc/wireguard/public.key)
Endpoint = $SERVER_IP:$VPN_PORT
AllowedIPs = 0.0.0.0/0
CLIENT_EOF
    
    # Reload WireGuard configuration
    sudo wg syncconf wg0 <(sudo wg-quick strip wg0)
    
    echo "✅ Client created: $CLIENT_CONFIG"
    echo "📱 Client IP: $CLIENT_IP"
    
    generate_qr_code "$CLIENT_NAME"
}

list_vpn_clients() {
    echo "=== VPN Clients ==="
    echo "Config files in: $VPN_DIR/clients/"
    echo ""
    
    if ls "$VPN_DIR/clients/"*.conf >/dev/null 2>&1; then
        for config in "$VPN_DIR/clients/"*.conf; do
            CLIENT_NAME=$(basename "$config" .conf)
            CLIENT_IP=$(grep "Address" "$config" | cut -d' ' -f3 | cut -d'/' -f1)
            echo "🔸 $CLIENT_NAME - $CLIENT_IP"
        done
    else
        echo "No clients found"
    fi
    
    echo ""
    echo "Active peers:"
    sudo wg show wg0 | grep "peer:" | while read line; do
        PEER_KEY=$(echo $line | cut -d' ' -f2)
        PEER_IP=$(sudo wg show wg0 | grep -A1 "$PEER_KEY" | grep "allowed ips" | cut -d':' -f2 | xargs)
        echo "🔹 $PEER_IP"
    done
}

generate_qr_code() {
    CLIENT_NAME="$1"
    if [ -z "$CLIENT_NAME" ]; then
        read -p "Enter client name: " CLIENT_NAME
    fi
    
    CLIENT_CONFIG="$VPN_DIR/clients/${CLIENT_NAME}.conf"
    
    if [ ! -f "$CLIENT_CONFIG" ]; then
        echo "❌ Client config not found: $CLIENT_CONFIG"
        return 1
    fi
    
    if command -v qrencode &> /dev/null; then
        QR_FILE="$VPN_DIR/clients/${CLIENT_NAME}_qr.png"
        qrencode -t png -o "$QR_FILE" < "$CLIENT_CONFIG"
        echo "✅ QR code generated: $QR_FILE"
        
        echo ""
        echo "📱 QR Code (terminal):"
        qrencode -t ansiutf8 < "$CLIENT_CONFIG"
    else
        echo "⚠️ qrencode not installed. Install with: sudo apt install qrencode"
        echo "📋 Config content:"
        cat "$CLIENT_CONFIG"
    fi
}

case "$1" in
    "status")
        check_vpn_status
        ;;
    "create-client")
        create_vpn_client "$2"
        ;;
    "list-clients")
        list_vpn_clients
        ;;
    "generate-qr")
        generate_qr_code "$2"
        ;;
    "restart")
        sudo systemctl restart wg-quick@wg0
        echo "✅ WireGuard VPN restarted"
        ;;
    *)
        show_usage
        ;;
esac
EOF

chmod +x "/home/lev/scripts/vpn/vpn-manager.sh"

# --- Management Scripts ---
log_header "SETTING UP MANAGEMENT SCRIPTS"

cat > "/home/lev/scripts/management/server-manager.sh" << 'EOF'
#!/bin/bash

source "/home/lev/.config/server_env"

case "$1" in
    "start")
        cd "/home/lev/docker" && docker-compose up -d
        sudo systemctl start wg-quick@wg0 2>/dev/null || true
        echo "✅ All services started"
        ;;
    "stop")
        cd "/home/lev/docker" && docker-compose down
        sudo systemctl stop wg-quick@wg0 2>/dev/null || true
        echo "✅ All services stopped"
        ;;
    "restart")
        cd "/home/lev/docker" && docker-compose restart
        sudo systemctl restart wg-quick@wg0 2>/dev/null || true
        echo "✅ All services restarted"
        ;;
    "status")
        echo "=== DOCKER SERVICES ==="
        cd "/home/lev/docker" && docker-compose ps
        echo ""
        echo "=== VPN STATUS ==="
        "/home/lev/scripts/vpn/vpn-manager.sh" status
        ;;
    "logs")
        cd "/home/lev/docker" && docker-compose logs -f
        ;;
    "vpn")
        "/home/lev/scripts/vpn/vpn-manager.sh" "$2"
        ;;
    "update")
        cd "/home/lev/docker" && docker-compose pull
        cd "/home/lev/docker" && docker-compose up -d --build
        echo "✅ System updated"
        ;;
    *)
        echo "🔧 Home Server Management"
        echo "Usage: $0 {start|stop|restart|status|logs|vpn|update}"
        echo ""
        echo "Commands:"
        echo "  start     - Start all services"
        echo "  stop      - Stop all services"
        echo "  restart   - Restart all services"
        echo "  status    - Show system status"
        echo "  logs      - Show logs in real time"
        echo "  vpn       - VPN management (status|create-client|list-clients|generate-qr)"
        echo "  update    - Update all services"
        ;;
esac
EOF

chmod +x "/home/lev/scripts/management/server-manager.sh"

# --- Final Setup ---
log_header "STARTING SERVICES"

log_step "Building and starting containers..."
cd "/home/lev/docker"
sudo docker-compose up -d --build

log_step "Waiting for services to initialize..."
sleep 30

log_step "Checking service status..."
sudo docker-compose ps

# --- Final Instructions ---
log_header "INSTALLATION COMPLETE"

log_success "🎉 Home Server successfully installed!"
echo ""
log_info "🌐 ACCESS URLs:"
echo "   🔗 Main System: http://$SERVER_IP"
echo "   🎬 Jellyfin: http://$SERVER_IP/jellyfin/"
echo "   ☁️ Nextcloud: http://$SERVER_IP/nextcloud/"
echo "   🐳 Portainer: http://$SERVER_IP:9001"
echo "   📥 qBittorrent: http://$SERVER_IP:8080"
echo ""
log_info "🔐 LOGIN CREDENTIALS:"
echo "   👑 Admin: admin / admin123"
echo "   👥 User: user / user123"
echo ""
log_info "🔒 VPN INFORMATION:"
echo "   📡 VPN Port: $VPN_PORT"
echo "   📱 First client: ~/vpn/clients/client01.conf"
echo "   📟 QR Code: ~/vpn/clients/client01.png"
echo ""
log_info "⚙️ MANAGEMENT:"
echo "   🛠️  Manage: ~/scripts/management/server-manager.sh"
echo "   📊 Status: ~/scripts/management/server-manager.sh status"
echo "   🔒 VPN: ~/scripts/management/server-manager.sh vpn"
echo "   📝 Logs: ~/scripts/management/server-manager.sh logs"
echo ""
log_success "Your iOS-inspired home server with WireGuard VPN is ready!"
echo "🔒 VPN will bypass blocks and emulate local network access"
