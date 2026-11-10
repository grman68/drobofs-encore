# Third-party software

The Encore download (`encore.tgz`) bundles the open-source components below, built with
[Buildroot](https://buildroot.org/) for the Drobo FS. Each stays under its own license.
Encore's own code is under the [GPL v3](LICENSE).

| Component | Version | License |
|---|---|---|
| Samba | 4.23.8 | GPL-3.0+ |
| rsync | 3.4.3 | GPL-3.0+ with exceptions |
| uClibc-ng (C library) | 1.0.57 | LGPL-2.1+ |
| GCC runtime libraries | 14.3.0 | GPL-3.0 with GCC Runtime Library Exception |
| Linux kernel headers (DroboFS 2.6.22.18) | custom | GPL-2.0 |
| OpenSSL | 3.6.2 | Apache-2.0 |
| GnuTLS | 3.8.13 | LGPL-2.1+ (library) |
| Nettle | 3.10.2 | GPL-2.0+ / LGPL-3.0+ |
| GMP | 6.3.0 | LGPL-3.0+ or GPL-2.0+ |
| libtasn1 | 4.21.0 | LGPL-2.1+ (library) |
| libunistring | 1.4.2 | LGPL-3.0+ or GPL-2.0 |
| libiconv | 1.18 | LGPL-2.1+ (library) |
| e2fsprogs (libraries) | 1.47.3 | GPL-2.0; MIT-like (libss, libet) |
| util-linux (libraries) | 2.41.4 | GPL-2.0+, LGPL-2.1+, BSD |
| libtirpc | 1.3.7 | BSD-3-Clause |
| popt | 1.19 | MIT |
| cmocka | 2.0.2 | Apache-2.0 |
| zlib | 1.3.2 | Zlib |
| xxHash | 0.8.3 | BSD-2-Clause (library) |
| lighttpd | 1.4.82 | BSD-3-Clause |
| PCRE2 | 10.47 | BSD-3-Clause |
| Lua | 5.4.8 | MIT |
| lua-cjson | 2.1.0.10-1 | MIT |
| luaposix | 36.3 | MIT |

## Getting the source

Every [release](https://github.com/grman68/drobofs-encore/releases) includes
`encore-<version>-sources.tar`. It holds the exact upstream source archives, every patch
applied to them, the license texts, and a `manifest.csv`, as collected by Buildroot's
`legal-info`. The Buildroot configuration and Encore's own patches that produced the
binaries are in this repository under [`build/`](build), at the release's tag. See
[docs/BUILDING.md](docs/BUILDING.md) to rebuild everything from them.

## Trademarks

Drobo, BeyondRAID and DroboApps are trademarks of their respective owners. Encore is
an independent project, not affiliated with or endorsed by them.
