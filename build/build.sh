#!/bin/bash
# Run the Buildroot build inside Docker. Output lives in the "drobofs-br" volume
# (case-sensitive, fast); logs go to build/logs/. The first run also generates the
# DroboFS 2.6.22 kernel headers (make-headers.sh -> build/dl/).
#   ./build.sh            full build
#   ./build.sh <target>   e.g. ./build.sh drobo-samba-rebuild
set -euo pipefail
cd "$(dirname "$0")"
BR_BRANCH=2026.02.x
mkdir -p logs dl
docker build -q -t drobofs-build . >/dev/null
docker run --rm -u root \
  -v "$PWD":/work \
  -v drobofs-br:/br \
  -e BR2_DL_DIR=/br/dl \
  drobofs-build bash -c "
    set -e
    [ -f /work/dl/linux-2.6.22.18-drobofs.tar.gz ] || bash /work/make-headers.sh /work/dl
    [ -d /br/buildroot ] || git clone -q --depth 1 -b $BR_BRANCH https://gitlab.com/buildroot.org/buildroot.git /br/buildroot
    cd /br/buildroot
    [ -f /br/output/.config ] || make -s O=/br/output BR2_EXTERNAL=/work/br2-external drobofs_defconfig
    make O=/br/output ${*:-}
  " 2>&1 | tee logs/build.log | grep --line-buffered -E '^>>> |Error|error:' 
