make -j4 SANITIZER=thread \
         OPTIMIZATION="-O2" \
         CC=clang MALLOC=libc 