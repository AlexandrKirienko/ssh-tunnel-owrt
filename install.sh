#!/bin/sh

set -e

# Константы
REPO_URL="https://raw.githubusercontent.com/AlexandrKirienko/ssh-tunnel-owrt/master"
INSTALL_DIR="/root"
CONFIG_DIR="/etc/config"
INIT_DIR="/etc/init.d"
LOG_DIR="/var/log"
SSH_KEY="$HOME/.ssh/id_dropbear"


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



# Загрузка файла с проверкой
download_file() {
    local url="$1"
    local output="$2"
    local max_retries=3
    local retry=0
    
    info "Загрузка: $(basename "$output")"
    
    while [ $retry -lt $max_retries ]; do
        # Для OpenWRT используем совместимый синтаксис
            if wget -h 2>&1 | grep -q "tries"; then
                # Полная версия wget
                wget --timeout=30 --tries=2 -q "$url" -O "$output" 2>/dev/null && return 0
            else
                # Busybox wget
                wget -T 30 -q "$url" -O "$output" 2>/dev/null && return 0
            fi
        
        retry=$((retry + 1))
        if [ $retry -lt $max_retries ]; then
            warning "Попытка $retry не удалась, повтор через 2 секунды..."
            sleep 2
        fi
    done
    
    error "Не удалось загрузить файл: $(basename "$output")"
    
    # Диагностика
    info "Проверка доступности URL..."
    if wget -T 10 -O /dev/null --spider "$url" 2>/dev/null; then
        info "URL доступен, но загрузка не удалась"
    else
        info "URL недоступен"
    fi
    
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

# Функция для проверки подключения по SSH с ключом
check_ssh_key_connection() {
	local user="$1"
    local host="$2"
    local port="$3"
    info "Проверяем подключение по SSH с ключом..."
    ssh -o BatchMode=yes -o ConnectTimeout=5 -p "$port" -i $SSH_KEY "$user@$host" "echo 'SSH connection with key successful'" 2>/dev/null
    return $?
}

# Получаем hostname роутера
get_hostname() {
    uci get system.@system[0].hostname 2>/dev/null || cat /proc/sys/kernel/hostname 2>/dev/null || echo "openwrt"
}

load_config() {
    if [ -f "$CONFIG_DIR/ssh_tunnel" ]; then
        SERVER_USER=$(uci get ssh_tunnel.settings.server_user 2>/dev/null || echo "root")
        SERVER_HOST=$(uci get ssh_tunnel.settings.server_host 2>/dev/null || echo "example.com")
        SERVER_PORT=$(uci get ssh_tunnel.settings.server_port 2>/dev/null || echo "22")
        SERVER_PASSWORD=$(uci get ssh_tunnel.settings.server_password 2>/dev/null)
    fi
}

# Функция для проверки подключения по SSH с паролем
check_ssh_password_connection() {
	local user="$1"
    local host="$2"
    local port="$3"
    local password="$4"
    info "Проверяем подключение по SSH с паролем..."
	
    # Используем sshpass для автоматизации ввода пароля
    if sshpass -p "$password" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -p "$port" "$user@$host" "echo 'Connection successful'" 2>/dev/null; then
        success "Подключение к серверу успешно!"
        return 0
    else
        error "Не удалось подключиться к серверу. Проверьте параметры."
        return 1
    fi
}

generate_ssh_key() {
    info "Генерируем SSH ключ..."
	
	local hostname=$(get_hostname)
	
    if [ ! -f "$SSH_KEY" ]; then
        dropbearkey -t ed25519 -f "$SSH_KEY" -C "$hostname"
        if [ $? -eq 0 ]; then
            success "SSH ключ успешно сгенерирован: $SSH_KEY"
            return 0
        else
            error "Ошибка генерации SSH ключа"
            return 1
        fi
    else
        info "SSH ключ уже существует: $SSH_KEY"
        return 0
    fi
}

# Функция для копирования SSH ключа на сервер
copy_ssh_key2() {
    local user="$1"
    local host="$2"
    local port="$3"
    local password="$4"
    info "Копируем SSH ключ на сервер..."
	local pub_key=$(cat "${SSH_KEY}.pub")
	if [ -z "$pub_key" ]; then
        error "Не удалось прочитать публичный ключ"
        return 1
    fi
	
	if sshpass -p "$password" ssh -p "$port" -o StrictHostKeyChecking=no "$user@$host" \
            "mkdir -p ~/.ssh && \
             chmod 700 ~/.ssh && \
             echo '$pub_key' >> ~/.ssh/authorized_keys && \
             chmod 600 ~/.ssh/authorized_keys" 2>/dev/null; then
            success "SSH ключ успешно скопирован на $host"
            return 0
    else
        error "Не удалось скопировать SSH ключ на $host"
        return 1
    fi	
}

# Проверка подключения к серверу
test_ssh_connection() {
    local user="$1"
    local host="$2"
    local port="$3"
    local password="$4"
    
    info "Проверка подключения к серверу..."
		
	if check_ssh_password_connection "$user" "$host" "$port" "$password"; then
        success  "Успешное подключение по SSH с паролем"
        # Генерируем ключ если его нет
        if generate_ssh_key; then
            # Копируем ключ на сервер
            if copy_ssh_key2 "$user" "$host" "$port" "$password"; then
                success "SSH ключ успешно скопирован на сервер"
                # Проверяем подключение с ключом после копирования
                info "Проверяем подключение с новым ключом..."
                if check_ssh_key_connection "$user" "$host" "$port"; then
                    success "Успешное подключение по SSH с ключом после настройки!"
                    return 0
                else
                    error "Не удалось подключиться с ключом после копирования"
                    return 1
                fi
            else
                error "Ошибка копирования SSH ключа на сервер"
                return 1
            fi
        else
            error "Ошибка генерации SSH ключа"
            return 1
        fi
    else
        error "Не удалось подключиться ни с ключом, ни с паролем"
        return 1
    fi
}

# Интерактивная настройка конфигурации
interactive_setup() {
    info "=== Настройка SSH туннеля ==="
	
	if check_ssh_key_connection "$SERVER_USER" "$SERVER_HOST" "$SERVER_PORT"; then
        success "Успешное подключение по SSH с ключом!"
		success "Подключение уже сконфигурировано"
        return 0
    else
		warning "Не удалось подключиться с ключом"
    fi
	
    # Запрос параметров сервера
    SERVER_USER=$(input_with_default "Имя пользователя на сервере" "$SERVER_USER")
    SERVER_PASSWORD=$(input_with_default "Пароль" "$SERVER_PASSWORD")
	SERVER_HOST=$(input_with_default "Адрес сервера" "$SERVER_HOST")
    SERVER_PORT=$(input_with_default "SSH порт сервера" "$SERVER_PORT")
    # Проверяем что пароль не пустой
    if [ -z "$SERVER_PASSWORD" ]; then
        error "Пароль не может быть пустым!"
        exit 1
    fi 
    
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
   
    success "Зависимости проверены"
}

# Основная установка
install_ssh_tunnel() {
    info "Начинаем установку SSH Tunnel..."
    
    # Проверяем систему
    check_openwrt
       
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
        error "Не удалось загрузить основной скрипт"
		return 1
    fi
    
    if download_file "$REPO_URL/src/ssh_tunnel.init" "$INIT_DIR/ssh_tunnel.tmp"; then
        mv "$INIT_DIR/ssh_tunnel.tmp" "$INIT_DIR/ssh_tunnel"
        chmod +x "$INIT_DIR/ssh_tunnel"
        success "Init скрипт загружен"
    else
        error "Не удалось загрузить init скрипт, создаем локально"
		return 1
    fi
    
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
    
    echo "Команды управления:"
    echo "  Запуск: /etc/init.d/ssh_tunnel start"
    echo "  Остановка: /etc/init.d/ssh_tunnel stop"
    echo "  Статус: /etc/init.d/ssh_tunnel status"
    echo "  Информация: /root/ssh_tunnel.sh info"
    echo ""
    echo "Логи: tail -f /var/log/ssh_tunnel.log"

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

# Показать помощь
show_help() {
    echo -e "${BLUE}SSH Tunnel Installer для OpenWRT${NC}"
    echo ""
    echo "Использование:"
    echo "  sh <(wget -O - URL/install.sh)           - Интерактивная установка"
    echo "  sh <(wget -O - URL/install.sh) install   - Установка"
    echo "  sh <(wget -O - URL/install.sh) uninstall - Удаление"
    echo "  sh <(wget -O - URL/install.sh) help      - Помощь"
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
