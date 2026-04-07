# SSH Tunnel для OpenWRT

Автоматический обратный SSH туннель для удаленного доступа к OpenWRT роутерам.

## Особенности установки

- **Интерактивная настройка** - ввод параметров сервера во время установки
- **Подключение по паролю** - автоматическая настройка SSH ключей
- **Автоматическая аутентификация** - после установки работает по ключам

## Быстрая установка

```bash
# Автоматическая установка с интерактивной настройкой
sh <(wget -O - https://raw.githubusercontent.com/AlexandrKirienko/ssh-tunnel-owrt/master/install.sh)
```

## Установка AWG 2.0 Для 24.10.2 

```bash
# Автоматическая установка с интерактивной настройкой
sh <(wget -O - https://raw.githubusercontent.com/AlexandrKirienko/ssh-tunnel-owrt/refs/heads/main/amneziawg24.10.2-install.sh)
```

## Установка Docke+Docker Compouse ubuntu
```bash
# Автоматическая установка с интерактивной настройкой
sh <(wget -O - https://raw.githubusercontent.com/AlexandrKirienko/ssh-tunnel-owrt/refs/heads/main/install_docker.sh)
```
