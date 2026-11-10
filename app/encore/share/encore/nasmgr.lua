-- High-level Drobo FS management on top of nasd.lua: users, shares, network,
-- email alerts, admin account, and drive/volume status. Every change is a
-- get -> modify -> set round trip through nasd, so nasd stays the owner of the
-- configuration and applies it to Linux accounts, Samba, AFP and Bonjour itself.
local N = require("nasd")
local R = require("encore")

local M = {}

local RESERVED_USERS = { everyone = true, admin = true, root = true, nobody = true,
  avahi = true, sshd = true, guest = true, daemon = true, bin = true }
local RESERVED_SHARES = { droboapps = true, ipc = true, ["ipc$"] = true, global = true,
  homes = true, printers = true, system = true, systemlogs = true, shares = true }

local function bad(msg) error({ user = msg }, 0) end

function M.valid_username(name)
  return type(name) == "string" and name:match("^[A-Za-z_][A-Za-z0-9_.%-]*$") and #name <= 32
    and not RESERVED_USERS[name:lower()]
end

function M.valid_sharename(name)
  return type(name) == "string" and name:match("^[A-Za-z0-9][A-Za-z0-9 _.%-]*$") and #name <= 64
    and not name:find("  ", 1, true) and not RESERVED_SHARES[name:lower()]
end

local function valid_password(pw)
  return type(pw) == "string" and #pw >= 6 and #pw <= 64 and not pw:find("[%z\r\n]")
end
local PW_HELP = "Choose a password of 6 to 64 characters."

---------------------------------------------------------------------------
-- Watchdog: nasd applies changes by driving helper programs (adduser, passwd,
-- smbpasswd). If one of them stalls, nasd waits forever. After a few minutes we
-- end a stuck passwd/smbpasswd child of nasd so nasd can finish or roll back.
---------------------------------------------------------------------------
local function proc_stat(pid)
  local s = R.read_file("/proc/" .. pid .. "/stat")
  if not s then return nil end
  local comm, ppid = s:match("^%d+ %((.-)%) %S+ (%d+)")
  return comm, tonumber(ppid)
end

function M.watchdog(elapsed)
  if elapsed < 240 then return true end
  local nasd = tonumber((R.capture("pidof nasd")):match("%d+") or "")
  if not nasd then return true end
  for pid in R.capture("ls /proc"):gmatch("%d+") do
    local comm, ppid = proc_stat(pid)
    if ppid == nasd and (comm == "passwd" or comm == "smbpasswd") then
      os.execute("kill " .. pid)
      R.log(string.format("nasd: ended stuck %s (pid %s) after %ds", comm, pid, elapsed))
    end
  end
  return true
end

-- Open a session with the watchdog attached.
local function session(fn)
  return N.with_session(function(s)
    s.on_wait = M.watchdog
    return fn(s, N.password_key(s.id))
  end)
end

