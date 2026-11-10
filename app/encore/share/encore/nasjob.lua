-- Runs one Drobo management change in the background (nasd takes minutes to
-- apply changes on this CPU). Usage: lua nasjob.lua <job-id>
-- Reads var/jobs/<id>.req (deleted immediately), writes var/jobs/<id>.json.
local R = require("encore")
local M = require("nasmgr")

local id = assert(arg[1] and arg[1]:match("^%x+$"), "job id")
local dir = R.VAR .. "/jobs"
local reqfile, outfile, lock = dir .. "/" .. id .. ".req", dir .. "/" .. id .. ".json", dir .. "/active"

local function status(t)
  t.id = id
  R.save_json(outfile, t)
end

local req = R.load_json(reqfile, nil)
os.remove(reqfile)
if not req then status({ state = "error", message = "Job request missing" }) os.remove(lock) return end

local started = os.time()
status({ state = "running", op = req.op, started = started, label = req.label })

local OPS = {
  user_add = function(r) return M.user_add(r.name, r.password) end,
  user_password = function(r) return M.user_password(r.name, r.password) end,
  user_delete = function(r)
    local ok, err = M.user_delete(r.name)
    if ok and M.valid_username(r.name) then
      -- nasd leaves the Samba entry behind; remove it (the Linux account is already gone).
      os.execute(string.format("/usr/bin/pdbedit -s %s -x %s >/dev/null 2>&1",
        R.sh_quote(R.NASD_SMB_CONF), R.sh_quote(r.name)))
    end
    return ok, err
  end,
  share_add = function(r) return M.share_add(r.spec) end,
  share_update = function(r)
    local ok, err = M.share_update(r.old, r.spec)
    if ok and r.old ~= r.spec.name then M.rename_extras(r.old, r.spec.name) end
    return ok, err
  end,
  share_delete = function(r)
    local ok, err = M.share_delete(r.name)
    if ok then M.delete_extras(r.name) end
    return ok, err
  end,
  network_set = function(r) return M.network_set(r.spec) end,
  email_set = function(r) return M.email_set(r.spec) end,
  admin_password = function(r) return M.admin_password(r.password) end,
}

local fn = OPS[req.op]
local ok, res, err
if not fn then
  ok, res, err = true, nil, "Unknown operation"
else
  ok, res, err = pcall(fn, req)
end
if not ok then err = type(res) == "table" and res.user or tostring(res); res = nil end
if type(err) == "table" then err = err.user or tostring(err) end

local finished = os.time()
if res then
  status({ state = "done", op = req.op, label = req.label, started = started, finished = finished })
  R.log(string.format("drobo: %s finished in %ds", req.label or req.op, finished - started))
else
  status({ state = "error", op = req.op, label = req.label, started = started, finished = finished,
           message = tostring(err or "failed") })
  R.log(string.format("drobo: %s failed: %s", req.label or req.op, tostring(err)))
end
os.remove(lock)
