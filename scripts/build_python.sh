#!/usr/bin/env bash
# Build CPython 3.11.9 for OHOS ARM64
set -ex

DEPS_DIR=/opt/deps
WORKDIR=${GITHUB_WORKSPACE:-/home/runner/work/ohos-python-builder/ohos-python-builder}
PREFIX=/opt/python-3.11.9-ohos-arm64
BUILD_PYTHON=${BUILD_PYTHON:-$(which python3)}

# Always rebuild Python to pick up newly built deps
rm -rf $PREFIX
echo "=== Building Python (forced rebuild) ==="

cd $WORKDIR/deps 2>/dev/null || { mkdir -p $WORKDIR/deps && cd $WORKDIR/deps; }

if [ ! -d Python-3.11.9 ]; then
    curl -fLO https://www.python.org/ftp/python/3.11.9/Python-3.11.9.tgz
    tar -zxf Python-3.11.9.tgz
    rm -rf Python-3.11.9.tgz
fi

cd Python-3.11.9

# Force aarch64-linux-ohos platform triplet (matches OHOS NDK --target)
sed -i 's|PLATFORM_TRIPLET="${PLATFORM_TRIPLET#PLATFORM_TRIPLET=}"|PLATFORM_TRIPLET="aarch64-linux-ohos"|g' configure
sed -i 's|MULTIARCH=$($CC --print-multiarch 2>/dev/null)|MULTIARCH="aarch64-linux-ohos"|g' configure
sed -i '/def get_platform():/a\    return "linux-aarch64"' Lib/sysconfig.py
sed -i '/def system():/a\    return "Linux"' Lib/platform.py
echo "PLATFORM_TRIPLET=aarch64-linux-ohos" > Misc/platform_triplet.c

# Create host-prefixed readelf symlink for cross-compile detection
ln -sf /bin/llvm-readelf /usr/local/bin/aarch64-linux-ohos-readelf
ln -sf /bin/llvm-readelf /usr/local/bin/aarch64-linux-gnu-readelf  # fallback

# Configure with cross-compiling support
./configure \
    --build=x86_64-linux-gnu \
    --host=aarch64-linux-ohos \
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
    ac_cv_header_linux_socket_h=no \
    LDFLAGS="-L$DEPS_DIR/lib -Wl,-rpath,'\$\$ORIGIN/../lib' -Wl,-rpath,'\$\$ORIGIN/../../../lib'" \
    CPPFLAGS="-I$DEPS_DIR/include" \
    CC=/bin/clang \
    CXX=/bin/clang++ \
    AR=/bin/llvm-ar \
    RANLIB=/bin/llvm-ranlib \
    LD=/bin/ld.lld \
    READELF=/bin/llvm-readelf \
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

# Fix _socket: OHOS SDK sysroot lacks CAN_RAW_FD_FRAMES/CAN_RAW_JOIN_FILTERS
cat > /tmp/can_raw_fix.h << 'EOF'
#ifndef CAN_RAW_FD_FRAMES
#define CAN_RAW_FD_FRAMES 1
#endif
#ifndef CAN_RAW_JOIN_FILTERS
#define CAN_RAW_JOIN_FILTERS 6
#endif
EOF
sed -i '1i\#include "/tmp/can_raw_fix.h"' Modules/socketmodule.c

# Disable checksharedmods (fails in cross compile)
sed -i 's/checksharedmods:/checksharedmods_disabled:/' Makefile

# 让 C 扩展模块显式链接 libpython3.11.so（OHOS 命名空间隔离要求）
# 默认 Python 构建中 C 扩展不链接 libpython，依赖运行时符号解析
# 但 OHOS 动态链接命名空间隔离阻止了这种方式
sed -i '/^LDSHARED=/s/$/ -L. -lpython3.11/' Makefile
sed -i '/^BLDSHARED=/s/$/ -L. -lpython3.11/' Makefile

make -j$(nproc)
make install

# 修改 SONAME：将 libpython3.11.so.1.0 改为 libpython3.11.so
# OHOS 命名空间隔离下，带版本号的 SONAME 会导致加载失败
echo "=== Fixing SONAME ==="

# 安装 patchelf
apt-get install -y patchelf 2>/dev/null || true

# 修改 libpython3.11.so 的 SONAME
if command -v patchelf >/dev/null 2>&1; then
    for sofile in $PREFIX/lib/libpython3.11.so*; do
        if [ -f "$sofile" ]; then
            patchelf --set-soname libpython3.11.so "$sofile" 2>/dev/null || true
        fi
    done
    # 修改 C 扩展模块的 NEEDED（从 libpython3.11.so.1.0 改为 libpython3.11.so）
    for sofile in $PREFIX/lib/python3.11/lib-dynload/*.so; do
        if [ -f "$sofile" ]; then
            patchelf --replace-needed libpython3.11.so.1.0 libpython3.11.so "$sofile" 2>/dev/null || true
        fi
    done
fi

# 删除带版本号的符号链接/副本，只保留 libpython3.11.so
rm -f $PREFIX/lib/libpython3.11.so.1.0
rm -f $PREFIX/lib/libpython3.11.so.1
# 确保 libpython3.11.so 是实际文件（不是符号链接）
if [ -L $PREFIX/lib/libpython3.11.so ]; then
    LINK_TARGET=$(readlink -f $PREFIX/lib/libpython3.11.so)
    cp "$LINK_TARGET" $PREFIX/lib/libpython3.11.so.tmp
    rm -f $PREFIX/lib/libpython3.11.so
    mv $PREFIX/lib/libpython3.11.so.tmp $PREFIX/lib/libpython3.11.so
fi

# Copy dependency libs
cp /opt/deps/lib/*.so* $PREFIX/lib/ 2>/dev/null || true

echo "=== Python build complete ==="
