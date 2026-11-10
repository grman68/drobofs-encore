-- Shared helpers for the Encore DroboApp (config generation + web API).
local M = {}

M.APP = os.getenv("ENCORE_APP") or "/mnt/DroboFS/Shares/DroboApps/encore"
M.VAR = M.APP .. "/var"
M.DRI = "/mnt/DroboFS"
M.NASD_SMB_CONF = M.DRI .. "/System/samba/conf/smb.conf"
M.SAMBA_SEC = M.DRI .. "/System/samba/security"
M.SMBPASSWD = M.SAMBA_SEC .. "/smbpasswd"
M.GEN_SMB_CONF = M.VAR .. "/etc/smb.conf"
M.SHARES_JSON = M.VAR .. "/shares.json"
M.SETTINGS = M.VAR .. "/settings.conf"
M.LOG = M.VAR .. "/log/encore.log"

function M.read_file(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("a")
  f:close()
  return s
end

-- Write via temp file + rename so readers never see a half-written file.
function M.write_file(path, data, mode)
  local tmp = path .. ".tmp"
  local f, err = io.open(tmp, "wb")
  if not f then return nil, err end
  f:write(data)
  f:close()
  if mode then os.execute(string.format("chmod %s '%s'", mode, tmp)) end
  return os.rename(tmp, path)
end

function M.file_exists(path)
  local f = io.open(path, "rb")
  if f then f:close() return true end
  return false
end

function M.log(msg)
  local f = io.open(M.LOG, "a")
  if f then
    f:write(os.date("%Y-%m-%d %H:%M:%S "), msg, "\n")
    f:close()
  end
end

function M.trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

-- Shell-style KEY=VALUE files (defaults.conf / settings.conf).
local function parse_kv(text, into)
  for line in (text or ""):gmatch("[^\n]+") do
    local k, v = line:match("^%s*([A-Z_][A-Z0-9_]*)=(.*)$")
    if k then
      v = M.trim(v)
      v = v:match("^'(.*)'$") or v:match('^"(.*)"$') or v
      into[k] = v
    end
  end
  return into
end

function M.load_settings()
  local s = parse_kv(M.read_file(M.APP .. "/etc/defaults.conf"), {})
  return parse_kv(M.read_file(M.SETTINGS), s)
end

-- Values are validated by callers; single quotes are refused outright.
function M.save_settings(tbl)
  local keys = {}
  for k in pairs(tbl) do keys[#keys + 1] = k end
  table.sort(keys)
  local out = { "# Saved by the Encore web admin" }
  for _, k in ipairs(keys) do
    local v = tostring(tbl[k])
    assert(k:match("^[A-Z_][A-Z0-9_]*$") and not v:find("'", 1, true) and not v:find("\n", 1, true))
    out[#out + 1] = string.format("%s='%s'", k, v)
  end
  return M.write_file(M.SETTINGS, table.concat(out, "\n") .. "\n", "600")
end

-- smb.conf parser that keeps section and parameter order.
-- Returns { {name="global", params={{k=..., v=...}, ...}}, ... }
function M.parse_ini(text)
  local sections, cur = {}, nil
  local function section(name)
    cur = { name = name, params = {} }
    sections[#sections + 1] = cur
  end
  section("global")
  local pending = ""
  for raw in ((text or "") .. "\n"):gmatch("([^\n]*)\n") do
    local line = pending .. raw:gsub("\r$", "")
    pending = ""
    if line:match("\\%s*$") then
      pending = line:gsub("\\%s*$", "")
    else
      line = M.trim(line)
      if line ~= "" and not line:match("^[#;]") then
        local name = line:match("^%[(.-)%]$")
        if name then
          if name:lower() == "global" then
            cur = sections[1]
          else
            section(name)
          end
        else
          local k, v = line:match("^([^=]-)%s*=%s*(.*)$")
          if k and k ~= "" then
            cur.params[#cur.params + 1] = { k = k:lower():gsub("%s+", " "), v = v }
          end
        end
      end
    end
  end
  return sections
end

-- Inline "include = /path" lines (nasd includes /etc/.backup_smb.conf and
-- /var/samba/netbios.conf). Paths with %-macros are skipped, as are cycles.
function M.expand_includes(text, depth, seen)
  depth, seen = depth or 0, seen or {}
  if depth > 5 then return text end
  local out = {}
  for line in ((text or "") .. "\n"):gmatch("([^\n]*)\n") do
    local path = line:match("^%s*[Ii][Nn][Cc][Ll][Uu][Dd][Ee]%s*=%s*(%S.-)%s*$")
    if path and not path:find("%", 1, true) and not seen[path] then
      seen[path] = true
      out[#out + 1] = M.expand_includes(M.read_file(path) or "", depth + 1, seen)
    elseif not path then
      out[#out + 1] = line
    end
  end
  return table.concat(out, "\n")
end

-- Read an smb.conf with its includes expanded.
function M.read_conf(path)
  return M.expand_includes(M.read_file(path) or "", 0, {})
end

-- Users: the Drobo keeps them in a Samba 3.4 tdbsam (passdb.tdb). Samba 4 may
-- upgrade a tdbsam in place, which would break stock Samba and nasd's own
-- smbpasswd, so Samba 4 gets a private copy that follows the original.
M.PASSDB_SRC = M.SAMBA_SEC .. "/passdb.tdb"
M.PASSDB_COPY = M.VAR .. "/samba/private/passdb.tdb"
M.SECRETS_SRC = M.SAMBA_SEC .. "/secrets.tdb"
M.SECRETS_COPY = M.VAR .. "/samba/private/secrets.tdb"

local stat_ok, pstat = pcall(require, "posix.sys.stat")
local function mtime(path)
  if not stat_ok then return nil end
  local st = pstat.stat(path)
  return st and st.st_mtime
end

function M.uses_tdbsam()
  return M.file_exists(M.PASSDB_SRC) or not M.file_exists(M.SMBPASSWD)
end

-- Copy passdb.tdb when the original is newer; copy secrets.tdb (machine SID) once.
function M.sync_passdb()
  os.execute("mkdir -p '" .. M.VAR .. "/samba/private' && chmod 700 '" .. M.VAR .. "/samba/private'")
  if M.file_exists(M.PASSDB_SRC) then
    local s, d = mtime(M.PASSDB_SRC), mtime(M.PASSDB_COPY)
    if not d or (s and s > d) then
      os.execute(string.format("cp -f '%s' '%s.new' && mv -f '%s.new' '%s' && chmod 600 '%s'",
        M.PASSDB_SRC, M.PASSDB_COPY, M.PASSDB_COPY, M.PASSDB_COPY, M.PASSDB_COPY))
      M.log("passdb: copied users from " .. M.PASSDB_SRC)
    end
  end
  if M.file_exists(M.SECRETS_SRC) and not M.file_exists(M.SECRETS_COPY) then
    os.execute(string.format("cp -f '%s' '%s' && chmod 600 '%s'", M.SECRETS_SRC, M.SECRETS_COPY, M.SECRETS_COPY))
  end
end

function M.param(section, key)
  local v
  for _, p in ipairs(section.params) do
    if p.k == key then v = p.v end
  end
  return v
end

local cjson_ok, cjson = pcall(require, "cjson")
M.json = cjson_ok and cjson or nil

function M.load_json(path, default)
  local s = M.read_file(path)
  if not s or s == "" then return default end
  local ok, v = pcall(M.json.decode, s)
  if ok and type(v) == "table" then return v end
  return default
end

function M.save_json(path, tbl)
  return M.write_file(path, M.json.encode(tbl), "600")
end

-- Shares as defined by nasd (Drobo Dashboard), excluding [global].
function M.nasd_shares()
  local out = {}
  for _, s in ipairs(M.parse_ini(M.read_conf(M.NASD_SMB_CONF))) do
    if s.name ~= "global" and s.name:lower() ~= "homes" and s.name:lower() ~= "printers" then
      out[#out + 1] = s
    end
  end
  return out
end

function M.truthy(v)
  if v == nil then return false end
  v = tostring(v):lower()
  return v == "yes" or v == "true" or v == "1" or v == "on"
end

function M.sh_quote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

function M.capture(cmd)
  local p = io.popen(cmd .. " 2>/dev/null")
  if not p then return "" end
  local s = p:read("a")
  p:close()
  return s or ""
end

return M
