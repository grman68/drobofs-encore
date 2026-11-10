#!/bin/sh
# Keep the Drobo's clock right. The firmware tries NTP exactly once at boot
# (often before the network/DNS is ready) and then leaves the clock wrong.
#   timesync.sh once     try each server once; exit 0 on success
#   timesync.sh boot     retry every minute for up to 30 minutes until it works
. /mnt/DroboFS/Shares/DroboApps/encore/libexec/common.sh
load_settings

STATE=$VAR/run/timesync.json
SERVERS=${NTP_SERVERS:-pool.ntp.org time.apple.com time.google.com}

# Run ntpclient (extra args first) against one server with a hard 20 s limit
# (BusyBox has no timeout). Output is one stats line per probe:
#   day second elapsed stall skew(us) dispersion freq
ntp() {
  out=$VAR/run/ntpclient.out
  ( /bin/ntpclient "$@" > "$out" 2>&1 ) &
  pid=$!
  n=0
  while kill -0 $pid 2>/dev/null; do
    n=$((n + 1)); [ $n -gt 20 ] && { kill $pid 2>/dev/null; return 1; }
    sleep 1
  done
  awk 'NF >= 7 && $1 ~ /^[0-9]+$/ { found = 1 } END { exit !found }' "$out"
}

# Offset of our clock from the server in whole milliseconds (absolute value),
# capped at 1e9 ms (11.5 days) so BusyBox's 32-bit shell arithmetic can't overflow.
offset_ms() {
  ntp -c 1 -h "$1" || return 1
  awk 'NF >= 7 && $1 ~ /^[0-9]+$/ { s = $5 / 1000; if (s < 0) s = -s; if (s > 1e9) s = 1e9; printf "%d", s; exit }' "$VAR/run/ntpclient.out"
}

# Check our offset against a server; set the clock only when it is off by
# half a second or more, then confirm it really is within 2 s.
# Leaves the offset before (pre_ms) and after (ms) in milliseconds.
try_server() {
  pre_ms=$(offset_ms "$1") || return 1
  [ -n "$pre_ms" ] || return 1
  ms=$pre_ms
  # Close enough already, unless the year says the clock was never set (dead RTC reads 1969).
  [ "$pre_ms" -lt 500 ] && [ "$(date +%Y)" -ge 2025 ] && return 0
  ntp -s -c 1 -h "$1" || return 1
  ms=$(offset_ms "$1") || return 1
  [ -n "$ms" ] && [ "$ms" -lt 2000 ]
}

once() {
  # Only one sync at a time (boot retries, hourly watcher, "Sync now").
  mkdir "$VAR/run/timesync.lock" 2>/dev/null || return 0
  trap 'rmdir "$VAR/run/timesync.lock" 2>/dev/null' EXIT
  for s in $SERVERS; do
    case "$s" in *[!A-Za-z0-9.:-]*) continue ;; esac   # ignore anything that isn't a host name
    if try_server "$s"; then
      echo "{\"ok\":true,\"server\":\"$s\",\"at\":$(date +%s),\"corrected_ms\":$pre_ms,\"offset_ms\":$ms}" > "$STATE"
      # Only log real corrections (a second or more), not every hourly no-op.
      if [ "$pre_ms" -ge 1000000000 ]; then log "Clock was off by more than 11 days; set from $s"
      elif [ "$pre_ms" -ge 1000 ]; then log "Clock was off by $((pre_ms / 1000)).$((pre_ms % 1000 / 100)) s; set from $s"; fi
      return 0
    fi
  done
  echo "{\"ok\":false,\"at\":$(date +%s),\"servers\":\"$SERVERS\"}" > "$STATE"
  return 1
}

case "$1" in
  once) once ;;
  boot)
    i=0
    while [ $i -lt 30 ]; do
      once && exit 0
      i=$((i + 1)); sleep 60
    done
    log "Could not reach any NTP server ($SERVERS) after 30 minutes"
    exit 1 ;;
  *) echo "usage: $0 once|boot"; exit 1 ;;
esac
