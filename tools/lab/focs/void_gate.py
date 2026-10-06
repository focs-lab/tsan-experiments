#!/usr/bin/env python3
"""void_gate.py <view dir> [<cell log dir root>] : EVCONF / OWNER-RT void-run gate (A59f F-M2, standing rule 6 Oct).
A run is VOID when its process exited 67 or any process's stderr (forked children included) carries
"ThreadSanitizer: EVCONF run void (exit 67)". Checked per run dir: every file in it (server.out, threadtest3.log,
cmd.log, cell_error.txt, meta.json "rc") and, when a cell log root is given, every tsan.* file under <root>/<cell>
(log_path redirects runtime messages there; such a hit voids every run of that cell, conservatively).
Prints one line per void run (realpath) to stdout for COV_RETIRED, and a summary to stderr. Exit 0 always.
--finalize=<prefixes>: for EVCONF / OWNER-RT / fd-model cells, the Finalize line must read exactly "descriptor reuse model on: 0 number(s)";
"model split" or a non-zero count is VOID (6 Oct: only the reuse line says whether the model held). --census=<prefixes>: OWNER-RT cells
must also print "owner census:" (an extra requirement, never an alternative). A missing Finalize line in server.out (or, with a log root, in the cell's
tsan.* files) makes the run VOID (A67 C5: covers internal _exit, SIGKILL timeouts, uncollected children; status 67 alone cannot decide, memcached's EX_NOUSER is 67 too).
VOID-SUSPECT (stderr only, listed, not retired automatically): a run with server.out whose server.rss lacks VmHWM (server gone early)."""
import sys, os, glob, json, re
LINE = "ThreadSanitizer: EVCONF run void (exit 67)"
TESTOPT = "ThreadSanitizer: owner test options set"   # L-D (6 Oct): a run with owner_test_* options is never a run of record
args = [a for a in sys.argv[1:] if not a.startswith("--finalize=") and not a.startswith("--census=")]
CEN = [x for a in sys.argv[1:] if a.startswith("--census=") for x in a.split("=",1)[1].split(",") if x]   # OWNER-RT cells: census line required IN ADDITION
FIN = [x for a in sys.argv[1:] if a.startswith("--finalize=") for x in a.split("=",1)[1].split(",") if x]   # A67 C5: cell prefixes of OWNER-RT / fd-model arms
D = args[0]; LR = args[1] if len(args) > 1 else None
REUSE_OK = re.compile(r"descriptor reuse model on: 0 number\(s\)")   # the only form of record (tsan_fd.cpp, FdPrintStats)
REUSE_BAD = re.compile(r"descriptor reuse model split|descriptor reuse model on: [1-9][0-9]* number")
CENSUS = "ThreadSanitizer: owner census:"
def hit_file(p, needle=None):
    try:
        with open(p, errors="replace") as f: t = f.read()
        return (needle in t) if needle else (LINE in t)
    except (IsADirectoryError, OSError): return False
void = []; suspect = []; n = 0
for cell in sorted(os.listdir(D)):
    cellhit = bool(LR) and any(hit_file(p) for p in glob.glob(os.path.join(LR, cell, "tsan*")))
    for rd in sorted(glob.glob(os.path.join(D, cell, "*", "*", "run[0-9]"))):
        n += 1; why = []
        if cellhit: why.append("cell log")
        if any(hit_file(p) for p in glob.glob(os.path.join(rd, "*"))): why.append("stderr line")
        if any(hit_file(p, TESTOPT) for p in glob.glob(os.path.join(rd, "*"))) or (LR and any(hit_file(p, TESTOPT) for p in glob.glob(os.path.join(LR, cell, "tsan*")))): why.append("owner test options set")
        try:
            m = json.load(open(os.path.join(rd, "meta.json")))
            if str(m.get("rc", "")) == "67": why.append("rc 67")
        except Exception: pass
        if re.search(r"\brc=67\b", open(os.path.join(rd, "cmd.log"), errors="replace").read() if os.path.exists(os.path.join(rd, "cmd.log")) else ""): why.append("rc=67 in cmd.log")
        if any(cell.startswith(p) for p in FIN) or any(cell.startswith(p) for p in CEN):
            texts = [open(os.path.join(rd, "server.out"), errors="replace").read()] if os.path.exists(os.path.join(rd, "server.out")) else []
            if LR: texts += [open(p, errors="replace").read() for p in glob.glob(os.path.join(LR, cell, "tsan*"))]
            t = "\n".join(texts)
            if REUSE_BAD.search(t): why.append("descriptor model split or unseen frees > 0")
            elif not REUSE_OK.search(t): why.append("Finalize line 'descriptor reuse model on: 0 number(s)' missing")
            if any(cell.startswith(p) for p in CEN) and CENSUS not in t: why.append("owner census line missing (OWNER-RT)")
        if why: void.append(os.path.realpath(rd)); print(os.path.realpath(rd)); print(f"VOID {cell} {os.path.basename(rd)}: {', '.join(why)}", file=sys.stderr)
        # A67 M2 (6 Oct): bench_one discards the server's exit status (wait $spid), and a normal TSan server writes nothing at exit
        # (report_bugs=0; stats go to log_path), so there is no Finalize line to look for. Proxy: bench_one reads VmHWM from
        # /proc/<server>/status after the client ends; an empty server.rss means the server was already gone -> void-suspect.
        elif os.path.exists(os.path.join(rd, "server.out")):
            rss = open(os.path.join(rd, "server.rss"), errors="replace").read() if os.path.exists(os.path.join(rd, "server.rss")) else ""
            if "VmHWM" not in rss: suspect.append(os.path.realpath(rd)); print(f"VOID-SUSPECT {cell} {os.path.basename(rd)}: server gone before the client ended (server.rss empty)", file=sys.stderr)
print(f"void_gate: {len(void)} void, {len(suspect)} void-suspect of {n} runs (server exit status: not recorded by bench_one)", file=sys.stderr)
