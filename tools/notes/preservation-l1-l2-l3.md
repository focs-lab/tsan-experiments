# Preservation at three key levels (L1 / L2 / L3), all rounds — revision material

Keys (`tools/preservation/tsan_reports.py`): **L1** identical = kind + both access sites `function@file:line` +
location descriptor; **L2** equivalent = sites by function only; **L3** location = kind + location descriptor +
the *writer* side's `function@file:line`, reader sites collapsed (on a one-writer/many-readers granule, which reader
record survives the four shadow slots is eviction arithmetic; L3 asks "is the race on this location still found?").
Caveat: L3 would *not* have caught the SWMR defect of b4bf8b8f4613 (three `current_time` reader sites elided, the
race still reported through the remaining reader) — L1/L2 remain the evidence for elision, L3 for race-level recall.

"lost" = in the stock union of the round and in 0 runs of the configuration; N = 10 unless stated.

| round (hash) | app | config | union L1/L2/L3 (stock) | lost L1 | lost L2 | lost L3 | note |
|---|---|---|---|---|---|---|---|
| b4bf8b8f4613 | SQLite | sound | 5/2/3 | 0 | 0 | 0 | |
| b4bf8b8f4613 | SQLite | AllOpt+peel | 5/2/3 | 0 | 0 | 0 | 1 new L1/L3 (same family, 1/10) |
| b4bf8b8f4613 | memcached | sound | 16/16/11 | 4 | 4 | 0 | SWMR defect: 3 reader sites elided, race still found via `conn_new:761` |
| b4bf8b8f4613 | memcached | AllOpt+peel | 16/16/11 | 4 | 4 | 0 | same |
| def2cf34faeb | SQLite | sound | 6/3/4 | 1 | 1 | 1 | new 1/10 stock site (`sqlite3BtreeSchema`), instrumented everywhere |
| def2cf34faeb | SQLite | AllOpt+peel | 6/3/4 | 1 | 1 | 1 | same site |
| def2cf34faeb | memcached | sound (N=10 vs stock N=10) | 17/17/11 | 0 | 0 | 0 | SWMR fixed: stock set exactly |
| def2cf34faeb | memcached | AllOpt+peel (N=30 vs stock N=30) | 34/21/27 | 1 (relocated) | 0 | 1 | the L3 loss is a 1/30 `conn_new` write/write self-pair |
| 297881ddc1c5 | SQLite | sound | 5/2/3 | 0 | 0 | 0 | both baselines |
| 297881ddc1c5 | SQLite | AllOpt+peel | 5/2/3 | 0 | 0 | 0 | both baselines |
| 297881ddc1c5 | memcached | sound | 35/20/27 | 2 (relocated) | 0 | 1 | L3 loss = 1/10 `conn_new` self-pair |
| 297881ddc1c5 | memcached | AllOpt+peel | 35/20/27 | 7 (5 relocated) | 2 | 4 | L2 losses are `current_time` reader sites (`conn_new:761`, `lru_pull_tail:1207`); the race is reported at other reader sites 10/10 → preserved at L3; the 4 L3 losses are 1/10 `conn_new` self-pairs |
| ad0623610ef6 | SQLite | sound | 5/2/3 | 0 | 0 | 0 | baseline = 297881ddc1c5 stock |
| ad0623610ef6 | SQLite | AllOpt+peel | 5/2/3 | 0 | 0 | 0 | |
| ad0623610ef6 | memcached | sound | 35/20/27 | 18 (1 reloc.) | 3 | 16 | all `conn_new` burst family (1/10 in stock) + `lru_pull_tail:1207` (2/10); `current_time` race preserved at L3 |
| ad0623610ef6 | memcached | AllOpt+peel | 35/20/27 | 25 | 10 | 23 | burst family + `conn_new:761` (10/10 → 0/10, as on 297881ddc1c5); no non-`conn_new` location lost at L3 |
| 43111f84d936 + summaries | memcached | sound + WP summaries | 35/20/27 | 25 | 10 | 23 | burst family + `lru_pull_tail:1207`; all ten frequent sites 10/10; no non-`conn_new` L3 loss |
| 43111f84d936 + summaries | memcached | AllOpt+peel + WP summaries | 35/20/27 | 18 (1 reloc.) | 3 | 16 | burst family; `conn_new:761` 0/10; no non-`conn_new` L3 loss |

`current_time` under AllOpt+peel on 297881ddc1c5, checked in the binaries: clock_handler's store instrumented in all
three builds (2 × `__tsan_write4`); instrumented accesses to `&current_time`: stock 71, sound 70, AllOpt+peel 74
(peeling duplicates a read) — nothing elided; `conn_new:761` keeps its `__tsan_read4`. The 10/10 → 0/10 shift of that
reader pair is therefore detection moving to other reader sites on the same granule (L3 preserved).
