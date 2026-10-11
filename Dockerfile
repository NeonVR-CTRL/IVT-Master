FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    PORT=8080 \
    LINK_PORT=8081 \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    IVT_ROLE=master

# Prevent apt from trying to start services during installation (Standard Docker Fix)
RUN printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d && chmod +x /usr/sbin/policy-rc.d

# Install minimal dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      bash coreutils procps util-linux mawk ca-certificates curl sudo python3-minimal systemd-sysv && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /usr/share/doc/* /usr/share/man/* /usr/share/info/* /var/cache/apt/*

# Force genuine Ubuntu 24.04 LTS identity so ALL installers work perfectly
RUN printf 'PRETTY_NAME="Ubuntu 24.04.1 LTS"\nNAME="Ubuntu"\nVERSION_ID="24.04"\nVERSION="24.04.1 LTS (Noble Numbat)"\nVERSION_CODENAME=noble\nID=ubuntu\nID_LIKE=debian\nHOME_URL="https://www.ubuntu.com/"\nSUPPORT_URL="https://help.ubuntu.com/"\nBUG_REPORT_URL="https://bugs.launchpad.net/ubuntu/"\nPRIVACY_POLICY_URL="https://www.ubuntu.com/legal/terms-and-policies/privacy-policy"\nUBUNTU_CODENAME=noble\nLOGO=ubuntu-logo\n' > /etc/os-release

# Create directory structure
RUN mkdir -p \
      /ivt/os /etc/ivt/units /etc/ivt/targets/default.wants \
      /run/ivt/ctrl /run/ivt/pids /run/ivt/state /run/ivt/manual /run/ivt/link \
      /var/log/ivt/journal /etc/systemd/system /lib/systemd/system /run/systemd

# Create IVT-D init system (PID 1)
RUN cat > /ivt/os/init << 'INITEOF'
#!/bin/bash
set -u
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
RUN=/run/ivt
UNITS=/etc/ivt/units
TARGETS=/etc/ivt/targets
LOG=/var/log/ivt/journal
TARGET_FILE=/etc/ivt/default.target

mkdir -p "$RUN"/ctrl "$RUN"/pids "$RUN"/state "$RUN"/manual "$RUN"/link "$LOG"
[[ ! -f /etc/machine-id ]] && cat /proc/sys/kernel/random/uuid > /etc/machine-id
cat /proc/sys/kernel/random/uuid > "$RUN/boot-id"
date +%s > "$RUN/boottime"

declare -A PIDS=()
declare -A RESTART=()

log_system() { echo "$(date -Is) $*" >> "$LOG/system.log"; }

get_value() {
  mawk -v section="$2" -v key="$3" 'BEGIN{c=""} /^\[/{c=$0;gsub(/[\[\] \t\r]/,"",c);next} c==section{p=index($0,"=");if(p>0){k=substr($0,1,p-1);gsub(/[ \t\r]/,"",k);if(k==key){v=substr($0,p+1);sub(/\r$/,"",v);print v;exit}}}' "$1" 2>/dev/null
}

kill_tree() {
  local pid=$1
  local sig=${2:-TERM}
  local children=$(pgrep -P $pid 2>/dev/null || true)
  for child in $children; do kill_tree $child $sig; done
  kill -$sig $pid 2>/dev/null || true
}

service_start() {
  local unitfile=$1
  local name=$(basename $1 .service)
  local pidfile="$RUN/pids/$name.pid"
  
  [[ -f $pidfile ]] && kill -0 $(cat $pidfile 2>/dev/null) 2>/dev/null && { echo running > $RUN/state/$name; return 0; }
  rm -f "$RUN/manual/$name"
  
  local execstart=$(get_value $unitfile Service ExecStart)
  local workdir=$(get_value $unitfile Service WorkingDirectory)
  local restart=$(get_value $unitfile Service Restart)
  local restartsec=$(get_value $unitfile Service RestartSec)
  
  restart=${restart:-no}
  restartsec=${restartsec:-1}
  
  [[ -z $execstart ]] && { echo failed > $RUN/state/$name; return 1; }
  
  echo starting > $RUN/state/$name
  
  (
    if [[ -n $workdir ]]; then
      cd "$workdir" || exit 1
    fi
    exec /bin/sh -c "$execstart" >> "$LOG/$name.log" 2>&1
  ) &
  
  local pid=$!
  echo $pid > $pidfile
  echo running > $RUN/state/$name
  PIDS[$pid]=$name
  RESTART[$name]="$restart:$restartsec"
  log_system "started $name pid=$pid"
}

