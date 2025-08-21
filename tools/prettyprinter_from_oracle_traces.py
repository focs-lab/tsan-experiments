#!/usr/bin/env python3

import sys
import os
import re

def print_pretty_table(header, rows):
    """
    Печатает список строк в виде хорошо отформатированной таблицы.
    """
    if not header or not rows:
        print("Нет данных для отображения.")
        return

    # 1. Рассчитываем максимальную ширину для каждого столбца
    col_widths = [len(h) for h in header]
    for row in rows:
        for i, cell in enumerate(row):
            if i < len(col_widths):
                if len(str(cell)) > col_widths[i]:
                    col_widths[i] = len(str(cell))

    # 2. Создаем строку формата для заголовка и строк
    row_format = "| " + " | ".join([f"{{:<{w}}}" for w in col_widths]) + " |"

    # 3. Создаем разделительную линию
    separator = "+-" + "-+-".join(["-" * w for w in col_widths]) + "-+"

    # 4. Печатаем таблицу
    print(separator)
    print(row_format.format(*header))
    print(separator)

    for row in rows:
        print(row_format.format(*row))

    print(separator)

def parse_log_file(filepath):
    """
    Разбирает один файл журнала для извлечения показателей `Unique addresses` и `Accesses`.
    Он ищет последние ненулевые значения в файле.
    """
    unique_addresses = None
    accesses = None

    # Регулярные выражения для поиска строк с нашими метриками
    addr_re = re.compile(r"^Unique addresses:\s+(\d+)")
    acc_re = re.compile(r"^Accesses:\s+(\d+)")

    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            for line in f:
                addr_match = addr_re.match(line)
                if addr_match:
                    val = addr_match.group(1)
                    # Сохраняем только ненулевые значения
                    if int(val) > 0:
                        unique_addresses = val

                acc_match = acc_re.match(line)
                if acc_match:
                    val = acc_match.group(1)
                    # Сохраняем только ненулевые значения
                    if int(val) > 0:
                        accesses = val
    except Exception:
        # Игнорируем файлы, которые не удается прочитать или разобрать
        return None

    # Возвращаем данные, только если мы нашли что-то значимое
    if unique_addresses is not None and accesses is not None:
        return os.path.basename(filepath), unique_addresses, accesses
    else:
        return None

def main():
    """
    Главная функция.
    """
    if len(sys.argv) < 2:
        print(f"Использование: {sys.argv[0]} <путь_к_папке_с_логами>", file=sys.stderr)
        sys.exit(1)

    logs_dir = sys.argv[1]

    if not os.path.isdir(logs_dir):
        print(f"Ошибка: Указанный путь '{logs_dir}' не является директорией.", file=sys.stderr)
        sys.exit(1)

    all_metrics = []
    # Перебираем все файлы в указанной директории
    for filename in sorted(os.listdir(logs_dir)):
        if filename.endswith(".log"):
            filepath = os.path.join(logs_dir, filename)
            metrics = parse_log_file(filepath)
            if metrics:
                all_metrics.append(metrics)

    if all_metrics:
        header = ['Log File', 'Unique addresses', 'Accesses']
        print_pretty_table(header, all_metrics)
    else:
        print("Не найдено валидных лог-файлов или не удалось извлечь метрики.")

if __name__ == "__main__":
    main()