// Control: G really is protected by one global mutex; LO may elide, no race expected.
#include <pthread.h>
#include <stdio.h>
pthread_mutex_t m = PTHREAD_MUTEX_INITIALIZER;
int G;
__attribute__((noinline)) int touch(void) { pthread_mutex_lock(&m); int v = ++G; pthread_mutex_unlock(&m); return v; }
void *worker(void *p) { long v = 0; for (int k = 0; k < 100000; k++) v += touch(); return (void *)v; }
int main(void) {
  pthread_t t1, t2;
  pthread_create(&t1, 0, worker, 0); pthread_create(&t2, 0, worker, 0);
  pthread_join(t1, 0); pthread_join(t2, 0);
  return 0;
}
