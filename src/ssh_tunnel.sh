#!/bin/sh

# Конфигурация
LOG_FILE="/var/log/ssh_tunnel.log"
PID_FILE="/var/run/ssh_tunnel.pid"
CONFIG_FILE="/etc/config/ssh_tunnel"
SECRET_KEY_FILE="/etc/ssh_tunnel.key"
PASSWORD_FILE="/etc/ssh_tunnel.pwd"

# Шифрование пароля
encrypt_password() {
    local password="$1"
    echo "$password" | openssl enc -aes-256-cbc -salt -pass file:"$SECRET_KEY_FILE" -base64 2>/dev/null
}

# Дешифрование пароля
decrypt_password() {
    local encrypted_password="$1"
    echo "$encrypted_password" | openssl enc -aes-256-cbc -d -salt -pass file:"$SECRET_KEY_FILE" -base64 2>/dev/null
}

# Получение расшифрованного пароля
get_decrypted_password() {
    if [ -f "$PASSWORD_FILE" ] && [ -f "$SECRET_KEY_FILE" ]; then
        local encrypted=$(cat "$PASSWORD_FILE" 2>/dev/null)
        if [ -n "$encrypted" ]; then
            decrypt_password "$encrypted"
            return $?
        fi
    fi
    return 1
}

# Загрузка конфигурации из UCI
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        SERVER_USER=$(uci get ssh_tunnel.settings.server_user 2>/dev/null)
        SERVER_HOST=$(uci get ssh_tunnel.settings.server_host 2>/dev/null)
        SERVER_PORT=$(uci get ssh_tunnel.settings.server_port 2>/dev/null)
        SERVER_CONFIG_PATH=$(uci get ssh_tunnel.settings.server_config_path 2>/dev/null)
        USE_AUTOSSH=$(uci get ssh_tunnel.settings.use_autossh 2>/dev/null || echo "1")
        MONITOR_PORT=$(uci get ssh_tunnel.settings.monitor_port 2>/dev/null || echo "0")
        SSH_TIMEOUT=$(uci get ssh_tunnel.settings.ssh_timeout 2>/dev/null || echo "30")
        PASSWORD_ENCRYPTED=$(uci get ssh_tunnel.settings.password_encrypted 2>/dev/null || echo "0")
    fi
}

# Функция для логирования
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# Получаем MAC адрес роутера
get_mac_address() {
    local interface=$(uci get network.lan.ifname 2>/dev/null || echo "br-lan")
    cat /sys/class/net/$interface/address 2>/dev/null | tr -d ':' | tr '[:upper:]' '[:lower:]'
}

# Получаем hostname роутера
get_hostname() {
    uci get system.@system[0].hostname 2>/dev/null || cat /proc/sys/kernel/hostname 2>/dev/null || echo "openwrt"
}

# Функция для выполнения команд на сервере через SSH с паролем
run_on_server() {
    local command="$1"
    local password
    
    # Получаем пароль
    if [ "$PASSWORD_ENCRYPTED" = "1" ]; then
        password=$(get_decrypted_password)
        if [ $? -ne 0 ]; then
            log "Ошибка дешифрования пароля"
            return 1
        fi
    else
        # Старая версия без шифрования (для обратной совместимости)
        password=$(uci get ssh_tunnel.settings.server_password 2>/dev/null)
    fi
    
    if [ -z "$password" ]; then
        log "Пароль не найден"
        return 1
    fi
    
    sshpass -p "$password" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15 -p "$SERVER_PORT" "$SERVER_USER@$SERVER_HOST" "$command" 2>/dev/null
}

# Функция для получения портов из конфига на сервере
get_tunnel_ports() {
    ROUTER_MAC=$(get_mac_address)
    ROUTER_HOSTNAME=$(get_hostname)
    
    log "Поиск портов для MAC: $ROUTER_MAC, Hostname: $ROUTER_HOSTNAME"
    
    # Ищем запись с нашим MAC адресом
    local line=$(run_on_server "grep -i '^$ROUTER_MAC' '$SERVER_CONFIG_PATH' 2>/dev/null")
    
    if [ -n "$line" ]; then
        local ssh_port=$(echo "$line" | awk '{print $2}')
        local web_port=$(echo "$line" | awk '{print $3}')
        local stored_hostname=$(echo "$line" | awk '{print $4}')
        
        # Обновляем hostname если он изменился
        if [ -n "$stored_hostname" ] && [ "$stored_hostname" != "$ROUTER_HOSTNAME" ]; then
            log "Hostname изменился: '$stored_hostname' -> '$ROUTER_HOSTNAME', обновляем запись"
            run_on_server "sed -i 's/^$ROUTER_MAC .*/$ROUTER_MAC $ssh_port $web_port $ROUTER_HOSTNAME/' '$SERVER_CONFIG_PATH'"
        fi
        
        if [ -n "$ssh_port" ] && [ "$ssh_port" -ge 2200 ] && [ "$ssh_port" -le 2299 ] && \
           [ -n "$web_port" ] && [ "$web_port" -ge 8000 ] && [ "$web_port" -le 8099 ]; then
            log "Найдены существующие порты: SSH=$ssh_port, WEB=$web_port, Hostname: $ROUTER_HOSTNAME"
            echo "$ssh_port $web_port"
            return 0
        fi
    fi
    
    log "Запись не найдена или некорректна, ищем следующие доступные порты"
    
    # Получаем последние использованные порты
    local last_ssh_port=$(run_on_server "grep -v '^#' '$SERVER_CONFIG_PATH' 2>/dev/null | awk '{print \$2}' | sort -n | tail -1")
    local last_web_port=$(run_on_server "grep -v '^#' '$SERVER_CONFIG_PATH' 2>/dev/null | awk '{print \$3}' | sort -n | tail -1")
    
    # Устанавливаем начальные значения если порты не найдены
    if [ -z "$last_ssh_port" ] || [ "$last_ssh_port" -lt 2200 ]; then
        last_ssh_port=2199
    fi
    if [ -z "$last_web_port" ] || [ "$last_web_port" -lt 8000 ]; then
        last_web_port=7999
    fi
    
    local new_ssh_port=$((last_ssh_port + 1))
    local new_web_port=$((last_web_port + 1))
    
    # Проверяем, что порты в допустимых диапазонах
    if [ "$new_ssh_port" -gt 2299 ]; then
        log "Ошибка: Достигнут лимит SSH портов (2299)"
        return 1
    fi
    if [ "$new_web_port" -gt 8099 ]; then
        log "Ошибка: Достигнут лимит WEB портов (8099)"
        return 1
    fi
    
    # Добавляем новую запись на сервер с hostname
    run_on_server "echo '$ROUTER_MAC $new_ssh_port $new_web_port $ROUTER_HOSTNAME' >> '$SERVER_CONFIG_PATH'"
    
    if [ $? -eq 0 ]; then
        log "Добавлена новая запись: $ROUTER_MAC -> SSH:$new_ssh_port WEB:$new_web_port Hostname:$ROUTER_HOSTNAME"
        echo "$new_ssh_port $new_web_port"
        return 0
    else
        log "Ошибка при добавлении записи на сервер"
        return 1
    fi
}

