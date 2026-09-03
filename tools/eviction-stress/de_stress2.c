// DE eviction stress, symmetric variant: two planted races on ONE 8-byte granule.
//   A: x=g[0] stored twice in one function, no sync between (second store dominated -> elided by DE).
//   C: y=g[1] stored once (its own shadow cell).  F2, F3 fill the other two cells.  F4 (escaping burst
//   of M stores, then a store) evicts a cell chosen by its trace position.  Then A's second store runs
//   (instrumented in stock/sound only), then B stores x and then y with no happens-before with A or C.
// Effects: (i) F4 evicts A's record -> DE cannot re-insert it -> DE loses A-B (stock re-inserts).
//          (ii) in stock, A's re-inserting store evicts a cell chosen by A's trace position; if it is
//               C's record, stock loses C-B; DE issues no store, so C's record survives.
// Shadow probes after F4's store, after A's second store and after B's y store record the ground truth.
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static char g[8] __attribute__((aligned(8)));
static volatile int go_flags[64] __attribute__((aligned(64)));   // A spins over 64 distinct words so that each
                                                                  // iteration is a traced event (random trace position)
static volatile int step __attribute__((aligned(64)));
static char shared_buf[256] __attribute__((aligned(64)));
static char shared_buf_b[256] __attribute__((aligned(64)));   // B's own burst buffer (no extra race with F4)
static char a_buf[65536] __attribute__((aligned(64)));         // A's in-function burst: distinct granules, so every
                                                              // store is traced (same-access fast path never hits)

__attribute__((noinline, no_sanitize("thread"))) static void set_step(int v) { step = v; }
__attribute__((noinline, no_sanitize("thread"))) static void wait_step(int v) { while (step < v) ; }
__attribute__((noinline, no_sanitize("thread"))) static void set_go(void) { for (int i = 0; i < 64; i++) go_flags[i] = 1; }
__attribute__((noinline)) static void opaque(char *p, int n) { (void)write(-1, p, n); }

static unsigned snaps[4][4];
__attribute__((noinline, no_sanitize("thread"))) static void snap(int k) {
  unsigned long x = (unsigned long)(void *)g;
  unsigned *sh = (unsigned *)((x & ~(0x700000000000ull | 7ull)) * 2 + 0x100000000000ull);
  for (int i = 0; i < 4; i++) snaps[k][i] = sh[i];
}
static unsigned sid_of(unsigned cell) { return (cell >> 8) & 0xff; }
static int has_sid(int k, unsigned sid) { for (int i = 0; i < 4; i++) if (snaps[k][i] && sid_of(snaps[k][i]) == sid) return 1; return 0; }

__attribute__((noinline)) static void burst_shared_on(char *buf, int n) {
#pragma clang loop vectorize(disable) unroll(disable)
  for (int i = 0; i < n; i++) buf[i & 255] = (char)i;
  opaque(buf, n);
}
static void burst_shared(int n) { burst_shared_on(shared_buf, n); }
__attribute__((noinline)) static void a_body(volatile int *p, int ma) {
  g[0] = 1;                 // A's first store (record)
  set_step(1);
  unsigned i = 0;
  while (!p[i++ & 63]) ;    // no synchronization from DE's point of view
#pragma clang loop vectorize(disable) unroll(disable)
  for (int j = 0; j < ma; j++) a_buf[(j * 8) & 65535] = (char)j;   // MA traced stores: sets A's trace position
  g[0] = 2;                 // dominated store: elided by DE; in stock it re-inserts A's record (and may evict)
}

static int burst_a;
static void *thread_a(void *arg) { (void)arg; a_body(go_flags, burst_a); snap(2); set_step(7); return NULL; }
static void *thread_c(void *arg) { (void)arg; wait_step(1); snap(0); g[1] = 1; set_step(2); return NULL; }
static void *filler(void *arg) { long k = (long)arg; wait_step(k); g[k] = 1; set_step(k + 1); return NULL; }
static void *thread_f4(void *arg) {
  long m = (long)arg; wait_step(4);
  burst_shared((int)m);
  g[4] = 1;                 // evicts one of {A, C, F2, F3}
  snap(1);
  set_go();
  return NULL;
}
// B checks y first, then x: TSan clears the granule's shadow after reporting a race, so the first report by
// B wipes the other race's record (a runtime property, identical in every build); y first lets the C-B
// race - the one DE can preserve where stock cannot - be observed independently of A-B.
static int burst_b;
static void *thread_b(void *arg) { (void)arg; wait_step(7); burst_shared_on(shared_buf_b, burst_b); g[1] = 3; snap(3); g[0] = 3; return NULL; }

int main(int argc, char **argv) {
  int m = argc > 1 ? atoi(argv[1]) : 0;
  burst_a = argc > 2 ? atoi(argv[2]) : 0;   // A's traced stores before its second store: victim of the re-insert
  burst_b = argc > 3 ? atoi(argv[3]) : 0;   // B's own escaping burst: victim of B's first insert
  pthread_t ta, tc, tf[2], t4, tb;
  pthread_create(&ta, NULL, thread_a, NULL);
  pthread_create(&tc, NULL, thread_c, NULL);
  for (long k = 2; k <= 3; k++) pthread_create(&tf[k - 2], NULL, filler, (void *)k);
  pthread_create(&t4, NULL, thread_f4, (void *)(long)m);
  pthread_create(&tb, NULL, thread_b, NULL);
  pthread_join(ta, NULL); pthread_join(tc, NULL); pthread_join(tf[0], NULL); pthread_join(tf[1], NULL);
  pthread_join(t4, NULL); pthread_join(tb, NULL);
  opaque(a_buf, 8);       // a_buf is read here, so the compiler cannot delete A's burst stores as dead
  unsigned a_sid = 0; for (int i = 0; i < 4; i++) if (snaps[0][i]) { a_sid = sid_of(snaps[0][i]); break; }
  unsigned c_sid = a_sid + 1;   // C is created right after A
  printf("done m=%d ma=%d mb=%d a_sid=%u c_sid=%u a_after_f4=%d c_after_f4=%d a_after_a2=%d c_after_a2=%d a_after_by=%d c_after_by=%d\n",
         m, burst_a, burst_b, a_sid, c_sid, has_sid(1, a_sid), has_sid(1, c_sid), has_sid(2, a_sid), has_sid(2, c_sid), has_sid(3, a_sid), has_sid(3, c_sid));
  return 0;
}
