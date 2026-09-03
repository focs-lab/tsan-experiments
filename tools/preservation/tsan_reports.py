#!/usr/bin/env python3
"""
Parse ThreadSanitizer reports and compare race sets across build configurations.

Used by the P2 (benchmark-level preservation) experiment of the ATC'26 rebuttal:
each application is run N times per configuration with
    TSAN_OPTIONS="log_path=<dir>/<app>.<cfg>.<run> exitcode=0"
(TSan appends ".<pid>" to log_path), and this script

  1. parses every `WARNING: ThreadSanitizer: ...` block into a structured record,
  2. assigns each record two keys:
       L1 "identical":  (kind, canonically ordered pair of access sites as
                         function@file:line, location descriptor)
       L2 "equivalent": same, with sites and location compared by function only
                        (tolerates Dominance Elimination reporting a race on a
                         different instruction of the same function),
  3. aggregates per configuration over runs (distinct races, per-race detection
     frequency, per-run counts), and
  4. compares every configuration against a baseline (normally stock `tsan`):
     races found by the baseline in >=1 run and by the configuration in 0 runs
     ("lost"), new races, and L2-only matches ("relocated").

Sub-commands:
  parse      FILE|DIR...            -> JSON list of parsed reports
  aggregate  --results-dir DIR ...  -> per-config summary + comparison tables

File naming expected by `aggregate`:  <app>.<cfg>.<run>[.<pid>]  (run = integer).
The <cfg> part may itself contain dots only if --name-regex is given.
"""

import argparse
import collections
import json
import math
import os
import re
import sys
from dataclasses import dataclass, field, asdict
from typing import Dict, List, Optional, Tuple

# --------------------------------------------------------------------------- #
# Parsing
# --------------------------------------------------------------------------- #

RE_WARNING = re.compile(r"^WARNING: ThreadSanitizer: (?P<kind>.+?) \(pid=(?P<pid>\d+)\)\s*$")
RE_SUMMARY = re.compile(r"^SUMMARY: ThreadSanitizer: (?P<kind>.+?) (?P<where>.+?)( in (?P<func>\S+))?\s*$")
# "  Write of size 4 at 0x7b0400000000 by thread T1 (mutexes: write M1):"
# "  Previous atomic read of size 8 at 0x... by main thread:"
# "  Read of size 8 at 0x... by thread T3:"
RE_ACCESS = re.compile(
    r"^\s{2}(?P<prev>Previous )?(?P<op>[Aa]tomic (?:read|write)|[Rr]ead|[Ww]rite)"
    r" of size (?P<size>\d+) at (?P<addr>0x[0-9a-f]+) by (?P<thread>main thread|thread T\d+)"
    r"(?P<mutexes> \(mutexes:[^)]*\))?:\s*$")
# Frames:  "    #0 func file.c:12:5 (bin+0x1234) (BuildId: ...)"
#          "    #1 <null> <null> (bin+0x1234)"
#          "    #0 memcpy /path/to/sanitizer_common_interceptors_memintrinsics.inc:115:5 (libclang_rt.tsan.so+0x...)"
RE_FRAME = re.compile(
    r"^\s+#(?P<idx>\d+) (?P<func>.+?) (?P<loc>\S+)(?: \((?P<mod>[^)]*)\))?(?: \(BuildId: [^)]*\))?\s*$")
# (func is lazy so that demangled C++ names such as "Foo::bar(int, int) const" parse; TSan always
#  prints a location token, "<null>" when unknown)
RE_FRAME_ANY = re.compile(r"^\s+#\d+ ")
RE_THREAD_ID = re.compile(r"\b([TM])\d+\b")
RE_LOCATION = re.compile(r"^\s{2}Location is (?P<desc>.+?):?\s*$")
RE_MUTEX = re.compile(r"^\s{2}Mutex M\d+ .*$")
RE_THREAD = re.compile(r"^\s{2}Thread T\d+ .*$")
RE_LOC_GLOBAL = re.compile(r"global '(?P<name>[^']*)' of size (?P<size>\d+) at (?P<addr>0x[0-9a-f]+)(?: \((?P<mod>[^)]*)\))?")
RE_LOC_MAPPED = re.compile(r"global '\?\?' at 0x[0-9a-f]+ \((?P<name>[^()+]+)\+(?P<off>0x[0-9a-f]+)\)")
RE_LOC_GLOBAL_NOSIZE = re.compile(r"global '(?P<name>[^']*)' at (?P<addr>0x[0-9a-f]+)")
RE_LOC_HEAP = re.compile(r"heap block of size (?P<size>\d+) at (?P<addr>0x[0-9a-f]+) allocated by (?P<thread>main thread|thread T\d+)")
RE_LOC_STACK = re.compile(r"stack of (?P<thread>main thread|thread T\d+)")
RE_LOC_FD = re.compile(r"file descriptor (?P<fd>\d+) created by (?P<thread>main thread|thread T\d+)")
RE_REPORTED = re.compile(r"^ThreadSanitizer: reported (?P<n>\d+) warnings\s*$")
RE_HEX = re.compile(r"0x[0-9a-fA-F]+")

