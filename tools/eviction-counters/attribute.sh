#!/bin/bash
# Attribute uncovered evictions to the wal-index granules named in the run's own race reports.
# Usage: ./attribute.sh <trace.err> -> <trace.err>.attrib.txt
set -uo pipefail
TR=${1:?}; OUT=$TR.attrib.txt
# addresses of the reported wal-index words (the report's access address), from "Location is global '??' at 0x... (test.db-shm+0x..)"
grep -a "Location is global '??' at 0x" "$TR" | grep -a "test.db-shm" | grep -aoE "at 0x[0-9a-f]+ \(test.db-shm\+0x[0-9a-f]+\)" | sort | uniq -c > $OUT.reported
python3 - "$OUT.reported" > $OUT.granules <<'PY'
import sys,re
seen=set()
for l in open(sys.argv[1]):
    m=re.search(r"at (0x[0-9a-f]+) \(test.db-shm\+(0x[0-9a-f]+)\)",l)
    if m:
        # TSan prints the mapping base in "at 0x..." and the offset in "(file+0x..)": granule = (base+off) & ~7
        g=(int(m.group(1),16)+int(m.group(2),16))&~7; seen.add((g,m.group(2)))
# always include the whole WalCkptInfo header words 0x60..0x78 of the same mapping (nBackfill, aReadMark[0..4])
bases={g-int(off,16) for g,off in seen}
for b in bases:
    for off in (0x60,0x68,0x70):
        seen.add((b+off, hex(off)))
for g,off in sorted(seen): print(f"0x{g:x} {off}")
PY
cut -d' ' -f1 $OUT.granules > $OUT.pat
echo "reported wal-index granules: $(wc -l < $OUT.pat)" > $OUT
echo "total uncovered eviction lines: $(grep -ac 'evicted concurrent' "$TR")" >> $OUT
grep -aF -f $OUT.pat "$TR" | grep -a "evicted concurrent" | sed -E 's/.*evicted concurrent (plain|atomic) (read|write) at (0x[0-9a-f]+).*/\3 \1 \2/' | sort | uniq -c | sort -k2 >> $OUT
echo "ATTRIB DONE" >> $OUT; cat $OUT
