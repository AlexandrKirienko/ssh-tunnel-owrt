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
NC='\033[0m' # No Color

# Функции для вывода
info() { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

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

# Создание SSH ключа если нет
create_ssh_key() {
    if [ ! -f "/root/.ssh/id_rsa" ]; then
        info "Создание SSH ключа..."
        mkdir -p /root/.ssh
        chmod 700 /root/.ssh
        ssh-keygen -t rsa -b 4096 -f /root/.ssh/id_rsa -N "" -q
        success "SSH ключ создан: /root/.ssh/id_rsa"
    else
        info "SSH ключ уже существует"
    fi
}

# Установка зависимостей
install_dependencies() {
    info "Проверка зависимостей..."
    
    if ! command -v ssh >/dev/null 2>&1; then
        warning "SSH клиент не найден, устанавливаем..."
        opkg update
        opkg install openssh-client-utils
        success "SSH клиент установлен"
    fi
    
    if ! command -v nc >/dev/null 2>&1; then
        info "Установка netcat (опционально)..."
        opkg update
        opkg install netcat || warning "Netcat не установлен, некоторые функции могут не работать"
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
    
    # Создаем SSH ключ
    create_ssh_key
    
    # Загружаем файлы
    info "Загрузка файлов..."
    
    download_file "$REPO_URL/src/ssh_tunnel.sh" "$INSTALL_DIR/ssh_tunnel.sh"
    download_file "$REPO_URL/src/ssh_tunnel.init" "$INIT_DIR/ssh_tunnel"
    download_file "$REPO_URL/src/ssh_tunnel.config" "$CONFIG_DIR/ssh_tunnel"
    
    # Делаем файлы исполняемыми
    chmod +x "$INSTALL_DIR/ssh_tunnel.sh"
    chmod +x "$INIT_DIR/ssh_tunnel"
    
    # Создаем log файл
    touch "$LOG_DIR/ssh_tunnel.log"
    chmod 644 "$LOG_DIR/ssh_tunnel.log"
    
    success "Файлы успешно установлены"
    
    # Показываем публичный ключ
    echo ""
    info "=== Ваш SSH публичный ключ ==="
    cat /root/.ssh/id_rsa.pub 2>/dev/null || \
        error "Не удалось прочитать публичный ключ. Сгенерируйте вручную: ssh-keygen"
    echo "==============================="
    
    # Конфигурация
    echo ""
    info "Настройка конфигурации..."
    echo "Отредактируйте файл конфигурации: nano $CONFIG_DIR/ssh_tunnel"
    echo ""
    echo "Основные параметры для изменения:"
    echo "  option server_user 'ваш_пользователь'"
    echo "  option server_host 'ваш-сервер.com'"
    echo "  option server_config_path '/путь/к/tunnel_configs.txt'"
    echo ""
    warning "Не забудьте добавить публичный ключ на сервер!"
    echo "Команда для копирования ключа: ssh-copy-id -i /root/.ssh/id_rsa.pub user@server"
    
    # Включаем автозапуск
    "$INIT_DIR/ssh_tunnel" enable
    success "Автозапуск включен"
    
    echo ""
    success "=== Установка завершена! ==="
    echo ""
    echo "Команды управления:"
    echo "  Запуск: /etc/init.d/ssh_tunnel start"
    echo "  Остановка: /etc/init.d/ssh_tunnel stop"
    echo "  Статус: /etc/init.d/ssh_tunnel status"
    echo "  Прямой вызов: /root/ssh_tunnel.sh info"
    echo ""
    echo "Сначала настройте конфигурацию, затем запустите туннель:"
    echo "  /etc/init.d/ssh_tunnel start"
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
    
    # Не удаляем SSH ключи специально!
    
    success "SSH Tunnel удален"
    warning "SSH ключи сохранены в /root/.ssh/"
}

# Обновление
update_ssh_tunnel() {
    info "Обновление SSH Tunnel..."
    
    # Останавливаем службу
    if [ -f "$INIT_DIR/ssh_tunnel" ]; then
        "$INIT_DIR/ssh_tunnel" stop 2>/dev/null || true
    fi
    
    # Загружаем новые версии файлов
    download_file "$REPO_URL/src/ssh_tunnel.sh" "$INSTALL_DIR/ssh_tunnel.sh.tmp"
    download_file "$REPO_URL/src/ssh_tunnel.init" "$INIT_DIR/ssh_tunnel.tmp"
    
    # Проверяем что загрузка успешна перед заменой
    if [ -f "$INSTALL_DIR/ssh_tunnel.sh.tmp" ] && [ -f "$INIT_DIR/ssh_tunnel.tmp" ]; then
        mv "$INSTALL_DIR/ssh_tunnel.sh.tmp" "$INSTALL_DIR/ssh_tunnel.sh"
        mv "$INIT_DIR/ssh_tunnel.tmp" "$INIT_DIR/ssh_tunnel"
        
        chmod +x "$INSTALL_DIR/ssh_tunnel.sh"
        chmod +x "$INIT_DIR/ssh_tunnel"
        
        success "Файлы обновлены"
        
        # Запускаем службу
        "$INIT_DIR/ssh_tunnel" start
        success "Служба запущена"
    else
        error "Ошибка при обновлении файлов"
        exit 1
    fi
}

# Показать помощь
show_help() {
    echo -e "${BLUE}SSH Tunnel Installer для OpenWRT${NC}"
    echo ""
    echo "Использование:"
    echo "  sh <(wget -O - $REPO_URL/install.sh) install    - Установка"
    echo "  sh <(wget -O - $REPO_URL/install.sh) uninstall  - Удаление"
    echo "  sh <(wget -O - $REPO_URL/install.sh) update     - Обновление"
    echo "  sh <(wget -O - $REPO_URL/install.sh) help       - Помощь"
    echo ""
    echo "Прямая установка одной командой:"
    echo "  sh <(wget -O - $REPO_URL/install.sh)"
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
