# DroboFS `nasd` management protocol (as used by Drobo Dashboard)

Recovered from `/usr/bin/nasd` in firmware 1.2.7 (ARM ELF, sha256
`52f717bc…46c8c`) with Ghidra via REA, then confirmed against the live device for
**Get** commands. Function addresses refer to that binary.

## Transport

Two TCP connections from the same client IP:

| Port | Role |
|---|---|
| 5000 | Status channel. On connect nasd sends an `ESATMUpdate` XML document and later updates. Holding this connection open creates the *session*; without it the command port refuses with "No session yet so refusing command connection". |
| 5001 | Command channel (login, then request/response). |

There is **no password authentication** on either port. Anyone on the LAN can issue
commands. (Dashboard asks for the admin password itself.)

## Framing (`FUN_000d9eb8`, `FUN_00025230`)

Every message starts with a 16-byte header:

| Offset | Size | Meaning |
|---|---|---|
| 0 | 8 | Magic: `DRINETTM` (commands) / `DRINASD\0` (status channel) |
| 8 | 1 | Type |
| 9 | 1 | Version, always 1 |
| 10 | 1 | Status (replies; 0 = success) |
| 11 | 1 | 0 |
| 12 | 4 | Payload length, **big-endian** |

## Login (`FUN_00041114`, first branch)

Client → header type `0x07`, then a payload of at least 220 bytes. A NUL-terminated
client ID string sits at offset 20; nasd keeps it as the session key. Use the
device's `mESAID` from the status XML. A second login with the same ID replaces the
first ("existing thread found").

nasd → header type `0x87`, status 0, length 0.

## Commands (header type `0x03`)

Payload: `[0] command code`, `[1..200] client ID (NUL-terminated, must equal the
login ID)`, `[201..] command data`.

Reply: header type `0x83`, status in byte 10 (0 ok, 0xFF failed, 6 out of memory,
2 unknown command), then `length` bytes of body (NUL-terminated XML for Get commands).

| Code | Name | Data | Reply |
|---|---|---|---|
| `0x17` | SetNASConfig | XML (NUL-terminated) | 16 status bytes (`0x01` each on success) |
| `0x18` | GetNASNetworkConfig | – | `DRINasNetworkConfig` |
| `0x19` | GetNASSharesConfig | – | `DRIShareConfig` |
| `0x1a` | GetNASEmailConfig | – | `DRINasEmailAlertConfig` |
| `0x20` | GetNASAdminConfig | – | `DRINasAdminConfig` (password zeroed) |
| `0x21` | GetNASAppsConfig | – | `DRINasDroboAppsConfig` |
| `0x2f` | SendTestEmail | email XML | – |
| `0x29` | GetDeviceConfigInfo | – | 0x27 bytes |

**Never send:** `0x03` (firmware update), `0x16` (device restart after 5 s),
`0x2c` / `0x36` (filesystem repair), `0x2e` (SetFlashConfig), `0x37` (WriteHostData),
`0x2b` (raw ESA command).

Other types: `0x09` → ping (reply `0x89`); `0x04` → "sled" commands
(`0x11` set time, `0x10` authenticate).

## SetNASConfig XML (`FUN_0006819c` = `DNASSetAllConfig`)

The root element picks the section: `DRINasAdminConfig`, `DRIShareConfig`,
`DRINasNetworkConfig`, `DRINasDroboAppsConfig` or `DRINasEmailAlertConfig`.
`<DRINASConfig>` can wrap several of them. Unchanged sections are skipped
("did not change yet it was sent"). nasd backs up `admin.conf` and `shares.conf`,
applies the change (Linux accounts, smbpasswd, Samba/AFP config, share
directories) and reverts on failure.

### `DRIShareConfig`

