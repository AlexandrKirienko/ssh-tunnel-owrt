#!/bin/sh
#
# SSH Tunnel Manager для OpenWRT
# Автоматический обратный туннель с управлением портами
# GitHub: https://github.com/username/ssh-tunnel-owrt
#

# Конфигурация (будет переопределена из /etc/config/ssh_tunnel)
SERVER_USER="username"
SERVER_HOST="your-server.com"
SERVER_PORT="22"
SERVER_CONFIG_PATH="/path/to/tunnel_configs.txt"
IDENTITY_FILE="/root/.ssh/id_rsa"

# Загрузка конфигурации из UCI
load_config() {
    if [ -f "/etc/config/ssh_tunnel" ]; then
        SERVER_USER=$(uci get ssh_tunnel.settings.server_user 2>/dev/null || echo "$SERVER_USER")
        SERVER_HOST=$(uci get ssh_tunnel.settings.server_host 2>/dev/null || echo "$SERVER_HOST")
        SERVER_PORT=$(uci get ssh_tunnel.settings.server_port 2>/dev/null || echo "$SERVER_PORT")
        SERVER_CONFIG_PATH=$(uci get ssh_tunnel.settings.server_config_path 2>/dev/null || echo "$SERVER_CONFIG_PATH")
        IDENTITY_FILE=$(uci get ssh_tunnel.settings.identity_file 2>/dev/null || echo "$IDENTITY_FILE")
    fi
}

# Инициализация конфигурации
load_config

# ... остальной код скрипта без изменений ...

# В функции run_on_server добавляем обработку ошибок
run_on_server() {
    local command="$1"
    local attempt=1
    local max_attempts=3
    
    while [ $attempt -le $max_attempts ]; do
        ssh -o BatchMode=yes -o ConnectTimeout=15 -i "$IDENTITY_FILE" -p "$SERVER_PORT" "$SERVER_USER@$SERVER_HOST" "$command" 2>/dev/null
        local result=$?
        
        if [ $result -eq 0 ]; then
            return 0
        fi
        
        if [ $attempt -lt $max_attempts ]; then
            sleep 2
        fi
        
        attempt=$((attempt + 1))
    done
    
    return 1
}
