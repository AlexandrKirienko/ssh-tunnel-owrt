#!/bin/sh

set -e

# Константы
REPO_URL="https://raw.githubusercontent.com/username/ssh-tunnel-owrt/master"
INSTALL_DIR="/root"
CONFIG_DIR="/etc/config"
INIT_DIR="/etc/init.d"
LOG_DIR="/var/log"
SSH_DIR="/root/.ssh"

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

# Загрузка файла
download_file() {
    local url="$1"
    local output="$2"
    
    case $DOWNLOAD_TOOL in
        wget)
            wget -q "$url" -O "$output"
            ;;
        curl)
            curl -s -L "$url" -o "$output"
            ;;
    esac
    
    if [ $? -ne 0 ]; then
        error "Не удалось загрузить файл: $url"
        exit 1
    fi
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

# Функция для ввода пароля с отображением звездочек
input_password() {
    local prompt="$1"
    local password=""
    local char=""
    local char_count=0
    
    prompt="$prompt: "
    echo -n "$(question "$prompt")"
    
    # Сохраняем текущие настройки терминала
    stty_save=$(stty -g)
    # Устанавливаем режим без echo
    stty -echo
    
    # Читаем пароль посимвольно
    while IFS= read -r -n 1 -s char; do
        # Enter - завершаем ввод
        if [[ $char == $'\0' ]]; then
            break
        fi
        # Backspace
        if [[ $char == $'\177' ]]; then
            if [ $char_count -gt 0 ]; then
                char_count=$((char_count - 1))
                password="${password%?}"
                echo -n $'\b \b'
            fi
            continue
        fi
        # Любой другой символ
        char_count=$((char_count + 1))
        password+="$char"
        echo -n "*"
    done
    
    # Восстанавливаем настройки терминала
    stty $stty_save
    echo
    
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

# Создание SSH ключа если нет и копирование на сервер
setup_ssh_key() {
    local user="$1"
    local host="$2"
    local port="$3"
    local password="$4"
    
    info "Настройка SSH аутентификации..."
    
    # Создаем директорию .ssh если нет
    mkdir -p "$SSH_DIR"
    chmod 700 "$SSH_DIR"
    
    # Создаем SSH ключ если нет
    if [ ! -f "$SSH_DIR/id_rsa" ]; then
        info "Создание SSH ключа..."
        ssh-keygen -t rsa -b 4096 -f "$SSH_DIR/id_rsa" -N "" -q
        success "SSH ключ создан"
    else
        info "SSH ключ уже существует"
    fi
    
    # Копируем публичный ключ на сервер используя пароль
    info "Копирование SSH ключа на сервер..."
    
    if sshpass -p "$password" ssh-copy-id -o StrictHostKeyChecking=no -i "$SSH_DIR/id_rsa.pub" -p "$port" "$user@$host" 2>/dev/null; then
        success "SSH ключ успешно скопирован на сервер"
        
        # Проверяем что ключ работает
        if ssh -o BatchMode=yes -o ConnectTimeout=10 -p "$port" -i "$SSH_DIR/id_rsa" "$user@$host" "echo 'Key-based authentication successful'" 2>/dev/null; then
            success "Аутентификация по ключу работает!"
            return 0
        else
            error "Аутентификация по ключу не работает"
            return 1
        fi
    else
        error "Не удалось скопировать SSH ключ на сервер"
        return 1
    fi
}

# Вывод summary конфигурации
show_config_summary() {
    local user="$1"
    local host="$2"
    local port="$3"
    local config_path="$4"
    
    echo ""
    info "=== Сводка конфигурации ==="
    config_show "Сервер: $user@$host:$port"
    config_show "Файл конфигурации на сервере: $config_path"
    config_show "SSH ключ: $SSH_DIR/id_rsa"
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
    
    show_config_summary "$user" "$host" "$port" "$config_path"
    
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

# Интерактивная настройка конфигурации
interactive_setup() {
    info "=== Настройка SSH туннеля ==="
    echo ""
    
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
    
    # Запрос пароля
    info "Теперь введите пароль для пользователя $SERVER_USER на сервере $SERVER_HOST"
    info "Пароль будет скрыт звездочками (*) при вводе"
    SERVER_PASSWORD=$(input_password "Пароль")
    
    # Проверяем что пароль не пустой
    if [ -z "$SERVER_PASSWORD" ]; then
        error "Пароль не может быть пустым!"
        exit 1
    fi
    
    # Показываем длину парвода (но не сам пароль)
    info "Длина пароля: ${#SERVER_PASSWORD} символов"
    
    # Подтверждение конфигурации
    confirm_configuration "$SERVER_USER" "$SERVER_HOST" "$SERVER_PORT" "$SERVER_CONFIG_PATH"
    
    # Проверка подключения
    if ! test_ssh_connection "$SERVER_USER" "$SERVER_HOST" "$SERVER_PORT" "$SERVER_PASSWORD"; then
        error "Проверка подключения не удалась. Прерывание установки."
        exit 1
    fi
    
    # Настройка SSH ключа
    if ! setup_ssh_key "$SERVER_USER" "$SERVER_HOST" "$SERVER_PORT" "$SERVER_PASSWORD"; then
        error "Настройка SSH аутентификации не удалась. Прерывание установки."
        exit 1
    fi
    
    # Создаем конфигурационный файл
    info "Создание конфигурационного файла..."
    cat > "$CONFIG_DIR/ssh_tunnel" << EOF
config tunnel 'settings'
    option server_user '$SERVER_USER'
    option server_host '$SERVER_HOST'
    option server_port '$SERVER_PORT'
    option server_config_path '$SERVER_CONFIG_PATH'
    option identity_file '/root/.ssh/id_rsa'
    option ssh_port '2200'
    option web_port '8000'
    option hostname 'openwrt'
EOF
    
    success "Конфигурация сохранена в $CONFIG_DIR/ssh_tunnel"
    
    # Показываем публичный ключ на всякий случай
    echo ""
    info "=== Ваш SSH публичный ключ ==="
    cat "$SSH_DIR/id_rsa.pub"
    echo "==============================="
    echo ""
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
        opkg install sshpass || warning "sshpass не установлен, будут использоваться существующие ключи"
    fi
    
    success "Зависимости проверены"
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
    
    download_file "$REPO_URL/src/ssh_tunnel.sh" "$INSTALL_DIR/ssh_tunnel.sh"
    download_file "$REPO_URL/src/ssh_tunnel.init" "$INIT_DIR/ssh_tunnel"
    
    # Делаем файлы исполняемыми
    chmod +x "$INSTALL_DIR/ssh_tunnel.sh"
    chmod +x "$INIT_DIR/ssh_tunnel"
    
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
    show_config_summary "$SERVER_USER" "$SERVER_HOST" "$SERVER_PORT" "$SERVER_CONFIG_PATH"
    
    echo "Команды управления:"
    echo "  Запуск: /etc/init.d/ssh_tunnel start"
    echo "  Остановка: /etc/init.d/ssh_tunnel stop"
    echo "  Статус: /etc/init.d/ssh_tunnel status"
    echo "  Информация: /root/ssh_tunnel.sh info"
    echo ""
    echo "Логи: tail -f /var/log/ssh_tunnel.log"
    echo ""
    info "Туннель будет автоматически запускаться при загрузке системы"
}

# ... остальные функции без изменений (uninstall, update, edit_config, show_help, main) ...

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
