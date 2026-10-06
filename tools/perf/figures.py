#!/usr/bin/env python3
"""figures.py [--out DIR] [results tree ...] -- the paper's bars, drawn from the tables.

The paper presents performance as bars: one group per application, one bar per configuration, the speedup
against stock ThreadSanitizer. This draws that figure from the shipped campaign, and, for every results tree
named on the command line, puts the evaluator's own points beside the bars.

It parses the SAME summary tables the comparator reads (perf_<app>.md, via compare_with_claims.parse_table),
so a bar cannot disagree with the table it is drawn from: the estimator lives in aggregate.py, once. The
output is SVG written by hand rather than by a plotting library, because the artifact's image carries no
plotting dependency and adding one to compare four numbers per application would be a poor trade.
"""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from compare_with_claims import parse_table  # the tables' own reader; keeps the figure and the table in step

# The paper's four configurations, in the paper's order, with the paper's names.
ROWS = ["AllOpt without peeling", "AllOpt with peeling", "DynSTC", "AllOpt with peeling and DynSTC"]
APPS = ["redis", "memcached", "sqlite", "ffmpeg", "mysql"]
W, H, PAD_L, PAD_R, PAD_T, PAD_B = 940, 360, 70, 20, 54, 96
COLS = ["#3b6ea5", "#4f8f4f", "#a5683b", "#7a5ba5"]


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def collect(root, app, shipped_sub="primary"):
    """{row: (point, (lo, hi) or None, n)} for one application from a results root, or None."""
    for sub in (shipped_sub, ""):
        d = os.path.join(root, sub) if sub else root
        if os.path.exists(os.path.join(d, f"perf_{app}.md")):
            return parse_table(d, app)
    return None


def svg(app, ours, yours_list, title_note):
    rows = [r for r in ROWS if (ours and r in ours) or any(y and r in y for y in yours_list)]
    if not rows:
        return None
    lo_v, hi_v = 1.0, 1.0
    for r in rows:
        for src in [ours] + yours_list:
            if not src or r not in src:
                continue
            pt, iv, _ = src[r]
            lo_v = min(lo_v, iv[0] if iv else pt); hi_v = max(hi_v, iv[1] if iv else pt)
    lo_v, hi_v = min(0.9, lo_v - 0.03), max(1.1, hi_v + 0.03)
    plot_w, plot_h = W - PAD_L - PAD_R, H - PAD_T - PAD_B
    def y(v):
        return PAD_T + plot_h * (hi_v - v) / (hi_v - lo_v)
    step = plot_w / len(rows)
    bw = min(96, step * 0.42)
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" font-family="DejaVu Sans, sans-serif">',
           f'<rect width="{W}" height="{H}" fill="white"/>',
           f'<text x="{PAD_L}" y="26" font-size="17" font-weight="bold">{esc(app)}</text>',
           f'<text x="{PAD_L}" y="45" font-size="12" fill="#555">{esc(title_note)}</text>']
    # y axis: gridlines every 0.05, the 1.0 line emphasised
    v = round(lo_v * 20) / 20
    while v <= hi_v + 1e-9:
        yy = y(v)
        one = abs(v - 1.0) < 1e-9
        out.append(f'<line x1="{PAD_L}" y1="{yy:.1f}" x2="{W-PAD_R}" y2="{yy:.1f}" '
                   f'stroke="{"#333" if one else "#e6e6e6"}" stroke-width="{1.2 if one else 1}" '
                   f'{"stroke-dasharray=\"5 4\"" if one else ""}/>')
        out.append(f'<text x="{PAD_L-8}" y="{yy+4:.1f}" font-size="11" text-anchor="end" fill="#444">{v:.2f}</text>')
        v = round(v + 0.05, 10)
    out.append(f'<text x="18" y="{PAD_T + plot_h/2:.0f}" font-size="12" fill="#444" '
               f'transform="rotate(-90 18 {PAD_T + plot_h/2:.0f})" text-anchor="middle">speedup vs stock TSan</text>')
    for i, r in enumerate(rows):
        cx = PAD_L + step * (i + 0.5)
        if ours and r in ours:
            pt, iv, n = ours[r]
            top, bot = y(max(pt, 1.0)), y(min(pt, 1.0))
            out.append(f'<rect x="{cx-bw/2:.1f}" y="{top:.1f}" width="{bw:.1f}" height="{max(1.0, bot-top):.1f}" '
                       f'fill="{COLS[i % len(COLS)]}" fill-opacity="0.85"/>')
            if iv:
                out.append(f'<line x1="{cx:.1f}" y1="{y(iv[0]):.1f}" x2="{cx:.1f}" y2="{y(iv[1]):.1f}" stroke="#222" stroke-width="1.4"/>')
                for b in iv:
                    out.append(f'<line x1="{cx-7:.1f}" y1="{y(b):.1f}" x2="{cx+7:.1f}" y2="{y(b):.1f}" stroke="#222" stroke-width="1.4"/>')
            out.append(f'<text x="{cx:.1f}" y="{y(iv[1] if iv else pt)-7:.1f}" font-size="11" text-anchor="middle">{pt:.3f}</text>')
        for k, yours in enumerate(yours_list):
            if not yours or r not in yours:
                continue
            pt, iv, n = yours[r]
            dx = cx + bw / 2 + 9 + k * 9
            out.append(f'<circle cx="{dx:.1f}" cy="{y(pt):.1f}" r="4.2" fill="#c0392b"/>')
            if iv:
                out.append(f'<line x1="{dx:.1f}" y1="{y(iv[0]):.1f}" x2="{dx:.1f}" y2="{y(iv[1]):.1f}" stroke="#c0392b" stroke-width="1.2"/>')
        # the configuration name, wrapped on spaces to fit the slot
        words, line, lines = r.split(), "", []
        for wd in words:
            if len(line) + len(wd) + 1 > 18:
                lines.append(line); line = wd
            else:
                line = (line + " " + wd).strip()
        lines.append(line)
        for j, ln in enumerate(lines):
            out.append(f'<text x="{cx:.1f}" y="{H-PAD_B+18+j*14:.0f}" font-size="11.5" text-anchor="middle">{esc(ln)}</text>')
    out.append(f'<line x1="{PAD_L}" y1="{y(lo_v):.1f}" x2="{W-PAD_R}" y2="{y(lo_v):.1f}" stroke="#333"/>')
    out.append(f'<rect x="{W-PAD_R-190}" y="{PAD_T+6}" width="12" height="12" fill="{COLS[0]}" fill-opacity="0.85"/>'
               f'<text x="{W-PAD_R-172}" y="{PAD_T+16}" font-size="11">our campaign, N = 5, 95 % interval</text>')
    if any(yours_list):
        out.append(f'<circle cx="{W-PAD_R-184}" cy="{PAD_T+30}" r="4.2" fill="#c0392b"/>'
                   f'<text x="{W-PAD_R-172}" y="{PAD_T+34}" font-size="11">this run</text>')
    out.append("</svg>")
    return "\n".join(out)