# Frames belonging to the sanitizer runtime / libc interceptors are skipped when
# picking the "application" frame that identifies a race site.
RUNTIME_FUNC_PREFIXES = ("__interceptor_", "__tsan_", "__sanitizer", "___interceptor_",
                         "__sanitizer_", "__cxa_", "wrap_", "__wrap_")
RUNTIME_MOD_SUBSTR = ("libclang_rt.tsan", "libclang_rt.asan")
RUNTIME_FILE_SUBSTR = ("/compiler-rt/lib/", "sanitizer_common_interceptors", "tsan_interceptors")
# libc/libstdc++ wrappers reported as the innermost frame with no source location.
LIBC_LIKE_FUNCS = {"memcpy", "memmove", "memset", "memcmp", "strlen", "strcpy", "strncpy",
                   "strcmp", "strncmp", "strcat", "strchr", "strrchr", "strstr", "bcopy", "bzero",
                   "malloc", "calloc", "realloc", "free", "posix_memalign", "aligned_alloc",
                   "operator new", "operator delete", "operator new[]", "operator delete[]",
                   "pthread_create", "pthread_mutex_lock", "pthread_mutex_unlock",
                   "read", "write", "pread", "pwrite", "recv", "send", "fread", "fwrite",
                   "wmemcpy", "wmemset", "wcslen", "strdup", "strndup", "snprintf", "vsnprintf",
                   "sprintf", "vsprintf", "sscanf", "vfprintf", "fprintf", "printf", "puts"}


@dataclass
class Frame:
    idx: int
    func: str
    file: Optional[str]      # basename (path stripped); None if <null>
    path: Optional[str]      # as printed
    line: Optional[int]
    col: Optional[int]
    module: Optional[str]

    def is_runtime(self) -> bool:
        if self.func.startswith(RUNTIME_FUNC_PREFIXES):
            return True
        if self.module and any(s in self.module for s in RUNTIME_MOD_SUBSTR):
            return True
        if self.path and any(s in self.path for s in RUNTIME_FILE_SUBSTR):
            return True
        # An unsymbolized libc-like call (e.g. "memcpy <null>") sits between the
        # interceptor and the application frame.
        if self.func in LIBC_LIKE_FUNCS and self.file is None:
            return True
        return False

    def site_l1(self) -> str:
        loc = f"{self.file}:{self.line}" if self.file and self.line is not None else (self.file or "?")
        return f"{self.func}@{loc}"

    def site_l2(self) -> str:
        return self.func


@dataclass
class Access:
    op: str                  # read | write | atomic read | atomic write
    previous: bool
    size: int
    addr: str
    thread: str
    mutexes: str
    stack: List[Frame] = field(default_factory=list)

    def app_frame(self) -> Optional[Frame]:
        for f in self.stack:
            if not f.is_runtime():
                return f
        return self.stack[0] if self.stack else None


@dataclass
class Location:
    kind: str                # global | heap | stack | fd | other
    raw: str                 # descriptor with addresses masked
    name: Optional[str] = None
    size: Optional[int] = None
    thread: Optional[str] = None
    stack: List[Frame] = field(default_factory=list)

    def app_frame(self) -> Optional[Frame]:
        for f in self.stack:
            if not f.is_runtime():
                return f
        return self.stack[0] if self.stack else None

    def desc_l1(self) -> str:
        if self.kind == "global":
            return f"global:{self.name}"
        if self.kind == "heap":
            f = self.app_frame()
            return f"heap:{f.site_l1() if f else '?'}"
        if self.kind == "stack":
            return "stack"
        if self.kind == "fd":
            f = self.app_frame()
            return f"fd:{f.site_l1() if f else '?'}"
        if self.kind == "mapped":
            return f"mapped:{self.raw}"          # file+offset
        return f"other:{self.raw}"

    def desc_l2(self) -> str:
        if self.kind == "global":
            return f"global:{self.name}"
        if self.kind == "heap":
            f = self.app_frame()
            return f"heap:{f.site_l2() if f else '?'}"
        if self.kind == "stack":
            return "stack"
        if self.kind == "fd":
            f = self.app_frame()
            return f"fd:{f.site_l2() if f else '?'}"
        if self.kind == "mapped":
            return f"mapped:{self.name}"         # file only
        return f"other:{self.raw}"