# Запуск туннеля с autossh
start_tunnel_with_autossh() {
    local ssh_port="$1"
    local web_port="$2"
    local password="$3"
    
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
    sshpass -p "$password" autossh $monitor_opts \
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
    local password="$3"
    
    log "Запуск туннеля с ssh: SSH=$ssh_port, WEB=$web_port"
    
    sshpass -p "$password" ssh \
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
    
    # Получаем пароль
    local password
    if [ "$PASSWORD_ENCRYPTED" = "1" ]; then
        password=$(get_decrypted_password)
        if [ $? -ne 0 ]; then
            log "Ошибка дешифрования пароля"
            echo "Ошибка: не удалось расшифровать пароль"
            return 1
        fi
    else
        # Совместимость со старыми версиями
        password=$(uci get ssh_tunnel.settings.server_password 2>/dev/null)
        if [ -z "$password" ]; then
            log "Пароль не найден в конфигурации"
            echo "Ошибка: пароль не настроен"
            return 1
        fi
    fi
    
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
    uci set ssh_tunnel.settings.hostname="$(get_hostname)"
    uci commit ssh_tunnel
    
    log "Используются порты: SSH=$ssh_port, WEB=$web_port"
    
    # Запускаем туннель
    local result=1
    if [ "$USE_AUTOSSH" = "1" ] && command -v autossh >/dev/null 2>&1; then
        if start_tunnel_with_autossh "$ssh_port" "$web_port" "$password"; then
            result=0
        fi
    fi
    
    # Если autossh не сработал, пробуем обычный ssh
    if [ $result -ne 0 ]; then
        if start_tunnel_with_ssh "$ssh_port" "$web_port" "$password"; then
            result=0
        fi
    fi
    
    # Очищаем переменную с паролем
    unset password
    
    if [ $result -eq 0 ]; then
        PID=$(pgrep -f "ssh.*$ssh_port:localhost:22.*$web_port:localhost:80")
        if [ -n "$PID" ]; then
            echo $PID > "$PID_FILE"
            log "Туннели успешно запущены (PID: $PID, SSH порт: $ssh_port, WEB порт: $web_port)"
            echo "SSH туннели запущены. Для подключения:"
            echo "SSH: ssh -p $ssh_port root@localhost"
            echo "WEB: http://localhost:$web_port"
            echo "Luci: http://localhost:$web_port/cgi-bin/luci"
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

# Смена пароля
change_password() {
    load_config
    
    echo "Смена пароля для пользователя $SERVER_USER на сервере $SERVER_HOST"
    read -r -s -p "Введите новый пароль: " new_password
    echo
    read -r -s -p "Повторите новый пароль: " new_password_confirm
    echo
    
    if [ "$new_password" != "$new_password_confirm" ]; then
        echo "Пароли не совпадают!"
        return 1
    fi
    
    if [ -z "$new_password" ]; then
        echo "Пароль не может быть пустым!"
        return 1
    fi
    
    # Проверяем новый пароль
    if ! sshpass -p "$new_password" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -p "$SERVER_PORT" "$SERVER_USER@$SERVER_HOST" "echo 'Password test successful'" 2>/dev/null; then
        echo "Не удалось подключиться с новым паролем. Проверьте правильность."
        return 1
    fi
    
    # Сохраняем новый пароль
    if echo "$new_password" | openssl enc -aes-256-cbc -salt -pass file:"$SECRET_KEY_FILE" -base64 > "$PASSWORD_FILE" 2>/dev/null; then
        chmod 600 "$PASSWORD_FILE"
        echo "Пароль успешно изменен и зашифрован"
        return 0
    else
        echo "Ошибка при сохранении пароля"
        return 1
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
    status)
        if [ -f "$PID_FILE" ] && kill -0 $(cat "$PID_FILE") 2>/dev/null; then
            echo "Туннель активен (PID: $(cat $PID_FILE))"
            exit 0
        else
            echo "Туннель не активен"
            exit 1
        fi
        ;;
    change-password)
        change_password
        ;;
    *)
        echo "Использование: $0 {start|stop|restart|status|change-password}"
        exit 1
        ;;
esac
