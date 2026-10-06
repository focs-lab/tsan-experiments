#!/usr/bin/env python3
"""profile_report.py <profile-root> [counters-root] — assemble the cycle profile and the counter runs.

Answers the two questions the campaign could not: where the instrumented cycles actually go, and how often
each callback class is reached. The two are deliberately kept in separate tables — a share of cycles and a
share of calls are different quantities, and the counters carry no per-call cost that would let one be
converted into the other.
"""
import sys, os, json, glob

ORDER = ["memcached", "redis", "sqlite", "ffmpeg", "mysql"]
CFGS = ["tsan", "tsan-sound", "tsan-sound-stmt", "tsan-sound-nofe"]
NAME = {"tsan": "stock", "tsan-sound": "sound", "tsan-sound-stmt": "sound+guard",
        "tsan-sound-nofe": "sound, no func entry/exit"}

def load(root):
    out = {}
    for f in glob.glob(os.path.join(root, "*", "*", "summary.json")):
        try:
            j = json.load(open(f))
        except Exception:
            continue
        if "error" not in j:
            out[(j["app"], j["config"])] = j
    return out

def main():
    prof = load(sys.argv[1])
    cnt = load(sys.argv[2]) if len(sys.argv) > 2 and os.path.isdir(sys.argv[2]) else {}

    print("## Where the instrumented cycles go (perf, cycles:u, one run per cell)\n")
    print(f"{'application':11s} {'configuration':26s} {'in TSan':>8s} {'access':>7s} {'shadow':>7s} "
          f"{'atomic':>7s} {'other':>6s}")
    print(f"{'':11s} {'':26s} {'% cyc':>8s} {'% of instrumented':>28s}")
    for app in ORDER:
        for c in CFGS:
            j = prof.get((app, c))
            if not j:
                continue
            s = j["share_of_instrumented"]
            print(f"{app:11s} {NAME.get(c, c):26s} {j['cycles_in_tsan_pct']:7.1f}% "
                  f"{s['access']:6.1f}% {s['shadow_stack']:6.1f}% {s['atomic']:6.1f}% {s['tsan_other']:5.1f}%")
        print()

    # the direct test of "the analyses remove cold code": how much access-callback time the sound bundle removed
    print("## What the sound bundle removed, in cycles rather than sites\n")
    print(f"{'application':11s} {'stock access % of cycles':>25s} {'sound':>8s} {'change':>9s}")
    for app in ORDER:
        a, b = prof.get((app, "tsan")), prof.get((app, "tsan-sound"))
        if not (a and b):
            continue
        x, y = a["of_which"]["access"], b["of_which"]["access"]
        print(f"{app:11s} {x:24.1f}% {y:7.1f}% {y - x:+8.1f}pp")

    print("\n## What dropping shadow-stack maintenance is worth\n")
    print(f"{'application':11s} {'sound: shadow % of cycles':>26s} {'no-fe':>7s} {'total TSan % change':>21s}")
    for app in ORDER:
        a, b = prof.get((app, "tsan-sound")), prof.get((app, "tsan-sound-nofe"))
        if not (a and b):
            continue
        print(f"{app:11s} {a['of_which']['shadow_stack']:25.1f}% {b['of_which']['shadow_stack']:6.1f}% "
              f"{b['cycles_in_tsan_pct'] - a['cycles_in_tsan_pct']:+20.1f}pp")

    if cnt:
        print("\n## Counter runs — counts, not costs\n")
        print(f"{'application':11s} {'configuration':12s} {'accesses':>16s} {'fast-path hits':>15s} "
              f"{'func entry/access':>18s} {'mean range B':>13s}")
        for app in ORDER:
            for c in ("tsan", "tsan-sound"):
                j = cnt.get((app, c))
                if not j:
                    continue
                t = j["totals"]
                print(f"{app:11s} {NAME.get(c, c):12s} {t['total']:16,d} "
                      f"{j.get('fast_path_hit_rate', float('nan')):14.2f}% "
                      f"{j.get('func_entries_per_access', float('nan')):18.3f} "
                      f"{j.get('mean_range_bytes', float('nan')):13.1f}")
        print("\nA fast-path hit and a function entry are not the same number of cycles, so nothing above is a")
        print("share of time; the cycle tables are where the cost lives.")

    miss = [(a, c) for a in ORDER for c in CFGS if (a, c) not in prof]
    if miss:
        print("\n**Cells with no usable measurement** (discarded, never recorded as zero): "
              + "; ".join(f"{a}/{c}" for a, c in miss))

main()
