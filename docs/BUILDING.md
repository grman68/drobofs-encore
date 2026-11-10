# Building Encore from source

Everything builds inside Docker, so the host only needs Docker. It's developed on macOS
with Docker Desktop; Linux works the same way.

## Requirements

- Docker with at least 8 GB of memory and about 25 GB of free disk space.
- About an hour for the first build. Later builds only rebuild what changed.
- Optional, for the firmware tests: your own copy of Drobo FS firmware `v1.2.7.tdz`.

## Build

```bash
build/build.sh       # toolchain, Samba, lighttpd, Lua, OpenSSL, rsync, ... (first run ~1 hour)
build/package.sh     # -> dist/encore.tgz
```

`build.sh` builds the `drobofs-build` image (Debian bookworm). On the first run it does
three things:

- generates sanitized Linux 2.6.22 headers from
  [droboports/kernel-drobofs](https://github.com/droboports/kernel-drobofs), via
  `make-headers.sh` into `build/dl/`;
- clones Buildroot 2026.02.x;
- builds with `br2-external/configs/drobofs_defconfig`.

Output lives in the Docker volume `drobofs-br`. It's case-sensitive, which the kernel
tree needs, and it's fast. Logs go to `build/logs/`. Any Buildroot target can be passed
through, for example:

```bash
build/build.sh drobo-samba-rebuild
build/build.sh menuconfig
```

`package.sh` collects the binaries and the app (`app/encore`) into one tree. It relocates
every ELF file to the app's private loader and RPATH, checks that every shared-library
dependency is inside the app, and writes `dist/encore.tgz`.

### Install path is compiled in

Samba records its install prefix, `/mnt/DroboFS/Shares/DroboApps/encore`, at build time
(`BR2_PACKAGE_DROBO_SAMBA_PREFIX`). If you change the app's folder name, change that
option and run `build/build.sh drobo-samba-dirclean drobo-samba`.

## Patches for the 2.6.22 kernel

All patches are in `build/br2-external`:

| Package | Patch | Why |
|---|---|---|
| uClibc-ng | `adjtimex` via `__NR_adjtimex` | `clock_adjtime` is 2.6.39+ |
| Samba | tevent: `eventfd(0, 0)` + `fcntl` fallback | `eventfd` flags need `eventfd2` (2.6.27) |
| Samba | guard `FICLONERANGE` | the reflink ioctl is 4.5+ |
| Samba | build cache answers (`drobo-samba-cache.txt`) | cross-compile answers, OFD locks off |
| lighttpd | link-test functions; guard `epoll_create1`/`inotify_init1` | uClibc declares syscalls it doesn't build |
| rsync | build without `linux/openat2.h` | rsync already falls back at runtime |
| kernel headers | `__GLIBC__` guards, `linux/random.h` include | 2007-era header bugs |

## Tests

```bash
(cd tests && docker build -t drobofs-test .)
tests/run-tests.sh
```

`run-tests.sh` makes 51 checks. It installs `dist/encore.tgz` on a fake Drobo under
`qemu-arm` and tests:

- SMB 3 with encryption, Time Machine and the recycle bin;
- the whole web API, from sign-in and settings to switching to stock Samba and back;
- a system-call audit: Samba traced with `qemu-arm -strace`, every call checked against
  the 2.6.22 ARM table in `tests/syscalls-2.6.22-arm.txt`.

With your own copy of the firmware, a second suite runs Encore inside the Drobo's real
root file system:

```bash
tools/extract-firmware.sh v1.2.7.tdz    # once: unpacks the firmware into tests/fw/ (not committed)
tests/run-chroot-tests.sh
```

`run-chroot-tests.sh` makes 26 checks. They include installing through the firmware's own
`DroboApps.sh`, running under BusyBox 1.14 next to stock Samba 3.4, and signing in to the
web admin as a Dashboard user.

## UI preview without a Drobo

```bash
python3 tools/mock_api.py      # http://localhost:8765, sign in as admin / admin
```

The mock serves the real UI from `app/encore/www` with sample data, which is handy for UI
work.

## Making a release

```bash
build/build.sh && build/package.sh
tests/run-tests.sh && tests/run-chroot-tests.sh
build/release.sh 1.0.0
```

`release.sh` writes three files to `dist/`:

- `encore.tgz.sha256`;
- `encore-<version>-sources.tar`, the corresponding source for every bundled component,
  from Buildroot's `legal-info`;
- that archive's checksum.

Attach all of them, together with `encore.tgz`, to a GitHub release tagged `v<version>`.
Keep the asset name `encore.tgz`. The install guide links to
`releases/latest/download/encore.tgz`, and the Drobo names the app folder after the file.
