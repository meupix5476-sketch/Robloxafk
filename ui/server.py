#!/usr/bin/env python3
"""Painel web do Modded Crafters — zero dependências (só biblioteca padrão).

Rode via: ./scripts/ui.sh start     (abra o link com ?token=...)
Nunca exponha este painel sem o token: ele executa comandos no servidor.
"""
import http.server
import json
import os
import re
import secrets
import shutil
import socketserver
import subprocess
import threading
import time
import urllib.parse
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
SCRIPTS = ROOT / "scripts"
BEDROCK = ROOT / "bedrock-server"
BACKUPS = ROOT / "backups"
TUNNEL = ROOT / "tunnel"
UPLOADS = HERE / "uploads"
TOKEN_FILE = HERE / ".token"
INDEX_FILE = HERE / "index.html"
PORT = int(os.environ.get("UI_PORT", "8080"))
MAX_UPLOAD = 1500 * 1024 * 1024  # 1.5 GB
ALLOWED_EXT = (".mcpack", ".mcaddon", ".zip", ".mcworld")


def get_token():
    if TOKEN_FILE.exists():
        t = TOKEN_FILE.read_text().strip()
        if t:
            return t
    t = secrets.token_hex(16)
    TOKEN_FILE.write_text(t + "\n")
    try:
        os.chmod(TOKEN_FILE, 0o600)
    except OSError:
        pass
    return t


TOKEN = get_token()


def run(argv, cwd=ROOT, timeout=120):
    try:
        p = subprocess.run(argv, cwd=str(cwd), capture_output=True,
                           text=True, timeout=timeout)
        return p.returncode, (p.stdout or "") + (p.stderr or "")
    except subprocess.TimeoutExpired:
        return 124, "[TEMPO ESGOTADO]"
    except FileNotFoundError:
        return 127, "comando não encontrado"


def read_props():
    props = {}
    f = BEDROCK / "server.properties"
    if f.exists():
        for line in f.read_text(encoding="utf-8", errors="replace").splitlines():
            if "=" in line and not line.startswith("#"):
                k, v = line.split("=", 1)
                props[k.strip()] = v.strip()
    return props


def have_tmux():
    return shutil.which("tmux") is not None


def tmux_has(session):
    if not have_tmux():
        return False
    code, _ = run(["tmux", "has-session", "-t", session], timeout=10)
    return code == 0


def pid_alive(pidfile):
    try:
        pid = int(Path(pidfile).read_text().strip())
        os.kill(pid, 0)
        return True
    except (ValueError, OSError):
        return False


def pgrep_exact(name):
    code, _ = run(["pgrep", "-x", name], timeout=10)
    return code == 0


def server_online():
    if tmux_has("mc-bedrock"):
        return True
    if pid_alive(BEDROCK / "bedrock-server.pid"):
        return True
    return pgrep_exact("bedrock_server")


def playit_running():
    if tmux_has("playit"):
        return True
    if pid_alive(TUNNEL / "playit.pid"):
        return True
    code, _ = run(["pgrep", "-f", r"[t]unnel/bin/playit( |$)"], timeout=10)
    return code == 0


def tail_file(path, n):
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            data = b""
            while len(data.split(b"\n")) <= n + 1 and size > 0:
                step = min(8192, size)
                size -= step
                f.seek(size)
                data = f.read(step) + data
                if size == 0:
                    break
        return data.decode("utf-8", errors="replace").splitlines()[-n:]
    except OSError:
        return []


