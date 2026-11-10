#!/bin/bash
# Assemble the Encore DroboApp (encore.tgz) from the Buildroot output + app/encore.
# Runs on the Mac; does the work inside the build container.
#   ./package.sh            -> dist/encore.tgz
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p ../dist
docker run --rm -i -u root \
  -v "$PWD/..":/proj \
  -v drobofs-br:/br \
  drobofs-build bash -s <<'EOS'
set -euo pipefail
APP=/mnt/DroboFS/Shares/DroboApps/encore
T=/br/output/target
HOST=/br/output/host/bin
READELF=$(ls $HOST/*-readelf | head -1)
PATCHELF=$HOST/patchelf
STAGE=/tmp/stage
OUT=$STAGE$APP
rm -rf $STAGE && mkdir -p $OUT/{bin,sbin,lib,etc,share}

# 1. Samba (already installed under the app prefix)
cp -a $T$APP/. $OUT/
rm -rf $OUT/var $OUT/include $OUT/share/man $OUT/lib/pkgconfig

# 2. C library + shared libraries
cp -a $T/lib/*.so* $OUT/lib/
for f in $T/usr/lib/*.so*; do cp -a "$f" $OUT/lib/; done
mkdir -p $OUT/lib/lighttpd $OUT/lib/lua/5.4 $OUT/share/lua/5.4
cp -a $T/usr/lib/lighttpd/*.so $OUT/lib/lighttpd/
cp -a $T/usr/lib/lua/5.4/. $OUT/lib/lua/5.4/
cp -a $T/usr/share/lua/5.4/. $OUT/share/lua/5.4/ 2>/dev/null || true

# 3. Tools
cp -a $T/usr/sbin/lighttpd $OUT/sbin/
cp -a $T/usr/bin/lua $T/usr/bin/openssl $T/usr/bin/rsync $OUT/bin/
cp -a $T/etc/ssl/openssl.cnf $OUT/etc/openssl.cnf

# 4. Our scripts, UI and config (wins over anything above)
cp -a /proj/app/encore/. $OUT/
chmod 755 $OUT/service.sh $OUT/libexec/*
rm -f $OUT/www/.DS_Store

# 5. Relocate every ELF: private loader + rpath into the app
LDSO=$(cd $OUT/lib && ls ld-uClibc.so.* ld-uClibc-*.so 2>/dev/null | head -1)
[ -n "$LDSO" ] || { echo "no ld-uClibc in lib/"; exit 1; }
RPATH="$APP/lib:$APP/lib/private:$APP/lib/samba"
n=0
while IFS= read -r -d '' f; do
  if head -c4 "$f" | grep -q $'\x7fELF'; then
    if $READELF -l "$f" 2>/dev/null | grep -q 'Requesting program interpreter'; then
      $PATCHELF --set-interpreter "$APP/lib/ld-uClibc.so.0" "$f"
    fi
    case "$f" in */lib/ld-uClibc*|*/lib/libc.so*|*/lib/libuClibc*) ;; *)
      $PATCHELF --force-rpath --set-rpath "$RPATH" "$f" ;;
    esac
    n=$((n+1))
  fi
done < <(find $OUT -type f -print0)
echo "relocated $n ELF files (loader $APP/lib/ld-uClibc.so.0)"

# 6. Check every DT_NEEDED is satisfied inside the app
missing=0
libs=$( (cd $OUT && find lib -name '*.so*' -printf '%f\n') | sort -u)
while IFS= read -r -d '' f; do
  head -c4 "$f" | grep -q $'\x7fELF' || continue
  for need in $($READELF -d "$f" 2>/dev/null | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p'); do
    echo "$libs" | grep -qx "$need" || { echo "MISSING $need <- ${f#$OUT/}"; missing=1; }
  done
done < <(find $OUT -type f -print0)
[ $missing = 0 ] && echo "all shared-library dependencies satisfied"

# 7. Highest syscall number referenced is informational only; real check is the qemu test.
du -sh $OUT | sed 's/^/installed size: /'
tar -C $OUT --owner=0 --group=0 -czf /proj/dist/encore.tgz .
ls -la /proj/dist/encore.tgz
EOS
