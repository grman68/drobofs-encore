#!/bin/sh
# Encore DroboApp: Samba 4 (SMB2/SMB3) + web admin for the DroboFS.
#
# Nothing here writes to the firmware flash. Stock Samba is replaced by
# bind-mounting wrappers over /sbin/smbd and /sbin/nmbd; the mounts disappear
# on reboot or on "service.sh stop", which restores stock Samba 3.4.
#
# Usage: service.sh start|stop|restart|status|samba-on|samba-off|reload

. /mnt/DroboFS/Shares/DroboApps/encore/libexec/common.sh

ensure_dirs() {
  mkdir -p "$VAR/etc" "$VAR/log" "$VAR/run" "$VAR/tmp" "$VAR/ssl" "$VAR/sessions" \
           "$VAR/samba/private" "$VAR/samba/lock" "$VAR/samba/state" \
           "$VAR/samba/cache" "$VAR/samba/ncalrpc" "$VAR/avahi"
  chmod 700 "$VAR/sessions" "$VAR/samba/private" "$VAR/ssl"
}

# Make sure our ARM binaries actually run on this kernel before we swap anything.
selftest() {
  "$APP/sbin/smbd" -V > "$VAR/run/selftest.out" 2>&1 || return 1
  "$APP/bin/lua" -e 'require("cjson"); require("posix.unistd")' >> "$VAR/run/selftest.out" 2>&1 || return 1
  return 0
}

gen_conf() {
  "$APP/bin/lua" "$APP/share/encore/smbconf.lua" >> "$LOG" 2>&1
}

# Stop whichever Samba is running (stock 3.4 or ours), by pid file first.
kill_samba() {
  for f in smbd smbd-smb.conf nmbd nmbd-smb.conf samba-dcerpcd; do
    [ -f "$SAMBA_SEC/$f.pid" ] && kill -9 "$(cat "$SAMBA_SEC/$f.pid")" 2>/dev/null
    rm -f "$SAMBA_SEC/$f.pid"
  done
  killall -KILL smbd nmbd samba-dcerpcd rpcd_classic rpcd_lsad rpcd_winreg \
    rpcd_epmapper rpcd_fsrvp rpcd_mdssvc rpcd_rpcecho rpcd_spoolss 2>/dev/null
  sleep 1
}

samba_takeover() {
  load_settings
  [ "$SMB_ENABLED" = "1" ] || { log "SMB disabled in settings; leaving stock Samba"; return 0; }
  gen_conf || { log "smb.conf generation failed; leaving stock Samba"; return 1; }
  "$APP/bin/testparm" -s "$GEN_SMB_CONF" > "$VAR/run/testparm.out" 2>&1 || {
    log "testparm rejected generated config; leaving stock Samba (see var/run/testparm.out)"; return 1; }

  for d in smbd nmbd; do
    is_bound /sbin/$d || mount -o bind "$APP/libexec/$d-wrap" /sbin/$d
  done
  kill_samba
  # Start through the same path nasd uses, so nasd's pid checks keep working.
  /sbin/smbd -s "$NASD_SMB_CONF"
  [ "$SMB_NETBIOS" = "1" ] && /sbin/nmbd -s "$NASD_SMB_CONF"
  log "Samba 4 started (min=$SMB_MIN_PROTOCOL max=$SMB_MAX_PROTOCOL encrypt=$SMB_ENCRYPT)"
}

samba_release() {
  is_bound /sbin/smbd || is_bound /sbin/nmbd || return 0
  kill_samba
  umount /sbin/smbd 2>/dev/null
  umount /sbin/nmbd 2>/dev/null
  /sbin/smbd -s "$NASD_SMB_CONF"
  /sbin/nmbd -s "$NASD_SMB_CONF"
  log "Restored stock Samba 3.4"
}

