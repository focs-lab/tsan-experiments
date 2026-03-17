#!/usr/bin/env python3

import pandas as pd
import numpy as np

# 1. Загружаем данные
csv_filename = 'speedometer3_results.csv'
df = pd.read_csv(csv_filename)

# 2. Оставляем только тесты, которые измеряются в миллисекундах (исключаем агрегированный Score)
df = df[df['unit'] == 'ms']

# 3. Делаем сводную таблицу: строки - названия тестов, столбцы - конфигурации, значения - среднее время
pivot_df = df.pivot_table(index='name', columns='displayLabel', values='avg')

baseline_name = 'tsan'

if baseline_name not in pivot_df.columns:
    print(f"Ошибка: базовая конфигурация '{baseline_name}' не найдена в файле.")
    exit(1)

# Выбираем все конфигурации, кроме базовой
opt_configs = [c for c in pivot_df.columns if c != baseline_name]

# Шаблон LaTeX-кода
latex_template = """
%% --- (b) CDF для {config} ---
\\subfloat[Cumulative Distribution of Speedups ({config})\\label{{fig:speedup_{config_clean}}}]{{
    \\begin{{minipage}}[t][4cm][t]{{0.48\\textwidth}}
    \\vspace{{0pt}}
    \\centering
    \\begin{{tikzpicture}}
        \\begin{{axis}}[
            chromestyle, %% Убедитесь, что этот стиль определен в вашей преамбуле
            xlabel={{\\small Speedup ($\\le X$)}},
            ylabel={{\\small Fraction of Benchmarks}},
            ylabel near ticks,
            ymin=0, ymax=1.05,
            xmin={xmin:.2f}, xmax={xmax:.2f},
            grid=both,
            legend pos=south east,
            legend cell align={{left}},
        ]
        \\addplot[thick, blue!80!black, mark=none, const plot] coordinates {{
{coordinates}
        }};
        \\addlegendentry{{{config}}}

        % Baseline line
        \\draw[red, dashed] (axis cs:1.0,0) -- (axis cs:1.0,1);
        \\node[anchor=west, red, font=\\scriptsize, rotate=90, yshift=-5pt, xshift=5pt] at (axis cs:1.0, 0.05) {{Baseline}};

        % Median line
        \\draw[gray, dotted] (axis cs:{xmin:.2f},0.5) -- (axis cs:{xmax:.2f},0.5);
        \\node[anchor=south east, gray, font=\\scriptsize] at (axis cs:{xmax:.2f}, 0.52) {{Median}};

        \\end{{axis}}
    \\end{{tikzpicture}}
    \\end{{minipage}}
}}
"""

for config in opt_configs:
    # Считаем ускорение. Так как время (ms) чем меньше, тем лучше:
    # Speedup = Время_базы / Время_оптимизации
    speedups = pivot_df[baseline_name] / pivot_df[config]

    # Удаляем пустые значения (если тест не прошел в одной из конфигураций) и сортируем
    speedups = speedups.dropna().sort_values().values
    n = len(speedups)

    if n == 0:
        continue

    # Определяем границы оси X с небольшим отступом
    min_x = speedups[0]
    max_x = speedups[-1]
    plot_xmin = min(0.9, min_x - 0.05)
    plot_xmax = max(1.1, max_x + 0.05)

    # Генерируем координаты (X, Y)
    coords =[]
    # Начальная точка на оси (Y=0), чтобы const plot начал рисоваться от нуля
    coords.append(f"({plot_xmin:.2f}, 0.00)")

    for i, val in enumerate(speedups):
        y = (i + 1) / n
        coords.append(f"({val:.2f}, {y:.2f})")

    # Форматируем координаты в строки (по 4 пары на строку для красоты)
    formatted_coords = ""
    for i in range(0, len(coords), 4):
        formatted_coords += "            " + " ".join(coords[i:i+4]) + "\n"

    # Чистим имя конфигурации для label
    clean_config_name = config.replace("-", "_").replace(" ", "_").lower()

    # Выводим сгенерированный LaTeX
    print(latex_template.format(
        config=config,
        config_clean=clean_config_name,
        xmin=plot_xmin,
        xmax=plot_xmax,
        coordinates=formatted_coords.rstrip()
    ))
    print("\n" + "%"*50 + "\n")