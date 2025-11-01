# Создаем w.sh скрипт для настройки WireGuard
cat > ~/w.sh << 'W_EOF'
#!/bin/bash
# WireGuard Auto-Setup Script
# GitHub: https://github.com/levgh/serverins/tree/main/wireguard

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    error "Please run as root or with sudo"
    exit 1
fi

# Configuration
WG_PORT=51820
WG_NETWORK="10.8.0.0/24"
WG_CONFIG="/etc/wireguard/wg0.conf"
CLIENTS_DIR="$HOME/wireguard-clients"
SCRIPTS_DIR="$HOME/scripts/wireguard"

install_wireguard() {
    log "Installing WireGuard..."
    apt update
    apt install -y wireguard resolvconf qrencode
    
    # Enable kernel module
    modprobe wireguard
    
    log "WireGuard installed successfully"
}

configure_server() {
    log "Configuring WireGuard server..."
    
    # Generate server keys
    SERVER_PRIVATE_KEY=$(wg genkey)
    SERVER_PUBLIC_KEY=$(echo $SERVER_PRIVATE_KEY | wg pubkey)
    
    # Create server config
    cat > $WG_CONFIG << SERVER_EOF
[Interface]
PrivateKey = $SERVER_PRIVATE_KEY
Address = 10.8.0.1/24
ListenPort = $WG_PORT
SaveConfig = true

# Enable forwarding and NAT
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

# DNS for bypassing restrictions
PostUp = sysctl -w net.ipv4.ip_forward=1
PostUp = echo "nameserver 8.8.8.8" > /etc/resolv.conf; echo "nameserver 1.1.1.1" >> /etc/resolv.conf
SERVER_EOF

    # Enable IP forwarding permanently
    echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
    sysctl -p
    
    log "WireGuard server configured"
}

setup_firewall() {
    log "Configuring firewall..."
    
    # Install UFW if not present
    if ! command -v ufw &> /dev/null; then
        apt install -y ufw
    fi
    
    ufw allow $WG_PORT/udp comment 'WireGuard VPN'
    ufw allow ssh comment 'SSH Access'
    
    # Enable UFW if not enabled
    if ! ufw status | grep -q "Status: active"; then
        echo "y" | ufw enable
    fi
    
    log "Firewall configured"
}

