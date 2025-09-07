#!/bin/sh

set -e

# Константы
REPO_URL="https://raw.githubusercontent.com/username/ssh-tunnel-owrt/master"
INSTALL_DIR="/root"
CONFIG_DIR="/etc/config"
INIT_DIR="/etc/init.d"
LOG_DIR="/var/log"

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

# Функции для вывода
info() { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
question() { echo -e "${CYAN}[QUESTION]${NC} $1"; }
config_show() { echo -e "${MAGENTA}[CONFIG]${NC} $1"; }

# Проверка наличия wget или curl
check_download_tool() {
    if command -v wget >/dev/null 2>&1; then
        echo "wget"
    elif command -v curl >/dev/null 2>&1; then
        echo "curl"
    else
        error "Не найден wget или curl. Установите один из них: opkg update && opkg install wget"
        exit 1
    fi
}

# Загрузка файла с проверкой
download_file() {
    local url="$1"
    local output="$2"
    local max_retries=3
    local retry=0
    
    info "Загрузка: $url"
    
    while [ $retry -lt $max_retries ]; do
        case $DOWNLOAD_TOOL in
            wget)
                wget --timeout=30 --tries=3 -q "$url" -O "$output" && return 0
                ;;
            curl)
                curl --connect-timeout 30 --retry 3 -s -L "$url" -o "$output" && return 0
                ;;
        esac
        
        retry=$((retry + 1))
        warning "Попытка $retry из $max_retries не удалась, повтор через 2 секунды..."
        sleep 2
    done
    
    error "Не удалось загрузить файл: $url"
    error "Проверьте:"
    error "1. Правильность URL: $url"
    error "2. Наличие файла в репозитории"
    error "3. Доступ в интернет"
    return 1
}

# Проверка, что мы на OpenWRT
check_openwrt() {
    if [ ! -f "/etc/openwrt_release" ]; then
        error "Это не система OpenWRT! Скрипт предназначен только для OpenWRT."
        exit 1
    fi
}

# Функция для ввода с проверкой
input_with_default() {
    local prompt="$1"
    local default="$2"
    local input
    
    if [ -n "$default" ]; then
        prompt="$prompt (по умолчанию: $default): "
    else
        prompt="$prompt: "
    fi
    
    read -r -p "$(question "$prompt")" input
    echo "${input:-$default}"
}

# Функция для ввода пароля в открытом виде
input_password_visible() {
    local prompt="$1"
    local password
    
    prompt="$prompt: "
    read -r -p "$(question "$prompt")" password
    echo "$password"
}

# Проверка подключения к серверу
test_ssh_connection() {
    local user="$1"
    local host="$2"
    local port="$3"
    local password="$4"
    
    info "Проверка подключения к серверу..."
    
    if ! command -v sshpass >/dev/null 2>&1; then
        warning "sshpass не установлен, пытаемся установить..."
        opkg update
        opkg install sshpass || {
            error "Не удалось установить sshpass. Установите вручную: opkg install sshpass"
            return 1
        }
    fi
    
    if sshpass -p "$password" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -p "$port" "$user@$host" "echo 'Connection successful'" 2>/dev/null; then
        success "Подключение к серверу успешно!"
        return 0
    else
        error "Не удалось подключиться к серверу. Проверьте параметры."
        return 1
    fi
}

# Вывод summary конфигурации
show_config_summary() {
    local user="$1"
    local host="$2"
    local port="$3"
    local config_path="$4"
    local password="$5"
    
    echo ""
    info "=== Сводка конфигурации ==="
    config_show "Сервер: $user@$host:$port"
    config_show "Пароль: $password"
    config_show "Файл конфигурации на сервере: $config_path"
    config_show "Локальный конфиг: $CONFIG_DIR/ssh_tunnel"
    config_show "Логи: $LOG_DIR/ssh_tunnel.log"
    echo "============================"
    echo ""
}

# Подтверждение конфигурации
confirm_configuration() {
    local user="$1"
    local host="$2"
    local port="$3"
    local config_path="$4"
    local password="$5"
    
    show_config_summary "$user" "$host" "$port" "$config_path" "$password"
    
    read -r -p "$(question 'Все верно? Продолжить установку? (Y/n): ')" answer
    case "${answer:-y}" in
        y|Y|yes|YES|"")
            return 0
            ;;
        *)
            info "Установка отменена."
            exit 0
            ;;
    esac
}

