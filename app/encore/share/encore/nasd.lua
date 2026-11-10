-- Client for the Drobo FS nasd management protocol (what Drobo Dashboard speaks).
-- See docs/nasd-protocol.md. Runs on the device and talks to 127.0.0.1.
local S = require("posix.sys.socket")
local unistd = require("posix.unistd")

local M = {}
M.HOST = "127.0.0.1"
M.STATUS_PORT = 5000
M.COMMAND_PORT = 5001
M.TIMEOUT = 15          -- per recv() attempt; long operations keep waiting via on_wait
M.MAX_WAIT = 600        -- give up on a single reply after 10 minutes

M.CMD = {
  SET_CONFIG = 0x17, GET_NETWORK = 0x18, GET_SHARES = 0x19, GET_EMAIL = 0x1a,
  GET_ADMIN = 0x20, GET_APPS = 0x21, SEND_TEST_EMAIL = 0x2f,
}

---------------------------------------------------------------------------
-- Minimal XML (enough for nasd's flat, attribute-free documents)
---------------------------------------------------------------------------
local ENT = { lt = "<", gt = ">", amp = "&", quot = '"', apos = "'" }
local function unescape(s)
  return (s:gsub("&(#?%w+);", function(e)
    if e:sub(1, 2) == "#x" then return utf8.char(tonumber(e:sub(3), 16)) end
    if e:sub(1, 1) == "#" then return utf8.char(tonumber(e:sub(2))) end
    return ENT[e] or ("&" .. e .. ";")
  end))
end
local function escape(s)
  return (tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

-- Returns the root node: { name=, kids={...}, text= }
function M.parse(xml)
  xml = (xml or ""):gsub("%z.*$", "")
  local root = { name = "#doc", kids = {} }
  local stack = { root }
  local pos = 1
  while true do
    local s, e, close, name, selfclose = xml:find("<(/?)([%w_:%-%.]+)[^>]-(/?)>", pos)
    local cur = stack[#stack]
    local textpart = xml:sub(pos, (s or #xml + 1) - 1)
    if textpart:find("%S") then cur.text = (cur.text or "") .. unescape(textpart) end
    if not s then break end
    if close == "/" then
      if cur.name ~= name then error("xml: mismatched </" .. name .. ">") end
      stack[#stack] = nil
    else
      local node = { name = name, kids = {} }
      cur.kids[#cur.kids + 1] = node
      if selfclose ~= "/" then stack[#stack + 1] = node end
    end
    pos = e + 1
  end
  -- skip <?xml ...?> (matched as no element because of '?') and return first element
  for _, k in ipairs(root.kids) do return k end
  error("xml: no root element")
end

function M.child(node, name)
  for _, k in ipairs(node and node.kids or {}) do if k.name == name then return k end end
end
function M.children(node, name)
  local out = {}
  for _, k in ipairs(node and node.kids or {}) do if k.name == name then out[#out + 1] = k end end
  return out
end
function M.text(node, name)
  local c = name and M.child(node, name) or node
  return c and (c.text or "") or nil
end
-- Set (or create) a child element's text.
function M.set(node, name, value)
  local c = M.child(node, name)
  if not c then c = { name = name, kids = {} }; node.kids[#node.kids + 1] = c end
  c.text = tostring(value); c.kids = {}
  return c
end
function M.remove(node, name)
  for i = #node.kids, 1, -1 do if node.kids[i].name == name then table.remove(node.kids, i) end end
end
function M.elem(name, kids, text) return { name = name, kids = kids or {}, text = text } end

function M.serialize(node, indent)
  indent = indent or ""
  local out = {}
  if indent == "" then out[1] = '<?xml version="1.0" encoding="UTF-8"?>\n\n' end
  if #node.kids == 0 then
    out[#out + 1] = string.format("%s<%s>%s</%s>\n", indent, node.name, escape(node.text or ""), node.name)
  else
    out[#out + 1] = string.format("%s<%s>\n", indent, node.name)
    for _, k in ipairs(node.kids) do out[#out + 1] = M.serialize(k, indent .. "    ") end
    out[#out + 1] = string.format("%s</%s>\n", indent, node.name)
  end
  return table.concat(out)
end

---------------------------------------------------------------------------
-- Password encoding Dashboard uses for <EncryptedPassword>1</EncryptedPassword>
-- (nasd UCrypto: FUN_000fe798 / FUN_000fe670 / FUN_000fe4f0). It is a
-- repeating-key XOR over [len_lo, len_hi, password, pad...] padded to 128 bytes
-- (doubling) from a fixed table, then base64. Key for passwords sent to nasd:
-- mESAID characters 4..12 followed by 7 fixed bytes.
---------------------------------------------------------------------------
local PAD = ("0003202a7b613c3a0d5b760841075c0140042a12574c78567d104f79501712296746184753387e30720674592536112319636879672a073c0b50761a6a437a2e206f29291f69064f5c0b490e30767a6f10181942371f442f1d7a5a06107264166446454248770b364234427340715574303c2d5158412f781833500143625027")
  :gsub("%x%x", function(h) return string.char(tonumber(h, 16)) end)
local KEY_SUFFIX = "\x57\x77\x61\x15\x39\x49\x75"

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function b64enc(s)
  return ((s:gsub(".", function(c)
    local b, r = c:byte(), ""
    for i = 8, 1, -1 do r = r .. (b % 2 ^ i - b % 2 ^ (i - 1) > 0 and "1" or "0") end
    return r
  end) .. "0000"):gsub("%d%d%d?%d?%d?%d?", function(x)
    if #x < 6 then return "" end
    local c = 0
    for i = 1, 6 do c = c + (x:sub(i, i) == "1" and 2 ^ (6 - i) or 0) end
    return B64:sub(c + 1, c + 1)
  end) .. ({ "", "==", "=" })[#s % 3 + 1])
end
local function b64dec(s)
  s = s:gsub("[^%w%+/=]", "")
  return (s:gsub(".", function(x)
    if x == "=" then return "" end
    local r, f = "", (B64:find(x, 1, true) - 1)
    for i = 6, 1, -1 do r = r .. (f % 2 ^ i - f % 2 ^ (i - 1) > 0 and "1" or "0") end
    return r
  end):gsub("%d%d%d?%d?%d?%d?%d?%d?", function(x)
    if #x ~= 8 then return "" end
    local c = 0
    for i = 1, 8 do c = c + (x:sub(i, i) == "1" and 2 ^ (8 - i) or 0) end
    return string.char(c)
  end))
end

local function xor_block(data, key, total)
  local out, klen = {}, #key
  for i = 0, total - 1 do
    local b = i < #data and data:byte(i + 1) or PAD:byte(i % 128 + 1)
    out[i + 1] = string.char(b ~ key:byte(i % klen + 1))
  end
  return table.concat(out)
end

function M.password_key(esaid)
  return (esaid or ""):sub(4, 12) .. KEY_SUFFIX
end

function M.encode_password(pw, key)
  local body = string.char(#pw & 0xff, (#pw >> 8) & 0xff) .. pw
  local total = 128
  while total < #body do total = total * 2 end
  return b64enc(xor_block(body, key, total))
end

-- Inverse, used only by the self-test. Returns nil when the result is not a
-- well-formed block (wrong key or corrupt data).
function M.decode_password(enc, key)
  local raw = b64dec(enc)
  if #raw < 2 then return nil end
  local plain = xor_block(raw, key, #raw)
  local n = plain:byte(1) | (plain:byte(2) << 8)
  if n + 2 > #plain then return nil end
  for i = n + 2, #plain - 1 do
    if plain:byte(i + 1) ~= PAD:byte(i % 128 + 1) then return nil end
  end
  return plain:sub(3, n + 2)
end

---------------------------------------------------------------------------
-- Wire protocol
---------------------------------------------------------------------------
local function header(kind, len, status)
  return "DRINETTM" .. string.char(kind, 1, status or 0, 0) .. string.pack(">I4", len)
end

local function connect(port)
  local fd, err = S.socket(S.AF_INET, S.SOCK_STREAM, 0)
  if not fd then return nil, err end
  S.setsockopt(fd, S.SOL_SOCKET, S.SO_RCVTIMEO, M.TIMEOUT, 0)
  S.setsockopt(fd, S.SOL_SOCKET, S.SO_SNDTIMEO, M.TIMEOUT, 0)
  local ok, cerr = S.connect(fd, { family = S.AF_INET, addr = M.HOST, port = port })
  if not ok then unistd.close(fd); return nil, "connect " .. port .. ": " .. tostring(cerr) end
  return fd
end

local function sendall(fd, data)
  local off = 1
  while off <= #data do
    local n, err = S.send(fd, data:sub(off))
    if not n then return nil, err end
    off = off + n
  end
  return true
end

local EAGAIN = { [11] = true, [35] = true }

-- on_wait(elapsed_seconds) is called on every receive timeout; return false to abort.
local function recvn(fd, n, on_wait)
  local parts, got, started = {}, 0, os.time()
  while got < n do
    local chunk, err, errno = S.recv(fd, math.min(n - got, 65536))
    if not chunk and EAGAIN[errno] then
      local elapsed = os.time() - started
      if elapsed > M.MAX_WAIT or (on_wait and on_wait(elapsed) == false) then
        return nil, "timed out after " .. elapsed .. "s"
      end
    elseif not chunk or chunk == "" then
      return nil, err or "connection closed"
    else
      parts[#parts + 1] = chunk
      got = got + #chunk
    end
  end
  return table.concat(parts)
end

local function read_message(fd, on_wait)
  local h, err = recvn(fd, 16, on_wait)
  if not h then return nil, err end
  local len = string.unpack(">I4", h, 13)
  local body = ""
  if len > 0 then
    body, err = recvn(fd, len, on_wait)
    if not body then return nil, err end
  end
  return { magic = h:sub(1, 8), kind = h:byte(9), status = h:byte(11), body = body }
end

-- Read the status document from port 5000 without opening a command session.
function M.status_xml()
  local fd, err = connect(M.STATUS_PORT)
  if not fd then return nil, err end
  local msg, rerr = read_message(fd)
  unistd.close(fd)
  if not msg then return nil, rerr end
  return (msg.body:gsub("%z.*$", ""))
end

-- A session holds the status connection (required by nasd) and the command connection.
local Session = {}
Session.__index = Session

function M.open()
  local info, err = connect(M.STATUS_PORT)
  if not info then return nil, err end
  local first, rerr = read_message(info)
  if not first then unistd.close(info); return nil, "status channel: " .. tostring(rerr) end
  local status_xml = first.body:gsub("%z.*$", "")
  local id = status_xml:match("<mESAID>([^<]+)</mESAID>") or "encore"
  local cmd, cerr = connect(M.COMMAND_PORT)
  if not cmd then unistd.close(info); return nil, cerr end
  local login = string.rep("\0", 20) .. id .. string.rep("\0", 220 - 20 - #id)
  local ok, serr = sendall(cmd, header(0x07, #login) .. login)
  local reply = ok and read_message(cmd)
  if not reply or reply.kind ~= 0x87 or reply.status ~= 0 then
    unistd.close(cmd); unistd.close(info)
    return nil, "login failed: " .. tostring(serr or (reply and reply.status) or "no reply")
  end
  return setmetatable({ info = info, cmd = cmd, id = id, status_xml = status_xml }, Session)
end

function Session:command(code, data)
  data = data or ""
  local idfield = self.id .. string.rep("\0", 200 - #self.id)
  local payload = string.char(code) .. idfield .. data
  local ok, err = sendall(self.cmd, header(0x03, #payload) .. payload)
  if not ok then return nil, err end
  local reply, rerr = read_message(self.cmd, self.on_wait)
  if not reply then return nil, rerr end
  if reply.kind ~= 0x83 then return nil, string.format("unexpected reply type 0x%02x", reply.kind) end
  return reply
end

function Session:get(code)
  local reply, err = self:command(code)
  if not reply then return nil, err end
  if reply.status ~= 0 then return nil, "nasd returned status " .. reply.status end
  return (reply.body:gsub("%z.*$", ""))
end

-- Send one config document (root decides which section changes).
function Session:set(doc)
  local xml = type(doc) == "table" and M.serialize(doc) or doc
  local reply, err = self:command(M.CMD.SET_CONFIG, xml .. "\0")
  if not reply then return nil, err end
  if reply.status ~= 0 then return nil, "nasd returned status " .. reply.status end
  -- 16 bytes of per-step results; 0x01 everywhere means success.
  if reply.body ~= "" and not reply.body:find("^\1+$") then
    return nil, "nasd could not apply the change (see Drobo NAS log)"
  end
  return true
end

function Session:close()
  if self.cmd then unistd.close(self.cmd); self.cmd = nil end
  if self.info then unistd.close(self.info); self.info = nil end
end

-- Run fn(session) with a session that is always closed afterwards.
function M.with_session(fn)
  local s, err = M.open()
  if not s then return nil, "Cannot reach the Drobo NAS service: " .. tostring(err) end
  local ok, a, b = pcall(fn, s)
  s:close()
  if not ok then return nil, a end
  return a, b
end

return M
