// evict_stress.c -- P4: does reduced instrumentation change race detection under
// shadow-granule pressure?  (ATC'26 #571 rebuttal, plan/rebuttal-experiments.md, P4)
//
// TSan keeps kShadowCnt = 4 shadow cells per 8-byte granule.  When a store finds
// no free cell and no cell of its own thread, it evicts
//     cell = (thr->trace_pos / 8) % 4          (tsan_rtl_access.cpp, CheckRaces)
// i.e. the victim is chosen by the evicting thread's *trace position* -- the
// number of events (instrumented accesses, function entries/exits) that thread
// has traced so far -- not by age.  Any instrumentation change therefore
// perturbs which record is evicted.
//
// Set-up (one 8-byte granule `g`, six threads, ordered by a TSan-invisible
// barrier that creates no happens-before and traces no events):
//   phase 0  A  : g[0] = 1                  <- first half of the planted race
//   phase 1  F1 : g[1] = 1                  <- fill the remaining three cells,
//   phase 2  F2 : g[2] = 1                     one thread at a time (two fillers
//   phase 3  F3 : g[3] = 1                     storing concurrently may pick the
//                                              same free cell and leave one free)
//   phase 4  F4 : burst of N writes to a    <- thread-local traffic; advances
//                 private buffer, then         F4's trace_pos by N in stock TSan,
//                 g[4] = 1                     by 0 if the compiler elided it
//                                           <- 5th record: evicts cell (c+N)%4
//   phase 5  B  : g[0] = 2                  <- second half of the race; reported
//                                              only if A's record survived
//   phase 6  all: (nothing; keeps all threads alive until B's store is done)
// With the burst elided, F4's trace position is a constant and the outcome is
// fixed per binary; with the burst traced it depends on N.  Neither outcome is
// "more correct": the eviction is a hash of an arbitrary counter in both cases.
//
// Usage: ./evict_stress <N> [mode [M]]     mode = local (default) | shared | mixed
//   local : N writes to a heap buffer that never escapes (elidable by EA/STC)
//   shared: M writes to a heap buffer handed to an opaque call (not elidable)
//   mixed : both bursts (N local, then M shared)
// Compile with -DSHADOW_PROBE to print the four raw shadow cells of `g` after
// every phase (read by an uninstrumented function; no events are traced).
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef unsigned invisible_barrier_t;
void __tsan_testonly_barrier_init(invisible_barrier_t *b, unsigned count);
void __tsan_testonly_barrier_wait(invisible_barrier_t *b);

#define NTHREADS 6
#define NPHASES 7
static char g[8] __attribute__((aligned(8)));
static invisible_barrier_t phase[NPHASES];
static int burst_n, burst_m;
static int mode; // 0 local, 1 shared, 2 mixed
static char *shared_buf;

#ifdef SHADOW_PROBE
// x86_64 Linux Mapping48AddressSpace: shadow(x) = (x & ~(kShadowMsk|7)) * 2 + kShadowAdd,
// four u32 cells per 8-byte granule: access:8 | sid:8 | epoch:14 | is_read:1 | is_atomic:1
static unsigned snaps[NPHASES][4];
__attribute__((noinline, no_sanitize("thread"))) static void snap(int k) {
  unsigned long x = (unsigned long)g;
  const unsigned *cell = (const unsigned *)((x & ~(0x700000000000ull | 7ull)) * 2 + 0x100000000000ull);
  for (int i = 0; i < 4; i++) snaps[k][i] = cell[i];
}
static void print_snaps(void) {
  for (int k = 0; k < NPHASES - 1; k++) {
    printf("after phase %d:", k);
    for (int i = 0; i < 4; i++) {
      unsigned c = snaps[k][i];
      if (c == 0) printf("  [%d] empty              ", i);
      else printf("  [%d] acc=%02x sid=%3u ep=%-5u", i, c & 0xff, (c >> 8) & 0xff, (c >> 16) & 0x3fff);
    }
    printf("\n");
  }
}
#else
#define snap(k) ((void)0)
#define print_snaps() ((void)0)
#endif