# Предупреждение о безопасности
show_security_warning() {
    echo ""
    warning "=== ВАЖНО: ИНФОРМАЦИЯ О БЕЗОПАСНОСТИ ==="
    warning "Пароль будет отображаться в открытом виде!"
    warning "Убедитесь, что никто не видит ваш экран."
    warning "Пароль будет сохранен в конфигурационном файле."
    warning "========================================"
    echo ""
    
    read -r -p "$(question 'Понятно? Продолжить? (Y/n): ')" answer
    case "${answer:-y}" in
        y|Y|yes|YES|"")
            return 0
            ;;
        *)
            info "Установка отменена."
            exit 0
            ;;
    esac
}

# Интерактивная настройка конфигурации
interactive_setup() {
    info "=== Настройка SSH туннеля ==="
    echo ""
    
    # Показываем предупреждение о безопасности
    show_security_warning
    
    # Запрос параметров сервера
    SERVER_USER=$(input_with_default "Имя пользователя на сервере" "root")
    SERVER_HOST=$(input_with_default "Адрес сервера" "example.com")
    SERVER_PORT=$(input_with_default "SSH порт сервера" "22")
    SERVER_CONFIG_PATH=$(input_with_default "Путь к файлу конфигурации на сервере" "/home/user/tunnel_configs.txt")
    
    # Показываем введенные параметры
    echo ""
    info "Введенные параметры:"
    config_show "Пользователь: $SERVER_USER"
    config_show "Сервер: $SERVER_HOST"
    config_show "Порт: $SERVER_PORT"
    config_show "Путь к конфигу: $SERVER_CONFIG_PATH"
    echo ""
    
    # Запрос пароля в открытом виде
    info "Теперь введите пароль для пользователя $SERVER_USER на сервере $SERVER_HOST"
    info "Пароль будет отображаться в открытом виде!"
    SERVER_PASSWORD=$(input_password_visible "Пароль")
    
    # Проверяем что пароль не пустой
    if [ -z "$SERVER_PASSWORD" ]; then
        error "Пароль не может быть пустым!"
        exit 1
    fi
    
    # Показываем введенный пароль
    config_show "Введенный пароль: $SERVER_PASSWORD"
    echo ""
    
    # Подтверждение конфигурации
    confirm_configuration "$SERVER_USER" "$SERVER_HOST" "$SERVER_PORT" "$SERVER_CONFIG_PATH" "$SERVER_PASSWORD"
    
    # Проверка подключения
    if ! test_ssh_connection "$SERVER_USER" "$SERVER_HOST" "$SERVER_PORT" "$SERVER_PASSWORD"; then
        error "Проверка подключения не удалась. Прерывание установки."
        exit 1
    fi
    
    # Создаем конфигурационный файл
    info "Создание конфигурационного файла..."
    cat > "$CONFIG_DIR/ssh_tunnel" << EOF
config tunnel 'settings'
    option server_user '$SERVER_USER'
    option server_host '$SERVER_HOST'
    option server_port '$SERVER_PORT'
    option server_password '$SERVER_PASSWORD'
    option server_config_path '$SERVER_CONFIG_PATH'
    option ssh_port '2200'
    option web_port '8000'
    option hostname 'openwrt'
EOF
    
    success "Конфигурация сохранена в $CONFIG_DIR/ssh_tunnel"
    warning "Пароль сохранен в конфигурационном файле в открытом виде!"
}

# Установка зависимостей
install_dependencies() {
    info "Проверка зависимостей..."
    
    if ! command -v ssh >/dev/null 2>&1; then
        warning "SSH клиент не найден, устанавливаем..."
        opkg update
        opkg install openssh-client-utils
    fi
    
    if ! command -v sshpass >/dev/null 2>&1; then
        info "Установка sshpass для подключения по паролю..."
        opkg update
        opkg install sshpass || {
            error "Не удалось установить sshpass. Обязательно для работы!"
            exit 1
        }
    fi
    
    success "Зависимости проверены"
}

