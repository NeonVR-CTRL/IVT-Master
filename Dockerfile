
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    PORT=8080 \
    LINK_PORT=8081 \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    IVT_ROLE=master \
    TERM=xterm-256color \
    LANG=C.UTF-8

RUN printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d && chmod +x /usr/sbin/policy-rc.d && touch /.dockerenv

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      bash coreutils procps util-linux mawk ca-certificates curl wget sudo \
      python3 python3-venv systemd-sysv openssh-server passwd \
      vim nano htop tmux screen git unzip zip tar less tree \
      net-tools iproute2 dnsutils iputils-ping traceroute \
      cron rsyslog logrotate locales tzdata && \
    locale-gen C.UTF-8 && \
    python3 -m venv /opt/ivt-venv && \
    /opt/ivt-venv/bin/pip install --no-cache-dir aiohttp asyncssh && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /usr/share/doc/* /usr/share/man/* /usr/share/info/* /var/cache/apt/*

RUN printf 'PRETTY_NAME="Ubuntu 24.04.1 LTS"\nNAME="Ubuntu"\nVERSION_ID="24.04"\nVERSION="24.04.1 LTS (Noble Numbat)"\nVERSION_CODENAME=noble\nID=ubuntu\nID_LIKE=debian\nHOME_URL="https://www.ubuntu.com/"\nSUPPORT_URL="https://help.ubuntu.com/"\nBUG_REPORT_URL="https://bugs.launchpad.net/ubuntu/"\nUBUNTU_CODENAME=noble\nLOGO=ubuntu-logo\n' > /etc/os-release

RUN mkdir -p \
      /ivt/os \
      /etc/ivt/units /etc/ivt/targets/default.wants /etc/ivt/targets/multi-user.target.wants \
      /home/container/.ivt/run/ctrl /home/container/.ivt/run/pids /home/container/.ivt/run/state /home/container/.ivt/run/manual /home/container/.ivt/run/link \
      /home/container/.ivt/log \
      /etc/systemd/system /lib/systemd/system /run/systemd /var/run/sshd

# ==========================================
# IVT FAKE SYSTEMD INIT
# ==========================================

RUN cat > /ivt/os/init << 'INITEOF'
#!/bin/bash
set -euo pipefail
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
RUN_DIR=/home/container/.ivt/run
UNITS=/etc/ivt/units
TARGETS=/etc/ivt/targets
LOG=/home/container/.ivt/log
TARGET_FILE=/etc/ivt/default.target

mkdir -p "$RUN_DIR"/{ctrl,pids,state,manual,link} "$LOG"
cat /proc/sys/kernel/random/uuid > "$RUN_DIR/machine-id" || true
cat /proc/sys/kernel/random/uuid > "$RUN_DIR/boot-id"
date +%s > "$RUN_DIR/boottime"

declare -A PIDS=()
declare -A RESTART=()

log_system() { echo "$(date -Is) $*" >> "$LOG/system.log"; }

get_value() {
  local file="$1" section="$2" key="$3"
  mawk -v section="$section" -v key="$key" '
    BEGIN { c="" }
    /^\[/ { c=$0; gsub(/[\[\] \t\r]/,"",c); next }
    c == section {
      p = index($0,"=")
      if (p > 0) {
        k = substr($0,1,p-1); gsub(/[ \t\r]/,"",k)
        if (k == key) { v = substr($0,p+1); sub(/\r$/,"",v); print v; exit }
      }
    }
  ' "$file" 2>/dev/null
}

kill_tree() {
  local pid="$1" sig="${2:-TERM}"
  local children
  children=$(pgrep -P "$pid" 2>/dev/null || true)
  local child
  for child in $children; do kill_tree "$child" "$sig"; done
  kill -"$sig" "$pid" 2>/dev/null || true
}

service_start() {
  local unitfile="$1"
  local name
  name=$(basename "$1" .service)
  local pidfile="$RUN_DIR/pids/$name.pid"

  if [[ -f "$pidfile" ]] && kill -0 "$(cat "$pidfile" 2>/dev/null)" 2>/dev/null; then
    echo "running" > "$RUN_DIR/state/$name"
    return 0
  fi

  rm -f "$RUN_DIR/manual/$name"

  local execstart workdir restart restartsec env_file env_vars
  execstart=$(get_value "$unitfile" Service ExecStart)
  workdir=$(get_value "$unitfile" Service WorkingDirectory)
  restart=$(get_value "$unitfile" Service Restart)
  restartsec=$(get_value "$unitfile" Service RestartSec)
  env_file=$(get_value "$unitfile" Service EnvironmentFile)
  env_vars=$(get_value "$unitfile" Service Environment)

  restart="${restart:-no}"
  restartsec="${restartsec:-1}"

  if [[ -z "$execstart" ]]; then
    echo "failed" > "$RUN_DIR/state/$name"
    return 1
  fi

  echo "starting" > "$RUN_DIR/state/$name"

  (
    set +e
    if [[ -n "$workdir" ]]; then cd "$workdir" || exit 1; fi

    if [[ -n "$env_file" ]]; then
      local clean_env="${env_file#-}"
      if [[ -f "$clean_env" ]]; then set -a; . "$clean_env" || true; set +a; fi
    fi

    if [[ -n "$env_vars" ]]; then
      env_vars="${env_vars%\"}"; env_vars="${env_vars#\"}"
      env_vars="${env_vars%\'}"; env_vars="${env_vars#\'}"
      export $env_vars
    fi

    set -e
    exec /bin/sh -c "$execstart" >> "$LOG/$name.log" 2>&1
  ) &

  local pid=$!
  echo "$pid" > "$pidfile"
  echo "running" > "$RUN_DIR/state/$name"
  PIDS[$pid]="$name"
  RESTART[$name]="$restart:$restartsec"
  log_system "started $name pid=$pid"
}

service_stop() {
  local name="$1"
  local pidfile="$RUN_DIR/pids/$name.pid"
  touch "$RUN_DIR/manual/$name"

  if [[ -f "$pidfile" ]]; then
    local pid
    pid=$(cat "$pidfile" 2>/dev/null || true)
    if [[ -n "$pid" ]]; then
      kill_tree "$pid" TERM
      local i
      for i in $(seq 1 20); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.1
      done
      kill_tree "$pid" KILL
      unset "PIDS[$pid]" 2>/dev/null || true
    fi
    rm -f "$pidfile"
  fi

  echo "stopped" > "$RUN_DIR/state/$name"
  log_system "stopped $name"
}

shutdown_system() {
  log_system "shutdown requested"
  local pid
  for pid in "${!PIDS[@]}"; do kill_tree "$pid" TERM; done
  sleep 1
  for pid in "${!PIDS[@]}"; do kill_tree "$pid" KILL; done
  exit 0
}

main() {
  local target cmd name policy restart_policy restart_sec
  target=$(cat "$TARGET_FILE" 2>/dev/null || echo "default")
  local fifo="$RUN_DIR/ctrl/control.fifo"

  rm -f "$fifo"
  mkfifo "$fifo"
  exec 3<>"$fifo"

  log_system "IVT-D MASTER starting target=$target"

  for unit in "$TARGETS/$target.wants"/*.service; do
    [[ -e "$unit" ]] && service_start "$unit"
  done

  trap shutdown_system TERM INT

  while true; do
    if read -r -t 1 -u 3 cmd; then
      case "$cmd" in
        start:*) service_start "$UNITS/${cmd#start:}.service" ;;
        stop:*) service_stop "${cmd#stop:}" ;;
        restart:*) service_stop "${cmd#restart:}"; sleep 0.2; service_start "$UNITS/${cmd#restart:}.service" ;;
        shutdown|poweroff) shutdown_system ;;
      esac
    fi

    for pid in "${!PIDS[@]}"; do
      if ! kill -0 "$pid" 2>/dev/null; then
        name="${PIDS[$pid]}"
        unset "PIDS[$pid]" 2>/dev/null || true
        rm -f "$RUN_DIR/pids/$name.pid"

        if [[ -f "$RUN_DIR/manual/$name" ]]; then
          echo "stopped" > "$RUN_DIR/state/$name"
          continue
        fi

        policy="${RESTART[$name]:-no:1}"
        restart_policy="${policy%%:*}"
        restart_sec="${policy##*:}"

        if [[ "$restart_policy" == "always" || "$restart_policy" == "on-failure" ]]; then
          log_system "restarting $name in ${restart_sec}s"
          sleep "$restart_sec" 2>/dev/null || true
          service_start "$UNITS/$name.service"
        else
          echo "exited" > "$RUN_DIR/state/$name"
        fi
      fi
    done

    sleep 0.5
  done
}

main "$@"
INITEOF

# ==========================================
# FAKE SYSTEMCTL
# ==========================================

RUN cat > /usr/local/bin/systemctl << 'SYSCTL_EOF'
#!/bin/bash
set -euo pipefail
RUN_DIR=/home/container/.ivt/run
UNITS=/etc/ivt/units
TARGETS=/etc/ivt/targets
LOG=/home/container/.ivt/log

is_running() {
  local name="$1"
  local state
  state=$(cat "$RUN_DIR/state/$name" 2>/dev/null || echo "inactive")

  if [[ "$state" == "running" ]]; then
    local pid
    pid=$(cat "$RUN_DIR/pids/$name.pid" 2>/dev/null || echo "")
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then return 0; fi
  fi

  if ps -eo pid,args 2>/dev/null | grep -v grep | grep -qE "/usr/local/$name/$name|/usr/local/x-ui/$name"; then return 0; fi
  if pgrep -f "/usr/local/$name/$name" > /dev/null 2>&1; then return 0; fi
  return 1
}

find_unit_arg() {
  local arg
  for arg in "$@"; do
    case "$arg" in -*) continue ;; *) echo "${arg%.service}"; return ;; esac
  done
  echo ""
}

ensure_unit() {
  local unit="${1%.service}.service"
  local sys_unit="/etc/systemd/system/$unit"
  local ivt_unit="$UNITS/$unit"

  if [[ -f "$sys_unit" && ! -e "$ivt_unit" ]]; then
    cp "$sys_unit" "$ivt_unit" 2>/dev/null || true
    chmod 644 "$ivt_unit" 2>/dev/null || true
  fi
}

send_cmd() {
  local fifo="$RUN_DIR/ctrl/control.fifo"
  if [[ -p "$fifo" ]]; then echo "$1" > "$fifo"; else echo "IVT-D not running" >&2; return 1; fi
}

main() {
  local cmd="${1:-}"
  shift || true

  case "$cmd" in
    start|stop|restart)
      local unit
      unit=$(find_unit_arg "$@")
      ensure_unit "$unit"
      send_cmd "$cmd:$unit"
      echo "$cmd request sent: $unit"
      ;;
    enable)
      local unit
      unit=$(find_unit_arg "$@")
      ensure_unit "$unit"
      mkdir -p "$TARGETS/default.wants" "$TARGETS/multi-user.target.wants"
      ln -sf "$UNITS/$unit.service" "$TARGETS/default.wants/$unit.service" 2>/dev/null || true
      ln -sf "$UNITS/$unit.service" "$TARGETS/multi-user.target.wants/$unit.service" 2>/dev/null || true
      echo "Created symlink"
      ;;
    disable)
      local unit
      unit=$(find_unit_arg "$@")
      rm -f "$TARGETS/default.wants/$unit.service" "$TARGETS/multi-user.target.wants/$unit.service"
      echo "Removed symlink"
      ;;
    is-active)
      local unit
      unit=$(find_unit_arg "$@")
      ensure_unit "$unit"
      if is_running "$unit"; then echo "active"; exit 0; fi
      echo "inactive"
      exit 3
      ;;
    is-enabled)
      local unit
      unit=$(find_unit_arg "$@")
      ensure_unit "$unit"
      if [[ -e "$TARGETS/default.wants/$unit.service" || -e "$TARGETS/multi-user.target.wants/$unit.service" ]]; then
        echo "enabled"
        exit 0
      else
        echo "disabled"
        exit 1
      fi
      ;;
    show)
      local unit
      unit=$(find_unit_arg "$@")
      ensure_unit "$unit"
      local prop="SubState" a
      for a in "$@"; do case "$a" in --property=*) prop="${a#--property=}" ;; esac; done
      if is_running "$unit"; then echo "${prop}=running"; else echo "${prop}=dead"; fi
      ;;
    daemon-reload)
      local f
      for f in /etc/systemd/system/*.service; do
        [[ -e "$f" ]] || continue
        cp "$f" "$UNITS/"
      done
      echo "IVT-D: daemon-reload simulated (units synced)"
      ;;
    status)
      if [[ -n "${1:-}" && "${1}" != -* ]]; then
        local unit="${1%.service}"
        ensure_unit "$unit"

        if is_running "$unit"; then
          echo "● $unit.service"
          echo "     Loaded: loaded (/etc/ivt/units/$unit.service; enabled)"
          echo "     Active: active (running)"
          local pid
          pid=$(cat "$RUN_DIR/pids/$unit.pid" 2>/dev/null || echo "-")
          echo "   Main PID: $pid"

          if [[ -f "$LOG/$unit.log" ]]; then
            echo "     Logs:"
            tail -n 5 "$LOG/$unit.log" | sed 's/^/     /'
          fi
        else
          echo "● $unit.service"
          echo "     Loaded: loaded (/etc/ivt/units/$unit.service; enabled)"
          echo "     Active: inactive (dead)"
        fi
      else
        printf '%-20s %-10s %-8s %-8s\n' "UNIT" "STATE" "PID" "ENABLED"
        local unit_file unit_name state pid enabled
        declare -A seen=()

        for unit_file in "$UNITS"/*.service /etc/systemd/system/*.service; do
          [[ -e "$unit_file" ]] || continue
          unit_name=$(basename "$unit_file" .service)
          [[ -n "${seen[$unit_name]:-}" ]] && continue
          seen[$unit_name]=1

          if is_running "$unit_name"; then state="running"; else state="inactive"; fi
          pid=$(cat "$RUN_DIR/pids/$unit_name.pid" 2>/dev/null || echo "-")
          enabled="no"
          [[ -e "$TARGETS/default.wants/$unit_name.service" || -e "$TARGETS/multi-user.target.wants/$unit_name.service" ]] && enabled="yes"
          printf '%-20s %-10s %-8s %-8s\n' "$unit_name" "$state" "$pid" "$enabled"
        done
      fi
      ;;
    --version) echo "systemd 255 (Ubuntu 24.04)"; exit 0 ;;
    *) exit 0 ;;
  esac
}

main "$@"
SYSCTL_EOF

RUN cat > /usr/local/bin/service << 'SVC_EOF'
#!/bin/bash
set -euo pipefail
if [[ $# -lt 2 ]]; then echo "Usage: service <unit> {start|stop|restart|status}" >&2; exit 1; fi
exec /usr/local/bin/systemctl "$2" "${1%.service}"
SVC_EOF

RUN cat > /usr/local/bin/journalctl << 'JCTL_EOF'
#!/bin/bash
set -euo pipefail
LOG=/home/container/.ivt/log
unit=""
lines=50
follow=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -u|--unit) shift; unit="${1:-}" ;;
    --unit=*) unit="${1#--unit=}" ;;
    -n|--lines) shift; lines="${1:-50}" ;;
    --lines=*) lines="${1#--lines=}" ;;
    -f|--follow) follow=true ;;
    *) shift ;;
  esac
done

unit="${unit%.service}"
file="$LOG/${unit:-system}.log"

if [[ ! -f "$file" ]]; then echo "-- No entries --"; exit 0; fi
if $follow; then exec tail -f "$file"; else exec tail -n "$lines" "$file"; fi
JCTL_EOF

RUN cat > /usr/local/bin/hostnamectl << 'HCTL_EOF'
#!/bin/bash
set -euo pipefail
RUN_DIR=/home/container/.ivt/run

main() {
  local cmd="${1:-status}"
  case "$cmd" in
    status)
      echo " Static hostname: $(cat "$RUN_DIR/hostname" 2>/dev/null || cat /etc/hostname 2>/dev/null || echo ivt-master)"
      echo "  Operating System: $(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-Ubuntu}")"
      echo "          Kernel: $(uname -r)"
      ;;
    set-hostname) echo "${2:-ivt-master}" > "$RUN_DIR/hostname" 2>/dev/null || true ;;
    hostname) cat "$RUN_DIR/hostname" 2>/dev/null || cat /etc/hostname 2>/dev/null || echo ivt-master ;;
  esac
}
main "$@"
HCTL_EOF

# ==========================================
# IVT MASTER API + EMBEDDED SSH TERMINAL
# ==========================================

RUN cat > /ivt/os/api.py << 'API_EOF'
#!/opt/ivt-venv/bin/python
import os
import html
import hmac
import json
import asyncio
import subprocess
from aiohttp import web
import asyncssh

PORT = int(os.environ.get("PORT", 8080))

def run(cmd):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=5)
        return r.stdout.strip()
    except Exception as e:
        return f"ERROR: {e}"

PAGE = r"""
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>IVT-OS MASTER</title>
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/xterm@5.3.0/css/xterm.css">
<style>
*{box-sizing:border-box}
body{background:#10151f;color:#dce7f5;font-family:Arial,sans-serif;margin:0;padding:24px}
h1{color:#56d6a0}
.panel{background:#192333;padding:18px;border-radius:10px;margin:16px 0}
input{background:#10151f;color:white;border:1px solid #526477;padding:10px;border-radius:5px;margin:5px}
button{background:#168b67;color:white;border:0;padding:10px 18px;border-radius:6px;cursor:pointer;margin:5px}
button:hover{background:#20a47e}
#terminal{height:430px;background:#080c12;padding:8px;border-radius:8px}
pre{white-space:pre-wrap;overflow-wrap:anywhere}
</style>
</head>
<body>
<h1>IVT-OS MASTER</h1>

<div class="panel">
<h2>System status</h2>
<pre id="status">Loading...</pre>
</div>

<div class="panel">
<h2>Linux SSH Terminal</h2>
<p>Sign in using a Linux username and password.</p>
<form id="login">
<input id="username" autocomplete="username" placeholder="Linux username" required>
<input id="password" type="password" autocomplete="current-password" placeholder="Linux password" required>
<button type="submit">Connect</button>
<button type="button" onclick="disconnectTerminal()">Disconnect</button>
</form>
<div id="terminal"></div>
</div>

<script src="https://cdn.jsdelivr.net/npm/xterm@5.3.0/lib/xterm.js"></script>
<script>
const term = new Terminal({
  cursorBlink:true,
  fontSize:14,
  fontFamily:"monospace",
  theme:{background:"#080c12",foreground:"#dce7f5"}
});
term.open(document.getElementById("terminal"));

let socket=null;

async function refresh(){
  try{
    const r=await fetch("/api/status");
    document.getElementById("status").textContent=await r.text();
  }catch(e){}
}
refresh();
setInterval(refresh,5000);

function disconnectTerminal(){
  if(socket) socket.close();
  socket=null;
  term.writeln("\r\n[Disconnected]");
}

document.getElementById("login").addEventListener("submit",function(event){
  event.preventDefault();

  const username=document.getElementById("username").value;
  const password=document.getElementById("password").value;

  if(socket) socket.close();

  term.clear();
  term.writeln("Connecting to IVT Linux SSH...");

  const protocol=location.protocol==="https:"?"wss:":"ws:";
  socket=new WebSocket(protocol+"//"+location.host+"/terminal");

  socket.onopen=()=>{
    socket.send(JSON.stringify({
      type:"login",
      username:username,
      password:password
    }));
  };

  socket.onmessage=(event)=>{
    try{
      const data=JSON.parse(event.data);
      if(data.type==="ready"){
        term.writeln("\r\n[SSH connected]\r\n");
        term.focus();
      }else if(data.type==="error"){
        term.writeln("\r\n[ERROR] "+data.message);
      }
    }catch(e){
      term.write(event.data);
    }
  };

  socket.onclose=()=>term.writeln("\r\n[Connection closed]");
  socket.onerror=()=>term.writeln("\r\n[WebSocket error]");
});

term.onData(data=>{
  if(socket && socket.readyState===WebSocket.OPEN){
    socket.send(JSON.stringify({type:"input",data:data}));
  }
});

term.onResize(size=>{
  if(socket && socket.readyState===WebSocket.OPEN){
    socket.send(JSON.stringify({
      type:"resize",
      cols:size.cols,
      rows:size.rows
    }));
  }
});
</script>
</body>
</html>
"""

async def dashboard(request):
    return web.Response(text=PAGE, content_type="text/html")

async def health(request):
    return web.Response(text="OK")

async def status(request):
    return web.Response(text=run(["systemctl","status"]))

async def system_info(request):
    return web.Response(text=run(["hostnamectl","status"]))

async def terminal(request):
    ws = web.WebSocketResponse(heartbeat=30, max_msg_size=1024 * 1024)
    await ws.prepare(request)

    process = None

    try:
        message = await asyncio.wait_for(ws.receive(), timeout=30)

        if message.type != web.WSMsgType.TEXT:
            await ws.send_json({"type":"error","message":"Login required"})
            await ws.close()
            return ws

        credentials = json.loads(message.data)

        username = str(credentials.get("username", ""))
        password = str(credentials.get("password", ""))

        if not username or not password:
            await ws.send_json({"type":"error","message":"Username and password required"})
            await ws.close()
            return ws

        async with asyncssh.connect(
            "127.0.0.1",
            port=22,
            username=username,
            password=password,
            known_hosts=None
        ) as conn:

            process = await conn.create_process(
                term_type="xterm-256color",
                term_size=(100,30)
            )

            await ws.send_json({"type":"ready"})

            async def ssh_to_browser():
                while not ws.closed:
                    data = await process.stdout.read(4096)
                    if not data:
                        break
                    await ws.send_str(data)

            async def browser_to_ssh():
                async for msg in ws:
                    if msg.type == web.WSMsgType.TEXT:
                        item = json.loads(msg.data)

                        if item.get("type") == "input":
                            process.stdin.write(item.get("data",""))
                            await process.stdin.drain()

                        elif item.get("type") == "resize":
                            process.change_terminal_size(
                                int(item.get("cols",100)),
                                int(item.get("rows",30))
                            )

            tasks = [
                asyncio.create_task(ssh_to_browser()),
                asyncio.create_task(browser_to_ssh())
            ]

            done, pending = await asyncio.wait(
                tasks,
                return_when=asyncio.FIRST_COMPLETED
            )

            for task in pending:
                task.cancel()

    except asyncssh.PermissionDenied:
        if not ws.closed:
            await ws.send_json({"type":"error","message":"Linux username or password incorrect"})

    except Exception as e:
        if not ws.closed:
            await ws.send_json({"type":"error","message":str(e)})

    finally:
        if process:
            process.close()
        if not ws.closed:
            await ws.close()

    return ws

app = web.Application()
app.router.add_get("/", dashboard)
app.router.add_get("/health", health)
app.router.add_get("/api/status", status)
app.router.add_get("/api/sys", system_info)
app.router.add_get("/terminal", terminal)

if __name__ == "__main__":
    web.run_app(app, host="0.0.0.0", port=PORT)
API_EOF

# ==========================================
# IVT LINK MASTER
# ==========================================

RUN cat > /ivt/os/ivt-link-master.py << 'LINK_EOF'
#!/usr/bin/env python3
import os, json, time, queue
from http.server import BaseHTTPRequestHandler, HTTPServer

LINK_SECRET = os.environ.get("IVT_LINK_SECRET", "default-secret")
LINK_PORT = int(os.environ.get("LINK_PORT", 8081))
task_queue = queue.Queue()

worker_status = {
    "state": "DISCONNECTED",
    "ram": 0,
    "cpu": 0,
    "last_seen": 0
}

class L(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def do_POST(self):
        cl = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(cl)

        try:
            data = json.loads(body)
        except:
            self.send_response(400)
            self.end_headers()
            return

        if self.path == "/ivt-link/auth" and data.get("secret") == LINK_SECRET:
            worker_status["state"] = "CONNECTED"
            worker_status["last_seen"] = time.time()
            self.send_response(200)
            self.send_header("Content-Type","application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"status":"auth_ok"}).encode())

        elif self.path == "/ivt-link/heartbeat" and data.get("secret") == LINK_SECRET:
            worker_status["last_seen"] = time.time()
            worker_status["ram"] = data.get("ram",0)
            worker_status["cpu"] = data.get("cpu",0)
            self.send_response(200)
            self.end_headers()

        else:
            self.send_response(200)
            self.end_headers()

    def do_GET(self):
        if self.path == "/ivt-link/poll":
            try:
                task = task_queue.get(timeout=15)
                self.send_response(200)
                self.send_header("Content-Type","application/json")
                self.end_headers()
                self.wfile.write(json.dumps(task).encode())
            except queue.Empty:
                self.send_response(204)
                self.end_headers()
        else:
            self.send_response(404)
            self.end_headers()

if __name__ == "__main__":
    print(f"[IVT-LINK MASTER] Listening on port {LINK_PORT}")
    HTTPServer(("0.0.0.0", LINK_PORT), L).serve_forever()
LINK_EOF

# ==========================================
# SERVICE UNITS
# ==========================================

RUN cat > /etc/ivt/units/ivt-api.service << 'EOF'
[Unit]
Description=IVT Master API & Dashboard
[Service]
ExecStart=/opt/ivt-venv/bin/python /ivt/os/api.py
Restart=always
RestartSec=2
[Install]
Target=default
EOF

RUN cat > /etc/ivt/units/ivt-link-master.service << 'EOF'
[Unit]
Description=IVT-LINK Master Agent
[Service]
ExecStart=/usr/bin/python3 /ivt/os/ivt-link-master.py
Restart=always
RestartSec=2
[Install]
Target=default
EOF

RUN cat > /etc/ivt/units/ivt-heartbeat.service << 'EOF'
[Unit]
Description=IVT Master Heartbeat
[Service]
ExecStart=/bin/sh -c 'while true; do date +%s > /home/container/.ivt/run/heartbeat; sleep 5; done'
Restart=always
RestartSec=1
[Install]
Target=default
EOF

RUN cat > /etc/ivt/units/ivt-sshd.service << 'EOF'
[Unit]
Description=OpenSSH Server
[Service]
ExecStart=/usr/sbin/sshd -D
Restart=always
RestartSec=2
[Install]
Target=default
EOF

# ==========================================
# SSH CONFIGURATION - PRESERVED
# ==========================================

RUN mkdir -p /etc/ssh/sshd_config.d && \
    echo "PermitRootLogin yes" > /etc/ssh/sshd_config.d/00-allow-root.conf && \
    echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config.d/00-allow-root.conf && \
    echo "Port 22" >> /etc/ssh/sshd_config.d/00-allow-root.conf && \
    sed -i 's/^#\?Port .*/Port 22/' /etc/ssh/sshd_config && \
    sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin yes/' /etc/ssh/sshd_config && \
    sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication yes/' /etc/ssh/sshd_config

