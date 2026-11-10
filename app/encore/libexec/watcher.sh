#!/bin/sh
# Keeps Samba 4's config in step with nasd (Drobo Dashboard share edits) and
# with settings saved from the web UI, and restarts the web server if it dies.
. /mnt/DroboFS/Shares/DroboApps/encore/libexec/common.sh

sig() {
  stat -c '%Y:%s' "$NASD_SMB_CONF" /etc/.backup_smb.conf /var/samba/netbios.conf \
    "$SAMBA_SEC/passdb.tdb" "$VAR/settings.conf" "$VAR/shares.json" 2>/dev/null | tr '\n' ' '
}
last=$(sig)
ticks=0
while true; do
  sleep 5
  # nasd drops DroboApp system accounts (e.g. sshd) whenever it applies changes.
  sh "$APP/libexec/accounts.sh" restore
  # Re-sync the clock about once an hour (720 x 5 s).
  ticks=$((ticks + 1))
  if [ $ticks -ge 720 ]; then ticks=0; sh "$APP/libexec/timesync.sh" once >/dev/null 2>&1; fi
  now=$(sig)
  if [ "$now" != "$last" ]; then
    last=$now
    if is_bound /sbin/smbd; then
      "$APP/bin/lua" "$APP/share/encore/smbconf.lua" >> "$LOG" 2>&1 && killall -HUP smbd 2>/dev/null
      "$APP/bin/lua" "$APP/share/encore/avahi.lua" >> "$LOG" 2>&1 && killall -HUP avahi-daemon 2>/dev/null
      log "Configuration changed; Samba reloaded"
    fi
  fi
  if [ -f "$VAR/run/lighttpd.pid" ] && ! kill -0 "$(cat "$VAR/run/lighttpd.pid")" 2>/dev/null; then
    log "Web server exited; restarting"
    "$APP/sbin/lighttpd" -f "$VAR/etc/lighttpd.conf" -m "$APP/lib/lighttpd" >> "$LOG" 2>&1
  fi
done
