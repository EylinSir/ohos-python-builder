#!/usr/bin/env bash
# Post-process: sign binaries and package
set -ex

PREFIX=/opt/python-3.11.9-ohos-arm64
WORKDIR=${GITHUB_WORKSPACE:-/home/runner/work/ohos-python-builder/ohos-python-builder}
SIGN_TOOL=/opt/ohos-sdk/linux/toolchains/lib/binary-sign-tool

cd $PREFIX

# Sign all ELF files
find . -type f -exec sh -c '
    file -b "$1" | grep -iqE "elf|sharedlib|ELF|shared object" && {
        echo "Signing $1"
        ORIG_PERM=$(stat -c %a "$1")
        '"$SIGN_TOOL"' sign -inFile "$1" -outFile "$1" -selfSign 1
        chmod "$ORIG_PERM" "$1"
    }
' _ {} \;

# Fix pip3/pydoc3 to be portable
cd $PREFIX/bin
printf '#!/bin/sh\nexec "$(dirname "$(readlink -f "$0")")"/python3.11 -m pip "$@"\n' > pip3
printf '#!/bin/sh\nexec "$(dirname "$(readlink -f "$0")")"/python3.11 -m pip "$@"\n' > pip3.11
printf '#!/bin/sh\nexec "$(dirname "$(readlink -f "$0")")"/python3.11 -m pydoc "$@"\n' > pydoc3.11

# Remove idle (no GUI)
rm -f idle3* 2>/dev/null || true

# Copy terminfo
cp -r $PREFIX/share/terminfo $PREFIX/lib/ 2>/dev/null || true

# Package
cd /opt
tar -zcf $WORKDIR/python-3.11.9-ohos-arm64.tar.gz python-3.11.9-ohos-arm64
sync

echo "=== Package complete ==="
ls -lh $WORKDIR/python-3.11.9-ohos-arm64.tar.gz
