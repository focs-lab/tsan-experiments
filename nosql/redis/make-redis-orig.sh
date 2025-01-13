make -j20 OPTIMIZATION="-O2" \
          CFLAGS="-g" \
          LDFLAGS="-fuse-ld=lld" \
          CC=clang MALLOC=libc V=1 
