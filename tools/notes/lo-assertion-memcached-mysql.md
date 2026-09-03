# LO assertion on memcached extstore.c (tsan-dev 0de7a7350375, 2026-09-02)

    opt -disable-output -passes='print<lock-ownership>' memcached-extstore.ll
    -> LockOwnership.cpp:155: handleUnlock: Assertion `It->second.LockInstr && "LockInstr should be set"' failed.

`memcached-extstore.ll` = memcached 1.6.29 `extstore.c`, `clang -DHAVE_CONFIG_H -I. -DNDEBUG -O2 -g
-fsanitize=thread -mllvm -tsan-instrument-*=0 -S -emit-llvm` (uninstrumented IR, produced by
`nosql/memcached/gen_summaries.sh`). Any build of memcached with `-mllvm -tsan-use-lock-ownership`
on an assertions-enabled compiler aborts in this TU (`tsan-lo`, `tsan-sound`, `tsan-all`, ...).

Mechanism (from `-debug-only=lock-ownership`, function `extstore_write_request`):
1. `pthread_mutex_unlock(%ptr)` on a path where `%ptr` is not in the lock state
   -> `handleUnlock` inserts the marker entry `{false, nullptr}` for `%ptr`.
2. A later `pthread_mutex_lock(&e->stats_mutex)` has the same underlying object `%ptr`
   -> `handleLock` finds the entry, logs "Double lock", and keeps `LockInstr == nullptr`.
3. The matching `pthread_mutex_unlock(&e->stats_mutex)` -> `handleUnlock` asserts on the null `LockInstr`.
   Without assertions it would insert `{nullptr, &Instr}` into `LockUnlockPairs`.

Underlying reason for step 1/2: locks are identified by `getUnderlyingObject(arg0)`, so
`e->mutex` and `e->stats_mutex` (different mutexes in one struct) are the same "lock" `%ptr`.
See ../lo-soundness for the consequences of that identification.

## Update 2026-09-02 08:05 — still present after the LO fixes; also hits MySQL

Compiler rebuilt at 07:07 (`clang --version` = 89e5d0078d2f, tree HEAD 0de7a7350375, includes
`cb992349855e Fix two lock-ownership name defects` and `06bbe6c2e015 Stop lock ownership
concluding protection it cannot justify`): the assertion is unchanged for `memcached-extstore.ll`.

An (accidental, see below) `build_mysql.sh tsan-sound` run on the same compiler aborted with the
same assertion in 11 TUs — `mysys/thr_mutex.cc`, `mysys/thr_cond.cc`, ICU `locid.cpp`,
`loadednormalizer2impl.cpp`, `anytrans.cpp`, `brktrans.cpp`, abseil `time_zone_impl.cc`, router
`registry.cc`, `log_reopen.cc`, `process_launcher.cc`, xcom `xcom_network_provider.cc`
(`mysql-build-attempt/make.stderr.log`, 12 "Program arguments" blocks).  Smallest reproducer:

    opt -disable-output -passes='print<lock-ownership>' mysql-thr_mutex.ll

`mysql-thr_mutex.ll` = MySQL 8.0.39 `mysys/thr_mutex.cc` with the build's flags (`-O2 -g
-fsanitize=thread -O1 -fno-inline -DSAFE_MUTEX ...`, `-mllvm -tsan-instrument-*=0`, no analysis
flags), 85 KB.  So on an assertions build every `-tsan-use-lock-ownership` build of memcached
and MySQL aborts; Redis 7.0.15 and SQLite (threadtest3) compile.

## Resolved 2026-09-02 23:26 (tsan-dev b4bf8b8f4613, includes 51c96792787b + 35a2bae9aad5)

`build_mysql.sh tsan-sound` (EA+LO+STC+SWMR) on b4bf8b8f4613 completes: 43 min, exit 0, no assertion in
`make.stderr.log`, `mysql-tsan-sound/bin/mysqld` stamped b4bf8b8f4613. Static memory-access sites: stock 583854,
tsan-sound 540001 (−7.5 %). The 11 TUs that asserted (incl. `mysys/thr_mutex.cc`) compile; the memcached
`extstore.c` case was verified by tsan-dev-f on the IR. MySQL P2 (5 sysbench scripts × 180 s × 3 configs × 10 runs)
is a P5-time item.