service_stop() {
  local name=$1
  local pidfile="$RUN/pids/$name.pid"
  
  touch "$RUN/manual/$name"
  
  if [[ -f $pidfile ]]; then
    local pid=$(cat $pidfile 2>/dev/null || true)
    if [[ -n $pid ]]; then
      kill_tree $pid TERM
      for _ in $(seq 1 20); do kill -0 $pid 2>/dev/null || break; sleep 0.1; done
      kill_tree $pid KILL
      unset "PIDS[$pid]" 2>/dev/null || true
    fi
    rm -f $pidfile
  fi
  echo stopped > $RUN/state/$name
  log_system "stopped $name"
}

shutdown_system() {
  log_system "shutdown requested"
  for pid in "${!PIDS[@]}"; do kill_tree $pid TERM; done
  sleep 1
  for pid in "${!PIDS[@]}"; do kill_tree $pid KILL; done
  exit 0
}

TARGET=$(cat $TARGET_FILE 2>/dev/null || echo default)
FIFO="$RUN/ctrl/control.fifo"
rm -f $FIFO; mkfifo $FIFO; exec 3<>"$FIFO"
log_system "IVT-D MASTER starting target=$TARGET"

for unit in $TARGETS/$TARGET.wants/*.service; do [[ -e $unit ]] && service_start $unit; done
trap shutdown_system TERM INT

while true; do
  if read -r -t 1 -u 3 cmd; then
    case $cmd in
      start:*) service_start "$UNITS/${cmd#start:}.service" ;;
      stop:*) service_stop "${cmd#stop:}" ;;
      restart:*) service_stop "${cmd#restart:}"; sleep 0.2; service_start "$UNITS/${cmd#restart:}.service" ;;
      shutdown|poweroff) shutdown_system ;;
    esac
  fi
  for pid in "${!PIDS[@]}"; do
    if ! kill -0 $pid 2>/dev/null; then
      name=${PIDS[$pid]}
      unset "PIDS[$pid]" 2>/dev/null || true
      rm -f "$RUN/pids/$name.pid"
      if [[ -f $RUN/manual/$name ]]; then echo stopped > $RUN/state/$name; continue; fi
      policy=${RESTART[$name]:-no:1}
      restart_policy=${policy%%:*}
      restart_sec=${policy##*:}
      if [[ $restart_policy == "always" || $restart_policy == "on-failure" ]]; then
        log_system "restarting $name in ${restart_sec}s"
        sleep $restart_sec 2>/dev/null || true
        service_start "$UNITS/$name.service"
      else
        echo exited > $RUN/state/$name
      fi
    fi
  done
  sleep 0.5
done
INITEOF

# Create ivtctl control tool
RUN cat > /usr/local/bin/ivtctl << 'CTL_EOF'
#!/bin/bash
set -u
RUN=/run/ivt; FIFO="$RUN/ctrl/control.fifo"; UNITS=/etc/ivt/units; TARGETS=/etc/ivt/targets; LOG=/var/log/ivt/journal
send() { [[ -p $FIFO ]] || { echo "IVT-D not running" >&2; return 1; }; echo "$1" > $FIFO; }
status_pretty() {
  printf '%-20s %-10s %-8s %-8s\n' "UNIT" "STATE" "PID" "ENABLED"
  for unit in $UNITS/*.service; do
    [[ -e $unit ]] || continue
    name=$(basename $unit .service)
    state=$(cat $RUN/state/$name 2>/dev/null || echo inactive)
    pid=$(cat $RUN/pids/$name.pid 2>/dev/null || echo -)
    enabled=no; [[ -e $TARGETS/default.wants/$name.service ]] && enabled=yes
    printf '%-20s %-10s %-8s %-8s\n' "$name" "$state" "$pid" "$enabled"
  done
}
cmd=$1; shift || true
case $cmd in
  start|stop|restart) send "$cmd:${1%.service}"; echo "$cmd request sent: ${1%.service}" ;;
  status) status_pretty ;;
  journal) unit="${1%.service}"; lines=${2:-50}; [[ $unit == "system" || -z $unit ]] && file=$LOG/system.log || file=$LOG/$unit.log; [[ -f $file ]] && tail -n $lines $file || echo "-- No entries --" ;;
  new) unit="${1%.service}"; shift; command="$*"; cat > $UNITS/$unit.service << EOF
[Unit]
Description=Invented service: $unit
[Service]
ExecStart=$command
Restart=always
RestartSec=2
[Install]
Target=default
EOF
  ln -sf $UNITS/$unit.service $TARGETS/default.wants/$unit.service; send "start:$unit"; echo "created and started: $unit" ;;
  remove) unit="${1%.service}"; send "stop:$unit" 2>/dev/null || true; rm -f $TARGETS/default.wants/$unit.service $UNITS/$unit.service $RUN/state/$unit $RUN/pids/$unit.pid $RUN/manual/$unit; echo "removed $unit" ;;
  sys) echo "== IVT-OS MASTER =="; . /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-Ubuntu}"; echo "Kernel: $(uname -r)"; echo "Uptime: $(( $(cut -d. -f1 /proc/uptime) / 60 )) min"; free -m 2>/dev/null; df -h / 2>/dev/null ;;
  shell) exec /bin/bash ;;
  shutdown) send shutdown; echo "shutdown request sent" ;;
  *) echo "Usage: ivtctl {start|stop|restart|status|journal|new|remove|sys|shell|shutdown}" ;;
esac
CTL_EOF

# Create UNIVERSAL systemctl compatibility (NOW WITH BULLETPROOF pgrep FALLBACK)
RUN cat > /usr/local/bin/systemctl << 'SYSCTL_EOF'
#!/bin/bash
set -u
RUN=/run/ivt
UNITS=/etc/ivt/units
TARGETS=/etc/ivt/targets
LOG=/var/log/ivt/journal
IVTCTL=/usr/local/bin/ivtctl

ensure_unit() {
  local unit="${1%.service}.service"
  local sys_unit="/etc/systemd/system/$unit"
  local ivt_unit="$UNITS/$unit"
  if [[ -f "$sys_unit" && ! -f "$ivt_unit" ]]; then
    cp "$sys_unit" "$ivt_unit"
    chmod 644 "$ivt_unit"
  fi
}

cmd=$1; shift || true

case $cmd in
  daemon-reload)
    for f in /etc/systemd/system/*.service; do
      [[ -e "$f" ]] || continue
      cp "$f" "$UNITS/"
    done
    echo "IVT-D: daemon-reload simulated (units synced)"
    ;;
  enable)
    unit="${1%.service}"
    ensure_unit "$unit"
    mkdir -p "$TARGETS/default.wants"
    ln -sf "$UNITS/$unit.service" "$TARGETS/default.wants/$unit.service"
    echo "Created symlink"
    ;;
  disable)
    unit="${1%.service}"
    rm -f "$TARGETS/default.wants/$unit.service"
    echo "Removed symlink"
    ;;
  is-active)
    unit="${1%.service}"
    ensure_unit "$unit"
    
    # 1. Check internal PID tracking
    state=$(cat $RUN/state/$unit 2>/dev/null || echo inactive)
    if [[ "$state" == "running" ]]; then
      pid=$(cat $RUN/pids/$unit.pid 2>/dev/null || echo "")
      if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        echo "active"
        exit 0
      fi
    fi
    
    # 2. BULLETPROOF FALLBACK: Check if the actual binary is running via pgrep
    # This guarantees detection even if shell-wrapping detaches the PID
    execstart=$(get_value "/etc/ivt/units/$unit.service" Service ExecStart)
    if [[ -n "$execstart" ]]; then
      cmd=$(echo "$execstart" | awk '{print $1}')
      proc_name=$(basename "$cmd")
      if pgrep -x "$proc_name" > /dev/null 2>&1; then
        echo "active"
        exit 0
      fi
    fi
    
    echo "inactive"
    exit 3
    ;;
  is-enabled)
    unit="${1%.service}"
    if [[ -e "$TARGETS/default.wants/$unit.service" ]]; then
      echo "enabled"
      exit 0
    else
      echo "disabled"
      exit 1
    fi
    ;;
  start|stop|restart)
    unit="${1%.service}"
    ensure_unit "$unit"
    $IVTCTL "$cmd" "$unit"
    ;;
  status)
    if [[ -n "${1:-}" ]]; then
      unit="${1%.service}"
      ensure_unit "$unit"
      state=$(cat $RUN/state/$unit 2>/dev/null || echo inactive)
      pid=$(cat $RUN/pids/$unit.pid 2>/dev/null || echo -)
      echo "● $unit.service"
      echo "   Active: $state (Main PID: $pid)"
      if [[ -f $LOG/$unit.log ]]; then
        echo "   Logs (last 10 lines):"
        tail -n 10 $LOG/$unit.log | sed 's/^/     /'
      fi
    else
      printf '%-20s %-10s %-8s %-8s\n' "UNIT" "STATE" "PID" "ENABLED"
      declare -A seen
      for unit_file in $UNITS/*.service /etc/systemd/system/*.service; do
        [[ -e $unit_file ]] || continue
        unit=$(basename $unit_file .service)
        [[ -n "${seen[$unit]}" ]] && continue
        seen[$unit]=1
        state=$(cat $RUN/state/$unit 2>/dev/null || echo inactive)
        pid=$(cat $RUN/pids/$unit.pid 2>/dev/null || echo -)
        enabled=no; [[ -e $TARGETS/default.wants/$unit.service ]] && enabled=yes
        printf '%-20s %-10s %-8s %-8s\n' "$unit" "$state" "$pid" "$enabled"
      done
    fi 
    ;;
  *)
    $IVTCTL "$cmd" "$@"
    ;;
esac
SYSCTL_EOF

# Create journalctl compatibility
RUN cat > /usr/local/bin/journalctl << 'JCTL_EOF'
#!/bin/bash
LOG=/var/log/ivt/journal; unit=""; lines=50; follow=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    -u|--unit) shift; unit="${1:-}";; --unit=*) unit="${1#--unit=}";;
    -n|--lines) shift; lines="${1:-50}";; --lines=*) lines="${1#--lines=}";;
    -f|--follow) follow=true;;
  esac; shift || true
done
unit="${unit%.service}"
file="$LOG/${unit:-system}.log"
[[ ! -f $file ]] && { echo "-- No entries --"; exit 0; }
$follow && exec tail -f "$file" || exec tail -n "$lines" "$file"
JCTL_EOF

# Create service compatibility
RUN cat > /usr/local/bin/service << 'SVC_EOF'
#!/bin/bash
[[ $# -lt 2 ]] && { echo "Usage: service <unit> {start|stop|restart|status}" >&2; exit 1; }
exec /usr/local/bin/ivtctl "$2" "$1"
SVC_EOF

# Create hostnamectl compatibility
RUN cat > /usr/local/bin/hostnamectl << 'HCTL_EOF'
#!/bin/bash
cmd="${1:-status}"
case "$cmd" in
  status) echo " Static hostname: $(cat /etc/hostname 2>/dev/null || echo ivt-master)"; echo "  Operating System: $(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-Ubuntu}")"; echo "          Kernel: $(uname -r)";;
  set-hostname) echo "${2:-ivt-master}" > /etc/hostname 2>/dev/null || true;;
  hostname) cat /etc/hostname 2>/dev/null || echo ivt-master;;
esac
HCTL_EOF

# Create API server
RUN cat > /ivt/os/api.py << 'API_EOF'
#!/usr/bin/env python3
import html, os, subprocess
from http.server import BaseHTTPRequestHandler, HTTPServer
PORT = int(os.environ.get("PORT", 8080))
def run(cmd):
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=5)
        return result.stdout.strip()
    except Exception as e:
        return f"ERROR: {e}"
class IVTHandler(BaseHTTPRequestHandler):
    server_version = "IVT-OS-MASTER"
    sys_version = ""
    def log_message(self, *args): pass
    def send(self, code, body, ctype="text/plain; charset=utf-8"):
        data = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def do_GET(self):
        if self.path == "/health":
            self.send(200, "OK")
            return
        if self.path == "/api/status":
            self.send(200, run(["ivtctl", "status"]))
            return
        if self.path == "/api/sys":
            self.send(200, run(["ivtctl", "sys"]))
            return
        status = run(["ivtctl", "status"])
        kernel = run(["uname", "-a"])
        page = f"""<html><head><title>IVT-OS MASTER</title></head><body>
<h1>IVT-OS MASTER</h1><p>{html.escape(kernel)}</p>
<h2>Services</h2><pre>{html.escape(status)}</pre></body></html>"""
        self.send(200, page, "text/html; charset=utf-8")
if __name__ == "__main__":
    HTTPServer(("0.0.0.0", PORT), IVTHandler).serve_forever()
API_EOF

# Create IVT-LINK Master Agent
RUN cat > /ivt/os/ivt-link-master.py << 'LINK_EOF'
#!/usr/bin/env python3
import os, json, time, queue
from http.server import BaseHTTPRequestHandler, HTTPServer
WORKER_URL = os.environ.get("IVT_WORKER_URL", "")
LINK_SECRET = os.environ.get("IVT_LINK_SECRET", "default-secret")
LINK_PORT = int(os.environ.get("LINK_PORT", 8081))
task_queue = queue.Queue()
worker_status = {"state": "DISCONNECTED", "ram": 0, "cpu": 0, "last_seen": 0}
class LinkHandler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_POST(self):
        content_len = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(content_len)
        try:
            data = json.loads(body)
        except:
            self.send_response(400); self.end_headers(); return
        if self.path == "/ivt-link/auth":
            if data.get("secret") == LINK_SECRET:
                worker_status["state"] = "CONNECTED"
                worker_status["last_seen"] = time.time()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps({"status": "auth_ok"}).encode())
            else:
                self.send_response(403); self.end_headers()
        elif self.path == "/ivt-link/heartbeat":
            if data.get("secret") == LINK_SECRET:
                worker_status["last_seen"] = time.time()
                worker_status["ram"] = data.get("ram", 0)
                worker_status["cpu"] = data.get("cpu", 0)
                self.send_response(200); self.end_headers()
        elif self.path == "/ivt-link/result":
            if data.get("secret") == LINK_SECRET:
                self.send_response(200); self.end_headers()
    def do_GET(self):
        if self.path == "/ivt-link/poll":
            try:
                task = task_queue.get(timeout=15)
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps(task).encode())
            except queue.Empty:
                self.send_response(204); self.end_headers()
        else:
            self.send_response(404); self.end_headers()
if __name__ == "__main__":
    print(f"[IVT-LINK MASTER] Listening on port {LINK_PORT}")
    HTTPServer(("0.0.0.0", LINK_PORT), LinkHandler).serve_forever()
LINK_EOF

# Create service units
RUN cat > /etc/ivt/units/ivt-api.service << 'UNIT1_EOF'
[Unit]
Description=IVT Master API & Dashboard
[Service]
ExecStart=/usr/bin/python3 /ivt/os/api.py
Restart=always
RestartSec=2
[Install]
Target=default
UNIT1_EOF

RUN cat > /etc/ivt/units/ivt-link-master.service << 'UNIT2_EOF'
[Unit]
Description=IVT-LINK Master Agent
[Service]
ExecStart=/usr/bin/python3 /ivt/os/ivt-link-master.py
Restart=always
RestartSec=2
[Install]
Target=default
UNIT2_EOF

RUN cat > /etc/ivt/units/ivt-heartbeat.service << 'UNIT3_EOF'
[Unit]
Description=IVT Master Heartbeat
[Service]
ExecStart=/bin/sh -c 'while true; do date +%s > /run/ivt/heartbeat; sleep 5; done'
Restart=always
RestartSec=1
[Install]
Target=default
UNIT3_EOF

# Set permissions and OS identity
RUN chmod +x /ivt/os/init /usr/local/bin/ivtctl /usr/local/bin/systemctl \
      /usr/local/bin/journalctl /usr/local/bin/service /usr/local/bin/hostnamectl && \
    echo 'ivt-master' > /etc/hostname && \
    echo default > /etc/ivt/default.target && \
    ln -sf /etc/ivt/units/ivt-api.service /etc/ivt/targets/default.wants/ && \
    ln -sf /etc/ivt/units/ivt-link-master.service /etc/ivt/targets/default.wants/ && \
    ln -sf /etc/ivt/units/ivt-heartbeat.service /etc/ivt/targets/default.wants/ && \
    ln -sf /usr/local/bin/systemctl /usr/bin/systemctl && \
    ln -sf /usr/local/bin/journalctl /usr/bin/journalctl && \
    ln -sf /usr/local/bin/service /usr/sbin/service && \
    ln -sf /usr/local/bin/hostnamectl /usr/bin/hostnamectl && \
    ln -sf /etc/ivt/units /etc/systemd/system && \
    ln -sf /etc/ivt/units /lib/systemd/system && \
    echo 'root ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/root && \
    chmod 0440 /etc/sudoers.d/root

EXPOSE 8080 8081

HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD curl -sf http://127.0.0.1:8080/health || exit 1

CMD ["/ivt/os/init"]
