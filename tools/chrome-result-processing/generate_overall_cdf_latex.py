#!/usr/bin/env python3

import argparse
import sys
from pathlib import Path
from typing import Dict, List, Optional, Tuple

import pandas as pd

DEFAULT_CSV_DIRNAME = 'csv'
DEFAULT_BASELINE = 'tsan'
DEFAULT_GLOB = '*.csv'
PLOT_STYLES = [
    'thick, blue!80!black, mark=none, const plot',
    'thick, teal!70!black, mark=none, const plot',
    'thick, orange!90!black, mark=none, const plot',
    'thick, purple!80!black, mark=none, const plot',
    'thick, green!60!black, mark=none, const plot',
    'thick, brown!80!black, mark=none, const plot',
]
REQUIRED_COLUMNS = {'name', 'benchmarks', 'unit', 'displayLabel', 'avg'}


def resolve_default_csv_dir() -> Path:
    script_dir = Path(__file__).resolve().parent

    for candidate in (
        Path.cwd() / DEFAULT_CSV_DIRNAME,
        script_dir / DEFAULT_CSV_DIRNAME,
    ):
        if candidate.is_dir():
            return candidate

    return script_dir / DEFAULT_CSV_DIRNAME


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            'Собирает все CSV с результатами Chrome-бенчмарков и генерирует '
            'один общий LaTeX/TikZ CDF-график ускорений относительно baseline.'
        )
    )
    parser.add_argument(
        '--csv-dir',
        type=Path,
        default=None,
        help='Каталог с CSV-файлами (по умолчанию: auto-detect папки csv рядом со скриптом или из текущей директории).',
    )
    parser.add_argument(
        '--glob',
        default=DEFAULT_GLOB,
        help=f'Glob для выбора CSV внутри каталога (по умолчанию: {DEFAULT_GLOB}).',
    )
    parser.add_argument(
        '--baseline',
        default=DEFAULT_BASELINE,
        help=f'Имя базовой конфигурации (по умолчанию: {DEFAULT_BASELINE}).',
    )
    parser.add_argument(
        '--output',
        type=Path,
        default=None,
        help='Путь для записи LaTeX/TikZ. Если не задан, выводится в stdout.',
    )
    parser.add_argument(
        '--xmin',
        type=float,
        default=None,
        help='Явно задать минимальную границу оси X.',
    )
    parser.add_argument(
        '--xmax',
        type=float,
        default=None,
        help='Явно задать максимальную границу оси X.',
    )
    return parser.parse_args()


def discover_csv_files(csv_dir: Path, glob_pattern: str) -> List[Path]:
    if not csv_dir.exists():
        print(f"Ошибка: каталог с CSV '{csv_dir}' не найден.", file=sys.stderr)
        sys.exit(1)

    if not csv_dir.is_dir():
        print(f"Ошибка: путь '{csv_dir}' не является каталогом.", file=sys.stderr)
        sys.exit(1)

    csv_files = sorted(path for path in csv_dir.glob(glob_pattern) if path.is_file())
    if not csv_files:
        print(
            f"Ошибка: в каталоге '{csv_dir}' не найдено CSV по шаблону '{glob_pattern}'.",
            file=sys.stderr,
        )
        sys.exit(1)

    return csv_files


def load_csv_files(csv_files: List[Path]) -> pd.DataFrame:
    frames = []

    for csv_file in csv_files:
        frame = pd.read_csv(csv_file)
        missing_columns = REQUIRED_COLUMNS.difference(frame.columns)
        if missing_columns:
            missing = ', '.join(sorted(missing_columns))
            print(
                f"Ошибка: в CSV '{csv_file}' отсутствуют обязательные колонки: {missing}.",
                file=sys.stderr,
            )
            sys.exit(1)

        frame = frame[list(REQUIRED_COLUMNS)].copy()
        frame['source_csv'] = csv_file.name
        frames.append(frame)

    df = pd.concat(frames, ignore_index=True)
    df = df[df['unit'] == 'ms'].copy()
    df['avg'] = pd.to_numeric(df['avg'], errors='coerce')
    df = df.dropna(subset=['avg', 'displayLabel', 'name'])
    df['benchmarks'] = df['benchmarks'].fillna('unknown_benchmark')
    df['test_id'] = df['benchmarks'].astype(str) + ':' + df['name'].astype(str)
    df = df[df['avg'] > 0].copy()
    return df


