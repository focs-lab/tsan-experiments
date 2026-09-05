# Escape analysis does not terminate on mysql/sql_yacc.cc (tsan-dev 729521af8965)

**Where:** MySQL 8.0.39, generated bison parser `sql/sql_yacc.cc` (~60k lines, one enormous
`MYSQLparse` function), Debug build flags of `sql/mysql/build_mysql.sh`
(`-fsanitize=thread -g -O2 … -O1 -fno-inline -fPIC`), compiler
`/extra/alexey/builds/tsan-dev-729521af8965`.

**Symptom:** the `tsan-sound` build (EA+LO+STC+SWMR) reached 94 % and then sat on this one
translation unit for 3 h 02 min at 100 % CPU and 3.5 GB peak RSS (14:12:58 - 17:15:03). It *does* terminate:
the analysis is superlinear on this function, not looping. The same
configuration built end to end in ~43 minutes on `b4bf8b8f4613` (2026-09-02); `orig` and `tsan`
on 729521af8965 build in 6.7 and 6.5 minutes.

**Bisect** (same command line taken from `/proc/<pid>/cmdline`, one `-mllvm` flag at a time,
CPUs 52-55,108-111, 2026-09-04):

| flags | wall time |
|---|---|
| none of the four | 55 s |
| `-tsan-use-lock-ownership` | 55 s |
| `-tsan-use-single-threaded` | 60 s |
| `-tsan-use-swmr` | 56 s |
| `-tsan-use-escape-analysis-global` | **3 h 02 min** |

The three cheap analyses produce byte-identical object sizes (5 435 864) — they change nothing on
this TU; the EA object is 5 433 816 bytes. The shape to suspect is one enormous function: `MYSQLparse` is a
bison-generated parser of ~60k lines, and the other ~3 500 translation units of the same build compile normally
under the same flag. Escape analysis alone reproduces the blow-up, so it is not STC-3 (bodiless callees) from
this hash's commits; the regression is in EA and may predate 729521af8965 (MySQL was last built
with EA on b4bf8b8f4613).

**Consequence for P5:** every Stage A configuration of MySQL except `orig` and `tsan` contains EA,
so MySQL has no optimised binaries on this hash. Stage A ran the other four applications; the MySQL
adapter was exercised with `orig`/`tsan` only. Reported to the tsan-dev lane on 2026-09-04 with the
exact command line; the stuck compile was left running for their gdb sampling.


## Aftermath (same day)

Stopping the frozen make tree destroyed the finished object: the compiler had exited but `make` had not reaped
it, so `make` treated the recipe as interrupted and deleted `sql_yacc.cc.o`. Resume a stopped build (`kill
-CONT`) and let it reap before stopping it, or the last target is lost.

`build_mysql.sh` now takes `RESUME_BUILD=1`, which keeps an existing scratch tree when its CMake cache records
the same compiler and flags (the cache spells the key `CMAKE_CXX_COMPILER:STRING=` when the compiler is passed
on the command line, not `:FILEPATH=`). With it an interrupted MySQL build continues instead of paying the
three hours again.

## Second reproducer (2026-09-05): Chromium `vk_safe_struct_utils.cpp`

The Chromium `tsan-sound` build (EA+LO+STC+SWMR, 729521af8965) serialised behind one translation unit:
`third_party/vulkan-utility-libraries/src/src/vulkan/vk_safe_struct_utils.cpp`, 3 667 lines, generated (one
giant switch over Vulkan struct types). Same command without EA: **1 s**; with EA alone: minutes to tens of
minutes (the real build's compile passed 33 min at 100 % CPU, 0.2 GB RSS — pure time, not memory). A far
smaller test case than `sql_yacc.cc` for the fixpoint fix; sent to the tsan-dev lane.
