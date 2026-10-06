#!/usr/bin/env python3
"""check_sqlite_subtests.py <cell dir> <subtest>... : exit 1 unless every listed threadtest3 subtest yields a metric > 0 in the
cell's threadtest3.log. Same kind of gate as the 60 s check: until 3 Oct 2026 the parser dropped create_drop_index_1 silently
(no metric -> removed), so the record set's composite was stress2 alone and no cell said so. A pre-registered subtest that
yields nothing is a different test set, not a smaller sample."""
import sys, os, importlib.util
here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("sqlite_parse_results", os.path.join(here, "..", "..", "sql", "sqlite", "parse_results.py"))
P = importlib.util.module_from_spec(spec); spec.loader.exec_module(P)
d, tests = sys.argv[1], sys.argv[2:]
got = dict(P.parse_log_file(os.path.join(d, "threadtest3.log")))
missing = [t for t in tests if not got.get(t)]
if missing:
    print(f"pre-registered subtest(s) with no metric: {' '.join(missing)}; got {' '.join(f'{k}={v:.0f}' for k, v in sorted(got.items()))}")
    sys.exit(1)
print("all subtests have a metric: " + " ".join(f"{k}={got[k]:.0f}" for k in tests))