```xml
<DRIShareConfig>
  <ConfigVersionBasis>15</ConfigVersionBasis>   <!-- must equal current, else rejected -->
  <UserList>
    <User>
      <Username>alice</Username>
      <Password>…</Password>
      <ValidPassword>0|1</ValidPassword>         <!-- 0: keep existing password -->
      <EncryptedPassword>0|1</EncryptedPassword> <!-- 0: Password is plaintext -->
    </User>
  </UserList>
  <Shares>
    <Share>
      <ShareName>Media</ShareName>
      <OldShareName>Movies</OldShareName>        <!-- only when renaming -->
      <ShareState>0</ShareState>
      <TimeMachineEnabled>0|1</TimeMachineEnabled>
      <ShareMaxTMSizeGB>0.000000</ShareMaxTMSizeGB>
      <ShareUsers>
        <ShareUser>
          <ShareUsername>alice | Everyone</ShareUsername>
          <ShareUserAccess>1|0</ShareUserAccess>  <!-- 1 = read/write ("RW"), 0 = read-only ("RO") -->
        </ShareUser>
      </ShareUsers>
    </Share>
  </Shares>
  <UserDeleteConfirm>1</UserDeleteConfirm>       <!-- required when a user is removed -->
  <ShareDeleteConfirm>1</ShareDeleteConfirm>     <!-- required when a share is removed -->
</DRIShareConfig>
```

Password handling (`FUN_00059eb4`): if `ValidPassword` is 1, nasd takes
`Password`, decodes it when `EncryptedPassword` is 1, re-encodes it with its storage
key and stores it. Get commands always return `ValidPassword=0`, so echoing a user
back unchanged keeps the password.

**Always send `EncryptedPassword=1`, as Dashboard does.** With `EncryptedPassword=0`,
nasd re-encodes the password in its document but leaves the flag at 0, then later
feeds the *encoded* string to `/usr/bin/passwd` as if it were plaintext. That hung
nasd's apply thread on the live device (it needed a power cycle). Plaintext is also
written to `/var/log/nasd.log` ("Received XML for setting").

### Password encoding (`UCrypto`, `FUN_000fe798` / `FUN_000fe670` / `FUN_000fe4f0`)

1. Block = `len & 0xff`, `len >> 8`, password bytes.
2. Pad to 128 bytes (doubling if longer) with a fixed 128-byte table at `0x17203c`.
3. XOR every byte with a repeating 16-byte key.
4. Base64 (128 bytes give 172 characters).

Keys:
- **Sent to nasd (Dashboard key):** `mESAID` characters 4–12 (9 bytes) followed by
  `57 77 61 15 39 49 75` (`DAT_001583af`). The ID comes from the port-5000 status XML.
- **Stored in `shares.conf`/`admin.conf`:** the 16-hex-character `DNASDiskPackId`.
  Anyone with root on the device can therefore recover user passwords.

This is obfuscation, not encryption. Verified on the device by decoding the stored
passwords with the disk-pack key (lengths and padding check out) and by confirming
the NT hash Samba stores after a set.

### Side effects of every apply

- nasd deletes and re-creates **all** Linux accounts it manages, rebuilding
  `/etc/passwd` from its own list. Accounts other DroboApps added (OpenSSH's
  `sshd`) disappear and sshd then resets every connection. Encore's watcher
  restores them (`libexec/accounts.sh`).
- nasd restarts Samba and AFP. A user change takes about 25 s on the Drobo FS.
- On user delete, nasd leaves the user's Samba (`passdb.tdb`) entry behind.
- nasd decides whether Samba is running from `/proc/<pid>/cmdline` of the pid file
  and expects `/sbin/smbd`; with Encore it reports "not running" and restarts it
  through the wrapper, which is harmless.

Deleted shares are moved to `System/DNAS/deleted_shares/` and removed in the
background.

## Status XML (port 5000, `ESATMUpdate`)

Useful fields: `mName`, `mVersion`, `mESAID`, `mStatus`, `mTotalCapacityProtected`,
`mUsedCapacityProtected`, `mFreeCapacityProtected`, `mYellowThreshold` /
`mRedThreshold` (basis points), `mSlotCountExp`, and per slot `mSlotsExp/nN/{mSlotNumber,
mStatus, mPhysicalCapacity}`, `DNASStatus` (6 = shares online).