@dataclass
class Report:
    kind: str
    pid: int
    source: str              # file the report came from
    index: int               # ordinal within that file
    accesses: List[Access] = field(default_factory=list)
    location: Optional[Location] = None
    summary_line: Optional[str] = None
    extra_stacks: int = 0    # mutex / thread creation stacks (not used in keys)
    unparsed_frames: int = 0 # "#N ..." lines the frame regex did not accept

    # ---- keys -------------------------------------------------------------
    def _sites(self, level: int) -> Tuple[str, ...]:
        out = []
        for a in self.accesses:
            f = a.app_frame()
            site = (f.site_l1() if level == 1 else f.site_l2()) if f else "?"
            out.append(f"{a.op}:{site}")
        # Which access is "current" and which is "previous" depends on thread
        # timing, so the pair is ordered canonically.
        return tuple(sorted(out))

    def key(self, level: int) -> str:
        loc = ""
        if self.location is not None:
            loc = self.location.desc_l1() if level == 1 else self.location.desc_l2()
        sites = self._sites(level)
        if not sites and self.summary_line:
            # kinds without access stacks (thread leak, mutex misuse, signal-unsafe call):
            # identify them by the SUMMARY line's location, with addresses/ids masked
            prefix = f"SUMMARY: ThreadSanitizer: {self.kind} "
            where = self.summary_line[len(prefix):] if self.summary_line.startswith(prefix) else self.summary_line
            sites = (RE_THREAD_ID.sub(r"\1?", RE_HEX.sub("0x?", where)),)
        return " | ".join([self.kind, *sites, loc])

    def key_l1(self) -> str:
        return self.key(1)

    def key_l2(self) -> str:
        return self.key(2)

    def key_l3(self) -> str:
        """L3 'location': kind + location descriptor (function-level) + the WRITER side(s) at
        function@file:line; reader sites are collapsed. On a granule with one writer and many hot
        readers, which reader record survives the four shadow slots is eviction arithmetic; the
        question "is the race on this location still found?" is answered at this level."""
        loc = self.location.desc_l2() if self.location is not None else ""
        writers = []
        for a in self.accesses:
            if "write" in a.op:
                f = a.app_frame()
                writers.append(f"{a.op}:{f.site_l1() if f else '?'}")
        if not writers:                      # read/read cannot be a race; keep whatever there is
            writers = list(self._sites(1))
        return " | ".join([self.kind, *sorted(writers), loc])

    def to_json(self) -> dict:
        d = asdict(self)
        d["key_l1"] = self.key_l1()
        d["key_l2"] = self.key_l2()
        d["key_l3"] = self.key_l3()
        return d


def _parse_frame(line: str) -> Optional[Frame]:
    m = RE_FRAME.match(line)
    if not m:
        return None
    loc = m.group("loc")
    path = file = None
    ln = col = None
    if loc != "<null>":
        # path:line:col | path:line | path
        parts = loc.rsplit(":", 2)
        if len(parts) == 3 and parts[1].isdigit() and parts[2].isdigit():
            path, ln, col = parts[0], int(parts[1]), int(parts[2])
        elif len(parts) >= 2 and parts[-1].isdigit():
            path, ln = ":".join(parts[:-1]), int(parts[-1])
        else:
            path = loc
        file = os.path.basename(path)
    return Frame(idx=int(m.group("idx")), func=m.group("func"), file=file, path=path,
                 line=ln, col=col, module=m.group("mod"))


