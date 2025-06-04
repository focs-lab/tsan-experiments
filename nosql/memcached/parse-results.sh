#!/bin/bash

# --- Configuration ---
RESULTS_DIR="results" # По умолчанию текущая директория, можно изменить на "results"
BASELINE_FILENAME_PATTERN="tsan_results.txt" # Имя файла базовых результатов
RESULT_FILE_PATTERN="*_results.txt" # Шаблон для поиска всех файлов результатов

METRIC_SECTION_START_MARKER="AGGREGATED AVERAGE RESULTS"
TOTALS_LINE_MARKER="Totals"

# --- Functions ---

extract_metrics() {
    local file="$1"
    if [ ! -f "$file" ]; then
        echo "ERROR: File '$file' not found." >&2
        echo "N/A N/A"
        return
    fi

    awk -v section_marker="$METRIC_SECTION_START_MARKER" \
        -v totals_marker="$TOTALS_LINE_MARKER" '
    BEGIN { in_section = 0; ops_sec = "N/A"; avg_latency = "N/A" }
    $0 ~ section_marker { in_section = 1; next }
    in_section && $1 == totals_marker {
        ops_sec = $2;
        avg_latency = $5;
    }
    END { print ops_sec, avg_latency }
    ' "$file"
}

# --- Main Script ---

# Определяем директорию для поиска результатов
target_dir="$RESULTS_DIR"
if [ -n "$1" ] && [ -d "$1" ]; then
    target_dir="$1"
    echo "Analyzing results in directory: $target_dir"
elif [ -n "$1" ]; then
    echo "Warning: Argument '$1' is not a directory. Analyzing results in '$target_dir'."
fi

# Ищем базовый файл
baseline_file_path=$(find "$target_dir" -maxdepth 1 -name "$BASELINE_FILENAME_PATTERN" -print -quit)

if [ -z "$baseline_file_path" ] || [ ! -f "$baseline_file_path" ]; then
    echo "Error: Baseline file '$BASELINE_FILENAME_PATTERN' not found in '$target_dir'." >&2
    exit 1
fi

echo "Using baseline file: $baseline_file_path"
read -r BASELINE_OPS_SEC BASELINE_AVG_LATENCY <<< "$(extract_metrics "$baseline_file_path")"

if [ "$BASELINE_OPS_SEC" == "N/A" ]; then
    echo "Error: Could not extract baseline metrics from '$baseline_file_path'. Exiting." >&2
    exit 1
fi

printf "%-35s | %-15s | %-10s | %-15s | %-15s\n" "Configuration (from file)" "Totals Ops/sec" "Speedup" "Avg. Latency" "Latency Improv."
printf "%-35s-+-%-15s-+-%-10s-+-%-15s-+-%-15s\n" "-----------------------------------" "---------------" "----------" "---------------" "---------------"

printf "%-35s | %15.2f | %10s | %15.3f | %15s\n" \
    "Baseline ($(basename "$baseline_file_path"))" \
    "$BASELINE_OPS_SEC" \
    "1.00x" \
    "$BASELINE_AVG_LATENCY" \
    "1.00x"

# Ищем все файлы результатов в указанной директории
# Используем find для поиска файлов, затем цикл while read для обработки
find "$target_dir" -maxdepth 1 -name "$RESULT_FILE_PATTERN" -print0 | while IFS= read -r -d $'\0' result_file; do
    # Пропускаем сам базовый файл, если он попадется в общем списке
    if [ "$result_file" == "$baseline_file_path" ]; then
        continue
    fi

    config_name=$(basename "$result_file")
    # config_name=${config_name%_results.txt} # Опционально: убрать _results.txt из имени

    read -r current_ops_sec current_avg_latency <<< "$(extract_metrics "$result_file")"

    if [ "$current_ops_sec" == "N/A" ]; then
        printf "%-35s | %15s | %10s | %15s | %15s\n" \
            "$config_name" "N/A" "N/A" "N/A" "N/A"
        continue
    fi

    ops_speedup=$(echo "scale=2; $current_ops_sec / $BASELINE_OPS_SEC" | bc -l)

    latency_improvement="N/A"
    if (( $(echo "$current_avg_latency > 0" | bc -l) )); then
        latency_improvement=$(echo "scale=2; $BASELINE_AVG_LATENCY / $current_avg_latency" | bc -l)
    fi

    printf "%-35s | %15.2f | %9.2fx | %15.3f | %14.2fx\n" \
        "$config_name" \
        "$current_ops_sec" \
        "$ops_speedup" \
        "$current_avg_latency" \
        "$latency_improvement"
done

echo "-------------------------------------------------------------------------------------------------------------"
echo "Ops/sec Speedup: Higher is better (relative to baseline)."
echo "Latency Improvement: Higher is better (lower latency relative to baseline results in a higher ratio)."
