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
SERVER_PASSWORD="password"
SERVER_CONFIG_PATH="/path/to/tunnel_configs.txt"

# Загрузка конфигурации из UCI
load_config() {
    if [ -f "/etc/config/ssh_tunnel" ]; then
        SERVER_USER=$(uci get ssh_tunnel.settings.server_user 2>/dev/null || echo "$SERVER_USER")
        SERVER_HOST=$(uci get ssh_tunnel.settings.server_host 2>/dev/null || echo "$SERVER_HOST")
        SERVER_PORT=$(uci get ssh_tunnel.settings.server_port 2>/dev/null || echo "$SERVER_PORT")
        SERVER_PASSWORD=$(uci get ssh_tunnel.settings.server_password 2>/dev/null || echo "$SERVER_PASSWORD")
        SERVER_CONFIG_PATH=$(uci get ssh_tunnel.settings.server_config_path 2>/dev/null || echo "$SERVER_CONFIG_PATH")
    fi
}

# Инициализация конфигурации
load_config

# Функция для логирования
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# Функция для выполнения команд на сервере через SSH с паролем
run_on_server() {
    local command="$1"
    sshpass -p "$SERVER_PASSWORD" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15 -p "$SERVER_PORT" "$SERVER_USER@$SERVER_HOST" "$command" 2>/dev/null
}

# ... остальной код скрипта без изменений (get_mac_address, get_hostname, get_tunnel_ports и т.д.) ...

# Функция запуска туннелей
start_tunnel() {
    if [ -f "$PID_FILE" ] && kill -0 $(cat "$PID_FILE") 2>/dev/null; then
        echo "Туннель уже запущен (PID: $(cat $PID_FILE))"
        return 1
    fi
    
    log "Запуск SSH туннелей для MAC: $ROUTER_MAC, Hostname: $ROUTER_HOSTNAME"
    
    # Получаем порты для туннелей
    local ports=$(get_tunnel_ports)
    
    if [ $? -ne 0 ] || [ -z "$ports" ]; then
        log "Ошибка: Не удалось получить порты для туннелей"
        return 1
    fi
    
    local ssh_port=$(echo $ports | awk '{print $1}')
    local web_port=$(echo $ports | awk '{print $2}')
    
    # Сохраняем порты в конфиг
    uci set ssh_tunnel.settings.ssh_port="$ssh_port"
    uci set ssh_tunnel.settings.web_port="$web_port"
    uci set ssh_tunnel.settings.hostname="$ROUTER_HOSTNAME"
    uci commit ssh_tunnel
    
    log "Используются порты: SSH=$ssh_port, WEB=$web_port, Hostname=$ROUTER_HOSTNAME"
    
    # Запускаем SSH туннель с двумя проброшенными портами используя sshpass
    sshpass -p "$SERVER_PASSWORD" ssh -f -N -T \
        -o ServerAliveInterval=60 \
        -o ServerAliveCountMax=3 \
        -o ExitOnForwardFailure=yes \
        -o StrictHostKeyChecking=no \
        -o ConnectTimeout=30 \
        -p "$SERVER_PORT" \
        -R $ssh_port:localhost:22 \
        -R $web_port:localhost:80 \
        "$SERVER_USER@$SERVER_HOST"
    
    if [ $? -eq 0 ]; then
        PID=$(pgrep -f "ssh.*$ssh_port:localhost:22.*$web_port:localhost:80")
        echo $PID > "$PID_FILE"
        log "Туннели успешно запущены (PID: $PID, SSH порт: $ssh_port, WEB порт: $web_port)"
        echo "SSH туннели запущены. Для подключения:"
        echo "SSH: ssh -p $ssh_port root@localhost"
        echo "WEB: http://localhost:$web_port"
        echo "Luci: http://localhost:$web_port/cgi-bin/luci"
        echo "Hostname: $ROUTER_HOSTNAME"
        return 0
    else
        log "Ошибка при запуске туннелей (SSH:$ssh_port, WEB:$web_port)"
        return 1
    fi
}

