#!/usr/bin/env python3
"""
count_tsan_instrumentation.py - Count __tsan_* instrumentation calls in a binary.

Usage:
    python3 count_tsan_instrumentation.py <binary> [--nm NM_PATH] [--objdump OBJDUMP_PATH]
    python3 count_tsan_instrumentation.py <binary> --verbose
    python3 count_tsan_instrumentation.py <binary> --summary

This script uses `nm` to list symbols and `objdump` (or `llvm-objdump`) to
disassemble the binary, then counts call-site references to each __tsan_* function.
"""

import argparse
import re
import subprocess
import sys
from collections import defaultdict


# ── Categories of TSan instrumentation functions ────────────────────────────

TSAN_CATEGORIES = {
    "memory_read":       re.compile(r"^__tsan_read\d+$"),
    "memory_write":      re.compile(r"^__tsan_write\d+$"),
    "unaligned_read":    re.compile(r"^__tsan_unaligned_read\d+$"),
    "unaligned_write":   re.compile(r"^__tsan_unaligned_write\d+$"),
    "volatile_read":     re.compile(r"^__tsan_volatile_read\d+$"),
    "volatile_write":    re.compile(r"^__tsan_volatile_write\d+$"),
    "unaligned_volatile_read":  re.compile(r"^__tsan_unaligned_volatile_read\d+$"),
    "unaligned_volatile_write": re.compile(r"^__tsan_unaligned_volatile_write\d+$"),
    "compound_rw":       re.compile(r"^__tsan_read_write\d+$"),
    "unaligned_compound_rw": re.compile(r"^__tsan_unaligned_read_write\d+$"),
    "atomic_load":       re.compile(r"^__tsan_atomic\d+_load$"),
    "atomic_store":      re.compile(r"^__tsan_atomic\d+_store$"),
    "atomic_rmw":        re.compile(r"^__tsan_atomic\d+_(exchange|fetch_add|fetch_sub|fetch_and|fetch_or|fetch_xor|fetch_nand|compare_exchange_weak|compare_exchange_strong)$"),
    "atomic_thread_fence": re.compile(r"^__tsan_atomic_thread_fence$"),
    "atomic_signal_fence": re.compile(r"^__tsan_atomic_signal_fence$"),
    "func_entry_exit":   re.compile(r"^__tsan_func_(entry|exit)$"),
    "ignore":            re.compile(r"^__tsan_ignore_thread_(begin|end)$"),
    "vptr":              re.compile(r"^__tsan_vptr_(read|update)$"),
    "memintrinsic":      re.compile(r"^__tsan_(memset|memcpy|memmove)$"),
    "other":             re.compile(r"^__tsan_"),   # catch-all
}


def classify(name: str) -> str:
    """Return the category name for a __tsan_* symbol."""
    for cat, pattern in TSAN_CATEGORIES.items():
        if cat == "other":
            continue
        if pattern.match(name):
            return cat
    if name.startswith("__tsan_"):
        return "other"
    return ""


# ── Helpers ──────────────────────────────────────────────────────────────────

def run(cmd: list[str]) -> str:
    try:
        result = subprocess.run(
            cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True
        )
        if result.returncode != 0 and not result.stdout:
            print(f"Warning: {cmd[0]} exited {result.returncode}: {result.stderr.strip()}",
                  file=sys.stderr)
        return result.stdout
    except FileNotFoundError:
        print(f"Error: '{cmd[0]}' not found. Install binutils or llvm-binutils.", file=sys.stderr)
        sys.exit(1)


def find_tsan_symbols_nm(binary: str, nm: str) -> dict[str, int]:
    """
    Use `nm -D` (dynamic symbols) + `nm` (all symbols) to find __tsan_* symbols
    and their addresses.  Returns {name: address}.
    """
    symbols: dict[str, int] = {}
    for flag in ["-D", ""]:
        args = [nm] + ([flag] if flag else []) + ["--defined-only", binary]
        output = run(args)
        for line in output.splitlines():
            # nm output: [address] type name
            parts = line.split()
            if len(parts) < 3:
                continue
            name = parts[-1]
            if name.startswith("__tsan_"):
                try:
                    addr = int(parts[0], 16)
                    symbols[name] = addr
                except ValueError:
                    pass
    return symbols


def count_calls_objdump(binary: str, tsan_names: set[str], objdump: str) -> dict[str, int]:
    """
    Disassemble the binary with `objdump -d` and count direct calls to __tsan_* symbols.
    Works for both PLT stubs (call __tsan_read1@plt) and statically linked symbols.
    """
    counts: dict[str, int] = defaultdict(int)

    # Pattern: call/bl/blx/jal/... followed by symbol name possibly with @plt suffix
    call_re = re.compile(
        r"\b(?:call|callq|bl|blx|jal|jalr)\b.*?<(__tsan_\w+?)(?:@plt|@GLIBC[^>]*)?>",
        re.IGNORECASE,
    )
    # Also match: e8 xx xx xx xx  # __tsan_read1  (inline comment style in some objdumps)
    comment_re = re.compile(r"#\s*<(__tsan_\w+?)(?:@plt|@GLIBC[^>]*)?>")

    output = run([objdump, "-d", "--no-show-raw-insn", binary])

    for line in output.splitlines():
        for m in call_re.finditer(line):
            name = m.group(1)
            if name in tsan_names or name.startswith("__tsan_"):
                counts[name] += 1
        for m in comment_re.finditer(line):
            name = m.group(1)
            if name in tsan_names or name.startswith("__tsan_"):
                counts[name] += 1

    return counts


