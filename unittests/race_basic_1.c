#include <pthread.h>

pthread_mutex_t l;
int varprotected = 0;
int varfree = 0;


void access_varprotected( void ) {
    pthread_mutex_lock( &l );
    varprotected++;
    pthread_mutex_unlock( &l );
}

void access_varfree( void ) {
    varfree++;
}


int main() {
    pthread_mutex_init( &l, NULL );

    access_varprotected();
    access_varfree();

    pthread_mutex_destroy( &l );
    return 0;
}
