#!/usr/bin/env python3
"""
Parse mysql-build-time_*.log files and print a comparison table.
"""

import glob
import os
import re
import sys


def parse_log(path):
    data = {}
    with open(path) as f:
        content = f.read()

    m = re.search(r'Command being timed:.*-j\s+(\d+)', content)
    data['jobs'] = int(m.group(1)) if m else None

    m = re.search(r'User time \(seconds\):\s+([\d.]+)', content)
    data['user_sec'] = float(m.group(1)) if m else None

    m = re.search(r'Percent of CPU this job got:\s+(\d+)%', content)
    data['cpu_pct'] = int(m.group(1)) if m else None

    m = re.search(r'Elapsed \(wall clock\) time.*?:\s+([\d:]+)', content)
    if m:
        data['wall_str'] = m.group(1)
        parts = m.group(1).split(':')
        parts = [float(p) for p in parts]
        if len(parts) == 3:
            data['wall_sec'] = parts[0] * 3600 + parts[1] * 60 + parts[2]
        elif len(parts) == 2:
            data['wall_sec'] = parts[0] * 60 + parts[1]
        else:
            data['wall_sec'] = parts[0]
    else:
        data['wall_str'] = None
        data['wall_sec'] = None

    m = re.search(r'Maximum resident set size \(kbytes\):\s+(\d+)', content)
    data['rss_kb'] = int(m.group(1)) if m else None

    return data


def format_sec(sec):
    if sec is None:
        return '—'
    h = int(sec // 3600)
    m = int((sec % 3600) // 60)
    s = int(sec % 60)
    if h > 0:
        return f'{h}h {m:02d}m {s:02d}s'
    return f'{m}m {s:02d}s'


def format_rss(kb):
    if kb is None:
        return '—'
    return f'{kb / 1024:.0f} MB'


def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    pattern = os.path.join(script_dir, 'mysql-build-time_*.log')
    files = sorted(glob.glob(pattern))

    if not files:
        print('No mysql-build-time_*.log files found.')
        sys.exit(1)

    rows = []
    for path in files:
        name = re.sub(r'^mysql-build-time_', '', os.path.basename(path))
        name = re.sub(r'\.log$', '', name)
        d = parse_log(path)
        rows.append((name, d))

    # Sort: first by user_sec ascending
    rows.sort(key=lambda x: x[1]['user_sec'] or 0)

    # Find baselines
    baseline_tsan = None
    baseline_orig = None
    for name, d in rows:
        if name == 'tsan':
            baseline_tsan = d['user_sec']
        if name == 'orig':
            baseline_orig = d['user_sec']
    if baseline_tsan is None:
        baseline_tsan = rows[0][1]['user_sec']
    if baseline_orig is None:
        baseline_orig = rows[0][1]['user_sec']

    # Column widths
    col_name  = max(len(r[0]) for r in rows)
    col_name  = max(col_name, len('Configuration'))

    header = (
        f"{'Configuration':<{col_name}}  "
        f"{'Jobs':>4}  "
        f"{'Wall time':>12}  "
        f"{'User time':>12}  "
        f"{'CPU%':>5}  "
        f"{'RSS peak':>9}  "
        f"{'vs orig (user)':>14}  "
        f"{'vs tsan (user)':>14}"
    )
    sep = '-' * len(header)

    print()
    print('MySQL 8.0.39 — Build time comparison')
    print(sep)
    print(header)
    print(sep)

    for name, d in rows:
        jobs     = str(d['jobs']) if d['jobs'] else '?'
        wall     = d['wall_str'] if d['wall_str'] else '—'
        user_h   = format_sec(d['user_sec'])
        cpu      = f"{d['cpu_pct']}%" if d['cpu_pct'] else '—'
        rss      = format_rss(d['rss_kb'])

        if d['user_sec'] and baseline_orig:
            delta = (d['user_sec'] - baseline_orig) / baseline_orig * 100
            sign  = '+' if delta >= 0 else ''
            vs_orig = f'{sign}{delta:.1f}%'
        else:
            vs_orig = '—'

        if d['user_sec'] and baseline_tsan:
            delta = (d['user_sec'] - baseline_tsan) / baseline_tsan * 100
            sign  = '+' if delta >= 0 else ''
            vs_tsan = f'{sign}{delta:.1f}%'
        else:
            vs_tsan = '—'

        # Highlight warning if jobs differ
        jobs_flag = ' !' if d['jobs'] and d['jobs'] != 7 else '  '

        print(
            f"{name:<{col_name}}  "
            f"{jobs:>4}{jobs_flag}"
            f"{wall:>12}  "
            f"{user_h:>12}  "
            f"{cpu:>5}  "
            f"{rss:>9}  "
            f"{vs_orig:>14}  "
            f"{vs_tsan:>14}"
        )

    print(sep)
    print()
    print('Notes:')
    print('  ! — jobs count differs from the majority (-j 7); wall-time not directly comparable.')
    print('  "vs orig"  — compilation time overhead vs native (orig) build, by CPU user time.')
    print('  "vs tsan"  — compilation time overhead vs baseline TSan build, by CPU user time.')
    print('  User time is the correct apples-to-apples metric regardless of -j.')
    print()


if __name__ == '__main__':
    main()