def count_calls_relocs(binary: str, objdump: str) -> dict[str, int]:
    """
    Count __tsan_* symbols that appear in relocation tables (useful when the
    binary hasn't been linked yet, e.g. .o / .bc files processed by objdump).
    """
    counts: dict[str, int] = defaultdict(int)
    output = run([objdump, "-r", "-R", binary])
    rel_re = re.compile(r"(__tsan_\w+)")
    for line in output.splitlines():
        for m in rel_re.finditer(line):
            counts[m.group(1)] += 1
    return counts


# ── Main ─────────────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Count __tsan_* instrumentation call sites in a binary.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("binary", help="Path to the binary / object file to analyse")
    parser.add_argument("--nm", default="nm", metavar="NM",
                        help="Path to nm (default: nm)")
    parser.add_argument("--objdump", default="objdump", metavar="OBJDUMP",
                        help="Path to objdump (default: objdump)")
    parser.add_argument("--verbose", "-v", action="store_true",
                        help="Print per-symbol counts in addition to categories")
    parser.add_argument("--summary", "-s", action="store_true",
                        help="Print only the grand total")
    parser.add_argument("--use-relocs", action="store_true",
                        help="Use relocation tables instead of disassembly "
                             "(useful for .o files)")
    args = parser.parse_args()

    # 1. Gather known __tsan_* symbols from the binary itself
    print(f"[*] Scanning symbols in: {args.binary}", file=sys.stderr)
    tsan_symbols = find_tsan_symbols_nm(args.binary, args.nm)
    if not tsan_symbols:
        # May be a PIE/stripped binary – proceed anyway, the disassembly search
        # will still find @plt entries.
        print("[!] No __tsan_* symbols found via nm (stripped? PIE?). "
              "Proceeding with disassembly scan.", file=sys.stderr)

    tsan_names = set(tsan_symbols.keys())

    # 2. Count call sites
    if args.use_relocs:
        print("[*] Counting via relocation tables …", file=sys.stderr)
        counts: dict[str, int] = count_calls_relocs(args.binary, args.objdump)
    else:
        print("[*] Disassembling and counting call sites …", file=sys.stderr)
        counts = count_calls_objdump(args.binary, tsan_names, args.objdump)

    if not counts:
        print("[!] No __tsan_* call sites found.  "
              "Is the binary compiled with -fsanitize=thread?", file=sys.stderr)
        sys.exit(0)

    # 3. Aggregate by category
    category_totals: dict[str, int] = defaultdict(int)
    for name, cnt in counts.items():
        cat = classify(name)
        category_totals[cat] += cnt

    grand_total = sum(counts.values())

    if args.summary:
        print(grand_total)
        return

    # ── Pretty print ────────────────────────────────────────────────────────
    print()
    col_w = 42

    if args.verbose:
        print("  Per-symbol call counts:")
        print("  " + "-" * (col_w + 12))
        for name in sorted(counts):
            print(f"  {name:<{col_w}} {counts[name]:>8}")
        print()

    print("  Category totals:")
    print("  " + "-" * (col_w + 12))
    for cat in sorted(category_totals):
        print(f"  {cat:<{col_w}} {category_totals[cat]:>8}")
    print("  " + "-" * (col_w + 12))

    # Break down memory accesses vs everything else
    mem_total = (
        category_totals.get("memory_read", 0)
        + category_totals.get("memory_write", 0)
        + category_totals.get("unaligned_read", 0)
        + category_totals.get("unaligned_write", 0)
        + category_totals.get("volatile_read", 0)
        + category_totals.get("volatile_write", 0)
        + category_totals.get("unaligned_volatile_read", 0)
        + category_totals.get("unaligned_volatile_write", 0)
        + category_totals.get("compound_rw", 0)
        + category_totals.get("unaligned_compound_rw", 0)
    )
    atomic_total = (
        category_totals.get("atomic_load", 0)
        + category_totals.get("atomic_store", 0)
        + category_totals.get("atomic_rmw", 0)
        + category_totals.get("atomic_thread_fence", 0)
        + category_totals.get("atomic_signal_fence", 0)
    )

    print(f"  {'Memory accesses (read/write)':<{col_w}} {mem_total:>8}")
    print(f"  {'Atomic operations':<{col_w}} {atomic_total:>8}")
    print(f"  {'Function entry/exit':<{col_w}} {category_totals.get('func_entry_exit', 0):>8}")
    print(f"  {'Other __tsan_*':<{col_w}} {grand_total - mem_total - atomic_total - category_totals.get('func_entry_exit', 0):>8}")
    print("  " + "=" * (col_w + 12))
    print(f"  {'GRAND TOTAL':<{col_w}} {grand_total:>8}")
    print()


if __name__ == "__main__":
    main()