__attribute__((noinline)) static void opaque(char *p, int n) {
  // An external call the analyses cannot see through: the buffer escapes.
  if (write(-1, p, (size_t)n) == 12345) puts("never");
}

// NOTE: keep every store a distinct byte -- TSan skips tracing an access
// that is identical (thread, address, size, kind) to one already in the cell.
// The buffer is heap-allocated: stock TSan already skips stores to a stack
// buffer that is never captured, so a stack buffer would trace nothing in any
// build.  A malloc'd buffer that is only written here and freed is instrumented
// by stock TSan and is what the escape analysis can prove thread-local.
__attribute__((noinline)) static void burst_local(int n) {
  char *buf = malloc(256);
#pragma clang loop vectorize(disable) unroll(disable)
  for (int i = 0; i < n; i++)
    buf[i & 255] = (char)i;
  // keep the stores alive (unknown index) without letting buf escape
  __asm__ volatile("" : : "r"(buf[n & 255]));
  free(buf);
}

__attribute__((noinline)) static void burst_shared(int n) {
  char *buf = shared_buf;
#pragma clang loop vectorize(disable) unroll(disable)
  for (int i = 0; i < n; i++)
    buf[i & 255] = (char)i;
  opaque(buf, n);
}

// Every thread passes every barrier; `me` is the phase in which it acts.
static void wait_phases(int from, int to) {
  for (int k = from; k < to; k++) __tsan_testonly_barrier_wait(&phase[k]);
}

static void *thread_a(void *arg) {
  (void)arg;
  g[0] = 1;
  snap(0);
  wait_phases(0, NPHASES);
  return NULL;
}

static void *thread_filler(void *arg) {
  int idx = (int)(long)arg; // 1..3: acts in phase idx
  wait_phases(0, idx);
  g[idx] = 1;
  snap(idx);
  wait_phases(idx, NPHASES);
  return NULL;
}

static void *thread_f4(void *arg) {
  // n, m and the mode arrive in the pointer value: F4 performs no memory access
  // other than the bursts and the granule store, so its trace position before
  // the store is a function of the bursts alone.
  long v = (long)arg;
  int md = (int)(v & 3), n = (int)((v >> 2) & 0xfffff), m = (int)(v >> 22);
  wait_phases(0, 4);
  if (md != 1) burst_local(n);
  if (md != 0) burst_shared(m);
  g[4] = 1;
  snap(4);
  wait_phases(4, NPHASES);
  return NULL;
}

static void *thread_b(void *arg) {
  (void)arg;
  wait_phases(0, 5);
  g[0] = 2; // races with thread_a's store
  snap(5);
  // phase 6: keep every thread alive until the race has been checked, so that
  // no thread exit (slot/trace recycling) can interfere with the report
  wait_phases(5, NPHASES);
  return NULL;
}

int main(int argc, char **argv) {
  burst_n = argc > 1 ? atoi(argv[1]) : 0;
  if (argc > 2) mode = strcmp(argv[2], "shared") == 0 ? 1 : strcmp(argv[2], "mixed") == 0 ? 2 : 0;
  burst_m = argc > 3 ? atoi(argv[3]) : burst_n;
  if (mode) shared_buf = malloc(256);
  for (int i = 0; i < NPHASES; i++) __tsan_testonly_barrier_init(&phase[i], NTHREADS);
  pthread_t t[NTHREADS];
  pthread_create(&t[0], NULL, thread_a, NULL);
  for (long i = 1; i <= 3; i++) pthread_create(&t[i], NULL, thread_filler, (void *)i);
  pthread_create(&t[4], NULL, thread_f4, (void *)(((long)burst_m << 22) | ((long)burst_n << 2) | mode));
  pthread_create(&t[5], NULL, thread_b, NULL);
  for (int i = 0; i < NTHREADS; i++) pthread_join(t[i], NULL);
  if (mode) { opaque(shared_buf, 256); free(shared_buf); }
  int sum = 0; // keep g observable so the stores are not dead
  for (int i = 0; i < 8; i++) sum += g[i];
  printf("done n=%d m=%d mode=%s g-sum=%d\n", burst_n, burst_m, mode == 1 ? "shared" : mode == 2 ? "mixed" : "local", sum);
  print_snaps();
  return 0;
}
