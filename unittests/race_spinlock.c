#include <pthread.h>
#include <stdio.h>
#include <unistd.h>

pthread_mutex_t m;
int shared_resource;
volatile int start_signal = 0;

void *thread_A_locks(void *arg) {
	while (!start_signal) { /* spin */ }

	pthread_mutex_lock(&m);
	// Если доступ к shared_resource здесь не инструментирован из-за оптимизации,
	// TSan не увидит эту сторону гонки.
	shared_resource = 10;
	printf("Thread A wrote %d\n", shared_resource);
	pthread_mutex_unlock(&m);
	return NULL;
}

void *thread_B_no_lock(void *arg) {
	while (!start_signal) { /* spin */ }

	// Эта запись создает гонку с thread_A_locks
	shared_resource = 20;
	printf("Thread B wrote %d\n", shared_resource);
	return NULL;
}

int main() {
	pthread_mutex_init(&m, NULL);
	shared_resource = 0;

	pthread_t tid_A, tid_B;
	pthread_create(&tid_A, NULL, thread_A_locks, NULL);
	pthread_create(&tid_B, NULL, thread_B_no_lock, NULL);

	usleep(10000); // Дать потокам время запуститься
	start_signal = 1;

	pthread_join(tid_A, NULL);
	pthread_join(tid_B, NULL);

	pthread_mutex_destroy(&m);
	printf("Main: final shared_resource = %d\n", shared_resource);
	return 0;
}
