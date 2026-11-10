# Shared environment for Encore shell scripts. Sourced, not executed.
APP=/mnt/DroboFS/Shares/DroboApps/encore
DRI=/mnt/DroboFS
NASD_SMB_CONF=$DRI/System/samba/conf/smb.conf
SAMBA_SEC=$DRI/System/samba/security
VAR=$APP/var
GEN_SMB_CONF=$VAR/etc/smb.conf
LOG=$VAR/log/encore.log

PATH=$APP/bin:$APP/sbin:/bin:/sbin:/usr/bin:/usr/sbin
LUA_PATH="$APP/share/encore/?.lua;$APP/share/lua/5.4/?.lua;$APP/share/lua/5.4/?/init.lua"
LUA_CPATH="$APP/lib/lua/5.4/?.so"
OPENSSL_CONF=$APP/etc/openssl.cnf
ENCORE_APP=$APP
export PATH LUA_PATH LUA_CPATH OPENSSL_CONF ENCORE_APP

log() {
  mkdir -p "$VAR/log"
  echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"
}

# Load defaults, then the user's saved settings (var/ survives app upgrades).
load_settings() {
  . "$APP/etc/defaults.conf"
  [ -f "$VAR/settings.conf" ] && . "$VAR/settings.conf"
  [ -n "$TIME_ZONE" ] && { TZ=$TIME_ZONE; export TZ; }
}
# Encore's own logs use the configured time zone (the firmware's is hard-coded Pacific).
load_settings

# True if $1 is a mount point (also matches /usr/sbin/x when /sbin is a symlink).
is_bound() { grep -qE " ($1|/usr$1) " /proc/mounts; }