def build_speedups(df: pd.DataFrame, baseline: str) -> Tuple[Dict[str, List[float]], pd.DataFrame]:
    if df.empty:
        print('Ошибка: после фильтрации не осталось строк с unit == \'ms\'.', file=sys.stderr)
        sys.exit(1)

    pivot_df = df.pivot_table(index='test_id', columns='displayLabel', values='avg', aggfunc='mean')

    if baseline not in pivot_df.columns:
        print(f"Ошибка: базовая конфигурация '{baseline}' не найдена в объединенных CSV.", file=sys.stderr)
        sys.exit(1)

    speedups_by_config: Dict[str, List[float]] = {}

    for config in sorted(column for column in pivot_df.columns if column != baseline):
        speedups = (pivot_df[baseline] / pivot_df[config]).replace([float('inf'), float('-inf')], pd.NA)
        speedups = speedups.dropna()
        speedups = speedups[speedups > 0]
        if speedups.empty:
            continue
        speedups_by_config[config] = sorted(speedups.tolist())

    if not speedups_by_config:
        print(
            f"Ошибка: не найдено ни одной конфигурации для сравнения с baseline '{baseline}'.",
            file=sys.stderr,
        )
        sys.exit(1)

    return speedups_by_config, pivot_df


def compute_x_range(
    speedups_by_config: Dict[str, List[float]],
    xmin: Optional[float],
    xmax: Optional[float],
) -> Tuple[float, float]:
    all_values = [value for values in speedups_by_config.values() for value in values]
    data_min = min(all_values)
    data_max = max(all_values)

    plot_xmin = xmin if xmin is not None else min(0.9, data_min - 0.05)
    plot_xmax = xmax if xmax is not None else max(1.1, data_max + 0.05)

    if plot_xmin >= plot_xmax:
        print(
            f"Ошибка: некорректные границы оси X: xmin={plot_xmin}, xmax={plot_xmax}.",
            file=sys.stderr,
        )
        sys.exit(1)

    return plot_xmin, plot_xmax


def format_coordinates(values: List[float], plot_xmin: float, plot_xmax: float) -> str:
    count = len(values)
    coords = [f"({plot_xmin:.2f}, 0.00)"]

    for index, value in enumerate(values, start=1):
        fraction = index / count
        coords.append(f"({value:.2f}, {fraction:.4f})")

    coords.append(f"({plot_xmax:.2f}, 1.0000)")

    lines = []
    for index in range(0, len(coords), 4):
        lines.append('            ' + ' '.join(coords[index:index + 4]))
    return '\n'.join(lines)


def render_latex(
    speedups_by_config: Dict[str, List[float]],
    plot_xmin: float,
    plot_xmax: float,
    baseline: str,
    csv_files: List[Path],
    pivot_df: pd.DataFrame,
) -> str:
    output_lines = [
        '% Auto-generated by generate_overall_cdf_latex.py',
        f'% CSV files: {len(csv_files)}',
        f'% Benchmarks with baseline ({baseline}): {len(pivot_df[baseline].dropna())}',
        '\\begin{tikzpicture}',
        '    \\begin{axis}[',
        '        chromestyle, % Убедитесь, что этот стиль определен в вашей преамбуле',
        '        xlabel={\\small Speedup ($\\le X$)},',
        '        ylabel={\\small Fraction of Benchmarks},',
        '        ylabel near ticks,',
        '        ymin=0, ymax=1.05,',
        f'        xmin={plot_xmin:.2f}, xmax={plot_xmax:.2f},',
        '        grid=both,',
        '        legend pos=south east,',
        '        legend cell align={left},',
        '    ]',
    ]

    for index, (config, values) in enumerate(speedups_by_config.items()):
        style = PLOT_STYLES[index % len(PLOT_STYLES)]
        coordinates = format_coordinates(values, plot_xmin, plot_xmax)
        output_lines.extend([
            f'        % {config}: {len(values)} benchmarks',
            f'        \\addplot[{style}] coordinates {{',
            coordinates,
            '        };',
            f'        \\addlegendentry{{{config} (n={len(values)})}}',
            '',
        ])

    output_lines.extend([
        '        % Baseline line',
        '        \\draw[red, dashed] (axis cs:1.0,0) -- (axis cs:1.0,1);',
        '        \\node[anchor=west, red, font=\\scriptsize, rotate=90, yshift=-5pt, xshift=5pt] at (axis cs:1.0, 0.05) {Baseline};',
        '    \\end{axis}',
        '\\end{tikzpicture}',
    ])

    return '\n'.join(output_lines) + '\n'


def write_output(content: str, output_path: Optional[Path]) -> None:
    if output_path is None:
        sys.stdout.write(content)
        return

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(content, encoding='utf-8')


def main() -> None:
    args = parse_args()
    csv_dir = args.csv_dir if args.csv_dir is not None else resolve_default_csv_dir()
    csv_files = discover_csv_files(csv_dir, args.glob)
    df = load_csv_files(csv_files)
    speedups_by_config, pivot_df = build_speedups(df, args.baseline)
    plot_xmin, plot_xmax = compute_x_range(speedups_by_config, args.xmin, args.xmax)
    latex = render_latex(speedups_by_config, plot_xmin, plot_xmax, args.baseline, csv_files, pivot_df)
    write_output(latex, args.output)


if __name__ == '__main__':
    main()