ssl_cert() {
  [ -s "$VAR/ssl/server.pem" ] && return 0
  host=$(hostname)
  "$APP/bin/openssl" req -x509 -nodes -days 3650 \
    -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -subj "/CN=$host" -keyout "$VAR/ssl/key.pem" -out "$VAR/ssl/cert.pem" >> "$LOG" 2>&1 || return 1
  cat "$VAR/ssl/key.pem" "$VAR/ssl/cert.pem" > "$VAR/ssl/server.pem"
  chmod 600 "$VAR/ssl/"*.pem
  log "Generated self-signed TLS certificate for $host"
}

web_start() {
  load_settings
  ssl_cert || log "TLS certificate generation failed"
  sed -e "s|@APP@|$APP|g" -e "s|@PORT@|$WEB_PORT|g" -e "s|@TZ@|$TIME_ZONE|g" \
      "$APP/etc/lighttpd.conf.in" > "$VAR/etc/lighttpd.conf"
  # lighttpd daemonizes itself and writes server.pid-file.
  "$APP/sbin/lighttpd" -f "$VAR/etc/lighttpd.conf" -m "$APP/lib/lighttpd" >> "$LOG" 2>&1
  log "Web admin listening on https://$(hostname):$WEB_PORT/"
}

web_stop() {
  [ -f "$VAR/run/lighttpd.pid" ] && kill "$(cat "$VAR/run/lighttpd.pid")" 2>/dev/null
  rm -f "$VAR/run/lighttpd.pid"
}

watcher_start() {
  watcher_stop
  setsid /bin/sh "$APP/libexec/watcher.sh" < /dev/null > /dev/null 2>&1 &
  echo $! > "$VAR/run/watcher.pid"
}

watcher_stop() {
  [ -f "$VAR/run/watcher.pid" ] && kill "$(cat "$VAR/run/watcher.pid")" 2>/dev/null
  rm -f "$VAR/run/watcher.pid"
}

bonjour_start() {
  "$APP/bin/lua" "$APP/share/encore/avahi.lua" >> "$LOG" 2>&1 || return 0
  is_bound /etc/avahi/services || mount -o bind "$VAR/avahi" /etc/avahi/services
  killall -HUP avahi-daemon 2>/dev/null
  return 0
}

bonjour_stop() {
  is_bound /etc/avahi/services || return 0
  umount /etc/avahi/services 2>/dev/null
  killall -HUP avahi-daemon 2>/dev/null
  return 0
}

start() {
  ensure_dirs
  sh "$APP/libexec/accounts.sh" record
  # The firmware gives up on NTP if it fails once at boot; keep trying in the background.
  setsid /bin/sh "$APP/libexec/timesync.sh" boot < /dev/null > /dev/null 2>&1 &
  if selftest; then
    gen_conf
    samba_takeover
    bonjour_start
  else
    log "Self-test failed, not touching Samba: $(cat "$VAR/run/selftest.out" 2>/dev/null | head -3)"
  fi
  web_start
  watcher_start
}

stop() {
  watcher_stop
  web_stop
  bonjour_stop
  samba_release
}

status() {
  pid=$(cat "$SAMBA_SEC/smbd.pid" "$SAMBA_SEC/smbd-smb.conf.pid" 2>/dev/null | head -1)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    if is_bound /sbin/smbd; then echo "samba: encore (Samba 4)"; else echo "samba: stock (Samba 3.4)"; fi
  else echo "samba: stopped"; fi
  if [ -f "$VAR/run/lighttpd.pid" ] && kill -0 "$(cat "$VAR/run/lighttpd.pid")" 2>/dev/null; then
    echo "web: running"; else echo "web: stopped"; fi
}

case "$1" in
  start)     start ;;
  stop)      stop ;;
  restart)   stop; sleep 2; start ;;
  status)    status ;;
  reload)    gen_conf && "$APP/bin/lua" "$APP/share/encore/avahi.lua" >> "$LOG" 2>&1
             killall -HUP smbd nmbd avahi-daemon 2>/dev/null ;;
  samba-on)  ensure_dirs; samba_takeover; bonjour_start ;;
  samba-off) bonjour_stop; samba_release ;;
  web-restart) web_stop; sleep 1; web_start ;;
  *) echo "Usage: $0 start|stop|restart|status|reload|samba-on|samba-off|web-restart"; exit 1 ;;
esac
