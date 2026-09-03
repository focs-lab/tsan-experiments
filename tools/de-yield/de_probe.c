#include <pthread.h>
#include <semaphore.h>
extern void unknown_ext(void);
int x; pthread_mutex_t m; pthread_cond_t c; sem_t s; pthread_t t;
struct S { int a; int b; } st;
int arr[16];
void f_cond(void)    { x = 1; pthread_cond_wait(&c, &m); x = 2; }
void f_join(void)    { x = 1; pthread_join(t, 0);        x = 2; }
void f_sem(void)     { x = 1; sem_wait(&s);              x = 2; }
void f_ext(void)     { x = 1; unknown_ext();             x = 2; }
void f_lock(void)    { x = 1; pthread_mutex_lock(&m);    x = 2; }
void f_unlock(void)  { x = 1; pthread_mutex_unlock(&m);  x = 2; }
void f_field(void)   { st.a = 1; st.b = 2; }
void f_index(int i, int j) { arr[i] = 1; arr[j] = 2; }
void f_same(void)    { x = 1; x = 2; }