def _parse_location(desc: str) -> Location:
    raw = RE_THREAD_ID.sub(r"\1?", RE_HEX.sub("0x?", desc))
    # Unsymbolized stack address: "global '??' at 0x... ([stack]+0x...)".
    if "[stack]" in desc:
        return Location("stack", raw)
    # Unsymbolized address inside a memory-mapped file (e.g. SQLite's wal-index
    # "global '??' at 0x... (test.db-shm+0x68)"): identify it by file + offset.
    if (m := RE_LOC_MAPPED.search(desc)):
        return Location("mapped", f"{m.group('name')}+{m.group('off')}", name=m.group("name"))
    if (m := RE_LOC_GLOBAL.search(desc)):
        return Location("global", raw, name=m.group("name"), size=int(m.group("size")))
    if (m := RE_LOC_GLOBAL_NOSIZE.search(desc)):
        return Location("global", raw, name=m.group("name"))
    if (m := RE_LOC_HEAP.search(desc)):
        return Location("heap", raw, size=int(m.group("size")), thread=m.group("thread"))
    if (m := RE_LOC_STACK.search(desc)):
        return Location("stack", raw, thread=m.group("thread"))
    if (m := RE_LOC_FD.search(desc)):
        return Location("fd", raw, name=m.group("fd"), thread=m.group("thread"))
    return Location("other", raw)


def parse_text(text: str, source: str = "<str>") -> Tuple[List[Report], Optional[int]]:
    """Parse all TSan report blocks in `text`. Returns (reports, reported_count)."""
    reports: List[Report] = []
    reported: Optional[int] = None
    cur: Optional[Report] = None
    # Where the next frame lines go: an Access, a Location, or None (ignored stack).
    sink = None
    for line in text.splitlines():
        if (m := RE_REPORTED.match(line)):
            reported = int(m.group("n"))
            continue
        if (m := RE_WARNING.match(line)):
            cur = Report(kind=m.group("kind").strip(), pid=int(m.group("pid")),
                         source=source, index=len(reports))
            reports.append(cur)
            sink = None
            continue
        if cur is None:
            continue
        if (m := RE_SUMMARY.match(line)):
            cur.summary_line = line.strip()
            cur = None
            sink = None
            continue
        if (m := RE_ACCESS.match(line)):
            op = m.group("op").lower()
            acc = Access(op=op, previous=bool(m.group("prev")), size=int(m.group("size")),
                         addr=m.group("addr"), thread=m.group("thread"),
                         mutexes=(m.group("mutexes") or "").strip())
            cur.accesses.append(acc)
            sink = acc.stack
            continue
        if (m := RE_LOCATION.match(line)):
            cur.location = _parse_location(m.group("desc"))
            sink = cur.location.stack
            continue
        if RE_MUTEX.match(line) or RE_THREAD.match(line):
            cur.extra_stacks += 1
            sink = None
            continue
        fr = _parse_frame(line)
        if fr is not None:
            if sink is not None:
                sink.append(fr)
            continue
        if RE_FRAME_ANY.match(line):
            cur.unparsed_frames += 1
            continue
        # Blank lines / "As if synchronized via sleep" / "==========" separators.
    return reports, reported


def parse_file(path: str) -> Tuple[List[Report], Optional[int]]:
    with open(path, "r", errors="replace") as fh:
        return parse_text(fh.read(), source=path)


def iter_files(paths: List[str]):
    for p in paths:
        if os.path.isdir(p):
            for root, _dirs, files in os.walk(p):
                for f in sorted(files):
                    yield os.path.join(root, f)
        else:
            yield p


# --------------------------------------------------------------------------- #
# Aggregation
# --------------------------------------------------------------------------- #

@dataclass
class RunResult:
    app: str
    cfg: str
    run: int
    files: List[str]
    reports: List[Report]
    reported_counter: Optional[int]     # sum of "reported N warnings" lines


def default_name_parser(app_hint: Optional[str]):
    """Return fn(filename) -> (app, cfg, run) or None for '<app>.<cfg>.<run>[.<pid>]'."""
    def parse(fname: str):
        base = os.path.basename(fname)
        parts = base.split(".")
        # strip trailing pid, or the ".noreports" placeholder the runner creates for a run
        # whose process(es) wrote no log file at all (counts as a run with zero reports)
        if len(parts) >= 4 and (parts[-1].isdigit() or parts[-1] == "noreports") and parts[-2].isdigit():
            parts = parts[:-1]
        if len(parts) < 3 or not parts[-1].isdigit():
            return None
        app, cfg, run = parts[0], ".".join(parts[1:-1]), int(parts[-1])
        if app_hint and app != app_hint:
            return None
        return app, cfg, run
    return parse


