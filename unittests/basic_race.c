#include <stdio.h>
#include <pthread.h>

pthread_mutex_t l;
int a = 0;

void * thread2( void *unused ) {
	pthread_mutex_lock( &l );
	a--;
	pthread_mutex_unlock( &l );

	return NULL;
}

void * thread1unsafe( void *unused ) {
	a++;

	return NULL;
}


#define MAX 100

int main() {
	pthread_t t1[ MAX ], t2[ MAX ]; // Обычные потоки.
	pthread_t u1[ MAX ], u2[ MAX ]; // Потоки с несинхронизированным доступом.

	a = 0;
	pthread_mutex_init( &l, NULL );

    for ( int i = 0; i < MAX; i++ ) {
		pthread_create( &u1[ i ], NULL, thread1unsafe, NULL );
		pthread_create( &u2[ i ], NULL, thread2, NULL );
	}

    for ( int i = 0; i < MAX; i++ ) {
		pthread_join( u1[ i ], NULL );
		pthread_join( u2[ i ], NULL );
	}

	printf( "Non-synchronized block: %i\n", a );

	return 0;
}
