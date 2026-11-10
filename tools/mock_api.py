#!/usr/bin/env python3
"""Local preview of the Encore web UI with a fake API (no Drobo needed).

    python3 tools/mock_api.py [port]     ->  http://localhost:8765/   (login: admin / admin)
"""
import json, os, random, sys, time
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from urllib.parse import urlparse, parse_qs

WWW = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "app", "encore", "www")
START = time.time()
STATE = {
    "settings": {"SMB_ENABLED": "1", "SMB_MIN_PROTOCOL": "SMB2_02", "SMB_MAX_PROTOCOL": "SMB3",
                 "SMB_ENCRYPT": "if_required", "SMB_SIGNING": "default", "SMB_MACOS": "1",
                 "SMB_NETBIOS": "1", "SMB_LOG_LEVEL": "1", "WEB_PORT": "8443",
                 "ADMIN_USERS": "admin", "BONJOUR_MODEL": "Xserve"},
    "mode": "encore",
    "extras": {"TimeMachine": {"timemachine": True, "tm_max_size": "1T", "recycle": False, "hidden": False, "encrypt": "default"}},
    "cpu": [0, 0], "net": [0, 0], "disk": [0, 0],
}
JOBS = {}
def TIME_STATE():
    now = int(time.time()) + STATE.get("skew", -57600)
    return {"epoch": now, "time_zone": STATE["settings"].get("TIME_ZONE", "EST5EDT,M3.2.0,M11.1.0"),
            "ntp_servers": STATE["settings"].get("NTP_SERVERS", "pool.ntp.org time.apple.com time.google.com"),
            "sync": {"ok": STATE.get("skew", -57600) == 0, "server": "pool.ntp.org", "at": now}}
DROBO = {"version": 15, "admin": {"username": "Admin"},
         "users": [{"name": "alice"}, {"name": "bob"}],
         "shares": [{"name": "DroboData", "timemachine": False, "tm_max_gb": 0, "access": [{"user": "alice", "access": "rw"}, {"user": "Everyone", "access": "rw"}], "recycle": False, "hidden": False, "encrypt": "default"},
                    {"name": "DroboPublic", "timemachine": False, "tm_max_gb": 0, "access": [{"user": "Everyone", "access": "rw"}], "recycle": True, "hidden": False, "encrypt": "default"}],
         "network": {"name": "Drobo-FS", "workgroup": "WORKGROUP", "mac": "00:1A:62:00:00:01", "mode": "static", "ip": "192.168.1.20", "subnet": "255.255.255.0", "gateway": "192.168.1.1", "dns1": "192.168.1.1", "dns2": "9.9.9.9", "jumbo": False, "mtu": 1500},
         "email": {"enabled": True, "level": 1, "to": "alerts@example.com", "from": "drobo@example.com", "server": "smtp.example.com", "port": 25, "auth": True, "username": "drobo", "ssl": False}}
SHARES = [("Public", "/mnt/DroboFS/Shares/Public", True, ""), ("Media", "/mnt/DroboFS/Shares/Media", False, "alice, family"),
          ("TimeMachine", "/mnt/DroboFS/Shares/TimeMachine", False, "alice"), ("DroboApps", "/mnt/DroboFS/Shares/DroboApps", False, "admin")]


