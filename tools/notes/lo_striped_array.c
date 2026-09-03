// LO soundness probe 2: an array of mutexes (memcached's lru_locks[] pattern).
// getUnderlyingObject(&locks[i]) is @locks for every stripe, so accesses under
// different stripes look like they share one lock. G is touched under stripe 0
// by one thread and stripe 1 by the other -> a real race.
#include <pthread.h>
#include <stdio.h>
pthread_mutex_t locks[2] = {PTHREAD_MUTEX_INITIALIZER, PTHREAD_MUTEX_INITIALIZER};
int G;
__attribute__((noinline)) int touch(int i) {
  pthread_mutex_lock(&locks[i]);
  int v = ++G;
  pthread_mutex_unlock(&locks[i]);
  return v;
}
void *worker(void *p) { int i = (int)(long)p; long v = 0; for (int k = 0; k < 100000; k++) v += touch(i); return (void *)v; }
int main(void) {
  pthread_t t1, t2;
  pthread_create(&t1, 0, worker, (void *)0L); pthread_create(&t2, 0, worker, (void *)1L);
  pthread_join(t1, 0); pthread_join(t2, 0);
  return 0;
}