def collect_runs(results_dir: str, app: Optional[str], name_regex: Optional[str]) -> Dict[Tuple[str, str, int], RunResult]:
    runs: Dict[Tuple[str, str, int], RunResult] = {}
    if name_regex:
        rx = re.compile(name_regex)

        def parse_name(fname):
            m = rx.search(os.path.basename(fname))
            if not m:
                return None
            return m.group("app"), m.group("cfg"), int(m.group("run"))
    else:
        parse_name = default_name_parser(app)
    for f in iter_files([results_dir]):
        if f.endswith((".json", ".csv", ".md", ".manifest", ".txt.zst")):
            continue
        parsed = parse_name(f)
        if parsed is None:
            continue
        a, cfg, run = parsed
        key = (a, cfg, run)
        rr = runs.get(key)
        if rr is None:
            rr = runs[key] = RunResult(a, cfg, run, [], [], None)
        reps, cnt = parse_file(f)
        rr.files.append(f)
        rr.reports.extend(reps)
        if cnt is not None:
            rr.reported_counter = (rr.reported_counter or 0) + cnt
    return runs


def mean_sd(xs: List[float]) -> Tuple[float, float]:
    n = len(xs)
    if n == 0:
        return float("nan"), float("nan")
    m = sum(xs) / n
    if n == 1:
        return m, 0.0
    var = sum((x - m) ** 2 for x in xs) / (n - 1)
    return m, math.sqrt(var)


def fisher_exact_two_sided(a: int, b: int, c: int, d: int) -> float:
    """Two-sided Fisher exact p for table [[a, b], [c, d]] (a = hits in cfg1, b = misses, ...)."""
    def lchoose(n, k):
        return math.lgamma(n + 1) - math.lgamma(k + 1) - math.lgamma(n - k + 1)
    n1, n2, k = a + b, c + d, a + c
    n = n1 + n2
    lo, hi = max(0, k - n2), min(k, n1)
    logs = {x: lchoose(n1, x) + lchoose(n2, k - x) - lchoose(n, k) for x in range(lo, hi + 1)}
    p_obs = logs[a]
    p = 0.0
    for x, lp in logs.items():
        if lp <= p_obs + 1e-9:
            p += math.exp(lp)
    return min(1.0, p)


@dataclass
class CfgSummary:
    cfg: str
    nruns: int
    runs: List[int]
    reports_per_run: List[int]
    distinct_l1_per_run: List[int]
    distinct_l2_per_run: List[int]
    union_l1: Dict[str, int]      # key -> number of runs containing it
    union_l2: Dict[str, int]
    l1_to_l2: Dict[str, str]
    example: Dict[str, Report]    # L1 key -> one example report
    kinds: Dict[str, int]         # kind -> total report count
    reported_counter: List[Optional[int]]
    union_l3: Dict[str, int] = field(default_factory=dict)
    l1_to_l3: Dict[str, str] = field(default_factory=dict)
    distinct_l3_per_run: List[int] = field(default_factory=list)


def summarize_cfg(cfg: str, runs: List[RunResult], kinds_filter: Optional[set]) -> CfgSummary:
    runs = sorted(runs, key=lambda r: r.run)
    union_l1: Dict[str, int] = collections.Counter()
    union_l2: Dict[str, int] = collections.Counter()
    l1_to_l2: Dict[str, str] = {}
    union_l3: Dict[str, int] = collections.Counter()
    l1_to_l3: Dict[str, str] = {}
    example: Dict[str, Report] = {}
    kinds: Dict[str, int] = collections.Counter()
    rpr, d1, d2, d3, rc = [], [], [], [], []
    for r in runs:
        reps = [x for x in r.reports if not kinds_filter or x.kind in kinds_filter]
        s1, s2, s3 = set(), set(), set()
        for x in reps:
            kinds[x.kind] += 1
            k1, k2, k3 = x.key_l1(), x.key_l2(), x.key_l3()
            s1.add(k1)
            s2.add(k2)
            s3.add(k3)
            l1_to_l2[k1] = k2
            l1_to_l3[k1] = k3
            example.setdefault(k1, x)
        for k in s1:
            union_l1[k] += 1
        for k in s2:
            union_l2[k] += 1
        for k in s3:
            union_l3[k] += 1
        rpr.append(len(reps))
        d1.append(len(s1))
        d2.append(len(s2))
        d3.append(len(s3))
        rc.append(r.reported_counter)
    return CfgSummary(cfg, len(runs), [r.run for r in runs], rpr, d1, d2,
                      dict(union_l1), dict(union_l2), l1_to_l2, example, dict(kinds), rc,
                      dict(union_l3), l1_to_l3, d3)


