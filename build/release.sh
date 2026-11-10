#!/bin/bash
# Prepare release files in dist/ after build.sh and package.sh:
#   encore.tgz.sha256              checksum of the DroboApp
#   encore-<version>-sources.tar   corresponding source for every bundled component
#                                  (Buildroot legal-info: upstream tarballs, patches,
#                                  license texts, manifest.csv)
#   ./release.sh 1.0.0
set -euo pipefail
cd "$(dirname "$0")"
VER=${1:?usage: release.sh <version>}
[ -f ../dist/encore.tgz ] || { echo "dist/encore.tgz missing: run package.sh first"; exit 1; }

./build.sh legal-info >/dev/null || true
docker run --rm -i -u root -v "$PWD/..":/proj -v drobofs-br:/br drobofs-build bash -s "$VER" <<'EOS'
set -euo pipefail
VER=$1
L=/br/output/legal-info
grep -q 'Legal info produced' /proj/build/logs/build.log || { echo "legal-info failed (see build/logs/build.log)"; exit 1; }
STAGE=/tmp/encore-$VER-sources
mkdir -p $STAGE
cp -a $L/sources $L/licenses $L/manifest.csv $STAGE/
cat > $STAGE/README.txt <<EOF
Encore $VER for the Drobo FS - corresponding source

This archive holds the exact source code, patches and license texts of every
third-party component in encore.tgz, as collected by Buildroot's legal-info:

  manifest.csv   package, version, license, source archive
  sources/       upstream source archives plus the patches applied to them
  licenses/      license texts for each package

Encore's own code and build system (including the Buildroot configuration and
patches used to produce these binaries) are at
https://github.com/grman68/drobofs-encore at tag v$VER.
EOF
tar -C /tmp --owner=0 --group=0 -cf /proj/dist/encore-$VER-sources.tar encore-$VER-sources
cd /proj/dist && sha256sum encore.tgz > encore.tgz.sha256 && sha256sum encore-$VER-sources.tar > encore-$VER-sources.tar.sha256
ls -la /proj/dist
EOS
