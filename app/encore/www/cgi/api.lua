-- Encore web API (CGI, run by lighttpd as /api/<route>).
-- All responses are JSON. Non-GET requests require the X-Encore header (CSRF guard).
local R = require("encore")
local json = R.json
local posix_ok, unistd = pcall(require, "posix.unistd")

local APP, VAR = R.APP, R.VAR
local SESS_DIR = VAR .. "/sessions"
local SESSION_TTL = 12 * 3600

---------------------------------------------------------------------------
-- HTTP plumbing
---------------------------------------------------------------------------
local method = os.getenv("REQUEST_METHOD") or "GET"
local route = (os.getenv("PATH_INFO") or ""):gsub("^/+", ""):gsub("/+$", "")
local query = {}
for k, v in (os.getenv("QUERY_STRING") or ""):gmatch("([^&=]+)=?([^&]*)") do
  query[k] = v:gsub("+", " "):gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
end

local extra_headers = {}
local function respond(status, body)
  io.write("Status: ", status, "\r\n")
  io.write("Content-Type: application/json\r\n")
  io.write("Cache-Control: no-store\r\n")
  for _, h in ipairs(extra_headers) do io.write(h, "\r\n") end
  io.write("\r\n", json.encode(body))
  os.exit(0)
end
local function ok(body) respond("200 OK", body or { ok = true }) end
local function fail(status, msg) respond(status, { error = msg }) end

local function read_body()
  local n = tonumber(os.getenv("CONTENT_LENGTH") or "0") or 0
  if n <= 0 then return {} end
  if n > 65536 then fail("413 Payload Too Large", "Request too large") end
  local raw = io.read(n) or ""
  local okj, v = pcall(json.decode, raw)
  if not okj or type(v) ~= "table" then fail("400 Bad Request", "Invalid JSON") end
  return v
end

if method ~= "GET" and os.getenv("HTTP_X_ENCORE") ~= "1" then
  fail("403 Forbidden", "Missing X-Encore header")
end

---------------------------------------------------------------------------
-- Crypto helpers: MD4 for Samba NT hashes, random tokens
---------------------------------------------------------------------------
local function md4(msg)
  local function rotl(x, n) x = x & 0xffffffff; return ((x << n) | (x >> (32 - n))) & 0xffffffff end
  local function F(x, y, z) return (x & y) | ((~x) & z) end
  local function G(x, y, z) return (x & y) | (x & z) | (y & z) end
  local function H(x, y, z) return x ~ y ~ z end
  local len = #msg
  msg = msg .. "\128" .. string.rep("\0", (55 - len) % 64) .. string.pack("<I8", len * 8)
  local A, B, C, D = 0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476
  for i = 1, #msg, 64 do
    local X = { string.unpack(string.rep("I4", 16, ""), msg, i) }
    local a, b, c, d = A, B, C, D
    local function r1(p, q, r, s, k, n) return rotl(p + F(q, r, s) + X[k + 1], n) end
    local function r2(p, q, r, s, k, n) return rotl(p + G(q, r, s) + X[k + 1] + 0x5a827999, n) end
    local function r3(p, q, r, s, k, n) return rotl(p + H(q, r, s) + X[k + 1] + 0x6ed9eba1, n) end
    for _, k in ipairs({ 0, 4, 8, 12 }) do
      a = r1(a, b, c, d, k, 3); d = r1(d, a, b, c, k + 1, 7)
      c = r1(c, d, a, b, k + 2, 11); b = r1(b, c, d, a, k + 3, 19)
    end
    for _, k in ipairs({ 0, 1, 2, 3 }) do
      a = r2(a, b, c, d, k, 3); d = r2(d, a, b, c, k + 4, 5)
      c = r2(c, d, a, b, k + 8, 9); b = r2(b, c, d, a, k + 12, 13)
    end
    for _, k in ipairs({ 0, 2, 1, 3 }) do
      a = r3(a, b, c, d, k, 3); d = r3(d, a, b, c, k + 8, 9)
      c = r3(c, d, a, b, k + 4, 11); b = r3(b, c, d, a, k + 12, 15)
    end
    A = (A + a) & 0xffffffff; B = (B + b) & 0xffffffff
    C = (C + c) & 0xffffffff; D = (D + d) & 0xffffffff
  end
  return string.pack("<I4I4I4I4", A, B, C, D)