USAGE = """figures.py [--out DIR] [results tree ...]

  --out DIR   where to write the SVGs (default: ./figures)
  trees       results/perf-<app>-<stamp> directories, drawn as points beside our bars

With no tree it draws the shipped campaign alone. Called by scripts/92-figures.sh, which picks the output
directory under results/ for you."""


def main():
    args = sys.argv[1:]
    out_dir = "figures"
    # ARGUMENTS ARE CHECKED BEFORE ANYTHING IS WRITTEN. Until 22 Sep 2026 every argument was taken for a
    # results tree, so `figures.py --help` wrote five files into the current directory instead of printing
    # this; inside the container that directory is the read-only harness mount and it would have died on the
    # write rather than explaining itself. (found by running --help.)
    if any(a in ("-h", "--help") for a in args):
        print(USAGE); return 0
    if args and args[0] == "--out":
        if len(args) < 2:
            print("--out needs a directory\n\n" + USAGE, file=sys.stderr); return 64
        out_dir = args[1]; args = args[2:]
    for a in args:
        if a.startswith("-"):
            print(f"unknown option {a!r}\n\n" + USAGE, file=sys.stderr); return 64
        if not os.path.isdir(a):
            print(f"not a directory: {a}\n\n" + USAGE, file=sys.stderr); return 64
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.environ.get("ART_ROOT") or os.path.abspath(os.path.join(here, "..", "..", ".."))
    shipped = os.path.join(root, "data", "perf", "campaign-f3deebfbab60")
    if not os.path.isdir(shipped):
        print(f"no shipped campaign under {shipped}", file=sys.stderr); return 2
    os.makedirs(out_dir, exist_ok=True)
    written = 0
    for app in APPS:
        ours = collect(shipped, app)
        note = "our campaign, N = 5"
        if app == "ffmpeg":
            # FFmpeg's default is 16 threads, so the figure is that leg alone rather than a mixture of two
            # thread counts: a bar from one count beside a bar from another would be a chart of two machines.
            t16 = collect(shipped, app, "ffmpeg-t16")
            if t16:
                ours, note = t16, "our campaign at the artifact's default of 16 encoder threads, N = 5"
        yours = []
        for tree in args:
            if f"perf-{app}-" in os.path.basename(tree.rstrip("/")):
                t = parse_table(tree, app)
                if t:
                    yours.append(t); note += f"; red: {os.path.basename(tree.rstrip('/'))}"
        s = svg(app, ours, yours, note)
        if s:
            p = os.path.join(out_dir, f"speedup-{app}.svg")
            open(p, "w").write(s); print(f"  {p}"); written += 1
    print(f"{written} figure(s); bars are the shipped campaign, drawn from the same tables the comparator reads")
    return 0


if __name__ == "__main__":
    sys.exit(main())
