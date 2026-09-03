// LO soundness probe 3: two mutexes inside one global struct. Underlying object of
// both &S.a and &S.b is @S. G is touched under S.a by one thread and S.b by the other.
#include <pthread.h>
#include <stdio.h>
struct { pthread_mutex_t a, b; } S = {PTHREAD_MUTEX_INITIALIZER, PTHREAD_MUTEX_INITIALIZER};
int G;
__attribute__((noinline)) int touch_a(void) { pthread_mutex_lock(&S.a); int v = ++G; pthread_mutex_unlock(&S.a); return v; }
__attribute__((noinline)) int touch_b(void) { pthread_mutex_lock(&S.b); int v = ++G; pthread_mutex_unlock(&S.b); return v; }
void *wa(void *p) { long v = 0; for (int k = 0; k < 100000; k++) v += touch_a(); return (void *)v; }
void *wb(void *p) { long v = 0; for (int k = 0; k < 100000; k++) v += touch_b(); return (void *)v; }
int main(void) {
  pthread_t t1, t2;
  pthread_create(&t1, 0, wa, 0); pthread_create(&t2, 0, wb, 0);
  pthread_join(t1, 0); pthread_join(t2, 0);
  return 0;
}