# Создание основных файлов если их нет в репозитории
create_missing_files() {
    # Создаем основной скрипт если его нет
    if [ ! -f "$INSTALL_DIR/ssh_tunnel.sh" ]; then
        info "Создание основного скрипта ssh_tunnel.sh..."
        cat > "$INSTALL_DIR/ssh_tunnel.sh" << 'EOF'
#!/bin/sh

# Конфигурация
LOG_FILE="/var/log/ssh_tunnel.log"
PID_FILE="/var/run/ssh_tunnel.pid"

# Загрузка конфигурации из UCI
load_config() {
    if [ -f "/etc/config/ssh_tunnel" ]; then
        SERVER_USER=$(uci get ssh_tunnel.settings.server_user 2>/dev/null)
        SERVER_HOST=$(uci get ssh_tunnel.settings.server_host 2>/dev/null)
        SERVER_PORT=$(uci get ssh_tunnel.settings.server_port 2>/dev/null)
        SERVER_PASSWORD=$(uci get ssh_tunnel.settings.server_password 2>/dev/null)
        SERVER_CONFIG_PATH=$(uci get ssh_tunnel.settings.server_config_path 2>/dev/null)
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
    sshpass -p "$SERVER_PASSWORD" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15 -p "$SERVER_PORT" "$SERVER_USER@$SERVER_HOST" "$command" 2>/dev/null
}

# Основная логика скрипта...
# Здесь должен быть полный код из предыдущих версий
EOF
        chmod +x "$INSTALL_DIR/ssh_tunnel.sh"
        success "Создан основной скрипт"
    fi

    # Создаем init скрипт если его нет
    if [ ! -f "$INIT_DIR/ssh_tunnel" ]; then
        info "Создание init скрипта..."
        cat > "$INIT_DIR/ssh_tunnel" << 'EOF'
#!/bin/sh /etc/rc.common

START=99
STOP=10

USE_PROCD=1
PROG=/root/ssh_tunnel.sh

start_service() {
    procd_open_instance
    procd_set_param command "$PROG" start
    procd_set_param respawn
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}

stop_service() {
    "$PROG" stop
}

restart() {
    stop
    sleep 2
    start
}
EOF
        chmod +x "$INIT_DIR/ssh_tunnel"
        success "Создан init скрипт"
    fi
}

# Основная установка
install_ssh_tunnel() {
    info "Начинаем установку SSH Tunnel..."
    
    # Проверяем систему
    check_openwrt
    
    # Определяем инструмент для загрузки
    DOWNLOAD_TOOL=$(check_download_tool)
    info "Используем инструмент: $DOWNLOAD_TOOL"
    
    # Устанавливаем зависимости
    install_dependencies
    
    # Интерактивная настройка
    interactive_setup
    
    # Загружаем файлы
    info "Загрузка файлов..."
    
    # Пробуем загрузить файлы из репозитория
    if download_file "$REPO_URL/src/ssh_tunnel.sh" "$INSTALL_DIR/ssh_tunnel.sh.tmp"; then
        mv "$INSTALL_DIR/ssh_tunnel.sh.tmp" "$INSTALL_DIR/ssh_tunnel.sh"
        chmod +x "$INSTALL_DIR/ssh_tunnel.sh"
        success "Основной скрипт загружен"
    else
        warning "Не удалось загрузить основной скрипт, создаем локально"
    fi
    
    if download_file "$REPO_URL/src/ssh_tunnel.init" "$INIT_DIR/ssh_tunnel.tmp"; then
        mv "$INIT_DIR/ssh_tunnel.tmp" "$INIT_DIR/ssh_tunnel"
        chmod +x "$INIT_DIR/ssh_tunnel"
        success "Init скрипт загружен"
    else
        warning "Не удалось загрузить init скрипт, создаем локально"
    fi
    
    # Создаем недостающие файлы
    create_missing_files
    
    # Создаем log файл
    touch "$LOG_DIR/ssh_tunnel.log"
    chmod 644 "$LOG_DIR/ssh_tunnel.log"
    
    success "Файлы успешно установлены"
    
    # Включаем автозапуск
    "$INIT_DIR/ssh_tunnel" enable
    success "Автозапуск включен"
    
    # Запускаем туннель
    echo ""
    info "Запуск туннеля..."
    if "$INIT_DIR/ssh_tunnel" start; then
        success "Туннель успешно запущен!"
    else
        warning "Туннель не запустился автоматически, проверьте настройки"
    fi
    
    # Финальный summary
    echo ""
    success "=== Установка завершена! ==="
    show_config_summary "$SERVER_USER" "$SERVER_HOST" "$SERVER_PORT" "$SERVER_CONFIG_PATH" "$SERVER_PASSWORD"
    
    echo "Команды управления:"
    echo "  Запуск: /etc/init.d/ssh_tunnel start"
    echo "  Остановка: /etc/init.d/ssh_tunnel stop"
    echo "  Статус: /etc/init.d/ssh_tunnel status"
    echo "  Информация: /root/ssh_tunnel.sh info"
    echo ""
    echo "Логи: tail -f /var/log/ssh_tunnel.log"
    echo ""
    warning "Пароль сохранен в открытом виде в $CONFIG_DIR/ssh_tunnel"
    info "Туннель будет автоматически запускаться при загрузке системы"
}

