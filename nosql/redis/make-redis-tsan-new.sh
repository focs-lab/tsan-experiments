patch -p0 <Makefile.patch && echo "Patch applied successfully!" || { echo "Patch failed to apply!" ; exit 1; }

make -j4 SANITIZER=thread \
         OPTIMIZATION="-O2" \
         CC=clang MALLOC=libc 
