#!/usr/bin/env python3
"""profile_summarize.py <perf-report.txt> <app> <config> — cycle composition by TSan callback class.

Reads `perf report --stdio --sort symbol --percent-limit 0 -q` and buckets every symbol into the classes that
matter for deciding where to aim a transform. The point of the exercise is that our five analyses only ever
touched the memory-access bucket, and nothing has ever touched the shadow stack.
"""
import sys, re, json, collections

# perf DEMANGLES C++ symbols, so a runtime frame reads "void __tsan::MemoryAccessRangeT<false>(...)" rather
# than "_ZN6__tsan...". Two bugs followed from ignoring that: the symbol field was taken as the first
# whitespace token (so those frames were binned under the literal string "void"), and the classifier required
# "__tsan_" with an underscore, so every "__tsan::" frame fell through to "application". Together they put
# 58 % of memcached's cycles — SlotLock, Release, MetaMap::GetSync, VectorClock::Acquire, MemoryAccessRangeT —
# on the application side. Match on substrings, and take the whole symbol field.
CLASSES = [
    ("access",      re.compile(r"__tsan_(read|write|unaligned_|vptr)")),
    ("shadow_stack",re.compile(r"__tsan_func_(entry|exit)\b")),
    ("atomic",      re.compile(r"__tsan_atomic")),
    ("range",       re.compile(r"MemoryAccessRange")),
    ("sync",        re.compile(r"__tsan::(SlotLock|SlotUnlock|Release|Acquire|MetaMap|VectorClock|Mutex|"
                               r"SlotAttachAndLock|SlotDetach|DoReset|IncrementEpoch)|VectorClock::")),
    ("tsan_other",  re.compile(r"__tsan|__interceptor_|__sanitizer_|_ZN6__tsan|ThreadSanitizer")),
]

def classify(sym):
    for name, rx in CLASSES:
        if rx.match(sym):
            return name
    return "application"

def main():
    path, app, cfg = sys.argv[1], sys.argv[2], sys.argv[3]
    buckets = collections.Counter()
    per_symbol = collections.Counter()
    total = 0.0
    # perf -q --sort symbol emits "  99.92%  [.] main"; with --sort dso,symbol a dso column appears between
    # the percentage and the [.] marker. Make that column optional — assuming it was there parsed nothing at
    # all, silently, which is the failure mode this whole campaign keeps running into.
    # take the WHOLE symbol field, not its first token: a demangled C++ frame starts with its return type
    line_rx = re.compile(r"^\s*([\d.]+)%\s+(?:\S+\s+)?\[([.k])\]\s+(.+?)\s*(?:-\s+-\s*)?$")
    for line in open(path, errors="replace"):
        m = line_rx.match(line)
        if not m:
            continue
        pct, kind, sym = float(m.group(1)), m.group(2), m.group(3)
        total += pct
        c = "kernel" if kind == "k" else classify(sym)
        buckets[c] += pct
        if c != "application":
            per_symbol[sym] += pct
    if total <= 0:
        print(json.dumps({"app": app, "config": cfg, "error": "no samples parsed"}))
        return
    # renormalise to the samples actually attributed, so a truncated report cannot inflate a share
    norm = {k: 100.0 * v / total for k, v in buckets.items()}
    instrumented = sum(v for k, v in norm.items() if k not in ("application", "kernel"))
    out = {
        "app": app, "config": cfg,
        "cycles_in_tsan_pct": round(instrumented, 2),
        "of_which": {k: round(norm.get(k, 0.0), 2)
                     for k in ("access", "shadow_stack", "atomic", "range", "sync", "tsan_other")},
        "share_of_instrumented": {k: (round(100.0 * norm.get(k, 0.0) / instrumented, 1) if instrumented else 0.0)
                                  for k in ("access", "shadow_stack", "atomic", "range", "sync", "tsan_other")},
        "application_pct": round(norm.get("application", 0.0), 2),
        "kernel_pct": round(norm.get("kernel", 0.0), 2),
        "top_callbacks": [{"symbol": s, "pct": round(100.0 * p / total, 2)}
                          for s, p in per_symbol.most_common(12)],
    }
    print(json.dumps(out, indent=1))

main()
