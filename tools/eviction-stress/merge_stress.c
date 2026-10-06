// merge_stress.c — does the granule merge change what TSan misses under shadow-cell pressure?
//
// The existing P4 probes cannot answer this. They use single-byte accesses to `static char g[8]` issued from
// *different* threads, and the merge only combines adjacent same-granule accesses inside one basic block of one
// function. No probe here contains such a block, so the merge transforms nothing in them and the whole harness
// would run green while exercising none of the change. This probe exists to make the check able to fire.
//
// Shape: one aligned 8-byte granule holding two adjacent int32 fields.
//
//   phase 0  A  : s.a = 1; s.b = 1;   <- THE MERGEABLE PAIR, both stores in one basic block.
//                                        merge off -> two __tsan_write4 (masks 0x0F and 0xF0)
//                                        merge on  -> one __tsan_write8 (mask 0xFF)
//   phase 1  F1 : s.b = 3             <- a distinct mask from a distinct thread: takes a slot
//   phase 2  F2 : s.a = 3             <- another
//   phase 3  F3 : burst of N thread-local writes, then s.b = 4. The burst advances trace_pos, which is what
//                 selects the random replacement slot at the bottom of CheckRaces.
//   phase 4  B  : s.a = 2             <- races A's write of `a`; reported iff A's record for `a` survived
//
// PRE-REGISTERED DIRECTION (fixed before the first run, agreed before the first run): at any given burst the
// merge-on arm should lose NO MORE races than merge-off, and plausibly fewer. Verified in CheckRaces
// (tsan_rtl_access.cpp): a same-thread access whose mask differs from the stored one does NOT overwrite in
// place — `cur.access() == old.access()` fails, it `continue`s, and it ends at the random-slot replacement.
// So A's two write4s (masks 0x0F, 0xF0) each take a turn at that path, each able to evict a remote thread's
// record; the merged write8 takes one. The merge halves this thread's eviction events in the granule.
// If merge-on loses MORE races, that reasoning is wrong and the transform is in trouble regardless of speed.
//
// ACCEPTANCE, before any run counts as evidence:
//   1. objdump must show one __tsan_write8 in write_pair under merge-on and two __tsan_write4 under
//      merge-off — the probe is verified transformed per arm, never assumed.
//   2. the merge-off arm MUST report the race at burst 0. A probe that reports nothing with the transform
//      disabled is broken, and every "no loss" result after it would be free.
//   3. only then does a difference between the arms under burst mean anything.
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>

#define NTHREADS 5
#define NPHASES 5

typedef unsigned invisible_barrier_t;
void __tsan_testonly_barrier_init(invisible_barrier_t *b, unsigned count);
void __tsan_testonly_barrier_wait(invisible_barrier_t *b);

static invisible_barrier_t phase[NPHASES];

// two adjacent int32 fields in one naturally aligned granule: the shape the merge combines
struct pair {
  int a;
  int b;
} __attribute__((aligned(8)));

// External linkage on purpose. With `static` the optimiser narrows these stores before the pass runs — two
// __tsan_write1 rather than a mergeable pair — and the probe silently stops testing the transform. Caught by
// acceptance condition 1, which is why that condition exists.
struct pair s;

static int burst_n;

__attribute__((noinline)) static void opaque(char *p, int n) {
  __asm__ __volatile__("" ::"r"(p), "r"(n) : "memory");
}

__attribute__((noinline)) static void burst_local(int n) {
  char *buf = malloc(256);            // never escapes; only the address reaches the asm barrier
  for (int i = 0; i < n; i++) buf[i & 255] = (char)i;
  opaque(buf, 256);
  free(buf);
}

// A's pair. Both stores must stay in one basic block — no call, no branch between them, or the transform
// refuses the pair and the probe stops testing anything.
// Source order matters and is selected at compile time. The merged call is emitted at the LOWER-addressed
// member, so in ascending order it sits ahead of both stores — TSan's normal shape, no window at all, which is
// 95 % of merged groups on sqlite3.c. Only descending order puts the survivor at the later instruction, which
// is the one arrangement where a member's record moves after its own access. An ascending-only probe tests the
// common case and cannot show the deviation: a third way to get a clean result for free.
#ifdef DESCENDING
__attribute__((noinline)) static void write_pair(void) {
  s.b = 1;
  s.a = 1;
}
#else
__attribute__((noinline)) static void write_pair(void) {
  s.a = 1;
  s.b = 1;
}
#endif

static void act(int who) {
  switch (who) {
    case 0: write_pair();                    break;   // the mergeable pair
    case 1: s.b = 3;                         break;   // distinct mask, distinct thread
    case 2: s.a = 3;                         break;   // another
    case 3: burst_local(burst_n); s.b = 4;   break;   // burst, then a store that may evict
    case 4: s.a = 2;                         break;   // races A's `a`
  }
}

// Every thread traverses every barrier and acts only at its own phase. The first version had each thread wait
// on a hand-written subset of the barriers and deadlocked — filler 1 never waited on barrier 1 while A did.
// One loop shared by all threads makes that class of mistake impossible rather than merely unlikely.
static void *worker(void *arg) {
  int who = (int)(long)arg;
  for (int i = 0; i < NPHASES; i++) {
    if (i == who) act(who);
    __tsan_testonly_barrier_wait(&phase[i]);
  }
  return NULL;
}

int main(int argc, char **argv) {
  burst_n = argc > 1 ? atoi(argv[1]) : 0;
  for (int i = 0; i < NPHASES; i++) __tsan_testonly_barrier_init(&phase[i], NTHREADS);
  pthread_t t[NTHREADS];
  for (long i = 0; i < NTHREADS; i++) pthread_create(&t[i], NULL, worker, (void *)i);
  for (int i = 0; i < NTHREADS; i++) pthread_join(t[i], NULL);
  printf("done n=%d a=%d b=%d\n", burst_n, s.a, s.b);   // keep the stores observable
  return 0;
}
