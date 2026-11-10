#!/bin/bash
# Produce sanitized userspace headers from the DroboFS 2.6.22.18 kernel tree
# and wrap them in a tarball whose Makefile implements `headers_install`,
# so Buildroot can consume it as a "custom tarball" kernel-headers source.
#
# Runs inside the build container (case-sensitive FS needed). $1 = output dir
set -euo pipefail
OUT=$1
SRC=$(mktemp -d)/k; git clone -q --depth 1 https://github.com/droboports/kernel-drobofs.git "$SRC"; SRC=$SRC/kernel
WORK=$(mktemp -d)
cp -a "$SRC" "$WORK/linux"
cd "$WORK/linux"

# Old kernel Makefiles trip on GNU make >= 3.82 ("mixed implicit and normal rules").
sed -i 's/^config %config: scripts_basic outputmakefile FORCE/%config: scripts_basic outputmakefile FORCE/' Makefile
sed -i 's|^/ %/: prepare scripts FORCE|%/: prepare scripts FORCE|' Makefile
# unifdef's getline() collides with the libc one on modern hosts.
sed -i 's/\bgetline\b/unifdef_getline/g' scripts/unifdef.c

make ARCH=arm HOSTCFLAGS="-O2 -fcommon -std=gnu89" INSTALL_HDR_PATH="$WORK/hdr/usr" headers_install >/dev/null
find "$WORK/hdr" \( -name '.install' -o -name '..install.cmd' \) -delete
# 2.6.22 headers expose duplicate libc structs unless __GLIBC__ >= 2; uClibc-ng
# no longer defines __GLIBC__, so make those guards kernel-only (as later kernels do).
grep -rl 'defined(__KERNEL__) || !defined(__GLIBC__) || (__GLIBC__ < 2)' "$WORK/hdr" | \
  xargs sed -i 's/defined(__KERNEL__) || !defined(__GLIBC__) || (__GLIBC__ < 2)/defined(__KERNEL__)/'
# linux/random.h uses __u32 without including linux/types.h (fixed upstream later).
sed -i 's|^#define _LINUX_RANDOM_H$|#define _LINUX_RANDOM_H\n#include <linux/types.h>|' "$WORK/hdr/usr/include/linux/random.h"

PKG=linux-2.6.22.18-drobofs
mkdir -p "$WORK/$PKG"
cp -a "$WORK/hdr/usr/include" "$WORK/$PKG/sanitized-include"
cp "$SRC/COPYING" "$WORK/$PKG/COPYING"   # GPLv2; Buildroot's legal-info needs it
cat > "$WORK/$PKG/Makefile" <<'EOF'
# Pre-generated headers for the DroboFS kernel (2.6.22.18).
headers_install:
	mkdir -p $(INSTALL_HDR_PATH)/include
	cp -a sanitized-include/. $(INSTALL_HDR_PATH)/include/
.PHONY: headers_install
EOF
mkdir -p "$OUT"
tar -C "$WORK" -czf "$OUT/$PKG.tar.gz" "$PKG"
grep -E 'LINUX_VERSION_CODE' "$WORK/$PKG/sanitized-include/linux/version.h"
echo "wrote $OUT/$PKG.tar.gz"
