#!/usr/bin/env bash
# Build CPython 3.11.9 for OHOS ARM64
set -ex

DEPS_DIR=/opt/deps
WORKDIR=/home/runner/work/ohos-python-builder/ohos-python-builder
PREFIX=/opt/python-3.11.9-ohos-arm64
BUILD_PYTHON=${BUILD_PYTHON:-$(which python3)}

if [ -f $PREFIX/bin/python3.11 ]; then
    echo "=== Python already built, skipping ==="
    exit 0
fi

cd $WORKDIR/deps 2>/dev/null || { mkdir -p $WORKDIR/deps && cd $WORKDIR/deps; }

if [ ! -d Python-3.11.9 ]; then
    curl -fLO https://www.python.org/ftp/python/3.11.9/Python-3.11.9.tgz
    tar -zxf Python-3.11.9.tgz
    rm -rf Python-3.11.9.tgz
fi

cd Python-3.11.9

# Force aarch64-linux-musl platform triplet (reuse musl pip packages)
sed -i 's|PLATFORM_TRIPLET="${PLATFORM_TRIPLET#PLATFORM_TRIPLET=}"|PLATFORM_TRIPLET="aarch64-linux-musl"|g' configure
sed -i 's|MULTIARCH=$($CC --print-multiarch 2>/dev/null)|MULTIARCH="aarch64-linux-musl"|g' configure
sed -i '/def get_platform():/a\    return "linux-aarch64"' Lib/sysconfig/__init__.py
sed -i '/def system():/a\    return "Linux"' Lib/platform.py
echo "PLATFORM_TRIPLET=aarch64-linux-musl" > Misc/platform_triplet.c

# Configure with cross-compiling support
./configure \
    --build=x86_64-linux-gnu \
    --host=aarch64-linux-gnu \
    --prefix=$PREFIX \
    --with-openssl=$DEPS_DIR \
    --disable-ipv6 \
    --with-readline=readline \
    --with-dbmliborder=gdbm \
    --enable-shared \
    --with-build-python=$BUILD_PYTHON \
    ac_cv_file__dev_ptmx=yes \
    ac_cv_file__dev_ptc=no \
    ac_cv_buggy_getaddrinfo=no \
    LDFLAGS="-L$DEPS_DIR/lib -Wl,-rpath,'\$\$ORIGIN/../lib' -Wl,-rpath,'\$\$ORIGIN/../../../lib'" \
    CC=/bin/clang \
    CXX=/bin/clang++ \
    AR=/bin/llvm-ar \
    RANLIB=/bin/llvm-ranlib \
    LD=/bin/ld.lld \
    CFLAGS="$CFLAGS -DNO_GETTEXT"

# Patch _localemodule.c: provide gettext stubs (libintl not available)
cat > /tmp/gettext_stubs.h << 'EOF'
#ifndef GETTEXT_STUBS_H
#define GETTEXT_STUBS_H
static inline char *textdomain(const char *d) { return (char*)d; }
static inline char *bindtextdomain(const char *d, const char *dir) { return (char*)dir; }
static inline char *gettext(const char *s) { return (char*)s; }
static inline char *dgettext(const char *d, const char *s) { return (char*)s; }
static inline char *dcgettext(const char *d, const char *s, int c) { return (char*)s; }
static inline char *ngettext(const char *s, const char *p, unsigned long n) { return (char*)(n==1?s:p); }
static inline char *dngettext(const char *d, const char *s, const char *p, unsigned long n) { return (char*)(n==1?s:p); }
static inline char *bind_textdomain_codeset(const char *d, const char *c) { return (char*)c; }
#endif
EOF
sed -i '1i\#include "/tmp/gettext_stubs.h"' Modules/_localemodule.c

# Fix zstd: disable _zstd module if zstd.h not found
if [ ! -f $DEPS_DIR/include/zstd.h ]; then
    echo "=== zstd.h not found, disabling _zstd module ==="
    sed -i 's|_zstd _zstd/|##_zstd _zstd/|' Modules/Setup.stdlib 2>/dev/null || true
fi

# Fix ffi: find ffi.h (libffi installs to libdir/include)
FFI_INC=$(find $DEPS_DIR -name "ffi.h" -printf "%h\n" 2>/dev/null | head -1)
if [ -n "$FFI_INC" ]; then
    echo "=== Found ffi.h in $FFI_INC, creating symlink ==="
    ln -sf $FFI_INC/ffi.h ./Include/ffi.h
    ln -sf $FFI_INC/ffitarget.h ./Include/ffitarget.h 2>/dev/null || true
else
    echo "=== ffi.h not found, disabling _ctypes module ==="
    # Disable in Setup.stdlib
    sed -i 's|_ctypes|##_ctypes|g' Modules/Setup.stdlib 2>/dev/null || true
    # Also remove from Makefile
    sed -i '/_ctypes/d' Makefile 2>/dev/null || true
fi

# Disable checksharedmods (fails in cross compile)
sed -i 's/checksharedmods:/checksharedmods_disabled:/' Makefile

make -j$(nproc)
make install

# Copy dependency libs
cp /opt/deps/lib/*.so* $PREFIX/lib/ 2>/dev/null || true

echo "=== Python build complete ==="