def mem_info():
    try:
        kv = {}
        for line in Path("/proc/meminfo").read_text().splitlines():
            k, _, v = line.partition(":")
            kv[k] = int(v.strip().split()[0])
        return {"total_mb": kv.get("MemTotal", 0) // 1024,
                "avail_mb": kv.get("MemAvailable", 0) // 1024}
    except OSError:
        return {"total_mb": 0, "avail_mb": 0}


def proc_usage():
    code, out = run(["ps", "-o", "%cpu=,%mem=,etime=", "-C",
                     "bedrock_server"], timeout=10)
    if code != 0 or not out.strip():
        return None
    parts = out.split()
    if len(parts) < 3:
        return None
    return {"cpu": parts[0], "mem": parts[1], "etime": parts[2]}


def dir_size(p):
    total = 0
    try:
        for dp, _, fns in os.walk(p):
            for fn in fns:
                try:
                    total += (Path(dp) / fn).stat().st_size
                except OSError:
                    pass
    except OSError:
        pass
    return total


def fmt_bytes(n):
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024:
            return f"{n:.1f} {unit}" if unit != "B" else f"{n} B"
        n /= 1024
    return f"{n:.1f} PB"


def tunnel_info():
    info = {"running": playit_running(), "host": "", "port": "",
            "has_secret": (TUNNEL / "playit.toml").exists()
            or bool(os.environ.get("PLAYIT_SECRET")),
            "agent": (TUNNEL / "bin" / "playit").exists()}
    f = TUNNEL / "tunnel-info.txt"
    if f.exists():
        for line in f.read_text(errors="replace").splitlines():
            m = re.match(r'TUNNEL_(HOST|PORT)="?(.*?)"?$', line.strip())
            if m:
                info[m.group(1).lower()] = m.group(2)
    return info


def list_backups():
    items = []
    if BACKUPS.exists():
        for p in sorted(BACKUPS.glob("world-*.tar.gz"),
                        key=lambda x: x.stat().st_mtime, reverse=True):
            st = p.stat()
            items.append({"name": p.name, "size": fmt_bytes(st.st_size),
                          "mtime": time.strftime("%d/%m %H:%M",
                                                 time.localtime(st.st_mtime))})
    return items


TASKS = {}
TASKS_LOCK = threading.Lock()
TASK_SEQ = [0]


def new_task(label):
    with TASKS_LOCK:
        TASK_SEQ[0] += 1
        tid = str(TASK_SEQ[0])
        TASKS[tid] = {"id": tid, "label": label, "running": True,
                      "code": None, "output": "", "started": time.time()}
    return tid


def task_append(tid, text):
    with TASKS_LOCK:
        t = TASKS.get(tid)
        if t is not None:
            t["output"] = (t["output"] + text)[-200000:]


def task_finish(tid, code):
    with TASKS_LOCK:
        t = TASKS.get(tid)
        if t:
            t["running"] = False
            t["code"] = code


def start_task(label, argv_list):
    tid = new_task(label)

    def worker():
        code = 0
        for argv in argv_list:
            task_append(tid, "$ " + " ".join(argv) + "\n")
            try:
                p = subprocess.Popen(
                    argv, cwd=str(ROOT), stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT, text=True, bufsize=1)
            except OSError as e:
                task_append(tid, f"[falha ao executar: {e}]\n")
                code = 1
                break
            for line in p.stdout:
                task_append(tid, line)
            p.wait()
            code = p.returncode
            if code != 0:
                break
        task_append(tid, f"\n[concluído — código {code}]\n")
        task_finish(tid, code)

    threading.Thread(target=worker, daemon=True).start()
    return tid


def parse_multipart(body, content_type):
    """Parser mínimo p/ 1 arquivo + campos texto. Retorna (fields, filename, data)."""
    m = re.search(r"boundary=([^;]+)", content_type or "")
    if not m:
        return None, None, None
    b = ("--" + m.group(1).strip().strip('"')).encode()
    fields, filename, data = {}, None, None
    for part in body.split(b):
        if b"Content-Disposition" not in part:
            continue
        head, _, content = part.partition(b"\r\n\r\n")
        if not content:
            continue
        content = content[:-2] if content.endswith(b"\r\n") else content
        h = head.decode("latin1")
        fn = re.search(r'filename="([^"]*)"', h)
        nm = re.search(r'name="([^"]*)"', h)
        if fn and fn.group(1):
            filename = os.path.basename(fn.group(1))
            data = content
        elif nm:
            fields[nm.group(1)] = content.decode("utf-8", errors="replace")
    return fields, filename, data


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "ModdedCraftersUI/1.0"

    def log_message(self, *a):
        pass

    def _send(self, code, obj, ctype="application/json"):
        if isinstance(obj, str):
            raw = obj.encode("utf-8")
        elif isinstance(obj, bytes):
            raw = obj
        else:
            raw = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype + "; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def _deny(self):
        self._send(403, {"ok": False, "error": "token inválido ou ausente"})

    def _auth(self, query):
        tok = query.get("token", [""])[0]
        if not tok:
            tok = self.headers.get("X-UI-Token", "")
        return bool(tok) and secrets.compare_digest(tok, TOKEN)

    def _json_body(self):
        try:
            n = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            n = 0
        if n <= 0 or n > 1024 * 1024:
            return {}
        try:
            return json.loads(self.rfile.read(n).decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            return {}

    def do_GET(self):
        url = urllib.parse.urlsplit(self.path)
        q = urllib.parse.parse_qs(url.query)
        path = url.path
        if path == "/favicon.ico":
            self.send_response(204)
            self.end_headers()
            return
        if path == "/":
            if INDEX_FILE.exists():
                self._send(200, INDEX_FILE.read_bytes(), "text/html")
            else:
                self._send(500, "index.html não encontrado", "text/plain")
            return
        if not self._auth(q):
            self._deny()
            return
        if path == "/api/status":
            props = read_props()
            lvl = props.get("level-name", "Survival")
            wdir = BEDROCK / "worlds" / lvl
            du = shutil.disk_usage(ROOT)
            bks = list_backups()
            try:
                nbp = sum(1 for d in (BEDROCK / "behavior_packs").iterdir()
                          if d.is_dir())
                nrp = sum(1 for d in (BEDROCK / "resource_packs").iterdir()
                          if d.is_dir())
            except OSError:
                nbp = nrp = 0
            vf = BEDROCK / "VERSION"
            self._send(200, {
                "online": server_online(),
                "version": vf.read_text().strip() if vf.exists() else "?",
                "world": lvl,
                "world_size": fmt_bytes(dir_size(wdir)) if wdir.exists() else "—",
                "gamemode": props.get("gamemode", "?"),
                "difficulty": props.get("difficulty", "?"),
                "max_players": props.get("max-players", "?"),
                "packs_bp": nbp, "packs_rp": nrp,
                "tunnel": tunnel_info(),
                "ram": mem_info(),
                "disk": {"total_gb": round(du.total / 1e9, 1),
                         "free_gb": round(du.free / 1e9, 1)},
                "proc": proc_usage(),
                "backups_count": len(bks),
                "latest_backup": bks[0]["name"] if bks else "",
            })
            return
        if path == "/api/logs":
            src = q.get("src", ["server"])[0]
            try:
                n = max(10, min(500, int(q.get("lines", ["150"])[0])))
            except ValueError:
                n = 150
            if src == "tunnel":
                lines = tail_file(TUNNEL / "playitd.log", n)
                if not lines:
                    lines = ["(túnel sem log ainda — ligue com Ligar túnel)"]
            elif tmux_has("mc-bedrock"):
                code, out = run(["tmux", "capture-pane", "-p", "-t",
                                 "mc-bedrock", "-S", f"-{n}"], timeout=10)
                lines = out.splitlines() if code == 0 else ["(falha no tmux)"]
            else:
                lines = tail_file(BEDROCK / "server.log", n)
                if not lines:
                    lines = ["(servidor offline — inicie para ver o console)"]
            self._send(200, {"lines": lines[-n:]})
            return
        if path == "/api/backups":
            self._send(200, {"backups": list_backups()})
            return
        if path == "/api/download":
            name = os.path.basename(q.get("file", [""])[0])
            f = BACKUPS / name
            if not (name.endswith(".tar.gz") and f.is_file()):
                self._send(404, {"ok": False, "error": "arquivo inválido"})
                return
            raw = f.read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "application/gzip")
            self.send_header("Content-Disposition",
                             f'attachment; filename="{name}"')
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)
            return
        if path == "/api/task":
            with TASKS_LOCK:
                t = TASKS.get(q.get("id", [""])[0])
            if t is None:
                self._send(404, {"ok": False, "error": "tarefa inexistente"})
            else:
                self._send(200, t)
            return
        if path == "/api/tunnel":
            self._send(200, tunnel_info())
            return
        self._send(404, {"ok": False, "error": "rota inexistente"})

    def do_POST(self):
        url = urllib.parse.urlsplit(self.path)
        q = urllib.parse.parse_qs(url.query)
        if not self._auth(q):
            self._deny()
            return
        path = url.path
        if path == "/api/upload":
            try:
                n = int(self.headers.get("Content-Length", "0"))
            except ValueError:
                n = 0
            if n <= 0 or n > MAX_UPLOAD:
                self._send(400, {"ok": False,
                                 "error": "arquivo vazio ou maior que 1.5 GB"})
                return
            body = self.rfile.read(n)
            fields, fname, data = parse_multipart(
                body, self.headers.get("Content-Type", ""))
            if not fname or data is None:
                self._send(400, {"ok": False, "error": "nenhum arquivo enviado"})
                return
            if not fname.lower().endswith(ALLOWED_EXT):
                self._send(400, {"ok": False, "error":
                                 "extensão inválida (use .mcpack/.mcaddon/.zip/.mcworld)"})
                return
            UPLOADS.mkdir(parents=True, exist_ok=True)
            dest = UPLOADS / fname
            if dest.exists():
                dest = UPLOADS / (f"{int(time.time())}_{fname}")
                fname = dest.name
            dest.write_bytes(data)
            argv = [str(SCRIPTS / "install-addon.sh"), str(dest)]
            if fields.get("set_level") == "1":
                argv.append("--set-level")
            tid = start_task("Instalar addon", [argv])
            self._send(200, {"ok": True, "task": tid, "file": fname})
            return
        body = self._json_body()
        if path == "/api/cmd":
            cmd = str(body.get("command", "")).strip()
            if not cmd:
                self._send(400, {"ok": False, "error": "comando vazio"})
                return
            code, out = run([str(SCRIPTS / "cmd.sh"), cmd], timeout=30)
            self._send(200, {"ok": code == 0, "output": out,
                             "error": None if code == 0 else out.strip()})
            return
        if path == "/api/start":
            code, out = run([str(SCRIPTS / "start.sh"), "--background"],
                            timeout=60)
            self._send(200, {"ok": code == 0, "output": out,
                             "error": None if code == 0 else out.strip()})
            return
        if path == "/api/stop":
            self._send(200, {"ok": True, "task": start_task(
                "Parar servidor", [[str(SCRIPTS / "stop.sh")]])})
            return
        if path == "/api/restart":
            self._send(200, {"ok": True, "task": start_task(
                "Reiniciar", [[str(SCRIPTS / "stop.sh")],
                              [str(SCRIPTS / "start.sh"), "--background"]])})
            return
        if path == "/api/backup":
            self._send(200, {"ok": True, "task": start_task(
                "Backup", [[str(SCRIPTS / "backup.sh")]])})
            return
        if path == "/api/update":
            self._send(200, {"ok": True, "task": start_task(
                "Atualizar Bedrock", [[str(SCRIPTS / "update.sh")]])})
            return
        if path == "/api/restore":
            name = os.path.basename(str(body.get("file", "")))
            f = BACKUPS / name
            if not (name.endswith(".tar.gz") and f.is_file()):
                self._send(400, {"ok": False, "error": "backup inválido"})
                return
            self._send(200, {"ok": True, "task": start_task(
                "Restaurar", [[str(SCRIPTS / "restore.sh"), str(f), "--yes"]])})
            return
        if path == "/api/tunnel/save":
            host = str(body.get("host", "")).strip()
            port = str(body.get("port", "")).strip()
            if not host or not port:
                self._send(400, {"ok": False, "error": "host/porta vazios"})
                return
            code, out = run([str(SCRIPTS / "tunnel.sh"), "set", host, port],
                            timeout=30)
            self._send(200, {"ok": code == 0, "output": out})
            return
        if path == "/api/tunnel/start":
            code, out = run([str(SCRIPTS / "tunnel.sh"), "start"], timeout=60)
            self._send(200, {"ok": code == 0, "output": out,
                             "error": None if code == 0 else out.strip()})
            return
        if path == "/api/tunnel/stop":
            code, out = run([str(SCRIPTS / "tunnel.sh"), "stop"], timeout=60)
            self._send(200, {"ok": code == 0, "output": out})
            return
        if path == "/api/tunnel/claim":
            code, out = run([str(SCRIPTS / "tunnel.sh"), "claim-url"],
                            timeout=120)
            if code != 0 or "|" not in out:
                self._send(500, {"ok": False,
                                 "error": "falha ao gerar link: " + out.strip()})
                return
            claim_code, _, claim_url = out.strip().splitlines()[-1].partition("|")
            self._send(200, {"ok": True, "code": claim_code.strip(),
                             "url": claim_url.strip()})
            return
        if path == "/api/tunnel/exchange":
            claim_code = str(body.get("code", "")).strip()
            if not claim_code:
                self._send(400, {"ok": False, "error": "código vazio"})
                return
            code, out = run([str(SCRIPTS / "tunnel.sh"), "claim-finish",
                             claim_code], timeout=180)
            self._send(200, {"ok": code == 0,
                             "error": None if code == 0 else out.strip()})
            return
        self._send(404, {"ok": False, "error": "rota inexistente"})


def main():
    try:
        UPLOADS.mkdir(parents=True, exist_ok=True)
        with socketserver.ThreadingTCPServer(
                ("0.0.0.0", PORT), Handler) as httpd:
            httpd.daemon_threads = True
            httpd.allow_reuse_address = True
            print(f"[ui] painel na porta {PORT} (token em ui/.token)",
                  flush=True)
            httpd.serve_forever()
    except OSError as e:
        print(f"[ui] ERRO ao abrir porta {PORT}: {e}", flush=True)
        sys.exit(1)


if __name__ == "__main__":
    main()