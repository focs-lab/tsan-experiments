#include <stdio.h>
#include <pthread.h>
#include <stdlib.h>

/*	Premature instrumentation unit test. Shows the case like:

	void * func() {
		void * ptr = ...;

		local_actions_without_escaping( &ptr );
		local_actions_without_escaping( &ptr );
		local_actions_without_escaping( &ptr );

		// No instrumentation for "ptr" needed up to this line.
		// First "ptr"-escaping call:
		local_actions_with_escaping( &ptr );

		local_actions_without_escaping( &ptr );
		local_actions_without_escaping( &ptr );

		return ptr;
	}
*/

// Адрес внутри функции может считаться ускользающим только с того момента, когда он действительно начнёт ускользать; до этого момента его не нужно инструментировать. Данный подход, рассматривающий пограничные случаи на пересечении Single-Threaded и Escape Analysis, позволяет исключить инструментацию в участках кода перед первой утечкой адреса.


#define NUM_THREADS 4
#define NUM_ITERS 400000
#define STR_LENGTH 100


pthread_mutex_t l1;
int a = 0;


void *firstIntersectThread( void *unused ) {
	char *str = (char *) malloc( STR_LENGTH * sizeof( char ) );

	if ( NULL == str )
		return NULL;

	int acur;

	for ( int i = 0; i < NUM_ITERS; i++ ) {
		pthread_mutex_lock( &l1 );
		a++;
		acur = a;
		pthread_mutex_unlock( &l1 );

		str[ 0 ] = acur;

		for ( int j = 1; j < STR_LENGTH; j++ )
			str[ j ] = ( str[ j - 1 ] + j ) ^ acur;
	}

	return (void *) str;
}


int main( void ) {
	pthread_t tarr[ NUM_THREADS ];

	pthread_mutex_init( &l1, NULL );

	pthread_mutex_lock( &l1 );
	a = 0;
	pthread_mutex_unlock( &l1 );

	for ( int i = 0; i < NUM_THREADS; i++ ) {
		pthread_create( &tarr[ i ], NULL, firstIntersectThread, NULL );
	}


	char finalstr[ STR_LENGTH + 1 ] = "";

	for ( int i = 0; i < NUM_THREADS; i++ ) {
		char *retstr;
		pthread_join( tarr[ i ], (void **) &retstr );

		for ( int i = 0; i < STR_LENGTH; i++ )
			finalstr[ i ] = ( finalstr[ i ] + retstr[ i ] ) % 26 + 'A';

		free( retstr );
	}

	finalstr[ STR_LENGTH ] = '\0';


	pthread_mutex_lock( &l1 );
	printf( "finalstr = %s\n", finalstr );
	pthread_mutex_unlock( &l1 );

	return 0;
}