def fmt_ms(xs: List[float]) -> str:
    m, s = mean_sd(xs)
    return f"{m:.1f} ± {s:.1f}"


def compare(base: CfgSummary, other: CfgSummary) -> dict:
    """Set differences base vs other at L1 and L2."""
    b1, o1 = set(base.union_l1), set(other.union_l1)
    b2, o2 = set(base.union_l2), set(other.union_l2)
    lost_l1 = sorted(b1 - o1)
    new_l1 = sorted(o1 - b1)
    lost_l2 = sorted(b2 - o2)
    new_l2 = sorted(o2 - b2)
    # L1-lost keys whose L2 key is still found by `other` = relocated (or a
    # different instruction of the same function).
    relocated = [k for k in lost_l1 if base.l1_to_l2[k] in o2]
    b3, o3 = set(base.union_l3), set(other.union_l3)
    lost_l3 = sorted(b3 - o3)
    new_l3 = sorted(o3 - b3)
    # L1-lost keys whose location-level (L3) key is still found by `other`: same race, other reader site.
    relocated_l3 = [k for k in lost_l1 if base.l1_to_l3[k] in o3]
    # Per-key detection frequency tests for keys present in both unions (L1).
    freq_tests = []
    for k in sorted(b1 & o1):
        a, c = base.union_l1[k], other.union_l1[k]
        p = fisher_exact_two_sided(a, base.nruns - a, c, other.nruns - c)
        freq_tests.append((k, a, c, p))
    return dict(lost_l1=lost_l1, new_l1=new_l1, lost_l2=lost_l2, new_l2=new_l2,
                relocated=relocated, freq_tests=freq_tests,
                lost_l3=lost_l3, new_l3=new_l3, relocated_l3=relocated_l3)


def describe_report(r: Report) -> str:
    parts = []
    for a in r.accesses:
        f = a.app_frame()
        parts.append(f"{'prev ' if a.previous else ''}{a.op} size {a.size} by {a.thread} at "
                     f"{f.func}@{f.path}:{f.line}:{f.col}" if f else f"{a.op} (no frame)")
    loc = r.location.desc_l1() if r.location else "no location"
    return f"{r.kind}: " + " / ".join(parts) + f" [{loc}]"


