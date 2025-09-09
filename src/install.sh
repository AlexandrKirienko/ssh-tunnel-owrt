#!/bin/sh

set -e

# Константы
REPO_URL="https://raw.githubusercontent.com/$GITHUB_USER/ssh-tunnel-owrt/master"
INSTALL_DIR="/root"
CONFIG_DIR="/etc/config"
INIT_DIR="/etc/init.d"
LOG_DIR="/var/log"
SECRET_KEY_FILE="/etc/ssh_tunnel.key"
PASSWORD_FILE="/etc/ssh_tunnel.pwd"

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

# Генерация ключа шифрования
generate_encryption_key() {
    if [ ! -f "$SECRET_KEY_FILE" ]; then
        info "Генерация ключа шифрования..."
        openssl rand -base64 32 > "$SECRET_KEY_FILE"
        chmod 600 "$SECRET_KEY_FILE"
        success "Ключ шифрования создан"
    fi
}

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

# Сохранение пароля в зашифрованном виде
save_encrypted_password() {
    local password="$1"
    local encrypted=$(encrypt_password "$password")
    if [ -n "$encrypted" ]; then
        echo "$encrypted" > "$PASSWORD_FILE"
        chmod 600 "$PASSWORD_FILE"
        return 0
    else
        return 1
    fi
}

# Получение расшифрованного пароля
get_decrypted_password() {
    if [ -f "$PASSWORD_FILE" ]; then
        local encrypted=$(cat "$PASSWORD_FILE")
        decrypt_password "$encrypted"
    else
        return 1
    fi
}

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

# Упрощенная загрузка файла для OpenWRT
download_file() {
    local url="$1"
    local output="$2"
    
    info "Загрузка: $(basename "$output")"
    
    case $DOWNLOAD_TOOL in
        wget)
            wget -q "$url" -O "$output" 2>/dev/null
            ;;
        curl)
            curl -s -L "$url" -o "$output" 2>/dev/null
            ;;
    esac
    
    if [ $? -eq 0 ] && [ -s "$output" ]; then
        return 0
    else
        error "Ошибка загрузки: $url"
        rm -f "$output" 2>/dev/null
        return 1
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