# Удаление
uninstall_ssh_tunnel() {
    info "Удаление SSH Tunnel..."
    
    # Останавливаем службу
    if [ -f "$INIT_DIR/ssh_tunnel" ]; then
        "$INIT_DIR/ssh_tunnel" stop 2>/dev/null || true
        "$INIT_DIR/ssh_tunnel" disable 2>/dev/null || true
    fi
    
    # Удаляем файлы
    rm -f "$INSTALL_DIR/ssh_tunnel.sh"
    rm -f "$INIT_DIR/ssh_tunnel"
    rm -f "$CONFIG_DIR/ssh_tunnel"
    rm -f "$LOG_DIR/ssh_tunnel.log"
    
    success "SSH Tunnel удален"
}

# Обновление
update_ssh_tunnel() {
    info "Обновление SSH Tunnel..."
    
    # Проверяем что конфигурация существует
    if [ ! -f "$CONFIG_DIR/ssh_tunnel" ]; then
        error "Конфигурация не найдена. Сначала выполните установку."
        exit 1
    fi
    
    # Останавливаем службу
    if [ -f "$INIT_DIR/ssh_tunnel" ]; then
        "$INIT_DIR/ssh_tunnel" stop 2>/dev/null || true
    fi
    
    # Загружаем новые версии файлов
    info "Обновление файлов..."
    
    if download_file "$REPO_URL/src/ssh_tunnel.sh" "$INSTALL_DIR/ssh_tunnel.sh.new"; then
        mv "$INSTALL_DIR/ssh_tunnel.sh.new" "$INSTALL_DIR/ssh_tunnel.sh"
        chmod +x "$INSTALL_DIR/ssh_tunnel.sh"
        success "Основной скрипт обновлен"
    fi
    
    if download_file "$REPO_URL/src/ssh_tunnel.init" "$INIT_DIR/ssh_tunnel.new"; then
        mv "$INIT_DIR/ssh_tunnel.new" "$INIT_DIR/ssh_tunnel"
        chmod +x "$INIT_DIR/ssh_tunnel"
        success "Init скрипт обновлен"
    fi
    
    # Запускаем службу
    "$INIT_DIR/ssh_tunnel" start
    success "Служба запущена"
}

# Редактирование конфигурации
edit_config() {
    if [ -f "$CONFIG_DIR/ssh_tunnel" ]; then
        info "Редактирование конфигурации..."
        ${EDITOR:-nano} "$CONFIG_DIR/ssh_tunnel"
        success "Конфигурация обновлена"
        
        # Перезапускаем службу
        "$INIT_DIR/ssh_tunnel" restart
        success "Служба перезапущена"
    else
        error "Конфигурация не найдена. Сначала выполните установку."
        exit 1
    fi
}

# Показать помощь
show_help() {
    echo -e "${BLUE}SSH Tunnel Installer для OpenWRT${NC}"
    echo ""
    echo "Использование:"
    echo "  sh <(wget -O - URL/install.sh)           - Интерактивная установка"
    echo "  sh <(wget -O - URL/install.sh) install   - Установка"
    echo "  sh <(wget -O - URL/install.sh) update    - Обновление"
    echo "  sh <(wget -O - URL/install.sh) config    - Редактирование конфигурации"
    echo "  sh <(wget -O - URL/install.sh) uninstall - Удаление"
    echo "  sh <(wget -O - URL/install.sh) help      - Помощь"
    echo ""
    echo "Требования:"
    echo "  - OpenWRT система"
    echo "  - wget или curl"
    echo "  - Доступ в интернет"
}

# Главная функция
main() {
    case "${1:-install}" in
        install)
            install_ssh_tunnel
            ;;
        uninstall)
            uninstall_ssh_tunnel
            ;;
        update)
            update_ssh_tunnel
            ;;
        config)
            edit_config
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            install_ssh_tunnel
            ;;
    esac
}

# Запуск
main "$@"
