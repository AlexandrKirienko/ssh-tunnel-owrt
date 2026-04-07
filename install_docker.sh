#!/bin/bash

# Цвета для вывода
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}===> Обновление индексов пакетов...${NC}"
sudo apt-get update

echo -e "${BLUE}===> Установка необходимых зависимостей...${NC}"
sudo apt-get install -y ca-certificates curl gnupg

# Создаем директорию для ключей, если её нет
sudo install -m 0755 -d /etc/apt/keyrings

# Добавляем официальный GPG-ключ Docker
echo -e "${BLUE}===> Настройка GPG-ключа Docker...${NC}"
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes
sudo chmod a+r /etc/apt/keyrings/docker.gpg

# Настраиваем репозиторий
echo -e "${BLUE}===> Настройка репозитория Docker...${NC}"
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

echo -e "${BLUE}===> Обновление базы пакетов после добавления репозитория...${NC}"
sudo apt-get update

echo -e "${BLUE}===> Установка/Обновление Docker и Docker Compose...${NC}"
# Устанавливаем docker-ce и docker-compose-plugin (актуальная версия v2)
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Проверка статуса
echo -e "${GREEN}===> Проверка версий:${NC}"
docker --version
docker compose version

# Опционально: добавление текущего пользователя в группу docker
# Чтобы можно было запускать docker без sudo
echo -e "${BLUE}===> Настройка прав доступа (группа docker)...${NC}"
if ! getent group docker > /dev/null; then
    sudo groupadd docker
fi
sudo usermod -aG docker $USER

echo -e "${GREEN}--------------------------------------------------${NC}"
echo -e "${GREEN}Установка завершена!${NC}"
echo -e "${GREEN}ВАЖНО: Чтобы команды docker работали без sudo,${NC}"
echo -e "${GREEN}выйдите из системы и зайдите снова (или выполните: newgrp docker)${NC}"