# Функция для ввода пароля с скрытым вводом
input_password_hidden() {
    local prompt="$1"
    local password
    
    # Сохраняем настройки терминала
    stty_save=$(stty -g)
    # Отключаем echo
    stty -echo
    
    prompt="$prompt: "
    echo -n "$(question "$prompt")"
    read -r password
    echo
    
    # Восстанавливаем настройки терминала
    stty $stty_save
    
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
    
    echo ""
    info "=== Сводка конфигурации ==="
    config_show "Сервер: $user@$host:$port"
    config_show "Пароль: ******** (зашифрован)"
    config_show "Файл конфигурации на сервере: $config_path"
    config_show "Локальный конфиг: $CONFIG_DIR/ssh_tunnel"
    config_show "Логи: $LOG_DIR/ssh_tunnel.log"
    config_show "Ключ шифрования: $SECRET_KEY_FILE"
    config_show "Файл пароля: $PASSWORD_FILE"
    config_show "Используется: autossh для автоматических переподключений"
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

# Предупреждение о безопасности
show_security_warning() {
    echo ""
    warning "=== ИНФОРМАЦИЯ О БЕЗОПАСНОСТИ ==="
    warning "Пароль будет зашифрован и сохранен в защищенном файле."
    warning "Ключ шифрования хранится в: $SECRET_KEY_FILE"
    warning "Зашифрованный пароль хранится в: $PASSWORD_FILE"
    warning "Оба файла защищены правами доступа."
    warning "=================================="
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
    
    # Генерируем ключ шифрования
    generate_encryption_key
    
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
    
    # Запрос пароля со скрытым вводом
    info "Введите пароль для пользователя $SERVER_USER на сервере $SERVER_HOST"
    info "Пароль не будет отображаться на экране"
    SERVER_PASSWORD=$(input_password_hidden "Пароль")
    
    # Проверяем что пароль не пустой
    if [ -z "$SERVER_PASSWORD" ]; then
        error "Пароль не может быть пустым!"
        exit 1
    fi
    
    # Подтверждение конфигурации
    confirm_configuration "$SERVER_USER" "$SERVER_HOST" "$SERVER_PORT" "$SERVER_CONFIG_PATH"
    
    # Проверка подключения
    if ! test_ssh_connection "$SERVER_USER" "$SERVER_HOST" "$SERVER_PORT" "$SERVER_PASSWORD"; then
        error "Проверка подключения не удалась. Прерывание установки."
        exit 1
    fi
    
    # Сохраняем пароль в зашифрованном виде
    info "Шифрование и сохранение пароля..."
    if save_encrypted_password "$SERVER_PASSWORD"; then
        success "Пароль зашифрован и сохранен"
    else
        error "Ошибка при шифровании пароля"
        exit 1
    fi
    
    # Очищаем переменную с паролем из памяти
    unset SERVER_PASSWORD
    
    # Создаем конфигурационный файл БЕЗ пароля
    info "Создание конфигурационного файла..."
    cat > "$CONFIG_DIR/ssh_tunnel" << EOF
config tunnel 'settings'
    option server_user '$SERVER_USER'
    option server_host '$SERVER_HOST'
    option server_port '$SERVER_PORT'
    option server_config_path '$SERVER_CONFIG_PATH'
    option ssh_port '2200'
    option web_port '8000'
    option hostname 'openwrt'
    option use_autossh '1'
    option monitor_port '0'
    option ssh_timeout '30'
    option password_encrypted '1'
EOF
    
    success "Конфигурация сохранена в $CONFIG_DIR/ssh_tunnel"
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
    
    # Проверяем наличие openssl для шифрования
    if ! command -v openssl >/dev/null 2>&1; then
        info "Установка openssl для шифрования паролей..."
        opkg update
        opkg install openssl-util || {
            error "Не удалось установить openssl. Обязательно для шифрования!"
            exit 1
        }
    fi
    
    # Установка autossh если не установлен
    if ! command -v autossh >/dev/null 2>&1; then
        info "Установка autossh для автоматических переподключений..."
        opkg update
        if opkg install autossh; then
            success "autossh установлен"
        else
            warning "autossh не удалось установить, будет использоваться обычный ssh"
        fi
    else
        info "autossh уже установлен"
    fi
    
    success "Зависимости проверены"
}

# Загрузка файлов из репозитория
download_project_files() {
    info "Загрузка файлов проекта..."
    
    # Создаем временную директорию
    local temp_dir=$(mktemp -d)
    
    # Загружаем основные файлы
    for file in ssh_tunnel.sh ssh_tunnel.init; do
        if download_file "$REPO_URL/src/$file" "$temp_dir/$file"; then
            success "Загружен: $file"
        else
            error "Не удалось загрузить: $file"
            rm -rf "$temp_dir"
            return 1
        fi
    done
    
    # Копируем файлы в целевую директорию
    cp "$temp_dir/ssh_tunnel.sh" "$INSTALL_DIR/"
    cp "$temp_dir/ssh_tunnel.init" "$INIT_DIR/ssh_tunnel"
    
    # Устанавливаем права
    chmod +x "$INSTALL_DIR/ssh_tunnel.sh"
    chmod +x "$INIT_DIR/ssh_tunnel"
    
    # Очищаем временную директорию
    rm -rf "$temp_dir"
    
    success "Все файлы загружены и настроены"
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
    download_project_files
    
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
    echo "  Смена пароля: /root/ssh_tunnel.sh change-password"
    echo ""
    echo "Логи: tail -f /var/log/ssh_tunnel.log"
    echo ""
    info "Туннель будет автоматически запускаться при загрузке системы"
    info "Используется autossh для автоматических переподключений"
    info "Пароль зашифрован и защищен"
}

# Удаление (с очисткой зашифрованных данных)
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
    
    # Удаляем зашифрованные данные
    rm -f "$SECRET_KEY_FILE"
    rm -f "$PASSWORD_FILE"
    
    success "SSH Tunnel и все зашифрованные данные удалены"
}

# Смена пароля
change_password_interactive() {
    if [ -f "$INSTALL_DIR/ssh_tunnel.sh" ]; then
        "$INSTALL_DIR/ssh_tunnel.sh" change-password
    else
        error "Основной скрипт не найден"
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
    echo "  sh <(wget -O - URL/install.sh) password  - Смена пароля"
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
            info "Обновление через переустановку..."
            uninstall_ssh_tunnel
            install_ssh_tunnel
            ;;
        password)
            change_password_interactive
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
