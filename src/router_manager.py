#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import sys
import os
import csv
import tempfile
from datetime import datetime

def main():
    if len(sys.argv) != 3:
        print("Использование: python script.py <MAC-адрес> <Hostname>")
        sys.exit(1)
    
    mac_address = sys.argv[1]
    hostname = sys.argv[2]
    routers_file = "routers.csv"
    
    if not os.path.exists(routers_file):
        create_routers_file(routers_file)
    
    found, ssh_port, luci_port = find_router_by_mac(routers_file, mac_address)
    
    if found:
        update_last_access(routers_file, mac_address)
        print(f"{ssh_port},{luci_port}")
    else:
        ssh_port, luci_port = add_new_router(routers_file, mac_address, hostname)
        print(f"{ssh_port},{luci_port}")

def safe_save_csv(filename, headers, rows):
    """Безопасная запись в файл через временный файл"""
    # Создаем временный файл в той же директории, что и целевой
    fd, temp_path = tempfile.mkstemp(dir=os.path.dirname(os.path.abspath(filename)), text=True)
    try:
        with os.fdopen(fd, 'w', newline='', encoding='utf-8') as temp_file:
            writer = csv.DictWriter(temp_file, fieldnames=headers)
            writer.writeheader()
            writer.writerows(rows)
        
        # Атомарно заменяем старый файл новым
        os.replace(temp_path, filename)
    except Exception as e:
        if os.path.exists(temp_path):
            os.remove(temp_path)
        raise e

def create_routers_file(filename):
    """Создает файл с заголовками, если его нет"""
    headers = ["Номер", "MAC-адрес", "Hostname", "Порт SSH", "Порт LuCi", 
               "Дата последнего обращения", "Время последнего обращения"]
    # Для создания пустого файла тоже используем безопасный метод
    safe_save_csv(filename, headers, [])

def find_router_by_mac(filename, mac_address):
    try:
        with open(filename, 'r', newline='', encoding='utf-8') as file:
            reader = csv.DictReader(file)
            for row in reader:
                if row['MAC-адрес'].lower() == mac_address.lower():
                    return True, row['Порт SSH'], row['Порт LuCi']
        return False, None, None
    except (FileNotFoundError, KeyError):
        return False, None, None

def update_last_access(filename, mac_address):
    rows = []
    headers = []
    
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

def add_new_router(filename, mac_address, hostname):
    rows = []
    with open(filename, 'r', newline='', encoding='utf-8') as file:
        reader = csv.DictReader(file)
        headers = reader.fieldnames
        rows = list(reader)
    
    if rows:
        try:
            last_number = int(rows[-1]['Номер'])
            next_number = last_number + 1
        except (ValueError, IndexError):
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
    
    return ssh_port, luci_port

if __name__ == "__main__":
    main()