class H(SimpleHTTPRequestHandler):
    def __init__(self, *a, **k):
        super().__init__(*a, directory=WWW, **k)

    def log_message(self, *a):
        pass

    def send_json(self, obj, status=200, cookie=None):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        if cookie:
            self.send_header("Set-Cookie", cookie)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def authed(self):
        return "encore_sid=mock" in (self.headers.get("Cookie") or "")

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n) or b"{}")

    def do_GET(self):
        u = urlparse(self.path)
        if not u.path.startswith("/api/"):
            return super().do_GET()
        r = u.path[5:]
        if r == "session":
            return self.send_json({"authenticated": self.authed(), "user": "admin" if self.authed() else None, "hostname": "Drobo-FS"})
        if not self.authed():
            return self.send_json({"error": "Not signed in"}, 401)
        s = STATE["settings"]
        if r == "overview":
            return self.send_json({
                "hostname": "Drobo-FS", "model": "Drobo FS", "kernel": "2.6.22.18",
                "cpu": "Feroceon rev 0 (v5l)", "uptime": time.time() - START + 86400 * 3 + 5000, "load": "0.42 0.38 0.30",
                "memory": {"total": 222 * 2**20, "free": 131 * 2**20, "swap_total": 0, "swap_free": 0},
                "volume": {"total": 7.2 * 2**40, "used": 5.1 * 2**40, "free": 2.1 * 2**40},
                "interfaces": [{"name": "eth0", "ip": "192.168.1.20", "mask": "255.255.255.0", "mac": "00:1A:62:00:00:01", "mtu": 1500, "up": True}],
                "samba": {"mode": STATE["mode"], "version": "4.23.8", "enabled": s["SMB_ENABLED"] == "1",
                          "min": s["SMB_MIN_PROTOCOL"], "max": s["SMB_MAX_PROTOCOL"], "encrypt": s["SMB_ENCRYPT"]},
                "services": [{"id": "smbd", "name": "SMB file service", "running": True},
                             {"id": "nmbd", "name": "NetBIOS name service", "running": True},
                             {"id": "afpd", "name": "AFP (Apple Filing Protocol)", "running": True},
                             {"id": "avahi", "name": "Bonjour (Avahi)", "running": True},
                             {"id": "nasd", "name": "Drobo NAS daemon", "running": True},
                             {"id": "dropbear", "name": "SSH (Dropbear)", "running": False},
                             {"id": "lighttpd", "name": "Web admin", "running": True}],
                "connections": 2,
                "warnings": {"root_default_password": True, "smb1_enabled": s["SMB_MIN_PROTOCOL"] == "NT1"},
            })
        if r == "resources":
            STATE["cpu"][0] += 200; STATE["cpu"][1] += random.randint(40, 190)
            STATE["net"][0] += random.randint(0, 30_000_000); STATE["net"][1] += random.randint(0, 4_000_000)
            STATE["disk"][0] += random.randint(0, 40000); STATE["disk"][1] += random.randint(0, 20000)
            return self.send_json({"t": time.time(), "load": "0.40",
                                   "cpu": {"total": STATE["cpu"][0], "idle": STATE["cpu"][1]},
                                   "net": {"eth0": {"rx": STATE["net"][0], "tx": STATE["net"][1]}},
                                   "disk": {"read_sectors": STATE["disk"][0], "write_sectors": STATE["disk"][1]},
                                   "memory": {"total": 222 * 2**20, "free": 40 * 2**20, "buffers": 20 * 2**20, "cached": 70 * 2**20}})
        if r == "shares":
            out = []
            for name, path, guest, users in SHARES:
                ex = STATE["extras"].get(name, {})
                out.append({"name": name, "path": path, "comment": "", "guest": guest, "read_only": False,
                            "valid_users": users, "write_list": users, "timemachine": ex.get("timemachine", False),
                            "tm_max_size": ex.get("tm_max_size", ""), "recycle": ex.get("recycle", False),
                            "hidden": ex.get("hidden", False), "encrypt": ex.get("encrypt", "default")})
            return self.send_json({"shares": out})
        if r == "settings":
            return self.send_json({"settings": s})
        if r == "users":
            return self.send_json({"users": [{"name": "admin", "uid": 501, "admin": True, "changed": START - 86400 * 200},
                                             {"name": "alice", "uid": 502, "admin": False, "changed": START - 86400 * 30},
                                             {"name": "family", "uid": 503, "admin": False, "disabled": True, "changed": START - 86400 * 900}]})
        if r == "connections":
            return self.send_json({"mode": STATE["mode"], "connections": [
                {"pid": 1234, "user": "alice", "group": "alice", "machine": "192.168.1.50 (ipv4:192.168.1.50:51022)", "protocol": "SMB3_11", "encryption": "-", "signing": "AES-128-GMAC"},
                {"pid": 1301, "user": "nobody", "group": "nobody", "machine": "192.168.1.51 (ipv4:192.168.1.51:49812)", "protocol": "SMB2_10", "encryption": "-", "signing": "-"}]})
        if r == "logs":
            name = parse_qs(u.query).get("name", ["encore"])[0]
            lines = "\n".join(f"2026-11-05 20:{i:02d}:00 [{name}] sample log line {i}" for i in range(40))
            return self.send_json({"name": name, "text": lines})
        if r == "time":
            return self.send_json(TIME_STATE())
        if r == "drobo":
            return self.send_json(DROBO)
        if r == "drobo/status":
            return self.send_json({"name": "Drobo-FS", "firmware": "1.2.7 [4.45.10288]", "status_code": 32768, "dnas_status": 6,
                "protected": {"total": 3428694097920, "used": 1183784960, "free": 3427510312960}, "yellow_threshold": 85, "red_threshold": 95,
                "relayout_count": 0, "slots": [{"slot": i, "status": "healthy", "status_code": 3, "capacity": c} for i, c in
                enumerate([1000204886016, 1000204886016, 1000204886016, 500107862016, 1000204886016])]})
        if r.startswith("job/"):
            j = JOBS.setdefault(r[4:], {"polls": 0})
            j["polls"] += 1
            return self.send_json({"id": r[4:], "state": "done" if j["polls"] > 1 else "running"})
        if r == "smbconf":
            return self.send_json({"generated": "[global]\n   workgroup = WORKGROUP\n   server min protocol = SMB2_02\n...", "nasd": ""})
        return self.send_json({"error": "No such endpoint"}, 404)

    def do_POST(self):
        r = urlparse(self.path).path[5:]
        if self.headers.get("X-Encore") != "1":
            return self.send_json({"error": "Missing X-Encore header"}, 403)
        if r == "login":
            b = self.body()
            if b.get("user") == "admin" and b.get("password") == "admin":
                return self.send_json({"ok": True, "user": "admin"}, cookie="encore_sid=mock; Path=/; HttpOnly; SameSite=Strict")
            return self.send_json({"error": "Wrong user name or password."}, 401)
        if r == "logout":
            return self.send_json({"ok": True}, cookie="encore_sid=; Path=/; Max-Age=0")
        if not self.authed():
            return self.send_json({"error": "Not signed in"}, 401)
        if r in ("time/sync", "time/set"):
            STATE["skew"] = 0
            return self.send_json(TIME_STATE())
        if r == "drobo/job":
            b = self.body(); jid = "%08x" % random.getrandbits(32); JOBS[jid] = {"polls": 0}
            op = b.get("op")
            if op == "user_add": DROBO["users"].append({"name": b["name"]})
            if op == "user_delete": DROBO["users"] = [u for u in DROBO["users"] if u["name"] != b["name"]]
            if op == "share_add": DROBO["shares"].append({**b["spec"], "recycle": False, "hidden": False, "encrypt": "default"})
            if op == "share_delete": DROBO["shares"] = [s for s in DROBO["shares"] if s["name"] != b["name"]]
            return self.send_json({"job": jid})
        if r == "samba":
            a = self.body().get("action")
            STATE["mode"] = {"encore": "encore", "stock": "stock"}.get(a, STATE["mode"])
            return self.send_json({"ok": True, "mode": STATE["mode"]})
        return self.send_json({"error": "No such endpoint"}, 404)

    def do_PUT(self):
        r = urlparse(self.path).path[5:]
        if not self.authed() or self.headers.get("X-Encore") != "1":
            return self.send_json({"error": "Not signed in"}, 401)
        b = self.body()
        if r == "settings":
            STATE["settings"].update({k: str(v) for k, v in b.items()})
            return self.send_json({"ok": True, "changed": list(b), "web_restart": False})
        if r.startswith("shares/"):
            from urllib.parse import unquote
            STATE["extras"][unquote(r[7:])] = b
            return self.send_json({"ok": True})
        return self.send_json({"error": "No such endpoint"}, 404)


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
    print(f"Encore UI preview on http://localhost:{port}/  (admin / admin)")
    ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