def write_markdown(out, app: str, base: CfgSummary, others: List[CfgSummary], cmps: Dict[str, dict],
                   kinds_filter: Optional[set]):
    out.write(f"# Preservation summary: {app}\n\n")
    if kinds_filter:
        out.write(f"Report kinds considered: {', '.join(sorted(kinds_filter))}\n\n")
    out.write("## Per-configuration counts (mean ± sample σ over runs)\n\n")
    out.write("| config | runs | reports/run | distinct L1/run | distinct L2/run | union L1 | union L2 | union L3 | kinds |\n")
    out.write("|---|---|---|---|---|---|---|---|---|\n")
    for s in [base, *others]:
        kinds = ", ".join(f"{k}:{v}" for k, v in sorted(s.kinds.items()))
        out.write(f"| {s.cfg} | {s.nruns} | {fmt_ms(s.reports_per_run)} | {fmt_ms(s.distinct_l1_per_run)} | "
                  f"{fmt_ms(s.distinct_l2_per_run)} | {len(s.union_l1)} | {len(s.union_l2)} | {len(s.union_l3)} | {kinds} |\n")
    out.write("\n")
    for s in others:
        c = cmps[s.cfg]
        out.write(f"## {s.cfg} vs {base.cfg}\n\n")
        out.write(f"- L1 (function@file:line): lost {len(c['lost_l1'])} of {len(base.union_l1)} baseline races, "
                  f"new {len(c['new_l1'])}; of the lost, {len(c['relocated'])} are still found at L2 (relocated).\n")
        out.write(f"- L2 (function only): lost {len(c['lost_l2'])} of {len(base.union_l2)}, new {len(c['new_l2'])}.\n")
        out.write(f"- L3 (location + writer site, readers collapsed): lost {len(c['lost_l3'])} of {len(base.union_l3)}, "
                  f"new {len(c['new_l3'])}; of the L1-lost, {len(c['relocated_l3'])} are still found at L3.\n\n")
        if c["lost_l3"]:
            out.write(f"### Locations (L3) reported by {base.cfg} in ≥1 run and by {s.cfg} in 0 runs\n\n")
            out.write("| baseline runs | race location |\n|---|---|\n")
            for k in c["lost_l3"]:
                out.write(f"| {base.union_l3[k]}/{base.nruns} | `{k}` |\n")
            out.write("\n")
        if c["lost_l1"]:
            out.write(f"### Races reported by {base.cfg} in ≥1 run and by {s.cfg} in 0 runs (L1)\n\n")
            out.write("| baseline runs | at L2 in cfg? | race |\n|---|---|---|\n")
            for k in c["lost_l1"]:
                reloc = "yes" if k in c["relocated"] else "**no**"
                out.write(f"| {base.union_l1[k]}/{base.nruns} | {reloc} | `{k}` |\n")
            out.write("\n")
        if c["new_l1"]:
            out.write(f"### Races reported by {s.cfg} but never by {base.cfg} (L1)\n\n")
            out.write("| cfg runs | at L2 in baseline? | race |\n|---|---|---|\n")
            for k in c["new_l1"]:
                inb = "yes" if s.l1_to_l2[k] in base.union_l2 else "**no**"
                out.write(f"| {s.union_l1[k]}/{s.nruns} | {inb} | `{k}` |\n")
            out.write("\n")
        sig = [(k, a, b, p) for (k, a, b, p) in c["freq_tests"] if p < 0.05]
        if sig:
            out.write(f"### Detection-frequency changes (both found it; Fisher exact p < 0.05)\n\n")
            out.write(f"| {base.cfg} | {s.cfg} | p | race |\n|---|---|---|---|\n")
            for k, a, b, p in sig:
                out.write(f"| {a}/{base.nruns} | {b}/{s.nruns} | {p:.3g} | `{k}` |\n")
            out.write("\n")
    out.write(f"## All races (L1) with per-configuration detection frequency\n\n")
    cfgs = [base, *others]
    out.write("| " + " | ".join(s.cfg for s in cfgs) + " | race |\n")
    out.write("|" + "---|" * (len(cfgs) + 1) + "\n")
    all_keys = sorted(set().union(*[set(s.union_l1) for s in cfgs]))
    for k in all_keys:
        cells = [f"{s.union_l1.get(k, 0)}/{s.nruns}" for s in cfgs]
        out.write("| " + " | ".join(cells) + f" | `{k}` |\n")
    out.write("\n")


