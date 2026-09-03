// DE-specific eviction stress (reviewer E's scenario): thread A stores x twice in one function with
// no synchronization between the stores; the second store is dominated by the first, so Dominance
// Elimination removes its instrumentation. Between the two stores other threads fill the granule's
// four shadow cells and one of them evicts a cell chosen by its trace position (a burst of M
// instrumented stores sets that position). Then thread B writes x without synchronization.
//   stock/sound: if A's first record was evicted, A's second store re-inserts it -> B reports the race.
//   DE/AllOpt : the second store is not instrumented -> if A's first record was evicted, B finds nothing.
// All ordering uses flags accessed from no_sanitize functions (invisible to TSan, no happens-before);
// A's wait between its stores is a volatile spin through a pointer (keeps the first store alive for
// DSE while DE still sees "no synchronization"). A -DSHADOW_PROBE snapshot after the evicting store
// tells whether A's record survived, so the detection rate can be conditioned on it.
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static char g[8] __attribute__((aligned(8)));                  // one 8-byte granule; x == g[0]
static volatile int go_second __attribute__((aligned(64)));    // A's wait flag (own granule)
static volatile int step __attribute__((aligned(64)));         // phase counter, no_sanitize only
static char shared_buf[256] __attribute__((aligned(64)));

__attribute__((noinline, no_sanitize("thread"))) static void set_step(int v) { step = v; }
__attribute__((noinline, no_sanitize("thread"))) static void wait_step(int v) { while (step < v) ; }
__attribute__((noinline, no_sanitize("thread"))) static void set_go(void) { go_second = 1; }
__attribute__((noinline)) static void opaque(char *p, int n) { (void)write(-1, p, n); }

#ifdef SHADOW_PROBE
static unsigned snaps[2][4];
__attribute__((noinline, no_sanitize("thread"))) static void snap(int k) {
  unsigned long x = (unsigned long)(void *)g;
  unsigned *sh = (unsigned *)((x & ~(0x700000000000ull | 7ull)) * 2 + 0x100000000000ull);
  for (int i = 0; i < 4; i++) snaps[k][i] = sh[i];
}
#else
static void snap(int k) { (void)k; }
#endif

// escaping burst: M instrumented stores by the evicting thread (kept in every configuration)
__attribute__((noinline)) static void burst_shared(int n) {
  char *buf = shared_buf;
#pragma clang loop vectorize(disable) unroll(disable)
  for (int i = 0; i < n; i++) buf[i & 255] = (char)i;
  opaque(buf, n);
}

// The two stores of thread A, same location, no synchronization in between (only a volatile spin
// through p, which DSE must respect because p may alias x). DE elides the second store.
__attribute__((noinline)) static void a_body(volatile int *p) {
  g[0] = 1;                 // first store: A's shadow record
  set_step(1);
  while (!*p) ;             // wait for the fillers + evictor (no HB: the flag is set from no_sanitize code)
  g[0] = 2;                 // second store, dominated by the first -> not instrumented under DE
}

static void *thread_a(void *arg) { (void)arg; a_body(&go_second); set_step(6); return NULL; }
static void *filler(void *arg) { long k = (long)arg; wait_step(k); if (k == 1) snap(0); g[k] = 1; set_step(k + 1); return NULL; }
static void *thread_f4(void *arg) {
  long m = (long)arg; wait_step(4);
  burst_shared((int)m);
  g[4] = 1;                 // the evicting store: victim = f(F4's trace position)
  snap(1);
  set_go();                 // release A's second store
  return NULL;
}
static void *thread_b(void *arg) { (void)arg; wait_step(6); g[0] = 3; return NULL; }   // races with A

int main(int argc, char **argv) {
  int m = argc > 1 ? atoi(argv[1]) : 0;
  pthread_t ta, tf[3], t4, tb;
  pthread_create(&ta, NULL, thread_a, NULL);
  for (long k = 1; k <= 3; k++) pthread_create(&tf[k - 1], NULL, filler, (void *)k);
  pthread_create(&t4, NULL, thread_f4, (void *)(long)m);
  pthread_create(&tb, NULL, thread_b, NULL);
  pthread_join(ta, NULL); for (int k = 0; k < 3; k++) pthread_join(tf[k], NULL);
  pthread_join(t4, NULL); pthread_join(tb, NULL);
  int sum = 0; for (int i = 0; i < 8; i++) sum += g[i];
#ifdef SHADOW_PROBE
  // A's record = the single occupied cell after A's first store (snap 0); evicted if absent after F4's store.
  unsigned a_cell = 0; for (int i = 0; i < 4; i++) if (snaps[0][i]) { a_cell = snaps[0][i]; break; }
  unsigned a_sid = (a_cell >> 8) & 0xff; int present = 0;
  for (int i = 0; i < 4; i++) if (snaps[1][i] && ((snaps[1][i] >> 8) & 0xff) == a_sid) present = 1;
  printf("done m=%d g-sum=%d a_sid=%u a_evicted=%d cells:", m, sum, a_sid, !present);
  for (int i = 0; i < 4; i++) printf(" %08x", snaps[1][i]);
  printf("\n");
#else
  printf("done m=%d g-sum=%d\n", m, sum);
#endif
  return 0;
}
