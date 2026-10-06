#!/usr/bin/env python3
"""mysql_units.py — the MySQL part of the compile smoke (tools/smoke/smoke_compile.sh).

  mysql_units.py select <compile_commands.json> <mysql source dir> <units.jsonl>
      Freeze the unit sample from a reference compile database: every extra/protobuf unit (the bundled protobuf is where
      P1-v2's EscapeAnalysis.cpp:3134 assertion fired), the 30 largest sql/ units, the 15 largest storage/innobase units, and
      every 10th of the rest in path order. Paths are relative to the source tree, or to the build tree for generated
      sources (sql/sql_yacc.cc, the X plugin's .pb.cc), so a generated sql/ unit competes with the others by size.
      Each line keeps the reference entry as it was (directory, file, output, argv).

  mysql_units.py run <units.jsonl> <root> <jobs> <outdir> [--extra "<flags>"] [--timeout S] [--filter RE]
                     [--expect-unit RE --expect-msg RE] [--objdir DIR]
      Compile every unit with <root>'s clang, -o /dev/null (or DIR/<unit>.o), the dependency-file options removed and <flags>
      appended. Exit 0 when every unit compiled (or, in control mode, when the expected unit failed with the expected
      message), 1 otherwise. A unit that exceeds the timeout fails: a compile-time blow-up breaks a build as surely as a crash.

  mysql_units.py textcmp <objdir A> <objdir B>
      The "flag off = base" check on the sample: per object, the disassembly of every code section with its relocations
      (objdump -d -r), so C++ inline and template functions in their COMDAT .text.* sections count, and debug info (which
      names the compiler and so differs between any two roots) does not. Exit 0 when every object is identical.
"""
import argparse, concurrent.futures as cf, json, os, re, shlex, subprocess, sys, time

def entries(db):
    seen = {}
    for e in json.load(open(db)):
        argv = e["arguments"] if "arguments" in e else shlex.split(e["command"])
        out = e.get("output") or (argv[argv.index("-o") + 1] if "-o" in argv else e["file"])
        key = os.path.join(e["directory"], out)
        seen.setdefault(key, {"directory": e["directory"], "file": os.path.normpath(os.path.join(e["directory"], e["file"])),
                              "output": out, "argv": argv})
    return list(seen.values())

def select(a):
    src, bld = os.path.realpath(a.src), os.path.realpath(os.path.dirname(a.db))
    def relpath(f):
        f = os.path.realpath(f)
        for d in (bld, src):   # generated sources live in the build tree
            if f.startswith(d + "/"): return os.path.relpath(f, d)
    allu = entries(a.db)
    units = [u for u in allu if relpath(u["file"])]
    rel = lambda u: relpath(u["file"])
    size = lambda u: os.path.getsize(u["file"])
    proto = sorted((u for u in units if rel(u).startswith("extra/protobuf/")), key=rel)
    sql = sorted((u for u in units if rel(u).startswith("sql/")), key=lambda u: (-size(u), rel(u)))[:30]
    inno = sorted((u for u in units if rel(u).startswith("storage/innobase/")), key=lambda u: (-size(u), rel(u)))[:15]
    taken = {id(u) for u in proto + sql + inno}
    rest = sorted((u for u in units if id(u) not in taken), key=rel)[::10]
    with open(a.out, "w") as f:
        for cat, us in (("protobuf", proto), ("sql-largest", sql), ("innobase-largest", inno), ("rest-every-10th", rest)):
            for u in us: f.write(json.dumps(dict(u, category=cat, rel=rel(u)), sort_keys=True) + "\n")
    print(f"{len(allu)} units in the compile database ({len(allu) - len(units)} outside the source and build trees, not sampled); sample {len(proto) + len(sql) + len(inno) + len(rest)}: "
          f"protobuf {len(proto)}, sql largest {len(sql)}, innobase largest {len(inno)}, rest every 10th {len(rest)}")

DEPOPTS_ARG = {"-MT", "-MF", "-MQ"}
def command(u, root, extra, obj="/dev/null"):
    argv, out, i = list(u["argv"]), [], 1
    cxx = os.path.basename(argv[0]).startswith("clang++") or argv[0].endswith("++")
    while i < len(argv):
        x = argv[i]
        if x == "-o" or x in DEPOPTS_ARG: i += 2; continue
        if x in ("-MD", "-MMD"): i += 1; continue
        out.append(x); i += 1
    return [os.path.join(root, "bin", "clang++" if cxx else "clang")] + out + ["-o", obj] + extra