end

local function utf16le(s)
  local out = {}
  for _, c in utf8.codes(s) do
    if c < 0x10000 then
      out[#out + 1] = string.pack("<I2", c)
    else
      c = c - 0x10000
      out[#out + 1] = string.pack("<I2I2", 0xD800 | (c >> 10), 0xDC00 | (c & 0x3FF))
    end
  end
  return table.concat(out)
end

local function hex(s) return (s:gsub(".", function(ch) return string.format("%02X", ch:byte()) end)) end

local function nt_hash(password) return hex(md4(utf16le(password))) end

local function random_hex(nbytes)
  local f = assert(io.open("/dev/urandom", "rb"))
  local b = f:read(nbytes)
  f:close()
  return hex(b):lower()
end

local function const_eq(a, b)
  if #a ~= #b then return false end
  local r = 0
  for i = 1, #a do r = r | (a:byte(i) ~ b:byte(i)) end
  return r == 0
end

---------------------------------------------------------------------------
-- Accounts (owned by nasd / Drobo Dashboard; read-only here)
---------------------------------------------------------------------------
local function smb_users()
  local users = {}
  local src
  if R.uses_tdbsam() then
    R.sync_passdb()
    src = R.capture(string.format("%s/bin/pdbedit -L -w -s %s", APP, R.sh_quote(R.GEN_SMB_CONF)))
  else
    src = R.read_file(R.SMBPASSWD) or ""
  end
  for line in src:gmatch("[^\n]+") do
    local name, uid, _, nt, flags, lct = line:match("^([^:]+):(%d+):([^:]*):([^:]*):%[([^%]]*)%]:([^:]*):")
    if name then
      local t = tonumber((lct or ""):match("LCT%-(%x+)") or "", 16)
      users[#users + 1] = {
        name = name, uid = tonumber(uid), nt = nt,
        disabled = flags:find("D", 1, true) ~= nil,
        no_password = flags:find("N", 1, true) ~= nil,
        changed = t,
      }
    end
  end
  return users
end

local function admin_list(S)
  local t = {}
  for u in (S.ADMIN_USERS or ""):gmatch("[^,%s]+") do t[u:lower()] = true end
  return t
end

local function root_crypt()
  for line in (R.read_file("/etc/passwd") or ""):gmatch("[^\n]+") do
    local h = line:match("^root:([^:]*):")
    if h then return h end
  end
end

-- md5-crypt via the bundled openssl; password goes over stdin, never argv.
local function md5crypt(password, salt)
  local tmp = VAR .. "/tmp/pw." .. random_hex(8)
  local f = io.open(tmp, "wb")
  if not f then return nil end
  f:write(password, "\n")
  f:close()
  os.execute("chmod 600 " .. R.sh_quote(tmp))
  local out = R.capture(string.format("%s/bin/openssl passwd -1 -salt %s -stdin < %s",
    APP, R.sh_quote(salt), R.sh_quote(tmp)))
  os.remove(tmp)
  return R.trim(out)
end

local function check_password(user, password)
  if user == "root" then
    local h = root_crypt()
    local salt = h and h:match("^%$1%$([^$]*)%$")
    if not salt then return false end
    local c = md5crypt(password, salt)
    return c ~= nil and const_eq(c, h)
  end
  for _, u in ipairs(smb_users()) do
    if u.name:lower() == user:lower() and not u.disabled and #u.nt == 32 then
      return const_eq(nt_hash(password), u.nt:upper())
    end
  end
  return false
end

local function root_default_password()
  local h = root_crypt()
  local salt = h and h:match("^%$1%$([^$]*)%$")
  return salt ~= nil and md5crypt("root", salt) == h
end

---------------------------------------------------------------------------
-- Sessions
---------------------------------------------------------------------------
local function cookie(name)
  local c = os.getenv("HTTP_COOKIE") or ""
  return c:match("%f[%w_]" .. name .. "=([%w]+)")
end

local function session()
  local sid = cookie("encore_sid")
  if not sid or not sid:match("^%x+$") or #sid ~= 64 then return nil end
  local path = SESS_DIR .. "/" .. sid
  local data = R.read_file(path)
  if not data then return nil end
  local user, exp = data:match("^([^\n]+)\n(%d+)")
  if not user or tonumber(exp) < os.time() then os.remove(path) return nil end
  R.write_file(path, user .. "\n" .. (os.time() + SESSION_TTL) .. "\n", "600")
  return { sid = sid, user = user }
end

local function require_auth()
  local s = session()
  if not s then fail("401 Unauthorized", "Not signed in") end
  return s
end

-- Simple lockout: 5 failures within 5 minutes blocks logins for 5 minutes.
local LOCK = VAR .. "/run/login-failures"
local function failures()
  local n, t = (R.read_file(LOCK) or ""):match("(%d+) (%d+)")
  n, t = tonumber(n) or 0, tonumber(t) or 0
  if os.time() - t > 300 then n = 0 end
  return n, t
end

---------------------------------------------------------------------------
-- System facts
---------------------------------------------------------------------------
local function read_meminfo()
  local m = {}
  for k, v in (R.read_file("/proc/meminfo") or ""):gmatch("(%w+):%s+(%d+)") do m[k] = tonumber(v) end
  return m
end

local function cpu_counters()
  local line = (R.read_file("/proc/stat") or ""):match("^cpu%s+([^\n]+)")
  local v = {}
  for n in (line or ""):gmatch("%d+") do v[#v + 1] = tonumber(n) end
  local idle = (v[4] or 0) + (v[5] or 0)
  local total = 0
  for _, n in ipairs(v) do total = total + n end
  return { total = total, idle = idle }
end

local function net_counters()
  local out = {}
  for line in (R.read_file("/proc/net/dev") or ""):gmatch("[^\n]+") do
    local name, rest = line:match("^%s*([%w%.:]+):%s*(.*)$")
    if name and name ~= "lo" then
      local f = {}
      for n in rest:gmatch("%d+") do f[#f + 1] = tonumber(n) end
      out[name] = { rx = f[1], tx = f[9] }
    end
  end
  return out
end

local function disk_counters()
  for line in (R.read_file("/proc/diskstats") or ""):gmatch("[^\n]+") do
    local f = {}
    for w in line:gmatch("%S+") do f[#f + 1] = w end
    if f[3] == "sda" then
      return { read_sectors = tonumber(f[6]), write_sectors = tonumber(f[10]) }
    end
  end
  return {}
end

local function interfaces()
  local list, cur = {}, nil
  for line in R.capture("ifconfig"):gmatch("[^\n]*") do
    local name, mac = line:match("^(%S+)%s+Link encap:%S+%s*HWaddr%s+(%S+)")
    local name2 = line:match("^(%S+)%s+Link")
    if name or name2 then
      cur = { name = name or name2, mac = mac }
      if cur.name ~= "lo" then list[#list + 1] = cur end
    elseif cur then
      local ip = line:match("inet addr:(%S+)")
      if ip then cur.ip = ip; cur.mask = line:match("Mask:(%S+)") end
      local mtu = line:match("MTU:(%d+)")
      if mtu then cur.mtu = tonumber(mtu); cur.up = line:find("UP", 1, true) ~= nil end
    end
  end
  return list
end

local function volume()
  for line in R.capture("df -k " .. R.DRI):gmatch("[^\n]+") do
    local total, used, avail = line:match("%s(%d+)%s+(%d+)%s+(%d+)%s+%d+%%")
    if total then
      return { total = tonumber(total) * 1024, used = tonumber(used) * 1024, free = tonumber(avail) * 1024 }
    end
  end
  return nil
end

local PIDFILES = {
  smbd = { R.SAMBA_SEC .. "/smbd.pid", R.SAMBA_SEC .. "/smbd-smb.conf.pid" },
  nmbd = { R.SAMBA_SEC .. "/nmbd.pid", R.SAMBA_SEC .. "/nmbd-smb.conf.pid" },
  afpd = { R.DRI .. "/System/netatalk/security/afpd.pid" },
  ["avahi-daemon"] = { "/var/run/avahi-daemon/pid" },
  dropbear = { "/var/run/dropbear.pid" },
  sshd = { R.DRI .. "/Shares/DroboApps/openssh/var/run/sshd.pid" },
}

-- Prefer pid files (reliable), fall back to pidof.
local function running(name)
  for _, f in ipairs(PIDFILES[name] or {}) do
    local pid = tonumber((R.read_file(f) or ""):match("%d+"))
    if pid and R.file_exists("/proc/" .. pid .. "/stat") then return true end
  end
  return R.capture("pidof " .. name):match("%d") ~= nil
end

-- SSH can come from the OpenSSH DroboApp (sshd) or the firmware's Dropbear.
local APPS_DIR = R.DRI .. "/Shares/DroboApps"
local function ssh_service()
  if running("sshd") then return { id = "ssh", name = "SSH (OpenSSH DroboApp)", running = true } end
  if running("dropbear") then return { id = "ssh", name = "SSH (Dropbear)", running = true } end
  local installed = R.file_exists(APPS_DIR .. "/openssh/service.sh") and "OpenSSH DroboApp"
    or R.file_exists(APPS_DIR .. "/dropbear/service.sh") and "Dropbear DroboApp" or "not installed"
  return { id = "ssh", name = "SSH (" .. installed .. ")", running = false }
end

-- Other common DroboApps, shown only when installed.
local function droboapp_services()
  local out = {}
  local known = {
    { dir = "pure-ftpd", proc = "pure-ftpd", name = "FTP (Pure-FTPd DroboApp)" },
    { dir = "proftpd", proc = "proftpd", name = "FTP (ProFTPD DroboApp)" },
    { dir = "apache", proc = "httpd", name = "Web server (Apache DroboApp)" },
  }
  for _, a in ipairs(known) do
    if R.file_exists(APPS_DIR .. "/" .. a.dir .. "/service.sh") then
      out[#out + 1] = { id = a.dir, name = a.name, running = running(a.proc) }
    end
  end
  return out
end

local function samba_mode()
  local mounts = R.read_file("/proc/mounts") or ""
  if not running("smbd") then return "stopped" end
  if mounts:find(" /sbin/smbd ", 1, true) or mounts:find(" /usr/sbin/smbd ", 1, true) then return "encore" end
  return "stock"
end

local function samba_version()
  local cached = R.read_file(VAR .. "/run/samba.version")
  if cached and cached ~= "" then return R.trim(cached) end
  local v = R.trim(R.capture(APP .. "/sbin/smbd -V"):gsub("^Version%s*", ""))
  R.write_file(VAR .. "/run/samba.version", v)
  return v
end

local function connections()
  if samba_mode() ~= "encore" then return {} end
  local out, started = {}, false
  for line in R.capture(APP .. "/bin/smbstatus -b -s " .. R.GEN_SMB_CONF):gmatch("[^\n]+") do
    if line:match("^%-%-%-") then
      started = true
    elseif started then
      local f = {}
      for w in line:gmatch("%S+") do f[#f + 1] = w end
      if #f >= 5 and tonumber(f[1]) then
        out[#out + 1] = {
          pid = tonumber(f[1]), user = f[2], group = f[3], machine = f[4],
          protocol = f[5], encryption = f[6] or "-", signing = f[7] or "-",
        }
      end
    end
  end
  return out
end

---------------------------------------------------------------------------
-- Validation for settings saved from the UI
---------------------------------------------------------------------------
local function one_of(...)
  local set = {}
  for _, v in ipairs({ ... }) do set[v] = true end
  return function(v) return set[v] end
end
local VALID = {
  SMB_ENABLED = one_of("0", "1"),
  SMB_MIN_PROTOCOL = one_of("NT1", "SMB2_02", "SMB2_10", "SMB3_00", "SMB3_11"),
  SMB_MAX_PROTOCOL = one_of("SMB2_10", "SMB3_00", "SMB3_02", "SMB3_11", "SMB3"),
  SMB_ENCRYPT = one_of("off", "if_required", "desired", "required"),
  SMB_SIGNING = one_of("default", "desired", "required"),
  SMB_MACOS = one_of("0", "1"),
  SMB_NETBIOS = one_of("0", "1"),
  SMB_LOG_LEVEL = one_of("0", "1", "2", "3"),
  BONJOUR_MODEL = one_of("Xserve", "RackMac", "TimeCapsule8,119", "MacPro7,1@ECOLOR=226,226,224"),
  WEB_PORT = function(v) local n = tonumber(v); return n and n >= 1024 and n <= 65535 and v:match("^%d+$") end,
  ADMIN_USERS = function(v) return #v <= 200 and v:match("^[%w%._%-, ]*$") end,
  NTP_SERVERS = function(v) return #v <= 200 and v:match("^[%w%.%-: ]+$") and v:match("%w") end,
  TIME_ZONE = function(v) return #v <= 64 and v:match("^[%w%+%-,%./:<>]+$") end,
}

local function saved_settings()
  local saved = {}
  for line in (R.read_file(R.SETTINGS) or ""):gmatch("[^\n]+") do
    local k, v = line:match("^([A-Z_][A-Z0-9_]*)='(.*)'$")
    if k then saved[k] = v end
  end
  return saved
end

local function run_service(action)
  os.execute(string.format("/bin/sh %s/service.sh %s >> %s 2>&1", APP, action, R.sh_quote(R.LOG)))
end

---------------------------------------------------------------------------
-- Routes
---------------------------------------------------------------------------
local routes = {}

routes["GET session"] = function()
  local s = session()
  ok({ authenticated = s ~= nil, user = s and s.user, hostname = R.trim(R.capture("hostname")) })
end

routes["POST login"] = function()
  local b = read_body()
  local user, pw = tostring(b.user or ""), tostring(b.password or "")
  local n = failures()
  if n >= 5 then fail("429 Too Many Requests", "Too many failed sign-ins. Try again in 5 minutes.") end
  local S = R.load_settings()
  local allowed = user == "root" or admin_list(S)[user:lower()]
  if not allowed or not check_password(user, pw) then
    R.write_file(LOCK, string.format("%d %d", n + 1, os.time()))
    R.log("web: failed sign-in for " .. user:gsub("[^%w%._%-]", "?"))
    if posix_ok then unistd.sleep(1) end
    fail("401 Unauthorized", allowed and "Wrong user name or password."
      or "That account isn't an administrator. Sign in as root or a user listed in Admin users.")
  end
  os.remove(LOCK)
  os.execute("mkdir -p " .. R.sh_quote(SESS_DIR))
  local sid = random_hex(32)
  R.write_file(SESS_DIR .. "/" .. sid, user .. "\n" .. (os.time() + SESSION_TTL) .. "\n", "600")
  extra_headers[#extra_headers + 1] = "Set-Cookie: encore_sid=" .. sid ..
    "; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=" .. SESSION_TTL
  R.log("web: " .. user .. " signed in")
  ok({ ok = true, user = user })
end

routes["POST logout"] = function()
  local s = session()
  if s then os.remove(SESS_DIR .. "/" .. s.sid) end
  extra_headers[#extra_headers + 1] = "Set-Cookie: encore_sid=; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=0"
  ok()
end

routes["GET overview"] = function()
  require_auth()
  local up = tonumber((R.read_file("/proc/uptime") or "0"):match("^([%d%.]+)")) or 0
  local load = (R.read_file("/proc/loadavg") or ""):match("^(%S+ %S+ %S+)")
  local mem = read_meminfo()
  local cpuinfo = R.read_file("/proc/cpuinfo") or ""
  local S = R.load_settings()
  ok({
    hostname = R.trim(R.capture("hostname")),
    model = "Drobo FS",
    kernel = ((R.read_file("/proc/version") or ""):match("Linux version (%S+)")),
    cpu = cpuinfo:match("Processor%s*:%s*([^\n]+)") or cpuinfo:match("model name%s*:%s*([^\n]+)"),
    bogomips = cpuinfo:match("BogoMIPS%s*:%s*([%d%.]+)"),
    uptime = up, load = load,
    time = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    memory = { total = (mem.MemTotal or 0) * 1024,
               free = ((mem.MemFree or 0) + (mem.Buffers or 0) + (mem.Cached or 0)) * 1024,
               swap_total = (mem.SwapTotal or 0) * 1024, swap_free = (mem.SwapFree or 0) * 1024 },
    volume = volume(),
    interfaces = interfaces(),
    samba = { mode = samba_mode(), version = samba_version(), enabled = S.SMB_ENABLED == "1",
              min = S.SMB_MIN_PROTOCOL, max = S.SMB_MAX_PROTOCOL, encrypt = S.SMB_ENCRYPT },
    services = {
      { id = "smbd", name = "SMB file service", running = running("smbd") },
      { id = "nmbd", name = "NetBIOS name service", running = running("nmbd") },
      { id = "afpd", name = "AFP (Apple Filing Protocol)", running = running("afpd") },
      { id = "avahi", name = "Bonjour (Avahi)", running = running("avahi-daemon") },
      { id = "nasd", name = "Drobo NAS daemon", running = running("nasd") },
      ssh_service(),
      { id = "lighttpd", name = "Web admin", running = true },
      table.unpack(droboapp_services()),
    },
    connections = #connections(),
    warnings = {
      root_default_password = root_default_password(),
      smb1_enabled = S.SMB_MIN_PROTOCOL == "NT1",
    },
  })
end

routes["GET resources"] = function()
  require_auth()
  local mem = read_meminfo()
  ok({
    t = os.time(), cpu = cpu_counters(), net = net_counters(), disk = disk_counters(),
    load = (R.read_file("/proc/loadavg") or ""):match("^(%S+)"),
    memory = { total = (mem.MemTotal or 0) * 1024, free = (mem.MemFree or 0) * 1024,
               buffers = (mem.Buffers or 0) * 1024, cached = (mem.Cached or 0) * 1024 },
  })
end

routes["GET shares"] = function()
  require_auth()
  local extras = R.load_json(R.SHARES_JSON, {})
  local list = {}
  for _, sec in ipairs(R.nasd_shares()) do
    local ex = extras[sec.name] or {}
    list[#list + 1] = {
      name = sec.name,
      path = R.param(sec, "path"),
      comment = R.param(sec, "comment"),
      guest = R.truthy(R.param(sec, "guest ok") or R.param(sec, "public")),
      read_only = R.truthy(R.param(sec, "read only")) or (R.param(sec, "writeable") and not R.truthy(R.param(sec, "writeable"))),
      valid_users = R.param(sec, "valid users"),
      write_list = R.param(sec, "write list"),
      read_list = R.param(sec, "read list"),
      timemachine = ex.timemachine == true,
      tm_max_size = ex.tm_max_size or "",
      recycle = ex.recycle == true,
      hidden = ex.hidden == true,
      encrypt = ex.encrypt or "default",
    }
  end
  ok({ shares = list })
end

routes["PUT shares"] = function(name)
  require_auth()
  local exists = false
  for _, sec in ipairs(R.nasd_shares()) do if sec.name == name then exists = true end end
  if not exists then fail("404 Not Found", "No such share") end
  local b = read_body()
  local enc = tostring(b.encrypt or "default")
  if not one_of("default", "off", "if_required", "desired", "required")(enc) then
    fail("400 Bad Request", "Invalid encryption mode")
  end
  local size = tostring(b.tm_max_size or ""):upper()
  if size ~= "" and not size:match("^%d+[KMGT]$") then
    fail("400 Bad Request", "Time Machine size must look like 500G or 2T")
  end
  local extras = R.load_json(R.SHARES_JSON, {})
  extras[name] = {
    timemachine = b.timemachine == true, tm_max_size = size,
    recycle = b.recycle == true, hidden = b.hidden == true, encrypt = enc,
  }
  R.save_json(R.SHARES_JSON, extras)
  run_service("reload")
  R.log("web: updated share options for " .. name)
  ok()
end

routes["GET settings"] = function()
  require_auth()
  ok({ settings = R.load_settings() })
end

routes["PUT settings"] = function()
  local s = require_auth()
  local b = read_body()
  local cur = R.load_settings()
  -- Persist only what the user changed on top of their saved settings (not defaults).
  local saved = saved_settings()
  local changed = {}
  for k, v in pairs(b) do
    v = tostring(v)
    if not VALID[k] then fail("400 Bad Request", "Unknown setting " .. tostring(k)) end
    if not VALID[k](v) then fail("400 Bad Request", "Invalid value for " .. k) end
    if cur[k] ~= v then changed[#changed + 1] = k end
    saved[k] = v
  end
  if saved.ADMIN_USERS and not saved.ADMIN_USERS:match("%S") and s.user ~= "root" then
    fail("400 Bad Request", "Keep at least one admin user, or sign in as root to clear the list")
  end
  R.save_settings(saved)
  R.log("web: " .. s.user .. " changed settings: " .. table.concat(changed, ", "))
  local web_restart = false
  for _, k in ipairs(changed) do
    if k == "SMB_ENABLED" then
      run_service(saved.SMB_ENABLED == "1" and "samba-on" or "samba-off")
    elseif k == "SMB_NETBIOS" or k == "SMB_MIN_PROTOCOL" or k == "SMB_MAX_PROTOCOL" then
      if samba_mode() == "encore" then run_service("samba-on") end
    elseif k == "WEB_PORT" or k == "TIME_ZONE" then
      web_restart = true
    end
  end
  run_service("reload")
  if web_restart then
    -- Restart the web server after this response has been delivered.
    os.execute(string.format("(sleep 2; /bin/sh %s/service.sh web-restart) >/dev/null 2>&1 &", APP))
  end
  ok({ ok = true, changed = changed, web_restart = web_restart })
end

routes["POST samba"] = function()
  local s = require_auth()
  local b = read_body()
  local action = b.action
  if action == "encore" or action == "stock" then
    local saved = saved_settings()
    saved.SMB_ENABLED = action == "encore" and "1" or "0"
    R.save_settings(saved)
    run_service(action == "encore" and "samba-on" or "samba-off")
  elseif action == "restart" then
    run_service("samba-off")
    run_service("samba-on")
  else
    fail("400 Bad Request", "Unknown action")
  end
  R.log("web: " .. s.user .. " samba action " .. action)
  ok({ ok = true, mode = samba_mode() })
end

routes["GET connections"] = function()
  require_auth()
  ok({ mode = samba_mode(), connections = connections() })
end

routes["GET users"] = function()
  require_auth()
  local S = R.load_settings()
  local admins = admin_list(S)
  local list = {}
  for _, u in ipairs(smb_users()) do
    list[#list + 1] = { name = u.name, uid = u.uid, disabled = u.disabled,
                        no_password = u.no_password, changed = u.changed, admin = admins[u.name:lower()] == true }
  end
  ok({ users = list })
end

local LOGS = {
  encore = VAR .. "/log/encore.log",
  samba = VAR .. "/log/samba.log",
  web = VAR .. "/log/lighttpd.log",
  nasd = "/var/log/nasd.log",
}
routes["GET logs"] = function()
  require_auth()
  local name = query.name or "encore"
  local lines = math.min(tonumber(query.lines or "300") or 300, 2000)
  local text
  if name == "kernel" then
    text = R.capture("dmesg | tail -n " .. lines)
  elseif LOGS[name] then
    text = R.capture(string.format("tail -n %d %s", lines, R.sh_quote(LOGS[name])))
  else
    fail("404 Not Found", "Unknown log")
  end
  ok({ name = name, text = text })
end

routes["GET smbconf"] = function()
  require_auth()
  ok({ generated = R.read_file(R.GEN_SMB_CONF) or "", nasd = R.read_file(R.NASD_SMB_CONF) or "" })
end

---------------------------------------------------------------------------
-- Date & time
---------------------------------------------------------------------------
local function time_state()
  local S = R.load_settings()
  return {
    epoch = os.time(),
    local_time = os.date("%Y-%m-%d %H:%M:%S %Z"),
    time_zone = S.TIME_ZONE, ntp_servers = S.NTP_SERVERS,
    sync = R.load_json(VAR .. "/run/timesync.json", nil),
  }
end

routes["GET time"] = function()
  require_auth()
  ok(time_state())
end

routes["POST time"] = function(sub)
  local s = require_auth()
  if sub == "sync" then
    os.execute(string.format("/bin/sh %s/libexec/timesync.sh once >/dev/null 2>&1", APP))
    R.log("web: " .. s.user .. " synced the clock")
    ok(time_state())
  elseif sub == "set" then
    local b = read_body()
    local t = tonumber(b.epoch)
    if not t or t < 1700000000 or t > 4102444800 then fail("400 Bad Request", "Invalid time") end
    os.execute("date -u -s " .. R.sh_quote(os.date("!%Y-%m-%d %H:%M:%S", math.floor(t))) .. " >/dev/null 2>&1")
    R.write_file(VAR .. "/run/timesync.json", json.encode({ ok = true, server = "browser", at = os.time(), manual = true }))
    R.log("web: " .. s.user .. " set the clock from their browser")
    ok(time_state())
  else
    fail("404 Not Found", "No such endpoint")
  end
end

---------------------------------------------------------------------------
-- Drobo management through nasd (what Drobo Dashboard does)
---------------------------------------------------------------------------
local nasmgr_ok, nasmgr = pcall(require, "nasmgr")
local JOBS = VAR .. "/jobs"

routes["GET drobo"] = function(sub)
  require_auth()
  if not nasmgr_ok then fail("500 Internal Server Error", "Management module missing") end
  if sub == "status" then
    local st, err = nasmgr.status()
    if not st then fail("502 Bad Gateway", "Drobo status unavailable: " .. tostring(err)) end
    ok(st)
  end
  local all, err = nasmgr.read_all()
  if not all then
    fail("502 Bad Gateway", type(err) == "table" and err.user or tostring(err))
  end
  local extras = R.load_json(R.SHARES_JSON, {})
  for _, sh in ipairs(all.shares) do
    local ex = extras[sh.name] or {}
    sh.recycle = ex.recycle == true
    sh.hidden = ex.hidden == true
    sh.encrypt = ex.encrypt or "default"
  end
  local job = R.read_file(JOBS .. "/active")
  all.active_job = job and R.trim(job) or nil
  ok(all)
end

local JOB_OPS = { user_add = true, user_password = true, user_delete = true, share_add = true,
  share_update = true, share_delete = true, network_set = true, email_set = true, admin_password = true }

routes["POST drobo"] = function(sub)
  local s = require_auth()
  if sub ~= "job" then fail("404 Not Found", "No such endpoint") end
  local b = read_body()
  if not JOB_OPS[b.op] then fail("400 Bad Request", "Unknown operation") end
  os.execute("mkdir -p " .. R.sh_quote(JOBS) .. " && chmod 700 " .. R.sh_quote(JOBS))
  local active = R.read_file(JOBS .. "/active")
  if active and active ~= "" then
    local st = R.load_json(JOBS .. "/" .. R.trim(active) .. ".json", {})
    if st.state == "running" then fail("409 Conflict", "Another change is still being applied. Wait for it to finish.") end
  end
  local id = random_hex(8)
  b.label = tostring(b.label or b.op):sub(1, 80)
  R.save_json(JOBS .. "/" .. id .. ".req", b)
  R.write_file(JOBS .. "/active", id)
  R.write_file(JOBS .. "/" .. id .. ".json", json.encode({ id = id, state = "queued", op = b.op, label = b.label }), "600")
  os.execute(string.format("setsid %s/bin/lua %s/share/encore/nasjob.lua %s </dev/null >>%s 2>&1 &",
    APP, APP, id, R.sh_quote(R.LOG)))
  R.log("web: " .. s.user .. " started " .. b.label)
  ok({ job = id })
end

routes["GET job"] = function(id)
  require_auth()
  if not id or not id:match("^%x+$") then fail("400 Bad Request", "Bad job id") end
  local st = R.load_json(JOBS .. "/" .. id .. ".json", nil)
  if not st then fail("404 Not Found", "No such job") end
  ok(st)
end

---------------------------------------------------------------------------
local head, arg = route:match("^([^/]+)/?(.*)$")
local handler = routes[method .. " " .. (head or "")]
if not handler then fail("404 Not Found", "No such endpoint") end
local okc, err = pcall(handler, arg ~= "" and arg or nil)
if not okc then
  R.log("web: error in " .. method .. " " .. route .. ": " .. tostring(err))
  fail("500 Internal Server Error", "Internal error (see Encore log)")
end
