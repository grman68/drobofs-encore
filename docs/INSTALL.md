# Installing Encore

This guide covers installing Encore on a Drobo FS, signing in for the first time,
upgrading, switching back to stock Samba, uninstalling, and fixing common problems. It
needs no command line. An optional SSH method is at the end.

## Before you start

- **Model and firmware:** this is for the **Drobo FS** only, on firmware **1.2.7**. Drobo
  Dashboard shows the firmware version. If yours is older, update it from Dashboard first.
- **DroboApps:** in Drobo Dashboard, open the Drobo's settings and turn on **DroboApps**.
  This creates a share called `DroboApps`.
- **Admin password:** you'll need the Drobo's admin user name and password, the same ones
  you use for the `DroboApps` share in Dashboard.
- **Backups:** Encore doesn't touch your data or BeyondRAID. Even so, back up anything
  irreplaceable before changing a storage device's software.

## 1. Download

Download **`encore.tgz`** from the
[latest release](https://github.com/grman68/drobofs-encore/releases/latest).

> **Keep the name exactly `encore.tgz`.** The Drobo names the app folder after the file.
> If your browser saves it as `encore (1).tgz`, rename it.
>
> **Safari users:** Safari may unpack `.tgz` files automatically and leave you with
> `encore.tar` or a folder. Either turn off *Safari → Settings → General → Open "safe"
> files after downloading*, use another browser, or download it from Terminal:
>
> ```bash
> curl -LO https://github.com/grman68/drobofs-encore/releases/latest/download/encore.tgz
> ```

To check the download, compare its checksum with `encore.tgz.sha256` on the release page:

```bash
shasum -a 256 encore.tgz
```

## 2. Copy it to the Drobo

Open the Drobo's **DroboApps** share and copy `encore.tgz` into its top level, next to
any other apps.

- **Mac:** in Finder choose *Go → Connect to Server…*, enter `smb://Drobo-FS/DroboApps`
  (use your Drobo's name or IP address), and sign in as the Drobo admin.
- **Windows:** in File Explorer, go to `\\Drobo-FS\DroboApps` and sign in as the Drobo
  admin.

Don't unpack the file. The Drobo does that itself.

## 3. Restart the Drobo

In Drobo Dashboard, restart the Drobo. While it starts up, the firmware unpacks
`encore.tgz` into a `DroboApps/encore` folder, deletes the `.tgz`, and starts Encore.

Encore checks that its programs run on your Drobo before switching anything over. If
that check fails, it leaves the stock Samba in place and starts only the web admin, so
your shares stay available either way.

## 4. Sign in

About **2–3 minutes** after the Drobo is back on the network, open:

```
https://Drobo-FS:8443/
```

Use your Drobo's name or IP address in place of `Drobo-FS`.

1. **Certificate warning:** your browser will warn that the connection isn't private.
   Encore created its own HTTPS certificate on the Drobo, because no public certificate
   authority can issue one for a device on your home network. Choose *Show details →
   visit this website* (Safari) or *Advanced → Proceed* (Chrome). The warning appears
   once per browser.
2. **Sign in** with the Drobo admin name (usually `Admin`) and password.

   You can also sign in as `root`. If the System Info window shows *"The root password
   is still the factory default"*, anyone on your network can sign in as root, here and
   over SSH. Change it soon with `passwd` over SSH.

You should see the Encore desktop with the System Info window open. Under **File
sharing** it should show **Samba 4** with protocols **SMB2_02 → SMB3**.

## 5. Connect your computers

Shares work as before, at the same names, with the same users and passwords.

- **Mac:** the Drobo appears under *Locations* in the Finder sidebar, or use
  `smb://Drobo-FS/`. Macs already connected should disconnect and reconnect once, so
  they negotiate SMB 3.
- **Windows:** `\\Drobo-FS\` as before.

To use the Drobo for **Time Machine**, open *Control Panel → Shared Folders*, edit a
share, and turn on *Time Machine backup destination*. Optionally set a size limit. The
share then appears in *System Settings → General → Time Machine → Add Backup Disk* on
your Macs.

---

## Upgrading

1. Download the new `encore.tgz` and copy it into `DroboApps`, exactly as for an install.
   The existing `encore` folder stays where it is.
2. Restart the Drobo.

The firmware unpacks the new version over the old one. Your settings, certificate and
logs are kept, because they live in `DroboApps/encore/var`, which the download doesn't
contain.

## Switching back to stock Samba

In the web admin, open *Control Panel → File Services* and click **Revert to stock
Samba**. The Drobo's original Samba 3.4 takes over within seconds. The web admin keeps
running, and **Use Samba 4** switches back.

## Uninstalling

1. Revert to stock Samba (above).
2. In the `DroboApps` share, delete the `encore` folder.
3. Restart the Drobo.

Nothing else is left behind. Encore never changed the firmware, and its takeover of Samba
lasts only until the next restart.

## Troubleshooting

**The web admin doesn't load.**
Wait a few minutes after a restart. The Drobo FS is slow to boot, and Encore starts last.
Check that you used `https://` and port `8443`. If it still doesn't load, check that the
`DroboApps/encore` folder exists. If `encore.tgz` is still there unpacked, DroboApps may
be off in Dashboard, or the file name may not be exactly `encore.tgz`.

**Encore's log.**
In the web admin, open *Log Center → Encore*. Without the web admin, the same log is in
the `DroboApps` share at `encore/var/log/encore.log`.

**The web admin says "Stock Samba" instead of Samba 4.**
Either Samba 4 was switched off in *File Services*, or the start-up check failed. The
Encore log says which. Click **Use Samba 4** to try again.

**An old device can't connect any more.**
Encore turns SMB 1 off by default. Devices from before about 2010 (Windows XP, some media
players and printers) may only speak SMB 1. In *File Services*, lower the minimum
protocol, and expect weaker security.

**A user or share change seems slow.**
That's normal. The Drobo's own `nasd` service applies each change by rebuilding every
account and restarting file sharing, which takes about 25 seconds. Encore shows progress
while it waits.

**The clock is wrong.**
*Control Panel → Date & Time* shows the last sync, and **Sync now** retries straight
away. The Drobo needs internet access to reach the NTP servers listed there.

---

## Alternative: install over SSH

If you already run an SSH DroboApp (OpenSSH or Dropbear), you can install without a
restart:

```bash
scp encore.tgz root@Drobo-FS:/mnt/DroboFS/Shares/DroboApps/
ssh root@Drobo-FS
```

Then, on the Drobo:

```bash
/usr/bin/DroboApps.sh install
```

That runs the firmware's own installer, which unpacks every new `.tgz` in `DroboApps` and
starts it. Afterwards, `/mnt/DroboFS/Shares/DroboApps/encore/service.sh status` shows
the state, and `service.sh stop` reverts to stock Samba until the next start.