create_management_scripts() {
    log "Creating management scripts..."
    
    mkdir -p $SCRIPTS_DIR
    mkdir -p $CLIENTS_DIR
    
    # Create client management script
    cat > $SCRIPTS_DIR/create_client.sh << 'CLIENT_EOF'
#!/bin/bash

CLIENT_NAME=$1

if [ -z "$CLIENT_NAME" ]; then
    echo "Usage: $0 <client_name>"
    exit 1
fi

# Generate keys
CLIENT_PRIVATE_KEY=$(wg genkey)
CLIENT_PUBLIC_KEY=$(echo $CLIENT_PRIVATE_KEY | wg pubkey)

# Find next available IP
LAST_IP=$(grep -o '10.8.0.[0-9]*' /etc/wireguard/wg0.conf | tail -1)
if [ -z "$LAST_IP" ]; then
    CLIENT_IP="10.8.0.2"
else
    IP_NUM=$(echo $LAST_IP | awk -F. '{print $4}')
    CLIENT_IP="10.8.0.$((IP_NUM + 1))"
fi

# Add client to server config
cat >> /etc/wireguard/wg0.conf << EOF

# Client: $CLIENT_NAME
[Peer]
PublicKey = $CLIENT_PUBLIC_KEY
AllowedIPs = $CLIENT_IP/32
EOF

# Get server data
SERVER_PUBLIC_KEY=$(grep 'PrivateKey' /etc/wireguard/wg0.conf | head -1 | awk '{print $3}' | wg pubkey)
SERVER_IP=$(curl -s http://checkip.amazonaws.com || hostname -I | awk '{print $1}')

# Create client config
cat > $HOME/wireguard-clients/${CLIENT_NAME}.conf << CLIENT_CONFIG
[Interface]
PrivateKey = $CLIENT_PRIVATE_KEY
Address = $CLIENT_IP/24
DNS = 8.8.8.8, 1.1.1.1

[Peer]
PublicKey = $SERVER_PUBLIC_KEY
Endpoint = $SERVER_IP:$WG_PORT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
CLIENT_CONFIG

# Reload WireGuard
systemctl restart wg-quick@wg0

echo "✅ Client $CLIENT_NAME created!"
echo "📁 Config: $HOME/wireguard-clients/${CLIENT_NAME}.conf"
echo "🌐 IP: $CLIENT_IP"
CLIENT_EOF

    # Create QR code script
    cat > $SCRIPTS_DIR/generate_qr.sh << 'QR_EOF'
#!/bin/bash

CLIENT_NAME=$1
CONFIG_FILE="$HOME/wireguard-clients/${CLIENT_NAME}.conf"

if [ -z "$CLIENT_NAME" ] || [ ! -f "$CONFIG_FILE" ]; then
    echo "Usage: $0 <client_name>"
    echo "Available clients:"
    ls $HOME/wireguard-clients/*.conf 2>/dev/null | xargs -n 1 basename | sed 's/.conf//' || echo "No clients found"
    exit 1
fi

if command -v qrencode >/dev/null 2>&1; then
    qrencode -t ansiutf8 < "$CONFIG_FILE"
    qrencode -t png -o "$HOME/wireguard-clients/${CLIENT_NAME}_qr.png" < "$CONFIG_FILE"
    echo "✅ QR code saved: $HOME/wireguard-clients/${CLIENT_NAME}_qr.png"
else
    echo "⚠️ Install qrencode: sudo apt install qrencode"
    echo "📋 Config: $CONFIG_FILE"
fi
QR_EOF

    chmod +x $SCRIPTS_DIR/create_client.sh
    chmod +x $SCRIPTS_DIR/generate_qr.sh
    
    log "Management scripts created"
}

start_service() {
    log "Starting WireGuard service..."
    
    systemctl enable wg-quick@wg0
    systemctl start wg-quick@wg0
    
    # Wait for service to start
    sleep 3
    
    if systemctl is-active --quiet wg-quick@wg0; then
        log "WireGuard service started successfully"
    else
        error "Failed to start WireGuard service"
        exit 1
    fi
}

create_test_client() {
    log "Creating test client..."
    $SCRIPTS_DIR/create_client.sh "test-client"
}

show_status() {
    log "=== WireGuard Status ==="
    wg show
    
    echo ""
    log "=== System Information ==="
    echo "🔧 Port: $WG_PORT/udp"
    echo "🌐 Network: $WG_NETWORK"
    echo "📁 Clients directory: $CLIENTS_DIR"
    echo "🔧 Scripts directory: $SCRIPTS_DIR"
    
    echo ""
    log "=== Usage Examples ==="
    echo "Create client: $SCRIPTS_DIR/create_client.sh <name>"
    echo "Generate QR: $SCRIPTS_DIR/generate_qr.sh <name>"
    echo "Show status: wg show"
    echo "Restart: systemctl restart wg-quick@wg0"
}

main() {
    log "Starting WireGuard Auto-Setup..."
    
    install_wireguard
    configure_server
    setup_firewall
    create_management_scripts
    start_service
    create_test_client
    show_status
    
    log "🎉 WireGuard setup completed successfully!"
    log "📖 Full documentation: https://github.com/levgh/serverins/tree/main/wireguard"
}

# Run main function
main
W_EOF

# Делаем скрипт исполняемым
chmod +x ~/w.sh

# Создаем README для GitHub
cat > ~/README_wireguard.md << 'README_EOF'
# WireGuard Auto-Setup Script

Automated WireGuard VPN server setup with client management.

## Features

- ✅ Automatic WireGuard installation
- ✅ Server configuration with NAT
- ✅ Firewall setup (UFW)
- ✅ Client management scripts
- ✅ QR code generation
- ✅ DNS for bypassing restrictions
- ✅ Full internet access for clients

## Quick Start

```bash
# Download and run
wget https://raw.githubusercontent.com/levgh/serverins/main/wireguard/w.sh
chmod +x w.sh
sudo ./w.sh