def write_csv(path: str, app: str, cfgs: List[CfgSummary]):
    import csv
    with open(path, "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["app", "key_level", "key", *[f"{s.cfg}_runs_hit" for s in cfgs], *[f"{s.cfg}_runs" for s in cfgs]])
        for level, attr in ((1, "union_l1"), (2, "union_l2")):
            keys = sorted(set().union(*[set(getattr(s, attr)) for s in cfgs]))
            for k in keys:
                w.writerow([app, level, k, *[getattr(s, attr).get(k, 0) for s in cfgs], *[s.nruns for s in cfgs]])


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #

def cmd_parse(args):
    allrep = []
    for f in iter_files(args.paths):
        reps, cnt = parse_file(f)
        for r in reps:
            allrep.append(r)
        if args.verbose:
            print(f"{f}: {len(reps)} reports parsed, counter={cnt}", file=sys.stderr)
    if args.brief:
        for r in allrep:
            print(f"[{r.source}#{r.index}] L1: {r.key_l1()}")
            print(f"{' ' * (len(r.source) + len(str(r.index)) + 3)} L2: {r.key_l2()}")
    else:
        json.dump([r.to_json() for r in allrep], sys.stdout, indent=1)
        print()


def cmd_aggregate(args):
    runs = collect_runs(args.results_dir, args.app, args.name_regex)
    if not runs:
        sys.exit(f"no run files matching <app>.<cfg>.<run>[.<pid>] under {args.results_dir}")
    apps = sorted({k[0] for k in runs})
    kinds_filter = None if args.kinds in (None, "", "all") else set(args.kinds.split(","))
    for app in apps:
        by_cfg: Dict[str, List[RunResult]] = collections.defaultdict(list)
        for (a, cfg, _run), rr in runs.items():
            if a == app:
                by_cfg[cfg].append(rr)
        if args.baseline not in by_cfg:
            print(f"[{app}] baseline config '{args.baseline}' not found; configs: {sorted(by_cfg)}", file=sys.stderr)
            continue
        base = summarize_cfg(args.baseline, by_cfg[args.baseline], kinds_filter)
        order = args.configs.split(",") if args.configs else sorted(c for c in by_cfg if c != args.baseline)
        others = [summarize_cfg(c, by_cfg[c], kinds_filter) for c in order if c in by_cfg]
        cmps = {s.cfg: compare(base, s) for s in others}
        outdir = args.out_dir or args.results_dir
        os.makedirs(outdir, exist_ok=True)
        md_path = os.path.join(outdir, f"preservation_{app}.md")
        with open(md_path, "w") as fh:
            write_markdown(fh, app, base, others, cmps, kinds_filter)
        write_csv(os.path.join(outdir, f"preservation_{app}.csv"), app, [base, *others])
        with open(os.path.join(outdir, f"preservation_{app}.json"), "w") as fh:
            json.dump({
                "app": app,
                "baseline": base.cfg,
                "configs": {s.cfg: {
                    "runs": s.runs, "reports_per_run": s.reports_per_run,
                    "distinct_l1_per_run": s.distinct_l1_per_run,
                    "distinct_l2_per_run": s.distinct_l2_per_run,
                    "union_l1": s.union_l1, "union_l2": s.union_l2, "union_l3": s.union_l3, "kinds": s.kinds,
                    "reported_counter": s.reported_counter,
                } for s in [base, *others]},
                "compare": {c: {k: v for k, v in d.items() if k != "freq_tests"} for c, d in cmps.items()},
            }, fh, indent=1)
        # Console digest
        print(f"== {app} ==")
        unparsed = {cfg: sum(x.unparsed_frames for rr in rrs for x in rr.reports) for cfg, rrs in by_cfg.items()}
        if any(unparsed.values()):
            print(f"  WARNING: frame lines the parser did not accept (sites degrade to '?'): "
                  + ", ".join(f"{c}={n}" for c, n in sorted(unparsed.items()) if n), file=sys.stderr)
        else:
            print("  unparsed frame lines: 0")
        for s in [base, *others]:
            print(f"  {s.cfg:32s} runs={s.nruns:2d} reports/run={fmt_ms(s.reports_per_run):>14s} "
                  f"distinctL1/run={fmt_ms(s.distinct_l1_per_run):>12s} unionL1={len(s.union_l1):3d} unionL2={len(s.union_l2):3d} unionL3={len(s.union_l3):3d}")
        for s in others:
            c = cmps[s.cfg]
            print(f"  {s.cfg} vs {base.cfg}: lost L1={len(c['lost_l1'])} (relocated={len(c['relocated'])}) "
                  f"new L1={len(c['new_l1'])} | lost L2={len(c['lost_l2'])} new L2={len(c['new_l2'])} | "
                  f"lost L3={len(c['lost_l3'])} new L3={len(c['new_l3'])}")
        print(f"  -> {md_path}")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("parse", help="parse TSan log files and print structured reports")
    p.add_argument("paths", nargs="+")
    p.add_argument("--brief", action="store_true", help="print only L1/L2 keys")
    p.add_argument("-v", "--verbose", action="store_true")
    p.set_defaults(fn=cmd_parse)
    a = sub.add_parser("aggregate", help="aggregate runs per config and compare against a baseline")
    a.add_argument("--results-dir", required=True)
    a.add_argument("--app", help="only this app (default: all apps found)")
    a.add_argument("--baseline", default="tsan")
    a.add_argument("--configs", help="comma-separated config order (default: all others, sorted)")
    a.add_argument("--kinds", default="data race",
                   help="comma-separated report kinds to keep, e.g. 'data race,heap-use-after-free' "
                        "(default: 'data race'; 'all' keeps every kind incl. thread leak / deadlock)")
    a.add_argument("--name-regex", help="regex with named groups app, cfg, run for non-standard file names")
    a.add_argument("--out-dir", help="where to write preservation_<app>.{md,csv,json} (default: results dir)")
    a.set_defaults(fn=cmd_aggregate)
    args = ap.parse_args(argv)
    args.fn(args)


if __name__ == "__main__":
    main()
