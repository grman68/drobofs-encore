#!/bin/bash
# Unpack a DroboFS firmware .tdz into its parts, and the Linux root filesystem
# into tests/fw/drobofs-rootfs.tar.gz (used by tests/run-chroot-tests.sh).
#   tools/extract-firmware.sh [firmware.tdz]      (default: ./v1.2.7.tdz)
set -euo pipefail
cd "$(dirname "$0")/.."
TDZ=$(cd "$(dirname "${1:-v1.2.7.tdz}")" && pwd)/$(basename "${1:-v1.2.7.tdz}")
mkdir -p tests/fw
docker run --rm -i -v "$TDZ":/in/fw.tdz:ro -v "$PWD/tests/fw":/out drobofs-test bash -s <<'EOS'
set -euo pipefail
python3 -m venv /tmp/v >/dev/null && /tmp/v/bin/pip -q install jefferson >/dev/null 2>&1
cd /tmp && python3 -c 'import zipfile; zipfile.ZipFile("/in/fw.tdz").extractall("/tmp/tdz")'
TDF=$(ls /tmp/tdz/*.tdf)
python3 - "$TDF" <<'PY'
import struct, sys
d = open(sys.argv[1], 'rb').read()
hdr = struct.unpack('>I', d[0:4])[0]          # header length (0x22c)
# Offsets/sizes from the TDIH component table of v1.2.7 (LXKI, LXFS, VXIM).
parts = {'lxki': (0x0, 0x186724), 'lxfs': (0x300000, 0x1500000), 'vxim': (0x1800000, 0x32f9bf)}
for name, (o, n) in parts.items():
    open(f'/tmp/{name}.bin', 'wb').write(d[hdr + o: hdr + o + n])
    print(f'{name}: {n} bytes')
PY
/tmp/v/bin/jefferson -f -d /tmp/rootfs /tmp/lxfs.bin >/dev/null
tar -C /tmp/rootfs -czf /out/drobofs-rootfs.tar.gz .
cp /tmp/lxki.bin /out/kernel.uImage; cp /tmp/vxim.bin /out/vxworks.uImage
ls -la /out
EOS
