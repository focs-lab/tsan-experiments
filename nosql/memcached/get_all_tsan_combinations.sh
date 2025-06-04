#!/bin/bash

source config_definitions.sh

# Массив для хранения найденных суффиксов
TSAN_SUFFIXES_TEMP=()
for KEY in "${!CONFIG_DETAILS[@]}"; do
	# Проверяем, начинается ли ключ с "tsan-" и есть ли что-то после дефиса
	if [[ "$KEY" == "tsan-"* && "$KEY" != "tsan" ]]; then
		# Извлекаем суффикс (все, что после "tsan-")
		SUFFIX="${KEY#tsan-}"
		# Добавляем суффикс в массив, если он не пустой
		if [[ -n "$SUFFIX" ]]; then
			TSAN_SUFFIXES_TEMP+=("$SUFFIX")
		fi
	fi
done

if [ ${#TSAN_SUFFIXES_TEMP[@]} -eq 0 ]; then
	echo "Суффиксы для tsan-ключей не найдены. Нечего комбинировать."
	exit 0
fi


# Для примера и тестирования, можно задать TSAN_SUFFIXES напрямую:
# TSAN_SUFFIXES_TEMP=("lo" "st" "swmr" "ea" "dom")
# Если нужно использовать только определенный набор:
# TSAN_SUFFIXES_TEMP=("st" "swmr" "dom")


if [ ${#TSAN_SUFFIXES_TEMP[@]} -eq 0 ]; then
	echo "Суффиксы для tsan-ключей не найдены. Нечего комбинировать."
	exit 0
fi

# 2. Сортируем суффиксы, чтобы комбинации были в каноническом порядке
# (например, "dom-lo-st", а не "st-lo-dom" или "lo-st-dom")
# Это гарантирует уникальность при генерации.
mapfile -t SORTED_TSAN_SUFFIXES < <(printf "%s\n" "${TSAN_SUFFIXES_TEMP[@]}" | sort)

# Отладочный вывод отсортированных суффиксов
# echo "Отсортированные суффиксы для комбинаций:"
# printf "  %s\n" "${SORTED_TSAN_SUFFIXES[@]}"
# echo "---"

# 3. Генерируем все возможные комбинации
NUM_SUFFIXES=${#SORTED_TSAN_SUFFIXES[@]}
ALL_COMBINATIONS=()

# Мы будем использовать битовую маску для генерации всех подмножеств.
# Каждое число от 1 до 2^N - 1 представляет собой уникальное подмножество.
# (N - количество суффиксов)
# 0-й бит соответствует первому суффиксу, 1-й бит - второму и т.д.

# ((1 << NUM_SUFFIXES)) это 2 в степени NUM_SUFFIXES
# Мы итерируем от 1 (один элемент) до (2^N - 1) (все элементы)
MAX_ITERATIONS=$(( (1 << NUM_SUFFIXES) - 1 ))

for (( I=1; I <= MAX_ITERATIONS; I++ )); do
	CURRENT_COMBINATION_PARTS=()
	for (( J=0; J < NUM_SUFFIXES; J++ )); do
		# Проверяем, установлен ли J-ый бит в I
		# Если (I >> J) & 1 истинно, значит J-ый суффикс входит в текущую комбинацию
		if (( (I >> J) & 1 )); then
			CURRENT_COMBINATION_PARTS+=("${SORTED_TSAN_SUFFIXES[J]}")
		fi
	done

	# Соединяем части текущей комбинации через дефис
	# Поскольку SORTED_TSAN_SUFFIXES отсортирован, и мы добавляем элементы
	# в CURRENT_COMBINATION_PARTS в том же порядке,
	# результат соединения также будет в каноническом (отсортированном) виде.
	if [ ${#CURRENT_COMBINATION_PARTS[@]} -gt 0 ]; then
		# Старый добрый IFS для соединения элементов массива
		TEMP_IFS="$IFS"
		IFS="-"
		JOINED_STRING="${CURRENT_COMBINATION_PARTS[*]}"
		IFS="$TEMP_IFS"
		ALL_COMBINATIONS+=("$JOINED_STRING")
	fi
done

# 4. Выводим все сгенерированные комбинации
if [ ${#ALL_COMBINATIONS[@]} -gt 0 ]; then
	printf "%s\n" "${ALL_COMBINATIONS[@]}"
else
	echo "Не удалось сгенерировать комбинации."
fi

# Пример использования:
# Предположим, ALL_COMBINATIONS теперь содержит строки типа "st", "st-swmr", "dom-ea-lo-st-swmr"
# Вы можете дальше использовать их для формирования ключей для CONFIG_DETAILS или других целей.
# Например:
# for COMBO_KEY in "${ALL_COMBINATIONS[@]}"; do
#   NEW_CONFIG_KEY="tsan-${COMBO_KEY}"
#   echo "Нужно будет определить значение для: $NEW_CONFIG_KEY"
# done
