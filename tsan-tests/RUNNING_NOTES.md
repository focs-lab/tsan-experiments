# TSan test run notes

## Quick run commands

From `tsan-tests/`:

```bash
cd /home/alexey/tsan-experiments/tsan-tests
./run-tsan-tests.sh
```

That runs the branches listed in `RUN_TESTS` near the top of `run-tsan-tests.sh`.

Run a specific subset explicitly:

```bash
cd /home/alexey/tsan-experiments/tsan-tests
./run-tsan-tests.sh main tsan-escape-analysis-integration
```

Run all four explicitly:

```bash
cd /home/alexey/tsan-experiments/tsan-tests
./run-tsan-tests.sh main tsan-escape-analysis tsan-escape-analysis-integration tsan-dominance-based
```

## Current defaults in `run-tsan-tests.sh`

- `--check-all` is enabled by default
- `--skip-git` is enabled by default
- if no CLI args are given, tests are taken from `RUN_TESTS=(...)`

If you want to run against a clean checkout / worktree and use remote-tracking branches:

```bash
cd /home/alexey/tsan-experiments/tsan-tests
LLVM_TSAN_SOURCE=/path/to/clean/llvm-project-tsan ./run-tsan-tests.sh --git
```

## Result interpretation memo

As of 2026-05-19, these failures are considered ignorable for the current TSan work:

- `Clang :: Driver/sanitizer-ld.c`
  - caused by the path containing the word `tsan`
- `XRay-x86_64-linux :: TestCases/Posix/basic-filtering.cpp`
  - currently treated as unrelated to this TSan work

So when looking at `check-all`, these two failures should not be used as a regression signal for the TSan branches.

## Dominance branch note

For `tsan-dominance-based`, the branch-specific lit test is:

- `llvm/test/Instrumentation/ThreadSanitizer/dominance-elimination.ll`

The branch-specific check target should be:

- `check-tsan`

not `check-tsan-dominance-analysis`.

This was verified directly in the branch source:

- `llvm/lib/Transforms/Instrumentation/ThreadSanitizer.cpp` contains
  `ClUseDominanceAnalysis("tsan-use-dominance-analysis", cl::init(true), ...)`
- `dominance-elimination.ll` also uses the default run as the optimized case and
  only disables the optimization with
  `-tsan-use-dominance-analysis=false`

So dominance analysis is enabled by default on that branch.

## OCaml failure memo

Observed failing test:

- `LLVM :: Bindings/OCaml/executionengine.ml`

### What was happening

Initially, the failure was:

- `ocamlfind: Package 'ctypes-foreign' not found - required by 'ctypes.foreign'`

This means the missing dependency is the opam package:

- `ctypes-foreign`

### How to fix it

Install the missing package:

```bash
opam install -y ctypes-foreign
```

After installing it, the already-built LLVM OCaml bindings may still be stale / ABI-incompatible with the newly installed `ctypes` package. In practice this then turns into an interface mismatch like:

- `make inconsistent assumptions over interface Ctypes`

So after installing `ctypes-foreign`, do a clean rebuild.

For this script, a fresh rerun is enough because the script already does:

- `rm -rf "$LLVM_BUILD"`

before each branch.

So the practical fix is:

```bash
opam install -y ctypes-foreign
cd /home/alexey/tsan-experiments/tsan-tests
./run-tsan-tests.sh
```

or for a specific rerun:

```bash
opam install -y ctypes-foreign
cd /home/alexey/tsan-experiments/tsan-tests
./run-tsan-tests.sh main tsan-escape-analysis-integration
```

If you want to validate only the OCaml test manually after a rebuild, use `llvm-lit` from the rebuilt tree on:

- `test/Bindings/OCaml/executionengine.ml`

## Polling note

Previous long runs were polled by checking whether the log and exit files changed over time. That was only to monitor long LLVM builds without reading direct terminal output. The run did complete and was not stuck in an infinite loop.

