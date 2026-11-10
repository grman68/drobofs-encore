# How Encore works

## The Drobo FS, inside

Firmware 1.2.7 ships as `v1.2.7.tdz`, a zip holding `release.DroboNAS.tdf`. That file
contains three images:

| Image | Contents |
|---|---|
| LXKI | Linux 2.6.22.18 uImage for the ARMv5 Feroceon core of the Marvell MV78200 |
| LXFS | JFFS2 root file system: BusyBox 1.14, glibc 2.5, Samba 3.4.4, Netatalk 2, Avahi, `nasd` |
| VXIM | VxWorks image for the second core: the closed BeyondRAID engine |

The two cores share memory. Linux sees the BeyondRAID pool as `/dev/sda1` (ext3, mounted
at `/mnt/DroboFS`) through Drobo's `shared_mem.ko` driver, whose source was never
released. That rules out a modern kernel. Encore therefore runs as an app on the stock
firmware, and everything it ships has to work on Linux 2.6.22.

`nasd` is Drobo's management daemon. It owns users, shares, network and email settings,
writes Samba's and AFP's configuration, and talks to Drobo Dashboard over TCP ports 5000
and 5001.

## Binaries that run on a 2007 kernel

glibc 2.20 and later refuse kernels older than 2.6.32, and Buildroot's Samba package
doesn't support musl. Encore therefore uses **uClibc-ng built against the Drobo's own
2.6.22 kernel headers**, generated from
[droboports/kernel-drobofs](https://github.com/droboports/kernel-drobofs). System calls the
kernel lacks (`pipe2`, `accept4`, `preadv`, OFD locks, `eventfd2`…) are then never compiled
in, and Samba's configure picks its fallbacks. A few patches cover the cases where a
program assumes a newer kernel anyway (see [BUILDING.md](BUILDING.md)).

Every binary is relocated with `patchelf` to use a private loader,
`DroboApps/encore/lib/ld-uClibc.so.0`, and an RPATH inside the app. The firmware's own
glibc libraries are never used or touched.

The test suite runs Samba under `qemu-arm -strace` and checks every system call against
the 2.6.22 ARM table. It also installs the package inside a chroot of the real firmware
root file system.

## Taking over Samba without touching flash

`nasd` starts, stops and configures Samba itself, and expects `/sbin/smbd` and
`/sbin/nmbd`. Encore lets it carry on. At start, `service.sh`:

1. Runs a self-test: `smbd -V` and the Lua runtime must start on this Drobo. If they
   don't, it stops here and leaves stock Samba running.
2. Bind-mounts `libexec/smbd-wrap` and `libexec/nmbd-wrap` over `/sbin/smbd` and
   `/sbin/nmbd`, then restarts Samba. From then on, whenever `nasd` runs "smbd", it gets
   Encore's wrapper.
3. Bind-mounts a generated Avahi services folder over `/etc/avahi/services` to advertise
   SMB, the device icon, and Time Machine shares.

Bind mounts live in memory, so a reboot or `service.sh stop` restores the original
behaviour exactly.

Each time the wrapper runs, `smbconf.lua` generates Samba 4's configuration. It reads the
`smb.conf` that `nasd` wrote, including the files it pulls in with `include`, and keeps
`nasd`'s shares and permissions. On top, it adds Encore's settings (protocols,
encryption, signing, macOS support) and per-share extras (Time Machine, recycle bin,
hidden, encryption).

### Details that make Samba 4 fit

- **Users:** `nasd` keeps them in Samba 3.4's `passdb.tdb`. Samba 4 reads a copy in
  `var/samba/private`, refreshed whenever the original changes, so the original is never
  upgraded or rewritten.
- **PID files:** `nasd` checks Samba by pid file name. Encore links Samba 4's pid file to
  the name `nasd` expects.
- **Mac metadata:** the ext3 here has no extended attributes, so streams (Finder tags,
  resource forks) are stored with `vfs_streams_depot` in a hidden `.streams` folder per
  share. `streams_depot:check_valid = no` is set, because the usual xattr marker can't be
  stored.
- **RPC start-up time:** Samba 4's RPC helper programs take several seconds to start on
  this CPU, long enough for a Finder share listing to time out. Encore keeps
  `samba-dcerpcd` running with one warm worker each for `rpcd_classic`, `rpcd_winreg`,
  `rpcd_lsad` and `rpcd_epmapper`, and turns off on-demand helpers.
- **Old-kernel workarounds:** tevent falls back to `eventfd(0, 0)` plus `fcntl`, because
  `eventfd` with flags needs 2.6.27.

## Managing the Drobo through `nasd`

Encore doesn't edit `nasd`'s files directly. `nasd` would overwrite them, and Dashboard
would disagree. Instead, `nasd.lua` speaks the same protocol Dashboard uses, recovered
from the firmware and documented in [nasd-protocol.md](nasd-protocol.md):

- Port 5000 carries status XML. Holding it open creates the session that port 5001
  requires.
- Port 5001 carries commands: log in with the device ID, read a configuration section,
  send it back modified.
- Passwords are sent encoded the way Dashboard encodes them.

Applying a change takes `nasd` about 25 seconds, so the web API runs it as a background
job (`nasjob.lua`) and the UI shows progress. A watchdog kills a `passwd` or `smbpasswd`
child of `nasd` that hangs for more than 4 minutes.

`nasd` rebuilds `/etc/passwd` from its own user list on every change, which drops
accounts other DroboApps created (for example OpenSSH's `sshd`, after which SSH resets
every connection). `accounts.sh` records those accounts at start, and the watcher puts
them back after each change.

## The clock

The Drobo FS's real-time clock doesn't keep time (it reads 1969 after power loss). The
firmware runs `ntpclient` once at boot, often before the network is ready.
`libexec/timesync.sh`:

- at start, tries each configured NTP server every minute for up to 30 minutes;
- re-syncs hourly from the watcher, and on demand from *Date & Time → Sync now*;
- measures the offset first and sets the clock only if it's off by half a second or more
  (or the year is implausible), then confirms the result is within 2 seconds;
- logs corrections of one second or more.

Encore's logs and the web admin use the time zone set in *Date & Time*. The firmware's
own logs stay on its hard-coded Pacific time.

## The web admin

`lighttpd` serves the UI over HTTPS on port 8443 with a self-signed certificate created
on first start. The UI is plain HTML, CSS and JavaScript with no dependencies:
`www/index.html`, `www/app.css` and `www/app.js`, styled as a desktop with windows.

The API is a single Lua CGI script, `www/cgi/api.lua`:

- **Sign-in:** checks `root` against `/etc/shadow`, and users listed in *Admin users*
  against their Samba NT hash.
- **Sessions:** 64-character random IDs in `var/sessions`, sent as an `HttpOnly`,
  `Secure`, `SameSite=Strict` cookie that lasts 12 hours.
- **CSRF protection:** every request that changes something must carry an `X-Encore: 1`
  header.

## File layout

```
DroboApps/encore/
  service.sh            start | stop | restart | status | reload | samba-on | samba-off | web-restart
  bin/ sbin/ lib/       Samba 4, lighttpd, Lua, OpenSSL, rsync and their libraries
  libexec/
    common.sh           shared paths and settings loader
    smbd-wrap nmbd-wrap bind-mounted over /sbin/smbd and /sbin/nmbd
    watcher.sh          reacts to config changes, restores accounts, hourly clock sync
    accounts.sh         records/restores other DroboApps' system accounts
    timesync.sh         NTP with retries and verification
    samba/              Samba's helper programs (samba-dcerpcd, rpcd_*)
  share/encore/
    encore.lua          shared helpers (settings, JSON, files, nasd's smb.conf)
    smbconf.lua         generates Samba 4's configuration
    avahi.lua           generates Bonjour service records
    nasd.lua            the nasd protocol (framing, XML, password encoding)
    nasmgr.lua          users, shares, network, email via nasd
    nasjob.lua          runs nasd changes in the background
  www/                  the web UI and API
  etc/defaults.conf     default settings (do not edit)
  var/                  everything that changes; kept across upgrades
    settings.conf       settings saved from the web admin
    shares.json         per-share extras (Time Machine, recycle bin, ...)
    ssl/                HTTPS certificate
    samba/              Samba 4 state, including the passdb copy
    log/                encore.log, samba.log, lighttpd.log
    jobs/ sessions/     background nasd jobs and web sign-in sessions
```
