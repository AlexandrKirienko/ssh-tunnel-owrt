#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import sys
import os
import csv
import tempfile
import logging
from datetime import datetime

# Настройка логирования в файл
LOG_FILE = "routers.log"

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - [%(funcName)s] - %(message)s',
    handlers=[
        logging.FileHandler(LOG_FILE, encoding='utf-8')
    ]
)

def main():
    # Проверяем количество аргументов
    if len(sys.argv) != 3:
        logging.error("Скрипт вызван с неверным количеством аргументов")
        print("Использование: python script.py <MAC-адрес> <Hostname>")
        sys.exit(1)
    
    mac_address = sys.argv[1]
    hostname = sys.argv[2]
    routers_file = "routers.csv"
    
    logging.info(f"--- Запрос для MAC: {mac_address} (Hostname: {hostname}) ---")
    
    # Проверяем или создаем файл
    if not os.path.exists(routers_file):
        logging.info(f"Файл БД {routers_file} не найден. Инициация создания.")
        create_routers_file(routers_file)
    
    # Ищем запись по MAC-адресу
    found, ssh_port, luci_port = find_router_by_mac(routers_file, mac_address)
    
    if found:
        # Обновляем дату и время обращения
        logging.info(f"Устройство {mac_address} опознано. Обновление метки времени.")
        update_last_access(routers_file, mac_address)
        print(f"{ssh_port},{luci_port}")
    else:
        # Добавляем новую запись
        logging.info(f"Новое устройство: {mac_address}. Запуск регистрации.")
        ssh_port, luci_port = add_new_router(routers_file, mac_address, hostname)
        print(f"{ssh_port},{luci_port}")

def safe_save_csv(filename, headers, rows):
    """Вспомогательная функция для безопасной записи в файл через временный файл"""
    logging.debug(f"Подготовка к записи {len(rows)} строк в {filename}")
    
    # Создаем временный файл в той же директории
    fd, temp_path = tempfile.mkstemp(dir=os.path.dirname(os.path.abspath(filename)), text=True)
    try:
        with os.fdopen(fd, 'w', newline='', encoding='utf-8') as temp_file:
            writer = csv.DictWriter(temp_file, fieldnames=headers)
            writer.writeheader()
            writer.writerows(rows)
        
        # Атомарно заменяем старый файл новым
        os.replace(temp_path, filename)
        logging.info(f"Файл {filename} успешно перезаписан.")
    except Exception as e:
        logging.error(f"Критическая ошибка при записи в {filename}: {e}")
        if os.path.exists(temp_path):
            os.remove(temp_path)
        raise e

def create_routers_file(filename):
    """Создает файл routers.csv с заголовками"""
    headers = ["Номер", "MAC-адрес", "Hostname", "Порт SSH", "Порт LuCi", 
               "Дата последнего обращения", "Время последнего обращения"]
    
    logging.info(f"Создание нового CSV файла с заголовками: {filename}")
    # Используем безопасную запись для инициализации файла
    safe_save_csv(filename, headers, [])

def find_router_by_mac(filename, mac_address):
    """Ищет роутер по MAC-адресу и возвращает порты если найден"""
    logging.debug(f"Поиск совпадений для MAC {mac_address}")
    try:
        with open(filename, 'r', newline='', encoding='utf-8') as file:
            reader = csv.DictReader(file)
            for row in reader:
                if row['MAC-адрес'].lower() == mac_address.lower():
                    logging.debug("Совпадение найдено.")
                    return True, row['Порт SSH'], row['Порт LuCi']
        logging.debug("Совпадений не найдено.")
        return False, None, None
    except Exception as e:
        logging.error(f"Ошибка при чтении {filename}: {e}")
        return False, None, None

def update_last_access(filename, mac_address):
    """Обновляет дату и время последнего обращения"""
    rows = []
    
    with open(filename, 'r', newline='', encoding='utf-8') as file:
        reader = csv.DictReader(file)
        headers = reader.fieldnames
        rows = list(reader)
    
    current_date = datetime.now().strftime("%Y-%m-%d")
    current_time = datetime.now().strftime("%H:%M:%S")
    
    changed = False
    for row in rows:
        if row['MAC-адрес'].lower() == mac_address.lower():
            row['Дата последнего обращения'] = current_date
            row['Время последнего обращения'] = current_time
            changed = True
            break
    
    if changed:
        safe_save_csv(filename, headers, rows)
        logging.info(f"Данные времени доступа для {mac_address} сохранены.")

def add_new_router(filename, mac_address, hostname):
    """Добавляет новый роутер в файл"""
    rows = []
    with open(filename, 'r', newline='', encoding='utf-8') as file:
        reader = csv.DictReader(file)
        headers = reader.fieldnames
        rows = list(reader)
    
    # Определяем следующий номер
    if rows:
        try:
            last_number = int(rows[-1]['Номер'])
            next_number = last_number + 1
        except (ValueError, IndexError) as e:
            logging.warning(f"Не удалось распарсить последний номер, используем длину списка: {e}")
            next_number = len(rows) + 1
    else:
        next_number = 1
    
    formatted_number = f"{next_number:03d}"
    ssh_port = f"12{formatted_number}"
    luci_port = f"18{formatted_number}"
    
    new_row = {
        'Номер': formatted_number,
        'MAC-адрес': mac_address,
        'Hostname': hostname,
        'Порт SSH': ssh_port,
        'Порт LuCi': luci_port,
        'Дата последнего обращения': datetime.now().strftime("%Y-%m-%d"),
        'Время последнего обращения': datetime.now().strftime("%H:%M:%S")
    }
    
    rows.append(new_row)
    safe_save_csv(filename, headers, rows)
    logging.info(f"Устройство зарегистрировано под номером {formatted_number}. Выделены порты SSH:{ssh_port}, LuCi:{luci_port}")
    
    return ssh_port, luci_port

if __name__ == "__main__":
    main()
