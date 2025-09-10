#!/bin/sh
set -x

# Конфигурация
LOG_FILE="/var/log/ssh_tunnel.log"
PID_FILE="/var/run/ssh_tunnel.pid"
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

# Получаем MAC адрес роутера
get_mac_address() {
    local interface=$(uci get network.lan.ifname 2>/dev/null || echo "wan")
    cat /sys/class/net/$interface/address 2>/dev/null | tr -d ':' | tr '[:upper:]' '[:lower:]'
}

# Получаем hostname роутера
get_hostname() {
    uci get system.@system[0].hostname 2>/dev/null || cat /proc/sys/kernel/hostname 2>/dev/null || echo "openwrt"
}

# Функция для выполнения команд на сервере через SSH с паролем
run_on_server() {
    local command="$1"
       
    sshpass -p "$SERVER_PASSWORD" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15 -p "$SERVER_PORT" "$SERVER_USER@$SERVER_HOST" "$command" 2>/dev/null
}

# Функция для получения портов из конфига на сервере
get_tunnel_ports() {
    
    ROUTER_MAC=$(get_mac_address)
    ROUTER_HOSTNAME=$(get_hostname)
    
    log "Поиск портов для MAC: $ROUTER_MAC, Hostname: $ROUTER_HOSTNAME"    
    
    local result=$(run_on_server "python3 '$PYTHON_SCRIPT' '$ROUTER_MAC' '$ROUTER_HOSTNAME' 2>&1")
	
	echo $result
        
}

# Запуск туннеля с autossh
start_tunnel_with_autossh() {
    local ssh_port="$1"
    local web_port="$2"
    
    log "Запуск туннеля с autossh: SSH=$ssh_port, WEB=$web_port"
    
    # Определяем порт для мониторинга
    local monitor_opts=""
    if [ "$MONITOR_PORT" != "0" ] && [ -n "$MONITOR_PORT" ]; then
        monitor_opts="-M $MONITOR_PORT"
    else
        # Автоматический выбор порта мониторинга
        monitor_opts="-M 0"
    fi
    
    # Запускаем autossh
    sshpass -p "$SERVER_PASSWORD" autossh $monitor_opts \
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

# Запуск туннеля с обычным ssh
start_tunnel_with_ssh() {
    local ssh_port="$1"
    local web_port="$2"
    
    log "Запуск туннеля с ssh: SSH=$ssh_port, WEB=$web_port"
    
    sshpass -p "$SERVER_PASSWORD" ssh \
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
    
    if [ -f "$PID_FILE" ] && kill -0 $(cat "$PID_FILE") 2>/dev/null; then
        echo "Туннель уже запущен (PID: $(cat $PID_FILE))"
        return 1
    fi
    
    log "Запуск SSH туннелей"
    
    # Проверяем что пароль настроен
    if [ -z "$SERVER_PASSWORD" ]; then
        log "Ошибка: Пароль не настроен в конфигурации"
        echo "Ошибка: Пароль не настроен. Запустите установку заново или настройте вручную в $CONFIG_FILE"
        return 1
    fi
    
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
    if [ "$USE_AUTOSSH" = "1" ] && command -v autossh >/dev/null 2>&1; then
        if start_tunnel_with_autossh "$ssh_port" "$web_port"; then
            result=0
        fi
    fi
    
    # Если autossh не сработал, пробуем обычный ssh
    if [ $result -ne 0 ]; then
        if start_tunnel_with_ssh "$ssh_port" "$web_port"; then
            result=0
        fi
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


# Обработка команд
case "$1" in
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
        echo "Использование: $0 {start|stop|restart|status|info|check}"
        echo ""
        echo "Команды:"
        echo "  start   - Запуск туннеля"
        echo "  stop    - Остановка туннеля"
        echo "  restart - Перезапуск туннеля"
        echo "  info    - Подробная информация"
        exit 1
        ;;
esac
