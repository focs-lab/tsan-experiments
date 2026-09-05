# files_with_fixed_timeout

Copies of the three Chromium files whose timeouts must be raised before a TSan build can finish a Telemetry
suite: an instrumented Chromium is 5-20x slower than a stock one and the stock timeouts abort the run.

They are the *patched* versions, taken from the live checkout `/extra/alexey/chromium/chromium/src`, and are
kept here so a fresh checkout can be brought to the same state (copy over `src/`).

| file | stock | here |
|---|---|---|
| `tools/perf/page_sets/speedometer3_pages.py` (`testDone` wait) | 60 000 ms | 600 000 ms |
| `.../chrome_inspector/inspector_backend.py` (`__init__`, shared-storage notifications) | 12 000 / 6 000 ms | 120 000 / 60 000 ms |
| `content/browser/devtools/protocol/system_info_handler.cc` (GPU-info watchdog) | 100 000 | 2 000 000 |
| `.../telemetry/internal/browser/browser_options.py` (`_browser_startup_timeout`, no CLI flag) | 60 s | 600 s |

Refreshed on 2026-09-04 from the checkout the P5 Chromium builds are made from: the copies here had drifted
(they still held the stock values), so they no longer described what was actually built and benchmarked.
The `.cc` change is compiled into every `out/chrome-<cfg>` build; the two Python files act at run time.