NOISE = re.compile(r"^-- Using .* for Module|^\s*$")
def compile_one(u, root, extra, timeout, objdir=None):
    obj = "/dev/null"
    if objdir: obj = os.path.join(objdir, u["rel"] + "." + u["output"].replace("/", "_") + ".o"); os.makedirs(os.path.dirname(obj), exist_ok=True)
    argv, t0 = command(u, root, extra, obj), time.time()
    try:
        p = subprocess.run(argv, cwd=u["directory"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout,
                           text=True, errors="replace")
        rc, log = p.returncode, p.stdout
    except subprocess.TimeoutExpired as e:
        rc, log = "timeout", (e.stdout or b"").decode(errors="replace") if isinstance(e.stdout, bytes) else (e.stdout or "")
    lines = [l for l in log.splitlines() if not NOISE.search(l)]
    first = next((l for l in lines if re.search(r"Assertion|error:|PLEASE submit|Stack dump|LLVM ERROR|Segmentation", l)),
                 lines[0] if lines else "")
    return {"rel": u["rel"], "category": u["category"], "rc": rc, "secs": round(time.time() - t0, 1),
            "first": first[:400], "log": "\n".join(lines[:200]) if rc != 0 else ""}

def run(a):
    units = [json.loads(l) for l in open(a.units)]
    if a.filter: units = [u for u in units if re.search(a.filter, u["rel"])]
    extra = shlex.split(a.extra or "")
    os.makedirs(a.outdir, exist_ok=True)
    res = []
    with cf.ThreadPoolExecutor(a.jobs) as ex, open(os.path.join(a.outdir, "results.jsonl"), "w") as f:
        for r in ex.map(lambda u: compile_one(u, a.root, extra, a.timeout, a.objdir), units):
            res.append(r); f.write(json.dumps(r) + "\n"); f.flush()
    bad = [r for r in res if r["rc"] != 0]
    lines = [f"mysql sample: {len(res)} units, {len(bad)} failed ({sum(r['rc'] == 'timeout' for r in res)} timeouts of {a.timeout} s); "
             f"compile time total {sum(r['secs'] for r in res):.0f} s",
             "slowest: " + ", ".join(f"{r['rel']} {r['secs']} s" for r in sorted(res, key=lambda r: -r["secs"])[:5])]
    lines += [f"  FAILED {r['rel']} rc={r['rc']}: {r['first']}" for r in bad]
    ok = not bad
    if a.expect_unit:
        hit = [r for r in bad if re.search(a.expect_unit, r["rel"]) and re.search(a.expect_msg, r["log"])]
        cand = [r["rel"] for r in res if re.search(a.expect_unit, r["rel"])]
        if not cand: lines.append(f"CONTROL: no unit matches {a.expect_unit!r} - the control cannot run"); ok = False
        elif hit: lines.append(f"CONTROL REPRODUCED: {hit[0]['rel']} failed with {a.expect_msg!r}"); ok = True
        else: lines.append(f"CONTROL NOT REPRODUCED: {cand} did not fail with {a.expect_msg!r} - this smoke cannot be trusted to fire"); ok = False
    else:
        lines.append("MYSQL SAMPLE: " + ("PASS" if ok else "FAIL"))
    open(os.path.join(a.outdir, "summary.txt"), "w").write("\n".join(lines) + "\n")
    print("\n".join(lines))
    return 0 if ok else 1

def disasm(o):
    p = subprocess.run(["objdump", "-d", "-r", o], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, errors="replace")
    return "\n".join(l for l in p.stdout.splitlines() if "file format" not in l) if p.returncode == 0 else None

def textcmp(a):
    import hashlib
    objs = sorted(os.path.relpath(os.path.join(d, f), a.a) for d, _, fs in os.walk(a.a) for f in fs if f.endswith(".o"))
    same, diff, missing = 0, [], []
    for rel in objs:
        pb = os.path.join(a.b, rel)
        if not os.path.exists(pb): missing.append(rel); continue
        da, db = disasm(os.path.join(a.a, rel)), disasm(pb)
        if da is not None and da == db: same += 1
        else: diff.append(rel)
    print(f"textcmp {a.a} vs {a.b}: {len(objs)} objects, {same} identical, {len(diff)} different, {len(missing)} missing in B")
    for r in diff[:40]: print(f"  DIFFERENT {r}")
    for r in missing[:20]: print(f"  MISSING {r}")
    return 0 if objs and not diff and not missing else 1

ap = argparse.ArgumentParser(); sub = ap.add_subparsers(dest="cmd", required=True)
s = sub.add_parser("select"); s.add_argument("db"); s.add_argument("src"); s.add_argument("out")
r = sub.add_parser("run"); r.add_argument("units"); r.add_argument("root"); r.add_argument("jobs", type=int); r.add_argument("outdir")
r.add_argument("--extra"); r.add_argument("--timeout", type=int, default=1800); r.add_argument("--filter")
r.add_argument("--expect-unit"); r.add_argument("--expect-msg"); r.add_argument("--objdir")
t = sub.add_parser("textcmp"); t.add_argument("a"); t.add_argument("b")
a = ap.parse_args()
sys.exit({"select": select, "run": run, "textcmp": textcmp}[a.cmd](a))
