// LO soundness probe 1: the lock expression is not a global. Two threads run the
// same function on distinct structs (distinct mutexes) and both touch global G.
// A sound lock-ownership analysis must keep G instrumented.
#include <pthread.h>
#include <stdio.h>
struct E { pthread_mutex_t m; int pad; };
int G;
__attribute__((noinline)) int touch(struct E *e) {
  pthread_mutex_lock(&e->m);
  int v = ++G;                           // "protected" by e->m, but e differs per thread
  pthread_mutex_unlock(&e->m);
  return v;
}
void *worker(void *p) { long v = 0; for (int i = 0; i < 100000; i++) v += touch(p); return (void *)v; }
int main(void) {
  struct E e1, e2; pthread_mutex_init(&e1.m, 0); pthread_mutex_init(&e2.m, 0);
  pthread_t t1, t2;
  pthread_create(&t1, 0, worker, &e1); pthread_create(&t2, 0, worker, &e2);
  pthread_join(t1, 0); pthread_join(t2, 0);
  return 0;
}
