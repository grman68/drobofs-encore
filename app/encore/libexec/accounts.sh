#!/bin/sh
# Keep system accounts added by DroboApps (e.g. OpenSSH's "sshd") alive.
#
# Whenever nasd applies a user/share change it rebuilds /etc/passwd from its own
# list and silently drops accounts other DroboApps created; sshd then rejects every
# connection. We remember those accounts and put back the exact lines.
#   accounts.sh record    remember current app accounts (merged with earlier ones)
#   accounts.sh restore   re-add any remembered account that has gone missing
. /mnt/DroboFS/Shares/DroboApps/encore/libexec/common.sh

STORE=$VAR/app-accounts
mkdir -p "$STORE"

# System accounts (0 < uid < 1000) that the firmware itself doesn't define.
app_users() {
  awk -F: '$3 > 0 && $3 < 1000 && $1 != "nobody" && $1 != "avahi" { print $1 }' /etc/passwd
}

record() {
  for u in $(app_users); do
    grep "^$u:" /etc/passwd > "$STORE/$u.passwd"
    grep "^$u:" /etc/group > "$STORE/$u.group" 2>/dev/null
    grep "^$u:" /etc/shadow > "$STORE/$u.shadow" 2>/dev/null
  done
}

# Append one line to a system file atomically (copy, append, rename).
append_line() {
  file=$1; line=$2
  [ -n "$line" ] || return 0
  cp -p "$file" "$file.encore.tmp" && echo "$line" >> "$file.encore.tmp" && mv "$file.encore.tmp" "$file"
}

restore() {
  # nasd is rewriting the account files while this marker exists; wait for it.
  [ -e /var/network/config_update_in_progress ] && return 0
  for f in "$STORE"/*.passwd; do
    [ -f "$f" ] || continue
    u=$(basename "$f" .passwd)
    grep -q "^$u:" /etc/passwd && continue
    append_line /etc/passwd "$(cat "$f")"
    grep -q "^$u:" /etc/group || append_line /etc/group "$(cat "$STORE/$u.group" 2>/dev/null)"
    [ -f /etc/shadow ] && ! grep -q "^$u:" /etc/shadow && append_line /etc/shadow "$(cat "$STORE/$u.shadow" 2>/dev/null)"
    log "Restored system account '$u' that nasd removed from /etc/passwd"
  done
}

case "$1" in
  record)  record ;;
  restore) restore ;;
  *) echo "usage: $0 record|restore"; exit 1 ;;
esac
