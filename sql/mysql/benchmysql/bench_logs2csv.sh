#!/bin/bash

# Имя выходного CSV-файла с текущей датой и временем
CSV_OUTPUT_FILE="results_mysql_$(date +%y%m%d_%H%M).csv"

# Создаем файл и записываем в него заголовок CSV
echo "MySQL build,Sysbench script,Transactions/sec,Queries/sec,Read ops,Write ops,Other ops,Total" > "$CSV_OUTPUT_FILE"

# Перебираем все файлы, соответствующие шаблону benchmark_*.txt
for i in benchmark_*.txt; do
	# --- Парсинг имени файла ---
	IFS="_" read -a FILENAME_FIELDS <<< "$i"
	MYSQL_BUILD_NAME="${FILENAME_FIELDS[1]}"
	MYSQL_SYSBENCH_SCRIPT="${FILENAME_FIELDS[2]//\.txt/.lua}"
	echo "Reading logs for build $MYSQL_BUILD_NAME, script $MYSQL_SYSBENCH_SCRIPT..."

	# --- Извлечение данных из содержимого файла (с использованием sub()) ---

	# Извлекаем "transactions per sec". Ищем строку "transactions:",
	# затем с помощью sub() убираем первую скобку '(' из 4-го поля ($4).
	TRANSACTIONS_PER_SEC=$(awk '/transactions:/ { sub(/\(/, "", $4); print $4 }' "$i")
	#'

	# Извлекаем "queries per sec". Используем sub() для 3-го поля ($3).
	QUERIES_PER_SEC=$(awk '/queries:/ && !/performed/ { sub(/\(/, "", $3); print $3 }' "$i")
	#'

	# Остальные команды остаются без изменений, т.к. не используют gawk-расширений
	READ_OPS=$(awk '/read:/ { print $2 }' "$i")
	WRITE_OPS=$(awk '/write:/ { print $2 }' "$i")
	OTHER_OPS=$(awk '/other:/ { print $2 }' "$i")
	TOTAL_OPS=$(awk '/total:/ && !/time/ { print $2 }' "$i")
    
    # Защита на случай, если какая-то из операций отсутствует
    READ_OPS=${READ_OPS:-0}
    WRITE_OPS=${WRITE_OPS:-0}
    OTHER_OPS=${OTHER_OPS:-0}
    TOTAL_OPS=${TOTAL_OPS:-0}

	# --- Запись строки в CSV-файл ---
	echo "${MYSQL_BUILD_NAME},${MYSQL_SYSBENCH_SCRIPT},${TRANSACTIONS_PER_SEC},${QUERIES_PER_SEC},${READ_OPS},${WRITE_OPS},${OTHER_OPS},${TOTAL_OPS}" >> "$CSV_OUTPUT_FILE"
done
