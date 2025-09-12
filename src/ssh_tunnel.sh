#!/bin/sh

# Конфигурация
LOG_FILE="/var/log/ssh_tunnel.log"
PID_FILE="/var/run/ssh_tunnel.pid"
SSH_KEY="/root/.ssh/id_dropbear"
CONFIG_FILE="/etc/config/ssh_tunnel"
PYTHON_SCRIPT="/root/router_manager.py"


# Загрузка конфигурации из UCI
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        SERVER_USER=$(uci get ssh_tunnel.settings.server_user 2>/dev/null)
        SERVER_HOST=$(uci get ssh_tunnel.settings.server_host 2>/dev/null)
        SERVER_PORT=$(uci get ssh_tunnel.settings.server_port 2>/dev/null)
        SERVER_PASSWORD=$(uci get ssh_tunnel.settings.server_password 2>/dev/null)
        USE_AUTOSSH=$(uci get ssh_tunnel.settings.use_autossh 2>/dev/null || echo "1")
        MONITOR_PORT=$(uci get ssh_tunnel.settings.monitor_port 2>/dev/null || echo "0")
        SSH_TIMEOUT=$(uci get ssh_tunnel.settings.ssh_timeout 2>/dev/null || echo "30")
    fi
}

# Функция для логирования
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# Функция для ротации логов (альтернативный подход)
rotate_log() {
    local max_size_mb="${1:-5}"
    local max_backups="${2:-3}"
    local max_size_bytes=$((max_size_mb * 1024 * 1024))
    
    if [ ! -f "$LOG_FILE" ]; then
        return 0
    fi
    
    local file_size=$(wc -c < "$LOG_FILE" 2>/dev/null)
    
    if [ "$file_size" -gt "$max_size_bytes" ]; then
        echo "Ротируем лог: $LOG_FILE"
        
        # Ротируем логи
        for i in $(seq $max_backups -1 1); do
            local prev="${LOG_FILE}.${i}"
            local next="${LOG_FILE}.$((i+1))"
            
            if [ -f "$prev" ]; then
                mv "$prev" "$next" 2>/dev/null
            fi
        done
        
        # Перемещаем текущий лог
        mv "$LOG_FILE" "${LOG_FILE}.1" 2>/dev/null
        
        # Создаем новый пустой лог-файл
        touch "$LOG_FILE"
        chmod 644 "$LOG_FILE" 2>/dev/null
        
        echo "Ротация завершена"
        return 0
    fi
    
    return 0
}

# Получаем MAC адрес роутера
get_mac_address() {
    local interface=$(uci get network.lan.ifname 2>/dev/null || echo "wan")
    cat /sys/class/net/$interface/address 2>/dev/null | tr -d ':' | tr '[:upper:]' '[:lower:]'
}

# Получаем hostname роутера
get_hostname() {
    uci get system.@system[0].hostname 2>/dev/null || cat /proc/sys/kernel/hostname 2>/dev/null || echo "openwrt"
}

run_on_server_key() {
    local command="$1"
	      
    ssh -p "$SERVER_PORT" -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SERVER_USER@$SERVER_HOST" "$command" 2>/dev/null
}

# Функция для получения портов из конфига на сервере
get_tunnel_ports() {
    
    ROUTER_MAC=$(get_mac_address)
    ROUTER_HOSTNAME=$(get_hostname)
    
    log "Поиск портов для MAC: $ROUTER_MAC, Hostname: $ROUTER_HOSTNAME"    
    
    local result=$(run_on_server_key "python3 '$PYTHON_SCRIPT' '$ROUTER_MAC' '$ROUTER_HOSTNAME' 2>&1")
	
	echo $result
        
}

start_tunnel_with_ssh_key() {
    local ssh_port="$1"
    local web_port="$2"
    
    log "Запуск туннеля с ssh key: SSH=$ssh_port, WEB=$web_port"
	    
    ssh -i "$SSH_KEY"\
		-f -N -T \
        -o ServerAliveInterval=60 \
        -o ServerAliveCountMax=3 \
        -o ExitOnForwardFailure=yes \
        -o StrictHostKeyChecking=no \
        -o ConnectTimeout=$SSH_TIMEOUT \
        -p "$SERVER_PORT" \
        -R $ssh_port:localhost:22 \
        -R $web_port:localhost:80 \
        "$SERVER_USER@$SERVER_HOST"
    
    return $?
}

# Основные функции управления
start_tunnel() {
    
	load_config
	
	rotate_log
    
    if [ -f "$PID_FILE" ] && kill -0 $(cat "$PID_FILE") 2>/dev/null; then
        echo "Туннель уже запущен (PID: $(cat $PID_FILE))"
        return 1
    fi
    
    log "Запуск SSH туннелей"
    
    # Получаем порты для туннелей
    local ports=$(get_tunnel_ports)
    
    if [ $? -ne 0 ] || [ -z "$ports" ]; then
        log "Ошибка: Не удалось получить порты для туннелей"
        return 1
    fi
    
	
	local ssh_port=$(echo $ports | awk -F ',' '{print $1}')
    local web_port=$(echo $ports | awk -F ',' '{print $2}')
    
    log "Используются порты: SSH=$ssh_port, WEB=$web_port"
    
    # Запускаем туннель
    local result=1
    if start_tunnel_with_ssh_key "$ssh_port" "$web_port"; then
        result=0
    fi
    
    if [ $result -eq 0 ]; then
        PID=$(pgrep -f "ssh.*$ssh_port:localhost:22.*$web_port:localhost:80")
        if [ -n "$PID" ]; then
            echo $PID > "$PID_FILE"
            log "Туннели успешно запущены (PID: $PID, SSH порт: $ssh_port, WEB порт: $web_port)"
            echo "SSH туннели запущены. Для подключения:"
            return 0
        else
            log "Туннель запущен, но не удалось определить PID"
            echo "Туннель запущен, но могут быть проблемы с мониторингом"
            return 0
        fi
    else
        log "Ошибка при запуске туннелей (SSH:$ssh_port, WEB:$web_port)"
        return 1
    fi
}

stop_tunnel() {
    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE")
        if kill $pid 2>/dev/null; then
            log "Туннель остановлен (PID: $pid)"
            rm -f "$PID_FILE"
            echo "Туннель остановлен"
            return 0
        else
            rm -f "$PID_FILE"
            echo "Туннель не был запущен"
            return 1
        fi
    else
        echo "Туннель не запущен"
        return 1
    fi
}

# Показать информацию о туннеле
show_info() {
    load_config
    
    if [ -f "$PID_FILE" ] && kill -0 $(cat "$PID_FILE") 2>/dev/null; then
       
        echo "=== Информация о туннеле ==="
        echo "Статус: Активен (PID: $(cat $PID_FILE))"
		echo "Для остановки: /etc/init.d/ssh_tunnel stop"

    else
        echo "Туннель не активен"
        echo "Для запуска: /etc/init.d/ssh_tunnel start"
    fi
}

# Главная функция
main() {
    case "${1:-start}" in
        start)
            start_tunnel
            ;;
        stop)
            stop_tunnel
            ;;
		restart)
            stop_tunnel
			sleep 2
			start_tunnel
			;;
        info)
            show_info
			;;
        *)
            start_tunnel
            ;;
    esac
}

# Запуск
main "$@"
