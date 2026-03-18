#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import sys
import os
import csv
import tempfile
import logging
from datetime import datetime

# Настройка логирования: выводим время, уровень важности и сообщение
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    stream=sys.stderr  # Логи пойдут в stderr, чтобы не мешать выводу портов в stdout
)

def main():
    # Проверяем количество аргументов
    if len(sys.argv) != 3:
        logging.error("Неверное количество аргументов")
        print("Использование: python script.py <MAC-адрес> <Hostname>")
        sys.exit(1)
    
    mac_address = sys.argv[1]
    hostname = sys.argv[2]
    routers_file = "routers.csv"
    
    logging.info(f"Запуск скрипта для MAC: {mac_address}, Hostname: {hostname}")
    
    # Проверяем или создаем файл
    if not os.path.exists(routers_file):
        logging.info(f"Файл {routers_file} не найден. Создаем новый.")
        create_routers_file(routers_file)
    
    # Ищем запись по MAC-адресу
    found, ssh_port, luci_port = find_router_by_mac(routers_file, mac_address)
    
    if found:
        # Обновляем дату и время обращения
        logging.info(f"Роутер {mac_address} найден. Обновляем время доступа.")
        update_last_access(routers_file, mac_address)
        print(f"{ssh_port},{luci_port}")
    else:
        # Добавляем новую запись
        logging.info(f"Роутер {mac_address} не найден. Добавляем новую запись.")
        ssh_port, luci_port = add_new_router(routers_file, mac_address, hostname)
        print(f"{ssh_port},{luci_port}")

def safe_save_csv(filename, headers, rows):
    """Вспомогательная функция для безопасной записи в файл через временный файл"""
    logging.debug(f"Начало безопасной записи в {filename}")
    # Создаем временный файл в той же директории
    fd, temp_path = tempfile.mkstemp(dir=os.path.dirname(os.path.abspath(filename)), text=True)
    try:
        with os.fdopen(fd, 'w', newline='', encoding='utf-8') as temp_file:
            writer = csv.DictWriter(temp_file, fieldnames=headers)
            writer.writeheader()
            writer.writerows(rows)
        
        # Атомарно заменяем старый файл новым
        os.replace(temp_path, filename)
        logging.debug(f"Файл {filename} успешно обновлен через {temp_path}")
    except Exception as e:
        # Если что-то пошло не так, удаляем временный файл
        logging.error(f"Ошибка при записи во временный файл: {e}")
        if os.path.exists(temp_path):
            os.remove(temp_path)
        raise e

def create_routers_file(filename):
    """Создает файл routers.csv с заголовками"""
    logging.info(f"Инициализация файла {filename}")
    headers = ["Номер", "MAC-адрес", "Hostname", "Порт SSH", "Порт LuCi", 
               "Дата последнего обращения", "Время последнего обращения"]
    
    # Используем безопасную запись для инициализации файла
    safe_save_csv(filename, headers, [])

def find_router_by_mac(filename, mac_address):
    """Ищет роутер по MAC-адресу и возвращает порты если найден"""
    logging.debug(f"Поиск MAC: {mac_address} в файле {filename}")
    try:
        with open(filename, 'r', newline='', encoding='utf-8') as file:
            reader = csv.DictReader(file)
            for row in reader:
                if row['MAC-адрес'].lower() == mac_address.lower():
                    return True, row['Порт SSH'], row['Порт LuCi']
        return False, None, None
    except (FileNotFoundError, KeyError) as e:
        logging.warning(f"Ошибка при поиске: {e}")
        return False, None, None

def update_last_access(filename, mac_address):
    """Обновляет дату и время последнего обращения"""
    rows = []
    
    logging.debug(f"Чтение данных для обновления времени доступа MAC: {mac_address}")
    with open(filename, 'r', newline='', encoding='utf-8') as file:
        reader = csv.DictReader(file)
        headers = reader.fieldnames
        rows = list(reader)
    
    # Обновляем дату и время
    current_date = datetime.now().strftime("%Y-%m-%d")
    current_time = datetime.now().strftime("%H:%M:%S")
    
    changed = False
    for row in rows:
        if row['MAC-адрес'].lower() == mac_address.lower():
            row['Дата последнего обращения'] = current_date
            row['Время последнего обращения'] = current_time
            changed = True
            break
    
    # Записываем обновленные данные обратно в файл через временный файл
    if changed:
        safe_save_csv(filename, headers, rows)
        logging.info(f"Время последнего обращения для {mac_address} обновлено.")

def add_new_router(filename, mac_address, hostname):
    """Добавляет новый роутер в файл"""
    logging.debug(f"Подготовка к добавлению нового роутера: {hostname} ({mac_address})")
    # Читаем существующие данные
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
        except (ValueError, IndexError):
            next_number = len(rows) + 1
    else:
        next_number = 1
    
    # Форматируем номер с ведущими нулями
    formatted_number = f"{next_number:03d}"
    
    # Генерируем порты
    ssh_port = f"12{formatted_number}"
    luci_port = f"18{formatted_number}"
    
    # Текущие дата и время
    current_date = datetime.now().strftime("%Y-%m-%d")
    current_time = datetime.now().strftime("%H:%M:%S")
    
    # Создаем новую запись
    new_row = {
        'Номер': formatted_number,
        'MAC-адрес': mac_address,
        'Hostname': hostname,
        'Порт SSH': ssh_port,
        'Порт LuCi': luci_port,
        'Дата последнего обращения': current_date,
        'Время последнего обращения': current_time
    }
    
    # Добавляем новую запись и сохраняем через временный файл
    rows.append(new_row)
    safe_save_csv(filename, headers, rows)
    
    logging.info(f"Добавлен новый роутер: {formatted_number}, порты {ssh_port}/{luci_port}")
    
    return ssh_port, luci_port

if __name__ == "__main__":
    main()