---------------------------------------------------------------------------
-- Reading
---------------------------------------------------------------------------
local function shares_doc(s)
  local doc = N.parse(assert(s:get(N.CMD.GET_SHARES)))
  if doc.name ~= "DRIShareConfig" then error("unexpected shares document " .. doc.name) end
  if not N.child(doc, "UserList") then table.insert(doc.kids, 2, N.elem("UserList")) end
  if not N.child(doc, "Shares") then doc.kids[#doc.kids + 1] = N.elem("Shares") end
  return doc
end

local function share_to_table(sh)
  local access = {}
  for _, su in ipairs(N.children(N.child(sh, "ShareUsers"), "ShareUser")) do
    access[#access + 1] = { user = N.text(su, "ShareUsername"),
      access = N.text(su, "ShareUserAccess") == "1" and "rw" or "ro" }
  end
  return {
    name = N.text(sh, "ShareName"),
    timemachine = N.text(sh, "TimeMachineEnabled") == "1",
    tm_max_gb = tonumber(N.text(sh, "ShareMaxTMSizeGB") or "0") or 0,
    access = access,
  }
end

function M.read_all()
  return session(function(s)
    local doc = shares_doc(s)
    local users, shares = {}, {}
    for _, u in ipairs(N.children(N.child(doc, "UserList"), "User")) do
      users[#users + 1] = { name = N.text(u, "Username") }
    end
    for _, sh in ipairs(N.children(N.child(doc, "Shares"), "Share")) do
      shares[#shares + 1] = share_to_table(sh)
    end
    local admin = N.parse(assert(s:get(N.CMD.GET_ADMIN)))
    local net = N.parse(assert(s:get(N.CMD.GET_NETWORK)))
    local ip = N.child(net, "IPConfig")
    local jumbo = N.child(net, "JumboFramesConfig")
    local email = N.parse(assert(s:get(N.CMD.GET_EMAIL)))
    local mail = N.child(email, "MailConfig")
    local auth = N.child(mail, "Authentication")
    return {
      version = tonumber(N.text(doc, "ConfigVersionBasis")),
      users = users,
      shares = shares,
      admin = { username = N.text(admin, "UserName") },
      network = {
        name = N.text(net, "NasName"), workgroup = N.text(net, "NasWorkgroup"),
        mac = N.text(net, "MACAddress"),
        mode = N.text(ip, "IPConfigType") == "1" and "static" or "dhcp",
        ip = N.text(ip, "IP"), subnet = N.text(ip, "Subnet"), gateway = N.text(ip, "Gateway"),
        dns1 = N.text(ip, "DNS1"), dns2 = N.text(ip, "DNS2"),
        jumbo = N.text(jumbo, "Enabled") == "1", mtu = tonumber(N.text(jumbo, "MTUSize") or "1500"),
      },
      email = {
        enabled = N.text(email, "Enabled") == "1",
        level = tonumber(N.text(mail, "AlertLevel") or "1"),
        to = N.text(mail, "ToEmailAddress"), from = N.text(mail, "FromEmailAddress"),
        server = N.text(mail, "MailServer"), port = tonumber(N.text(mail, "Port") or "25"),
        auth = N.text(auth, "AuthenticationEnabled") == "1",
        username = N.text(auth, "Username"), ssl = N.text(auth, "UseSSL") == "1",
      },
    }
  end)
end

---------------------------------------------------------------------------
-- Users and shares (one DRIShareConfig round trip each)
---------------------------------------------------------------------------
local function find_user(doc, name)
  for _, u in ipairs(N.children(N.child(doc, "UserList"), "User")) do
    if N.text(u, "Username"):lower() == name:lower() then return u end
  end
end
local function find_share(doc, name)
  for _, sh in ipairs(N.children(N.child(doc, "Shares"), "Share")) do
    if N.text(sh, "ShareName"):lower() == name:lower() then return sh end
  end
end

-- Echo every user back unchanged unless told otherwise (ValidPassword=0 keeps passwords).
local function keep_passwords(doc)
  for _, u in ipairs(N.children(N.child(doc, "UserList"), "User")) do
    N.set(u, "ValidPassword", "0")
  end
end

-- Dashboard sends passwords encoded (EncryptedPassword=1); nasd mishandles plaintext.
local function set_password(node, pw, key, tag)
  N.set(node, tag or "Password", N.encode_password(pw, key))
  N.set(node, "ValidPassword", "1")
  N.set(node, "EncryptedPassword", "1")
end

local function modify_shares(fn)
  return session(function(s, key)
    local doc = shares_doc(s)
    keep_passwords(doc)
    fn(doc, key)
    local ok, err = s:set(doc)
    if not ok then error(err) end
    return true
  end)
end

function M.user_add(name, password)
  if not M.valid_username(name) then bad("User names use letters, digits, . _ - (up to 32), and can't be a reserved name.") end
  if not valid_password(password) then bad(PW_HELP) end
  return modify_shares(function(doc, key)
    if find_user(doc, name) then bad("A user with that name already exists.") end
    local u = N.elem("User", { N.elem("Username", nil, name) })
    set_password(u, password, key)
    local list = N.child(doc, "UserList")
    list.kids[#list.kids + 1] = u
  end)
end

function M.user_password(name, password)
  if not valid_password(password) then bad(PW_HELP) end
  return modify_shares(function(doc, key)
    local u = find_user(doc, name) or bad("No such user.")
    set_password(u, password, key)
  end)
end

function M.user_delete(name)
  return modify_shares(function(doc)
    local list = N.child(doc, "UserList")
    local u = find_user(doc, name) or bad("No such user.")
    for i, k in ipairs(list.kids) do if k == u then table.remove(list.kids, i) break end end
    for _, sh in ipairs(N.children(N.child(doc, "Shares"), "Share")) do
      local su = N.child(sh, "ShareUsers")
      for i = #(su and su.kids or {}), 1, -1 do
        if N.text(su.kids[i], "ShareUsername"):lower() == name:lower() then table.remove(su.kids, i) end
      end
    end
    N.set(doc, "UserDeleteConfirm", "1")
  end)
end

-- spec: { name, access = { {user=, access="rw"|"ro"} ... }, timemachine, tm_max_gb }
local function fill_share(sh, spec, doc)
  N.set(sh, "ShareName", spec.name)
  if not N.child(sh, "ShareState") then N.set(sh, "ShareState", "0") end
  N.set(sh, "TimeMachineEnabled", spec.timemachine and "1" or "0")
  N.set(sh, "ShareMaxTMSizeGB", string.format("%.6f", tonumber(spec.tm_max_gb) or 0))
  local su = N.child(sh, "ShareUsers") or N.elem("ShareUsers")
  su.kids = {}
  local seen = {}
  for _, a in ipairs(spec.access or {}) do
    local user = tostring(a.user or "")
    local known = user == "Everyone" or user == "Admin" or find_user(doc, user)
    if not known then bad("Unknown user " .. user) end
    if not seen[user:lower()] then
      seen[user:lower()] = true
      su.kids[#su.kids + 1] = N.elem("ShareUser", {
        N.elem("ShareUsername", nil, user),
        N.elem("ShareUserAccess", nil, a.access == "rw" and "1" or "0"),
      })
    end
  end
  if not N.child(sh, "ShareUsers") then sh.kids[#sh.kids + 1] = su end
  -- keep element order nasd writes (name, state, TM, size, users)
  local order = { ShareName = 1, OldShareName = 2, ShareState = 3, TimeMachineEnabled = 4, ShareMaxTMSizeGB = 5, ShareUsers = 6 }
  table.sort(sh.kids, function(a, b) return (order[a.name] or 9) < (order[b.name] or 9) end)
end

local function check_spec(spec)
  if not M.valid_sharename(spec.name) then bad("Share names use letters, digits, spaces, . _ - (up to 64), and can't be a reserved name.") end
  local gb = tonumber(spec.tm_max_gb or 0)
  if not gb or gb < 0 or gb > 1e6 then bad("Time Machine size must be a number of GB.") end
  if type(spec.access) ~= "table" or #spec.access == 0 then bad("Give at least one user (or Everyone) access.") end
end

function M.share_add(spec)
  check_spec(spec)
  return modify_shares(function(doc)
    if find_share(doc, spec.name) then bad("A share with that name already exists.") end
    local sh = N.elem("Share")
    fill_share(sh, spec, doc)
    local list = N.child(doc, "Shares")
    list.kids[#list.kids + 1] = sh
  end)
end

function M.share_update(old, spec)
  check_spec(spec)
  return modify_shares(function(doc)
    local sh = find_share(doc, old) or bad("No such share.")
    if spec.name:lower() ~= old:lower() then
      if find_share(doc, spec.name) then bad("A share with that name already exists.") end
      N.set(sh, "OldShareName", N.text(sh, "ShareName"))
    end
    fill_share(sh, spec, doc)
  end)
end

function M.share_delete(name)
  return modify_shares(function(doc)
    local list = N.child(doc, "Shares")
    local sh = find_share(doc, name) or bad("No such share.")
    for i, k in ipairs(list.kids) do if k == sh then table.remove(list.kids, i) break end end
    N.set(doc, "ShareDeleteConfirm", "1")
  end)
end

---------------------------------------------------------------------------
-- Network, email, admin
---------------------------------------------------------------------------
local function ipv4(s) return type(s) == "string" and s:match("^%d+%.%d+%.%d+%.%d+$") end

function M.network_set(spec)
  if spec.name and not (spec.name:match("^[A-Za-z0-9][A-Za-z0-9%-]*$") and #spec.name <= 15) then
    bad("The Drobo name can use letters, digits and - (up to 15 characters).")
  end
  if spec.workgroup and not (spec.workgroup:match("^[A-Za-z0-9][A-Za-z0-9_%-]*$") and #spec.workgroup <= 15) then
    bad("The workgroup can use letters, digits, _ and - (up to 15 characters).")
  end
  if spec.mode == "static" then
    for _, k in ipairs({ "ip", "subnet", "gateway" }) do
      if not ipv4(spec[k]) then bad("Enter a valid " .. k .. " address.") end
    end
  end
  for _, k in ipairs({ "dns1", "dns2" }) do
    if spec[k] and spec[k] ~= "" and not ipv4(spec[k]) then bad("Enter a valid DNS server address.") end
  end
  if spec.mtu and (tonumber(spec.mtu) or 0) < 1500 then bad("MTU must be at least 1500.") end
  return session(function(s)
    local net = N.parse(assert(s:get(N.CMD.GET_NETWORK)))
    if spec.name then N.set(net, "NasName", spec.name) end
    if spec.workgroup then N.set(net, "NasWorkgroup", spec.workgroup) end
    local ip = N.child(net, "IPConfig")
    if spec.mode then N.set(ip, "IPConfigType", spec.mode == "static" and "1" or "0") end
    for k, tag in pairs({ ip = "IP", subnet = "Subnet", gateway = "Gateway", dns1 = "DNS1", dns2 = "DNS2" }) do
      if spec[k] ~= nil then N.set(ip, tag, spec[k]) end
    end
    local j = N.child(net, "JumboFramesConfig")
    if spec.jumbo ~= nil then N.set(j, "Enabled", spec.jumbo and "1" or "0") end
    if spec.mtu then N.set(j, "MTUSize", tostring(math.floor(tonumber(spec.mtu)))) end
    local ok, err = s:set(net)
    if not ok then error(err) end
    return true
  end)
end

function M.email_set(spec)
  if spec.enabled and not (spec.to and spec.to:match("^[^@%s]+@[^@%s]+$")) then bad("Enter a recipient email address.") end
  return session(function(s, key)
    local email = N.parse(assert(s:get(N.CMD.GET_EMAIL)))
    local mail = N.child(email, "MailConfig")
    local auth = N.child(mail, "Authentication")
    N.set(email, "Enabled", spec.enabled and "1" or "0")
    if spec.level then N.set(mail, "AlertLevel", tostring(math.floor(tonumber(spec.level) or 1))) end
    for k, tag in pairs({ to = "ToEmailAddress", from = "FromEmailAddress", server = "MailServer" }) do
      if spec[k] ~= nil then N.set(mail, tag, spec[k]) end
    end
    if spec.port then N.set(mail, "Port", tostring(math.floor(tonumber(spec.port) or 25))) end
    if spec.auth ~= nil then N.set(auth, "AuthenticationEnabled", spec.auth and "1" or "0") end
    if spec.username ~= nil then N.set(auth, "Username", spec.username) end
    if spec.ssl ~= nil then N.set(auth, "UseSSL", spec.ssl and "1" or "0") end
    if spec.password and spec.password ~= "" then
      set_password(auth, spec.password, key)
    else
      N.set(auth, "ValidPassword", "0")
    end
    local ok, err = s:set(email)
    if not ok then error(err) end
    return true
  end)
end

function M.admin_password(password)
  if not valid_password(password) then bad(PW_HELP) end
  return session(function(s, key)
    local admin = N.parse(assert(s:get(N.CMD.GET_ADMIN)))
    set_password(admin, password, key)
    local ok, err = s:set(admin)
    if not ok then error(err) end
    return true
  end)
end

---------------------------------------------------------------------------
-- Status (port 5000, no session needed)
---------------------------------------------------------------------------
local SLOT_STATUS = { [0] = "off", [1] = "failed", [2] = "warning", [3] = "healthy", [4] = "rebuilding", [128] = "empty" }

function M.status()
  local xml, err = N.status_xml()
  if not xml then return nil, err end
  local st = N.parse(xml)
  local slots = {}
  for _, sl in ipairs((N.child(st, "mSlotsExp") or { kids = {} }).kids) do
    local code = tonumber(N.text(sl, "mStatus") or "-1")
    local cap = tonumber(N.text(sl, "mPhysicalCapacity") or "0") or 0
    slots[#slots + 1] = {
      slot = tonumber(N.text(sl, "mSlotNumber")), status_code = code,
      status = cap == 0 and "empty" or (SLOT_STATUS[code] or ("code " .. tostring(code))),
      capacity = cap, make = N.text(sl, "mMake"), model = N.text(sl, "mModel"),
    }
  end
  local num = function(tag) return tonumber(N.text(st, tag) or "") end
  return {
    name = N.text(st, "mName"), firmware = N.text(st, "mVersion"), release_date = N.text(st, "mReleaseDate"),
    status_code = num("mStatus"), dnas_status = num("DNASStatus"),
    protected = { total = num("mTotalCapacityProtected"), used = num("mUsedCapacityProtected"),
                  free = num("mFreeCapacityProtected") },
    unprotected = num("mTotalCapacityUnprotected"),
    yellow_threshold = (num("mYellowThreshold") or 8500) / 100,
    red_threshold = (num("mRedThreshold") or 9500) / 100,
    relayout_count = num("mRelayoutCount"),
    slots = slots,
  }
end

-- Keep Encore's own per-share options in step with nasd renames/deletes.
function M.rename_extras(old, new)
  local extras = R.load_json(R.SHARES_JSON, {})
  if extras[old] then extras[new] = extras[old]; extras[old] = nil; R.save_json(R.SHARES_JSON, extras) end
end
function M.delete_extras(name)
  local extras = R.load_json(R.SHARES_JSON, {})
  if extras[name] then extras[name] = nil; R.save_json(R.SHARES_JSON, extras) end
end

return M