RUN echo 'root:root' | chpasswd

# ==========================================
# ROOT BASH CONFIGURATION
# ==========================================

RUN echo 'cd /home/container' >> /root/.bashrc && \
    echo 'export PS1="\[\e[1;32m\]\u@ivt-os\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]\$ "' >> /root/.bashrc && \
    echo 'alias ls="ls --color=auto"' >> /root/.bashrc && \
    echo 'alias ll="ls -alF"' >> /root/.bashrc

# ==========================================
# PERMISSIONS AND SYMLINKS
# ==========================================

RUN chmod +x /ivt/os/init /usr/local/bin/systemctl /usr/local/bin/service /usr/local/bin/journalctl /usr/local/bin/hostnamectl && \
    echo 'ivt-master' > /etc/hostname && \
    echo "default" > /etc/ivt/default.target && \
    ln -sf /etc/ivt/units/ivt-api.service /etc/ivt/targets/default.wants/ && \
    ln -sf /etc/ivt/units/ivt-link-master.service /etc/ivt/targets/default.wants/ && \
    ln -sf /etc/ivt/units/ivt-heartbeat.service /etc/ivt/targets/default.wants/ && \
    ln -sf /etc/ivt/units/ivt-sshd.service /etc/ivt/targets/default.wants/ && \
    ln -sf /usr/local/bin/systemctl /usr/bin/systemctl && \
    ln -sf /usr/local/bin/journalctl /usr/bin/journalctl && \
    ln -sf /usr/local/bin/service /usr/sbin/service && \
    ln -sf /usr/local/bin/hostnamectl /usr/bin/hostnamectl && \
    ln -sf /etc/ivt/units /etc/systemd/system && \
    ln -sf /etc/ivt/units /lib/systemd/system && \
    echo 'root ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/root && \
    chmod 0440 /etc/sudoers.d/root

WORKDIR /home/container

EXPOSE 22 8080 8081

HEALTHCHECK --interval=30s --timeout=5s --retries=3 CMD curl -sf http://127.0.0.1:8080/health || exit 1

RUN printf '%s\n' \
  '#!/bin/sh' \
  'echo "[ivt] container starting..."' \
  'exec /ivt/os/init "$@"' \
  > /entrypoint.sh && chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
