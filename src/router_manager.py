#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import sys
import os
import csv
from datetime import datetime

def main():
    # Проверяем количество аргументов
    if len(sys.argv) != 3:
        print("Использование: python script.py <MAC-адрес> <Hostname>")
        sys.exit(1)
    
    mac_address = sys.argv[1]
    hostname = sys.argv[2]
    routers_file = "routers.csv"
    
    # Проверяем или создаем файл
    if not os.path.exists(routers_file):
        create_routers_file(routers_file)
    
    # Ищем запись по MAC-адресу
    found, ssh_port, luci_port = find_router_by_mac(routers_file, mac_address)
    
    if found:
        # Обновляем дату и время обращения
        update_last_access(routers_file, mac_address)
        print(f"{ssh_port},{luci_port}")
    else:
        # Добавляем новую запись
        ssh_port, luci_port = add_new_router(routers_file, mac_address, hostname)
        print(f"{ssh_port},{luci_port}")

def create_routers_file(filename):
    """Создает файл routers.csv с заголовками"""
    headers = ["Номер", "MAC-адрес", "Hostname", "Порт SSH", "Порт LuCi", 
               "Дата последнего обращения", "Время последнего обращения"]
    
    with open(filename, 'w', newline='', encoding='utf-8') as file:
        writer = csv.writer(file)
        writer.writerow(headers)

def find_router_by_mac(filename, mac_address):
    """Ищет роутер по MAC-адресу и возвращает порты если найден"""
    try:
        with open(filename, 'r', newline='', encoding='utf-8') as file:
            reader = csv.DictReader(file)
            for row in reader:
                if row['MAC-адрес'].lower() == mac_address.lower():
                    return True, row['Порт SSH'], row['Порт LuCi']
        return False, None, None
    except FileNotFoundError:
        return False, None, None

def update_last_access(filename, mac_address):
    """Обновляет дату и время последнего обращения"""
    rows = []
    
    with open(filename, 'r', newline='', encoding='utf-8') as file:
        reader = csv.DictReader(file)
        headers = reader.fieldnames
        rows = list(reader)
    
    # Обновляем дату и время
    current_date = datetime.now().strftime("%Y-%m-%d")
    current_time = datetime.now().strftime("%H:%M:%S")
    
    for row in rows:
        if row['MAC-адрес'].lower() == mac_address.lower():
            row['Дата последнего обращения'] = current_date
            row['Время последнего обращения'] = current_time
            break
    
    # Записываем обновленные данные обратно в файл
    with open(filename, 'w', newline='', encoding='utf-8') as file:
        writer = csv.DictWriter(file, fieldnames=headers)
        writer.writeheader()
        writer.writerows(rows)

def add_new_router(filename, mac_address, hostname):
    """Добавляет новый роутер в файл"""
    # Читаем существующие данные
    rows = []
    with open(filename, 'r', newline='', encoding='utf-8') as file:
        reader = csv.DictReader(file)
        headers = reader.fieldnames
        rows = list(reader)
    
    # Определяем следующий номер
    if rows:
        last_number = int(rows[-1]['Номер'])
        next_number = last_number + 1
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
    
    # Добавляем новую запись и сохраняем
    rows.append(new_row)
    
    with open(filename, 'w', newline='', encoding='utf-8') as file:
        writer = csv.DictWriter(file, fieldnames=headers)
        writer.writeheader()
        writer.writerows(rows)
    
    return ssh_port, luci_port

if __name__ == "__main__":
    main()
