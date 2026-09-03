# Lock-ownership soundness probes (tsan-dev, 2026-09-02)

`./lo_probes_run.sh` (originally `run.sh`) builds each probe with plain TSan and with `-mllvm -tsan-use-lock-ownership`, counts the
`__tsan_read/write` calls left in the `touch*()` functions, and runs the binary to see whether TSan
reports the race on the global `G`.

Result on the hardened compiler (first run: tsan-dev 5d6c824caab7; identical on the rebuilt
compiler 89e5d0078d2f / HEAD 0de7a7350375, binary mtime 2026-09-02 07:07, i.e. *after* the LO
commits cb992349855e "LO name defects" and 06bbe6c2e015 "protection it cannot justify" — see
`run-0de7a7350375.txt`):

| probe                       | pattern                                                        | stock: instr / reports | LO: instr / reports |
|-----------------------------|----------------------------------------------------------------|------------------------|---------------------|
| lo_control                  | one global mutex protects G                                    | 1 / 0                  | 0 / 0  (correct)    |
| lo_distinct_instances       | lock is `e->m`, two threads use two different `e`              | 1 / 1                  | 0 / 0  **race lost**|
| lo_striped_array            | `pthread_mutex_t locks[2]`, threads use different stripes      | 1 / 1                  | 0 / 0  **race lost**|
| lo_two_mutexes_one_struct   | `struct {mutex a, b} S`, one thread under S.a, other under S.b | 2 / 1                  | 0 / 0  **race lost**|

Cause: `LockOwnership.cpp` identifies a lock by `getUnderlyingObject(lock-pointer)` and compares these
values across accesses (`findProtectedGlobalVariables`: intersection of lock sets). Every mutex
reachable from one base object collapses to that object, and a non-global base object (function
argument, loaded pointer) is accepted as a lock identity although it denotes a different mutex in
every call. memcached has the striped pattern (`lru_locks[POWER_LARGEST]` in items.c, `item_locks`
in thread.c) and the struct pattern (`extstore` engine `e->mutex` / `e->stats_mutex`).

A sound identification must (a) treat only a lock pointer that is a global mutex object or a
*constant* GEP into a global (fixed field/index) as a known lock, compared by exact pointer value,
and (b) treat every other lock pointer (argument, load, variable-index GEP) as unknown, i.e. as
protecting nothing.

## After the fix (tsan-dev 51c96792787b "Identify a lock by the mutex, not the object it lives in"; shared clang built 2026-09-02 20:27, VCS stamp e5080b0ab463 is stale)

`./lo_probes_run.sh` (recreated here; probes `lo_*.c` in this directory), `lo-probes-after-51c96792787b.txt`:

| probe                       | stock: instr / reports (5 runs) | LO: instr / reports (5 runs) |
|-----------------------------|---------------------------------|------------------------------|
| lo_control                  | 1 / 0                           | 0 / 0  (correct)             |
| lo_distinct_instances       | 1 / 5                           | 1 / 5  (race kept)           |
| lo_striped_array            | 1 / 5                           | 1 / 5  (race kept)           |
| lo_two_mutexes_one_struct   | 2 / 5                           | 2 / 5  (race kept)           |

A lock is now known only if it is a global mutex or a constant offset into a global; a pointer
argument, loaded pointer or variable-index GEP is unknown and protects nothing. Expected cost:
LO's static reach on memcached drops (striped `item_locks[hv & mask]` / `lru_locks[i]` are
variable-index); on sqlite3.c LO-only reach equals stock. Before/after application numbers are
to be measured with the first rebuild after the tsan-dev go.
