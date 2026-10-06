#!/bin/bash
# gen_summaries.sh — whole-program analysis summaries for mysqld (sound interface), the MySQL counterpart of the other
# applications' generators.
#
# "Whole program" = every object the linker actually puts into mysqld: mysqld's own link command (CMake's
# sql/CMakeFiles/mysqld.dir/link.txt) is re-run into a scratch file with -Wl,--trace, and the extracted archive members are
# mapped back to their objects through each archive target's `ar qc` rule. Not every member of the 127 archives: the linker
# extracts only what resolves a reference, and a member it leaves out (a stub, a test double) must not enter the module.
# Every extracted object has a compile line in the reference tree's compile database; there is no assembly, so no object is
# outside the IR. Debug info is dropped from the IR (-g0): it does not reach the analyses and triples the module.
#
# External symbols: the FULL-EXPORT fallback (26 Sep, audit A13 item 2): every symbol mysqld exports
# dynamically is treated as referenced from outside, because dynamically loaded plugins bind to mysqld's copies of C++
# inline functions and their statics. Sound without the weak-definition analysis, only less aggressive; a readout of a
# -wp arm built from these summaries must say so.
#
# The IR comes from a configured and fully built reference tree (REF_BUILD, e.g. the compile smoke's reference, which has
# the generated headers): each unit's compile line, with <root>'s clang, the TSan flags of the line, the arm's extra
# -mllvm flags and NOINSTR, emitted as bitcode.
#
# Usage:  LLVM_TSAN_ROOT=<frozen copy> REF_BUILD=<configured+built mysql tree> MYSQLD_EXPORTS=<a mysqld of the same source>
#         [SUMMARY_ID=<tag>] [NPROC=<jobs>] ./gen_summaries.sh <out_dir>
set -euo pipefail
GEN_SHA=$(sha256sum < "${BASH_SOURCE[0]}" | cut -c1-16); GEN_NAME="$(basename "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")/gen_summaries.sh"
cd "$(dirname "$0")"
source ../../tools/tsan_compiler.sh
OPT="$TSAN_OPT"; LLVM_LINK="$TSAN_LLVM_ROOT/bin/llvm-link"; LLVM_NM="$TSAN_LLVM_ROOT/bin/llvm-nm"; CXX="$TSAN_LLVM_ROOT/bin/clang++"; CC="$TSAN_LLVM_ROOT/bin/clang"
for t in "$OPT" "$LLVM_LINK" "$LLVM_NM" "$CXX" "$CC"; do [ -x "$t" ] || { echo "missing $t"; exit 1; }; done
: "${REF_BUILD:?REF_BUILD: a configured and built MySQL tree with compile_commands.json}"; : "${MYSQLD_EXPORTS:?MYSQLD_EXPORTS: a mysqld binary of the same source}"
[ -s "$REF_BUILD/compile_commands.json" ] && [ -s "$REF_BUILD/sql/CMakeFiles/mysqld.dir/link.txt" ] || { echo "error: $REF_BUILD lacks compile_commands.json or mysqld's link.txt"; exit 1; }
HEAD=$(head -1 "$TSAN_LLVM_ROOT/TSAN_AUDIT_HASH" | grep -oE "[0-9a-f]{12}" | head -1)
SUMMARY_ID="${SUMMARY_ID:-$HEAD}"
OUT="${1:?out_dir}"; [[ "$OUT" = /* ]] || OUT="$PWD/$OUT"
if [ -d "$OUT" ] && [ -n "$(ls -A "$OUT" 2>/dev/null)" ]; then echo "error: $OUT exists and is not empty; remove it or pass another dir"; exit 1; fi
EXTRA_OPT=$(echo " ${TSAN_EXTRA_MLLVM:-} " | sed -E 's/ -mllvm / /g')
NPROC=${NPROC:-8}
NOINSTR="-w -mllvm -tsan-instrument-memory-accesses=0 -mllvm -tsan-instrument-func-entry-exit=0 -mllvm -tsan-instrument-atomics=0 -mllvm -tsan-instrument-memintrinsics=0"
WORK=$PWD/mysql-summaries-work; rm -rf "$WORK"; mkdir -p "$WORK/bc"
echo "compiler: $CXX ($("$CXX" --version | head -1)); summary id $SUMMARY_ID; jobs $NPROC; reference $REF_BUILD"

# What the linker extracts: mysqld's own link line, output redirected, with --trace (a link only; the reference tree is not touched).
# A reference tree may keep its archives but not its loose objects (the compile smoke's does): a direct object missing on disk is
# recompiled from its own compile line into the work dir with the reference compiler, and the traced link uses that copy.
python3 - "$REF_BUILD" "$WORK" <<'PY2' > "$WORK/link-cmd.sh" || { echo "error: could not prepare the traced relink"; exit 1; }
import json, os, shlex, subprocess, sys
R, W = sys.argv[1:3]; S = R + "/sql"
db = {}
for e in json.load(open(R + "/compile_commands.json")):
    a = e.get("arguments") or shlex.split(e["command"]); db[os.path.normpath(os.path.join(e["directory"], a[a.index("-o") + 1]))] = (e["directory"], a)
t = open(S + "/CMakeFiles/mysqld.dir/link.txt").read().split("\n")[0]
toks = shlex.split(t); out = []; i = 0; os.makedirs(W + "/direct", exist_ok=True)
while i < len(toks):
    x = toks[i]
    if x == "-o": out += ["-o", W + "/mysqld.trace-link"]; i += 2; continue
    if x.endswith(".o") and not os.path.exists(os.path.join(S, x)):
        o = os.path.normpath(os.path.join(S, x))
        if o not in db: sys.exit(f"direct object {x} is missing and has no compile line")
        d, a = db[o]; c = W + "/direct/" + os.path.basename(x); a = list(a); a[a.index("-o") + 1] = c
        a = [y for k, y in enumerate(a) if y not in ("-MD", "-MMD") and not (k > 0 and a[k - 1] in ("-MT", "-MF", "-MQ")) and y not in ("-MT", "-MF", "-MQ")]
        subprocess.run(a, cwd=d, check=True, stdout=sys.stderr); print(f"# recompiled missing direct object {x} -> {c}", file=sys.stderr); x = c
    out.append(x); i += 1
print("cd " + shlex.quote(S) + " && " + shlex.join(out + ["-Wl,--trace,--trace"]))   # GNU ld names archive members only when --trace is given twice
PY2
bash "$WORK/link-cmd.sh" > "$WORK/link-trace.txt" 2> "$WORK/link-trace.err" \
  || { echo "error: the traced relink of mysqld failed, see $WORK/link-trace.err"; exit 1; }
rm -f "$WORK/mysqld.trace-link"
# Module membership and the per-unit bitcode commands (python: exact paths from CMake's rules and the linker's trace).
python3 - "$REF_BUILD" "$WORK" "$CXX" "$CC" "$NOINSTR ${TSAN_EXTRA_MLLVM:-}" <<'PY'
import json, os, glob, shlex, sys, hashlib, re
R, W, CXX, CC, extra = sys.argv[1:6]
db = json.load(open(R + "/compile_commands.json"))
def argv(e): return e.get("arguments") or shlex.split(e["command"])
def outp(e): a = argv(e); return os.path.normpath(os.path.join(e["directory"], a[a.index("-o") + 1]))
outs = {outp(e): e for e in db}
line = shlex.split(open(R + "/sql/CMakeFiles/mysqld.dir/link.txt").read())   # CMake quotes some paths: shlex, not split()
arch = [os.path.normpath(os.path.join(R + "/sql", a)) for a in line if a.endswith(".a")]
direct = [os.path.normpath(os.path.join(R + "/sql", a)) for a in line if a.endswith(".o")]
rules = {}
for f in glob.glob(R + "/**/CMakeFiles/*.dir/link.txt", recursive=True):
    t = shlex.split(open(f).read())
    if len(t) > 2 and t[1] == "qc":
        d = os.path.dirname(os.path.dirname(os.path.dirname(f)))
        rules[os.path.normpath(os.path.join(d, t[2]))] = [os.path.normpath(os.path.join(d, x)) for x in t[3:] if x.endswith(".o")]
miss = [a for a in arch if a not in rules]
if miss: sys.exit(f"archives without a CMake archive rule: {miss}")
# --trace --trace lines: "(<archive>)<member>" (GNU ld 2.42; older: "<archive>(<member>)") for an extracted member, "<file>" otherwise.
taken, members = {}, 0
for l in open(W + "/link-trace.txt"):
    m = re.match(r"^\((.*\.a)\)(.*)$", l.strip()) or re.match(r"^(.*\.a)\((.*)\)$", l.strip())
    if m: taken.setdefault(os.path.normpath(os.path.join(R + "/sql", m.group(1))), set()).add(m.group(2)); members += 1
if members < 1000: sys.exit(f"the link trace names only {members} archive members; is --trace output missing?")
unk = [a for a in taken if a not in rules and a in arch]
objs, amb = list(direct), 0
for a in arch:
    names = taken.get(a, set())
    pick = [o for o in rules[a] if os.path.basename(o) in names]
    amb += len(pick) - len(names)   # same basename twice in one archive: both kept (conservative: more code, never less)
    missing = names - {os.path.basename(o) for o in pick}
    if missing: sys.exit(f"{a}: extracted members with no object in its rule: {sorted(missing)[:3]}")
    objs += pick
print(f"link trace: {members} extracted members of {len(taken)} archives ({sum(len(rules[a]) for a in arch)} members in total); {amb} basename ambiguities kept both")
nodb = [o for o in objs if o not in outs]
if nodb: sys.exit(f"{len(nodb)} member objects without a compile line, e.g. {nodb[:3]}")
seen, cmds, noir = set(), [], []
for o in objs:
    if o in seen: continue
    seen.add(o); e = outs[o]; a = argv(e)
    cxx = os.path.basename(a[0]).startswith("clang++") or a[0].endswith("++")
    bc = W + "/bc/" + hashlib.sha1(o.encode()).hexdigest()[:16] + ".bc"
    r, i = [CXX if cxx else CC], 1
    while i < len(a):
        if a[i] in ("-o", "-MT", "-MF", "-MQ"): i += 2; continue
        if a[i] in ("-MD", "-MMD", "-c"): i += 1; continue
        r.append(a[i]); i += 1
    if e["file"].endswith((".S", ".s", ".asm")):   # assembly has no IR: compiled to an object, outside the module; its undefined names join the external list
        noir.append((e["directory"], r + ["-c", "-o", W + "/noir/" + os.path.basename(bc)[:-3] + ".o"], o)); continue
    cmds.append((e["directory"], r + shlex.split(extra) + ["-g0", "-c", "-emit-llvm", "-o", bc], o, bc))
os.makedirs(W + "/noir", exist_ok=True)
with open(W + "/noir.tsv", "w") as f:
    for d, c, o in noir: f.write(f"{o}\t{c[-1]}\n")
with open(W + "/units.tsv", "w") as f:
    for d, c, o, bc in cmds: f.write(f"{o}\t{bc}\n")
with open(W + "/commands.sh", "w") as f:
    for d, c, o, bc in cmds: f.write(f"cd {shlex.quote(d)} && {shlex.join(c)}\n")
    for d, c, o in noir: f.write(f"cd {shlex.quote(d)} && {shlex.join(c)}\n")
print(f"mysqld: {len(direct)} direct object(s) + {len(arch)} archives -> {len(objs)} linked objects, {len(cmds)} distinct units with IR, {len(noir)} assembly objects without IR")
PY
echo "emitting bitcode ($NPROC jobs)"
t0=$SECONDS
tr '\n' '\0' < "$WORK/commands.sh" | xargs -0 -P "$NPROC" -I{} bash -c '{}' > "$WORK/emit.log" 2>&1 || { echo "bitcode emission failed, see $WORK/emit.log"; exit 1; }
n=$(ls "$WORK/bc" | wc -l); [ "$n" = "$(wc -l < "$WORK/units.tsv")" ] || { echo "error: $n bitcode files for $(wc -l < "$WORK/units.tsv") units"; exit 1; }
while IFS=$'\t' read -r o bc; do head -c 4 "$bc" | grep -q "BC" || { echo "error: $bc ($o) is not bitcode"; exit 1; }; done < "$WORK/units.tsv"
while IFS=$'\t' read -r o ob; do [ -s "$ob" ] || { echo "error: no object for the assembly unit $o"; exit 1; }; done < "$WORK/noir.tsv"
echo "bitcode: $n units in $((SECONDS - t0)) s, $(du -sh "$WORK/bc" | cut -f1)"

# Strong duplicate definitions: the real link accepted this set, so there should be none; C++ inline functions and
# templates are weak/linkonce (nm W/V/u) and llvm-link merges those itself. A strong duplicate would mean the membership
# is wrong, and --override would choose a body by position, not the one the linker chose: stop instead.
cut -f2 "$WORK/units.tsv" | tr '\n' '\0' | xargs -0 -P "$NPROC" -n 64 "$LLVM_NM" --defined-only --extern-only 2>/dev/null \
  | awk 'NF >= 2 && $(NF-1) ~ /^[TDBR]$/ {print $NF}' | LC_ALL=C sort | uniq -d > "$WORK/strong-dups.txt"
[ ! -s "$WORK/strong-dups.txt" ] || { echo "error: $(wc -l < "$WORK/strong-dups.txt") strong symbols defined twice, e.g. $(head -3 "$WORK/strong-dups.txt" | tr '\n' ' '); see $WORK/strong-dups.txt"; exit 1; }
primary=(); override=()
while IFS=$'\t' read -r o bc; do primary+=("$bc"); done < "$WORK/units.tsv"
echo "linking ${#primary[@]} modules (no strong duplicates)"
/usr/bin/time -f "llvm-link: %e s, %M KB" "$LLVM_LINK" -o "$WORK/mysqld-whole.bc" "${primary[@]}" "${override[@]}" 2> "$WORK/link.log" || { cat "$WORK/link.log"; exit 1; }
tail -1 "$WORK/link.log"

mkdir -p "$OUT"
# Full-export list: every dynamic symbol mysqld defines (the plugins' view), header first, C order (the list's bytes are digested).
syms=$("$LLVM_NM" -D --defined-only --format=just-symbols "$MYSQLD_EXPORTS") || { echo "error: llvm-nm -D failed on $MYSQLD_EXPORTS"; exit 1; }
# plus what the objects without IR (assembly) reference: code outside the module that calls into it (as the FFmpeg generator's nasm objects)
if [ -s "$WORK/noir.tsv" ]; then
  noirsyms=$(cut -f2 "$WORK/noir.tsv" | xargs "$LLVM_NM" --undefined-only --format=just-symbols) || { echo "error: llvm-nm failed on the objects without IR"; exit 1; }
  syms=$(printf '%s\n%s\n' "$syms" "$noirsyms")
fi
{ echo "# tsan-external-symbols v1"; printf '%s\n' "$syms" | grep -v -E '^$' | LC_ALL=C sort -u || true; } > "$OUT/external-symbols.txt"
[ "$(wc -l < "$OUT/external-symbols.txt")" -gt 1000 ] || { echo "error: implausibly short full-export list from $MYSQLD_EXPORTS"; exit 1; }
echo "external list (full export): $(( $(wc -l < "$OUT/external-symbols.txt") - 1 )) names from $MYSQLD_EXPORTS"
OPT_ARGS=(-tsan-use-analysis-summaries -tsan-whole-program -tsan-summary-dir="$OUT" -tsan-summary-id="$SUMMARY_ID" -tsan-external-symbols="$OUT/external-symbols.txt" $EXTRA_OPT)
MODE=${GEN_PASS_MODE:-require}
cd "$WORK"
for pass in single-threaded lock-ownership escape-analysis-global; do
  /usr/bin/time -f "$pass: %e s, %M KB" "$OPT" -disable-output -passes="$MODE<$pass>" "${OPT_ARGS[@]}" mysqld-whole.bc > "$pass.$MODE.txt" 2>&1 \
    || { echo "opt $MODE<$pass> failed, see $WORK/$pass.$MODE.txt"; exit 1; }
  tail -1 "$pass.$MODE.txt"
done
for f in st lo ea; do [ -s "$OUT/${f}_summary.txt" ] || echo "warning: $OUT/${f}_summary.txt missing or empty"; done
cp "$WORK"/*."$MODE".txt "$WORK/units.tsv" "$OUT"/
{
  echo "date: $(date -Iseconds)"
  echo "generator: $GEN_NAME sha256 $GEN_SHA"
  echo "compiler: $CXX ($("$CXX" --version | head -1))"
  echo "summary_id: $SUMMARY_ID"
  echo "reference tree: $REF_BUILD (compile lines and CMake link rules)"
  echo "whole program: mysqld = $(wc -l < "$WORK/units.tsv") units ($(( ${#override[@]} / 2 )) linked with --override)"
  echo "opt: -passes=$MODE<single-threaded|lock-ownership|escape-analysis-global> ${OPT_ARGS[*]} (the arguments actually passed)"
  echo "external list: FULL EXPORT of $MYSQLD_EXPORTS + the undefined names of $(wc -l < "$WORK/noir.tsv") assembly objects without IR ($(( $(wc -l < "$OUT/external-symbols.txt") - 1 )) names) - sound, less aggressive than a weak-definition list"
  echo "sizes: $(wc -l "$OUT"/*_summary.txt | tr '\n' ';')"
} > "$OUT/PROVENANCE.txt"
cat "$OUT/PROVENANCE.txt"
