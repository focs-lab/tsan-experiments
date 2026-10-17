# ThreadSanitizer experiments

Build scripts, workloads, and result-processing tools for evaluating ThreadSanitizer
(TSan) and analysis-based instrumentation optimizations. The experiments measure
runtime, memory use, compilation time, and instrumentation counts across several
applications.

The compiler implementation is maintained in
[focs-lab/llvm-project](https://github.com/focs-lab/llvm-project).
This repository contains the experiment harness and application-specific setup.

Related research: [Instrumentation Optimization for Practical Dynamic Race Detection](https://focs-lab.comp.nus.edu.sg/publication/2026/2026-atc-paznikov-instrumentation-optimization/),
to appear at ATC 2026.

## Start here

1. Choose the workload and compiler revision for the experiment you want to
   reproduce. These scripts evolve alongside the compiler; record both commits.
2. Build the patched LLVM/Clang toolchain with the required TSan optimization
   flags. A stock Clang build does not provide these flags.
3. Set the compiler build directory explicitly:

   ```sh
   export LLVM_TSAN_ROOT=/absolute/path/to/patched/llvm/build
   source tools/tsan_compiler.sh
   ```

   Run this from the repository root. The helper checks the toolchain and exports
   `TSAN_CC`, `TSAN_CXX`, and `TSAN_OPT`.
4. Follow the workload's preparation, build, run, and analysis scripts below.
   Check their path settings and prerequisites before launching a full campaign.
   Many scripts expect to run from their own workload directory.

## Find an experiment

| Workload | Entry points |
| --- | --- |
| SQLite | [Prepare sources](sql/sqlite/download_and_compile_sqlite.sh), [build one configuration](sql/sqlite/build_sqlite_test.sh), [run it](sql/sqlite/run_sqlite_test.sh), [analyse results](sql/sqlite/analyze_sqlite_results.py) |
| MySQL | [Build](sql/mysql/build_mysql.sh), [benchmark launcher guide](sql/mysql/benchmysql/benchmarks-launch.md) |
| Redis | [Build scripts](nosql/redis), [benchmark scripts](nosql/redis/bench) |
| Memcached | [Build](nosql/memcached/build_memcached.sh), [benchmark](nosql/memcached/run-bench.sh) |
| ClickHouse | [Build and benchmark scripts](nosql/clickhouse) |
| FFmpeg | [Build](projects/ffmpeg/build_ffmpeg.sh), [benchmark configurations](projects/ffmpeg/bench_ffmpeg_all.sh), [input provenance](projects/ffmpeg/input/PROVENANCE.md) |
| Chromium | [Build configurations](chromium/build_configs.sh), [run benchmarks](chromium/run_all_chrome_bench.sh) |

[Shared tools](tools) provide compiler selection, build metadata, trace processing,
and result analysis. [TSan tests](tsan-tests) and [unit tests](unittests) provide
additional checks.

## Configurations and reproducibility

[config_definitions.sh](config_definitions.sh) maps configuration names to compiler
flags. Some workloads also have their own configuration files.

- `orig`: baseline without TSan instrumentation.
- `tsan`: baseline TSan instrumentation.
- `tsan-*`: individual optimizations or experimental combinations. Read the
  corresponding flags and comments before comparing results.

Keep the compiler and harness revisions, compiler flags, workload version, inputs,
thread count, and machine configuration with each result. Preserve build metadata
and raw logs so that measurements can be traced back to the exact experiment.

For setup questions or missing reproduction details, please
[open an issue](https://github.com/focs-lab/tsan-experiments/issues).
