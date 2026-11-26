FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    PORT=8080 \
    LINK_PORT=8081 \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    IVT_ROLE=master \
    TERM=xterm-256color \
    LANG=C.UTF-8 \
    PYTHONUNBUFFERED=1

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

# ==========================================
# OFFICIAL OOKLA SPEEDTEST CLI
# ==========================================

RUN cd /tmp && \
    curl -fLO https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-x86_64.tgz && \
    tar -xzf ookla-speedtest-1.2.0-linux-x86_64.tgz && \
    install -m 0755 speedtest /usr/local/bin/speedtest && \
    speedtest --version && \
    rm -f /tmp/ookla-speedtest-1.2.0-linux-x86_64.tgz /tmp/speedtest /tmp/speedtest.md /tmp/speedtest.5

RUN printf 'PRETTY_NAME="Ubuntu 24.04.1 LTS"\nNAME="Ubuntu"\nVERSION_ID="24.04"\nVERSION="24.04.1 LTS (Noble Numbat)"\nVERSION_CODENAME=noble\nID=ubuntu\nID_LIKE=debian\nHOME_URL="https://www.ubuntu.com/"\nSUPPORT_URL="https://help.ubuntu.com/"\nBUG_REPORT_URL="https://bugs.launchpad.net/ubuntu/"\nPRIVACY_POLICY_URL="https://www.ubuntu.com/legal/terms-and-policies/privacy-policy"\nUBUNTU_CODENAME=noble\nLOGO=ubuntu-logo\n' > /etc/os-release

RUN mkdir -p \
      /ivt/os \
      /etc/ivt/units /etc/ivt/targets/default.wants /etc/ivt/targets/multi-user.target.wants \
      /home/container/.ivt/run/ctrl /home/container/.ivt/run/pids /home/container/.ivt/run/state /home/container/.ivt/run/manual /home/container/.ivt/run/link \
      /home/container/.ivt/log \
      /etc/systemd/system /lib/systemd/system /run/systemd /run/sshd /var/run/sshd

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

mkdir -p "$RUN_DIR"/{ctrl,pids,state,manual,link} "$LOG" /run/sshd /var/run/sshd
ssh-keygen -A >/dev/null 2>&1 || true
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
# FAKE SYSTEMCTL / SERVICE TOOLS
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
        echo "enabled"; exit 0
      else
        echo "disabled"; exit 1
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
        cp "$f" "$UNITS/" 2>/dev/null || true
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
        printf '%-24s %-10s %-8s %-8s\n' "UNIT" "STATE" "PID" "ENABLED"
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
          printf '%-24s %-10s %-8s %-8s\n' "$unit_name" "$state" "$pid" "$enabled"
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
# IVT MASTER PREMIUM DASHBOARD + SSH API
# ==========================================

RUN cat > /ivt/os/api.py << 'API_EOF'
#!/opt/ivt-venv/bin/python
import os
import re
import json
import time
import asyncio
import secrets
import subprocess
from collections import deque
from aiohttp import web
import asyncssh

PORT = int(os.environ.get("PORT", 8080))
FIFO = "/home/container/.ivt/run/ctrl/control.fifo"
SESSIONS = {}
SCROLLBACK_LIMIT = 2 * 1024 * 1024
ALLOWED_LOGS = {"system", "ivt-api", "ivt-link-master", "ivt-heartbeat", "ivt-sshd"}
ALLOWED_UNITS = {"ivt-api", "ivt-link-master", "ivt-heartbeat", "ivt-sshd"}

def run(cmd, timeout=5):
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return result.stdout.strip()
    except Exception as exc:
        return "ERROR: " + str(exc)

def system_metrics():
    cpu = "N/A"
    try:
        with open("/proc/loadavg") as f:
            cpu = f.read().split()[0]
    except Exception:
        pass

    memory = {}
    try:
        with open("/proc/meminfo") as f:
            for line in f:
                key, value = line.split(":", 1)
                memory[key] = int(value.strip().split()[0]) * 1024
    except Exception:
        pass

    total = memory.get("MemTotal", 0)
    available = memory.get("MemAvailable", 0)
    used = max(0, total - available)

    disk = {}
    try:
        result = os.statvfs("/")
        disk_total = result.f_blocks * result.f_frsize
        disk_free = result.f_bavail * result.f_frsize
        disk = {
            "total": disk_total,
            "used": disk_total - disk_free,
            "free": disk_free
        }
    except Exception:
        pass

    return {
        "load": cpu,
        "memory_total": total,
        "memory_used": used,
        "memory_free": available,
        "memory_percent": round(used * 100 / total, 1) if total else 0,
        "disk": disk,
        "uptime": run(["uptime", "-p"]),
        "hostname": run(["hostname"]),
        "kernel": run(["uname", "-r"]),
        "platform": "Ubuntu 24.04"
    }

def service_data():
    result = []
    for name in sorted(ALLOWED_UNITS):
        state = run(["systemctl", "is-active", name + ".service"])
        result.append({"name": name, "state": state or "unknown"})
    extra = run(["systemctl", "is-active", "x-ui.service"])
    if extra and extra != "ERROR: " and "ERROR:" not in extra:
        result.append({"name": "x-ui", "state": extra})
    return result

def read_log(name, lines=None):
    if name not in ALLOWED_LOGS:
        raise ValueError("Unknown log")
    path = "/home/container/.ivt/log/%s.log" % name
    try:
        with open(path, "r", errors="replace") as f:
            if lines is None:
                return f.read()
            return "".join(deque(f, maxlen=lines))
    except FileNotFoundError:
        return "No log entries yet."

async def speedtest_result():
    try:
        def _run():
            return subprocess.run(
                ["speedtest", "--accept-license", "--accept-gdpr", "--format=json", "--progress=no"],
                capture_output=True, text=True, timeout=60
            )
        proc = await asyncio.to_thread(_run)
        if proc.returncode != 0:
            return {"ok": False, "error": (proc.stderr or "speedtest failed")[:400]}
        data = json.loads(proc.stdout)
        return {
            "ok": True,
            "download": data.get("download", {}).get("bandwidth"),
            "upload": data.get("upload", {}).get("bandwidth"),
            "latency": data.get("ping", {}).get("latency"),
            "jitter": data.get("ping", {}).get("jitter"),
            "packet_loss": data.get("packetLoss"),
            "isp": data.get("isp"),
            "server": data.get("server", {}).get("name"),
            "url": data.get("result", {}).get("url")
        }
    except Exception as exc:
        return {"ok": False, "error": str(exc)[:400]}

def bps(value):
    if not value:
        return "N/A"
    return "%.1f Mbps" % (value * 8 / 1000000)

PAGE = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="theme-color" content="#070b14">
<title>IVT Control</title>
<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'%3E%3Crect width='32' height='32' rx='7' fill='%23f6821f'/%3E%3Cg fill='none' stroke='white' stroke-width='2.4' stroke-linecap='round' stroke-linejoin='round'%3E%3Cpath d='M16 3.2 27 7.6v7.2c0 6.4-4.4 10.7-11 13.2C9.4 25.5 5 21.2 5 14.8V7.6z'/%3E%3Cpath d='m10.5 12.5 4.5 4-4.5 4'/%3E%3Cpath d='M17.5 20.5h4.5'/%3E%3C/g%3E%3C/svg%3E">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&family=JetBrains+Mono:wght@400;500;700&display=swap" rel="stylesheet">
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/xterm@5.3.0/css/xterm.css">
<script src="https://cdn.jsdelivr.net/npm/xterm@5.3.0/lib/xterm.min.js"></script>
<script src="https://cdn.jsdelivr.net/npm/xterm-addon-fit@0.8.0/lib/xterm-addon-fit.min.js"></script>
<script src="https://cdn.jsdelivr.net/npm/xterm-addon-search@0.11.0/lib/xterm-addon-search.min.js"></script>
<style>
:root{
 --bg:#f5f6f8;--panel:#ffffff;--ink:#1d1f23;--muted:#6b7280;--faint:#98a2b3;
 --line:#e3e6ec;--line2:#eef0f4;--subtle:#fafbfc;--subtle2:#fcfcfd;--iconbg:#f2f4f7;
 --btn:#ffffff;--btnhover:#f7f8fa;--text2:#344054;--text3:#475467;--icon:#667085;
 --orange:#f6821f;--orange-d:#cf6210;--orange-l:#fff4e8;
 --green:#12a150;--green-l:#e9f8ef;--green-b:#cceedd;--red:#d92d20;--red-l:#fef3f2;--red-b:#fbd5d2;
 --shadow:0 1px 2px rgba(16,24,40,.05);--shadowh:0 6px 20px rgba(16,24,40,.10);
 --scroll:#cbd2dc;--scrollh:#a9b2c0;
}
html[data-theme="dark"]{
 --bg:#101722;--panel:#1a2330;--ink:#eef3fb;--muted:#a3b1c6;--faint:#6d7d95;
 --line:#2b3749;--line2:#212c3b;--subtle:#1d2736;--subtle2:#18212e;--iconbg:#242f40;
 --btn:#1d2736;--btnhover:#283447;--text2:#dbe4f1;--text3:#bcc9db;--icon:#94a3b8;
 --orange:#ff8c2b;--orange-d:#ffb27a;--orange-l:#2b1c0f;
 --green:#34d399;--green-l:#0f2a20;--green-b:#1d4d3b;--red:#ff6b5e;--red-l:#2b1618;--red-b:#5a2a2d;
 --shadow:0 1px 2px rgba(0,0,0,.25);--shadowh:0 10px 28px rgba(0,0,0,.38);
 --scroll:#2b3648;--scrollh:#3d4b61;
}
*{box-sizing:border-box;scrollbar-width:thin;scrollbar-color:var(--scrollh) transparent}
::-webkit-scrollbar{width:5px;height:5px}
::-webkit-scrollbar-track{background:transparent}
::-webkit-scrollbar-thumb{background:var(--scrollh);border-radius:8px}
::-webkit-scrollbar-thumb:hover{background:var(--icon)}
html,body{height:100%}
html[data-theme="dark"] body{background:
 radial-gradient(820px 460px at -5% -12%,rgba(91,124,250,.16),transparent 62%),
 radial-gradient(760px 420px at 105% -8%,rgba(168,85,247,.12),transparent 60%),
 radial-gradient(700px 460px at 78% 112%,rgba(255,140,43,.10),transparent 62%),
 radial-gradient(rgba(150,170,205,.075) .8px,transparent .8px),
 linear-gradient(rgba(150,170,205,.028) 1px,transparent 1px),
 linear-gradient(90deg,rgba(150,170,205,.028) 1px,transparent 1px),
 var(--bg);
 background-size:auto,auto,auto,23px 23px,46px 46px,46px 46px,auto}
body{
 margin:0;color:var(--ink);
 background:
  radial-gradient(780px 430px at -8% -14%,rgba(91,124,250,.11),transparent 62%),
  radial-gradient(720px 400px at 108% -6%,rgba(34,211,238,.07),transparent 60%),
  radial-gradient(680px 440px at 74% 112%,rgba(246,130,31,.075),transparent 62%),
  radial-gradient(rgba(90,110,150,.11) .8px,transparent .8px),
  linear-gradient(rgba(90,110,150,.032) 1px,transparent 1px),
  linear-gradient(90deg,rgba(90,110,150,.032) 1px,transparent 1px),
  var(--bg);
 background-size:auto,auto,auto,23px 23px,46px 46px,46px 46px,auto;
 font-family:'Inter',-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;
 font-size:13px;line-height:1.45;overflow:hidden;transition:background .2s,color .2s;
}
button,input,select{font:inherit}
button{cursor:pointer}
svg{display:block}
.app{display:grid;grid-template-columns:238px minmax(0,1fr);height:100vh}

.side{background:linear-gradient(175deg,var(--panel),var(--subtle2));display:flex;flex-direction:column;padding:0;overflow:hidden;box-shadow:1px 0 0 var(--line)}
.brand{height:62px;display:flex;align-items:center;gap:10px;padding:0 18px;flex:0 0 auto}
.mark{width:30px;height:30px;border-radius:9px 3px 9px 3px;display:grid;place-items:center;background:var(--orange);color:#fff;flex:0 0 auto;box-shadow:0 2px 8px rgba(246,130,31,.28)}
.mark svg{width:19px;height:19px}
.bname{font-size:14px;font-weight:700;letter-spacing:-.02em;line-height:1.1}
.bname small{display:block;font-size:9px;font-weight:600;letter-spacing:.13em;color:var(--faint);margin-top:2px}
.cap{font-size:10px;font-weight:700;letter-spacing:.1em;color:var(--faint);padding:18px 20px 8px;text-transform:uppercase}
.nav{display:grid;gap:1px;padding:0 8px}
.nav button{
 width:100%;height:38px;display:flex;align-items:center;gap:11px;padding:0 12px;
 border:0;border-radius:5px;background:transparent;color:var(--text3);
 font-size:12.5px;font-weight:500;text-align:left;position:relative;transition:background .14s,color .14s;
}
.nav button svg{width:17px;height:17px;flex:0 0 auto;color:var(--icon)}
.nav button:hover{background:var(--subtle);color:var(--ink)}
.nav button.on{background:var(--orange-l);color:var(--orange-d);font-weight:650}
.nav button.on svg{color:var(--orange)}
.nav button.on:before{content:'';position:absolute;left:0;top:8px;bottom:8px;width:3px;border-radius:0 3px 3px 0;background:var(--orange)}
.sidefoot{margin:auto 14px 16px;padding:12px;border:1px solid var(--line);border-radius:6px;background:var(--subtle)}
.sidefoot b{font-size:10px;font-weight:700;letter-spacing:.08em;color:var(--text2);display:flex;align-items:center}
.sidefoot p{font-size:10px;color:var(--muted);margin:5px 0 0;line-height:1.6}
.dot{display:inline-block;width:7px;height:7px;border-radius:50%;background:var(--green);margin-right:7px;box-shadow:0 0 0 3px var(--green-l)}

.main{min-width:0;height:100vh;overflow:auto;overflow-x:hidden;display:flex;flex-direction:column}
.top{
 height:62px;flex:0 0 auto;display:flex;align-items:center;justify-content:space-between;
 gap:16px;padding:0 26px;background:linear-gradient(100deg,var(--panel),var(--subtle2));box-shadow:0 1px 0 var(--line);
}
.crumb{font-size:11px;color:var(--faint);font-weight:600;letter-spacing:.02em}
.crumb b{color:var(--orange-d);font-weight:700}
h1{margin:2px 0 0;font-size:19px;font-weight:700;letter-spacing:-.035em;line-height:1.2}
.tools{display:flex;align-items:center;gap:8px}
.pill{display:inline-flex;align-items:center;gap:7px;height:28px;padding:0 10px;border:1px solid var(--line);border-radius:5px;background:var(--subtle);font-size:11px;font-weight:650;color:var(--text2)}
.ib,.btn{
 display:inline-flex;align-items:center;justify-content:center;gap:6px;
 height:30px;padding:0 10px;border:1px solid var(--line);border-radius:5px;
 background:var(--btn);color:var(--text2);font-size:11.5px;font-weight:600;transition:.14s;
}
.ib{width:30px;padding:0}
.ib svg,.btn svg{width:14px;height:14px;color:var(--icon)}
.ib:hover,.btn:hover{background:var(--btnhover);border-color:var(--faint)}
.btn.pri{background:var(--orange);border-color:var(--orange);color:#fff;box-shadow:0 2px 6px rgba(246,130,31,.22)}
.btn.pri svg{color:#fff}
.btn.pri:hover{background:var(--orange-d);border-color:var(--orange-d)}
.btn.dan{color:var(--red);border-color:var(--red-b);background:var(--red-l)}
.btn.dan svg{color:var(--red)}
.btn:disabled{opacity:.5;cursor:default}

.page{padding:16px 26px 22px}
.page{display:none}
.page.on{display:block}
.grid{display:grid;gap:12px}
.metrics{grid-template-columns:repeat(4,minmax(0,1fr));margin-bottom:12px}
.card{
 min-width:0;background:var(--panel);border:1px solid var(--line);
 border-radius:15px 5px 15px 5px;padding:13px 15px;box-shadow:var(--shadow);overflow:hidden;
 transition:box-shadow .18s,transform .18s,border-color .18s;
}
.metrics .card:nth-child(1){border-radius:17px 5px 17px 5px}
.metrics .card:nth-child(2){border-radius:5px 17px 5px 17px}
.metrics .card:nth-child(3){border-radius:17px 17px 5px 17px}
.metrics .card:nth-child(4){border-radius:5px 17px 17px 17px}
.card.a{border-radius:5px 17px 5px 17px}
.card.b{border-radius:17px 17px 5px 17px}
.card.c{border-radius:5px 17px 17px 17px}
.card:hover{box-shadow:var(--shadowh);border-color:var(--faint);transform:translateY(-1px)}
.card:before{content:'';position:absolute;top:0;left:16px;width:44px;height:3px;border-radius:0 0 3px 3px;
 background:var(--orange);transform:skewX(-28deg);transform-origin:top}
.card.a:before{left:auto;right:16px;background:var(--green)}
.card.b:before{background:var(--blue,#5b7cfa)}
.card.c:before{right:16px;left:auto;background:var(--orange)}
.mh{display:flex;align-items:center;justify-content:space-between;gap:8px;font-size:10.5px;font-weight:700;letter-spacing:.08em;text-transform:uppercase;color:var(--faint)}
.tile{width:28px;height:28px;border-radius:9px 3px 9px 3px;display:grid;place-items:center;background:var(--iconbg);border:1px solid var(--line);color:var(--orange);transform:skewX(-9deg)}
.tile svg{transform:skewX(9deg)}
.tile svg{width:15px;height:15px;color:inherit}
.mv{font-size:23px;font-weight:700;letter-spacing:-.045em;margin:8px 0 2px;line-height:1.1;font-variant-numeric:tabular-nums}
.mv.sm{font-size:16px;letter-spacing:-.02em}
.mf{font-size:10.5px;color:var(--muted)}
.meter{height:3px;border-radius:3px;background:var(--line2);margin-top:10px;overflow:hidden}
.meter i{display:block;height:100%;border-radius:3px;background:linear-gradient(90deg,var(--orange),#fbbd6b);width:0;transition:width .5s}
.over{grid-template-columns:minmax(0,1.45fr) minmax(260px,.8fr);margin-bottom:12px}
.row2{grid-template-columns:1fr 1fr;margin-bottom:12px}
.hd{display:flex;align-items:center;justify-content:space-between;gap:10px;margin-bottom:13px}
.hd h2{margin:0;font-size:13.5px;font-weight:700;letter-spacing:-.015em}
.hd p{margin:2px 0 0;font-size:11px;color:var(--muted)}
.rows{display:grid;gap:0}
.row{display:flex;align-items:center;justify-content:space-between;gap:10px;padding:8px 11px;border-radius:6px;background:var(--subtle2);margin-bottom:5px}
.row:last-child{margin-bottom:0}
.row .n{font-size:12px;font-weight:600;display:flex;align-items:center;gap:9px;color:var(--text2)}
.row .n svg{width:14px;height:14px;color:var(--faint)}
.tag{display:inline-flex;align-items:center;gap:5px;font-size:10px;font-weight:700;padding:3px 8px;border-radius:6px 2px 6px 2px;background:var(--green-l);color:var(--green);border:1px solid var(--green-b);transform:skewX(-8deg)}
.tag:before{transform:skewX(8deg)}
.tag:before{content:'';width:5px;height:5px;border-radius:50%;background:currentColor}
.tag.off{background:var(--red-l);color:var(--red);border-color:var(--red-b)}
.tag.warn{background:var(--orange-l);color:var(--orange-d);border-color:var(--orange)}
.info{display:grid;gap:0}
.il{display:flex;justify-content:space-between;gap:14px;padding:7px 10px;font-size:11.5px;border-radius:5px}
.info .il:nth-child(odd){background:var(--subtle2)}
.il span{color:var(--muted)}.il strong{text-align:right;font-weight:600;overflow-wrap:anywhere;font-variant-numeric:tabular-nums}
.nt{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:10px}
.nbox{border:1px solid var(--line2);border-radius:5px;background:var(--subtle2);padding:11px}
.nbox .mf{font-size:10px}
.nv{font-size:16px;font-weight:700;letter-spacing:-.02em;margin-top:3px;font-variant-numeric:tabular-nums}
.quick{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:9px}
.qa{display:flex;align-items:center;gap:9px;padding:11px;border:1px solid var(--line);border-radius:6px;background:var(--panel);color:var(--text2);text-align:left;transition:.14s}
.qa:hover{border-color:var(--orange);background:var(--orange-l);box-shadow:var(--shadow)}
.qa svg{width:17px;height:17px;flex:0 0 auto;color:var(--orange)}
.qa span{min-width:0;overflow:hidden}
.qa b{font-size:11.5px;display:block;font-weight:650;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.qa small{font-size:10px;color:var(--muted);display:block;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.tcard{padding:0;overflow:hidden}
.ttop{display:flex;align-items:center;justify-content:space-between;gap:10px;padding:11px 14px;flex-wrap:wrap}
.ttitle{font-size:12.5px;font-weight:700}.tsub{font-size:10.5px;color:var(--muted);margin-top:2px}
.acts{display:flex;gap:6px;flex-wrap:wrap}
.acts .btn{height:27px;padding:0 8px;font-size:10.5px}
.tabs{display:flex;gap:4px;padding:7px 12px;overflow-x:auto;background:var(--subtle)}
.tab{white-space:nowrap;border:1px solid transparent;border-radius:4px;padding:5px 10px;background:transparent;color:var(--muted);font-size:10.5px;font-weight:600}
.tab.on{background:var(--panel);border-color:var(--line);color:var(--orange-d);box-shadow:var(--shadow)}
.login{display:flex;gap:7px;align-items:center;flex-wrap:wrap;padding:10px 13px;background:var(--subtle2)}
.login input{width:150px;max-width:100%;height:30px;background:var(--panel);border:1px solid var(--line);color:var(--ink);border-radius:5px;padding:0 9px;outline:0;font-size:11.5px}
.login input:focus{border-color:var(--orange);box-shadow:0 0 0 3px rgba(246,130,31,.13)}
.lstat{font-size:10.5px;color:var(--muted);margin-left:auto}
.wrap{background:linear-gradient(180deg,rgba(255,255,255,.03),transparent 130px),#0b1320;padding:9px 11px;min-height:320px;overflow:hidden;box-shadow:inset 0 0 0 1px rgba(255,255,255,.025)}
.inst{height:330px;min-width:0;width:100%}.inst .xterm{height:100%;width:100%!important;padding:4px;overflow:hidden}
.tfoot{display:flex;justify-content:space-between;gap:10px;flex-wrap:wrap;padding:8px 13px;background:var(--subtle);font-size:10.5px;color:var(--muted)}
.search{display:none;padding:8px 12px;gap:7px;background:var(--subtle2)}
.search.on{display:flex}
.search input{flex:1;min-width:0;height:28px;background:var(--panel);border:1px solid var(--line);border-radius:5px;padding:0 9px;font-size:11.5px;color:var(--ink)}
table{width:100%;border-collapse:collapse;font-size:11.5px}
th,td{text-align:left;padding:10px 12px}
th{color:var(--faint);font-size:10px;letter-spacing:.08em;text-transform:uppercase;font-weight:700;background:var(--subtle)}
tbody tr:nth-child(even){background:var(--subtle2)}
.logbox{white-space:pre-wrap;overflow-wrap:anywhere;background:linear-gradient(180deg,rgba(255,255,255,.03),transparent 130px),#0b1320;border:1px solid var(--line);border-radius:5px;padding:13px;min-height:260px;max-height:56vh;overflow:auto;font:11px/1.6 'JetBrains Mono',monospace;color:#ccd9ec}
select{height:30px;background:var(--panel);color:var(--ink);border:1px solid var(--line);border-radius:5px;padding:0 9px;font-size:11.5px}
.toast{position:fixed;right:20px;bottom:20px;z-index:99;padding:10px 14px;border-radius:6px;font-size:11.5px;font-weight:600;background:var(--text2);color:var(--panel);box-shadow:0 12px 32px rgba(0,0,0,.22);display:none}
.toast.on{display:block}
body.fs .side,body.fs .top,body.fs #dash,body.fs #services,body.fs #logs,body.fs #system{display:none!important}
body.fs .app{display:block}body.fs .main{padding:0;height:100vh}body.fs #terminal{padding:0}
body.fs .tcard{border:0;border-radius:0;min-height:100vh}
body.fs .inst{height:calc(100vh - 150px)}
@media(max-width:820px){.metrics{grid-template-columns:repeat(2,minmax(0,1fr))}}
@media(max-width:900px){
 .app{grid-template-columns:64px minmax(0,1fr)}
 .brand{padding:0 17px}.bname,.cap,.sidefoot,.nav button span{display:none}
 .nav{padding:0 8px}.nav button{justify-content:center;padding:0}
 .page{padding:16px}.over,.row2{grid-template-columns:1fr}
}
@media(max-width:640px){
 .app{display:block}
 .side{position:sticky;top:0;z-index:8;height:auto;flex-direction:row;justify-content:space-between;border-right:0;border-bottom:1px solid var(--line)}
 .brand{border-bottom:0;height:52px}.nav{display:flex;align-items:center;padding:0 8px;margin:0}.nav button{width:36px;height:36px}
 .top{padding:0 14px}.page{padding:14px 12px 28px}
 .metrics{gap:8px}.mv{font-size:20px}.inst{height:300px}.wrap{min-height:300px}
 .login input{width:calc(50% - 4px)}.lstat{width:100%;margin:0}
}
</style>
</head>
<body>
<script>
(function(){
  var t = localStorage.getItem('ivt-theme') || 'light';
  document.documentElement.dataset.theme = t;
  window.toggleTheme = function(){
    var n = document.documentElement.dataset.theme === 'dark' ? 'light' : 'dark';
    document.documentElement.dataset.theme = n;
    localStorage.setItem('ivt-theme', n);
    var u = document.querySelector('#themeBtn use');
    if (u) u.setAttribute('href', n === 'dark' ? '#i-sun' : '#i-moon');
  };
})();
</script>
<svg width="0" height="0" style="position:absolute" aria-hidden="true">
 <symbol id="i-grid" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="3" width="7" height="7" rx="1.5"/><rect x="14" y="3" width="7" height="7" rx="1.5"/><rect x="3" y="14" width="7" height="7" rx="1.5"/><rect x="14" y="14" width="7" height="7" rx="1.5"/></symbol>
 <symbol id="i-term" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><rect x="2.5" y="4" width="19" height="16" rx="2"/><path d="M6.5 9l3 3-3 3m6 0h5"/></symbol>
 <symbol id="i-stack" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3l9 4.5-9 4.5-9-4.5z"/><path d="M3 12l9 4.5 9-4.5M3 16.5l9 4.5 9-4.5"/></symbol>
 <symbol id="i-file" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M13 2H6a2 2 0 00-2 2v16a2 2 0 002 2h12a2 2 0 002-2V9z"/><path d="M13 2v7h7M8 13h8M8 17h5"/></symbol>
 <symbol id="i-cpu" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><rect x="6" y="6" width="12" height="12" rx="2"/><rect x="10" y="10" width="4" height="4" rx=".5"/><path d="M9 2v4m6-4v4M9 18v4m6-4v4M2 9h4m-4 6h4m12-6h4m-4 6h4"/></symbol>
 <symbol id="i-ref" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M20.5 11a8.5 8.5 0 10-2.4 6.5"/><path d="M20.5 4v7h-7"/></symbol>
 <symbol id="i-copy" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><rect x="8" y="8" width="12" height="12" rx="2"/><path d="M16 8V6a2 2 0 00-2-2H6a2 2 0 00-2 2v8a2 2 0 002 2h2"/></symbol>
 <symbol id="i-paste" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><rect x="5" y="5" width="14" height="16" rx="2"/><path d="M9 3h6v4H9zM9 12h6m-6 4h4"/></symbol>
 <symbol id="i-clear" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M4 7h16M9 7V4h6v3m-9 0l1 14h10l1-14M10 11v6m4-6v6"/></symbol>
 <symbol id="i-search" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><circle cx="10.5" cy="10.5" r="6.5"/><path d="M15.5 15.5L21 21"/></symbol>
 <symbol id="i-dl" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3v12m-5-5l5 5 5-5M4 20h16"/></symbol>
 <symbol id="i-ex" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M8 3H3v5m13-5h5v5M8 21H3v-5m13 5h5v-5"/></symbol>
 <symbol id="i-bolt" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M13 2L4 14h7l-1 8 9-12h-7z"/></symbol>
 <symbol id="i-mem" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><rect x="2.5" y="7" width="19" height="10" rx="2"/><path d="M6 7v10m4-10v10m4-10v10m4-10v10"/></symbol>
 <symbol id="i-disk" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="3"/><path d="M12 3v6"/></symbol>
 <symbol id="i-clock" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9"/><path d="M12 7v5l4 2"/></symbol>
 <symbol id="i-play" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M7 4.5l12 7.5-12 7.5z"/></symbol>
 <symbol id="i-stop" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><rect x="5" y="5" width="14" height="14" rx="2"/></symbol>
 <symbol id="i-restart" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M4 11a8 8 0 1014-5"/><path d="M4 4v7h7"/></symbol>
 <symbol id="i-wifi" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M2 9a16 16 0 0120 0M5 13a11 11 0 0114 0M8 17a6 6 0 018 0"/><circle cx="12" cy="20" r="1"/></symbol>
 <symbol id="i-shield" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M12 2l8 3v6c0 5-3 9-8 11-5-2-8-6-8-11V5z"/></symbol>
 <symbol id="i-moon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M20 14.5A8.5 8.5 0 019.5 4a8.5 8.5 0 1010.5 10.5z"/></symbol>
 <symbol id="i-sun" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="4"/><path d="M12 2v2m0 16v2M4.9 4.9l1.4 1.4m11.4 11.4l1.4 1.4M2 12h2m16 0h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/></symbol>
</svg>
<div class="app">
<aside class="side">
 <div class="brand">
  <div class="mark"><svg width="20" height="20" viewBox="0 0 32 32" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"><path d="M16 3.2 27 7.6v7.2c0 6.4-4.4 10.7-11 13.2C9.4 25.5 5 21.2 5 14.8V7.6z"/><path d="m10.5 12.5 4.5 4-4.5 4"/><path d="M17.5 20.5h4.5"/></svg></div>
  <div class="bname">IVT CONTROL<small>INFRASTRUCTURE</small></div>
 </div>
 <div>
  <div class="cap">WORKSPACE</div>
  <nav class="nav">
   <button class="on" data-p="dash"><svg><use href="#i-grid"/></svg><span class="ico">Overview</span></button>
   <button data-p="terminal"><svg><use href="#i-term"/></svg><span class="ico">Terminal</span></button>
   <button data-p="services"><svg><use href="#i-stack"/></svg><span class="ico">Services</span></button>
   <button data-p="logs"><svg><use href="#i-file"/></svg><span class="ico">Logs</span></button>
   <button data-p="system"><svg><use href="#i-cpu"/></svg><span class="ico">System</span></button>
  </nav>
 </div>
 <div class="sidefoot"><b><span class="dot"></span>SYSTEM ONLINE</b></div>
</aside>

<main class="main">
<header class="top">
 <div><h1 id="ttl">Command center</h1><div class="sub" id="sub"></div></div>
 <div class="tools"><div class="pill"><span class="dot"></span>LIVE</div><button class="ib" id="themeBtn" onclick="toggleTheme()" title="Toggle light / dark theme"><svg><use href="#i-moon"/></svg></button><button class="ib" onclick="refreshAll()" title="Refresh"><svg><use href="#i-ref"/></svg></button></div>
</header>

<section class="page on" id="dash">
 <div class="grid metrics">
  <div class="card"><div class="mh">CPU LOAD <span class="tile"><svg><use href="#i-bolt"/></svg></span></div><div class="mv" id="cpu">—</div><div class="mf"></div></div>
  <div class="card a"><div class="mh">MEMORY <span class="tile"><svg><use href="#i-mem"/></svg></span></div><div class="mv" id="ram">—</div><div class="mf" id="ramf"></div><div class="meter"><i id="rmeter"></i></div></div>
  <div class="card b"><div class="mh">STORAGE <span class="tile"><svg><use href="#i-disk"/></svg></span></div><div class="mv" id="disk">—</div><div class="mf" id="diskf"></div><div class="meter"><i id="dmeter"></i></div></div>
  <div class="card c"><div class="mh">UPTIME <span class="tile"><svg><use href="#i-clock"/></svg></span></div><div class="mv sm" id="up">—</div><div class="mf"></div></div>
 </div>

 <div class="grid over">
  <div class="card b">
   <div class="hd"><div><h2>Service health</h2></div><button class="btn" onclick="go('services')">Manage <svg><use href="#i-ex"/></svg></button></div>
   <div class="rows" id="srows"><div class="mf">Loading services…</div></div>
  </div>
  <div class="card a">
   <div class="hd"><div><h2>System overview</h2></div></div>
   <div class="info" id="sinfo"></div>
  </div>
 </div>

 <div class="grid row2" style="margin-top:13px">
  <div class="card">
   <div class="hd"><div><h2>Network &amp; speed</h2></div><button class="btn pri" id="stbtn" onclick="runSpeed()"><svg><use href="#i-bolt"/></svg>Run test</button></div>
   <div class="nt"><div><div class="mf">DOWN</div><div class="nv" id="sd">—</div></div><div><div class="mf">UP</div><div class="nv" id="su">—</div></div><div><div class="mf">PING</div><div class="nv" id="sp">—</div></div></div>
   <div class="mf" id="smsg" style="margin-top:8px"></div>
  </div>
  <div class="card a">
   <div class="hd"><div><h2>Quick actions</h2></div></div>
   <div class="quick">
    <button class="qa" onclick="go('terminal')"><svg><use href="#i-term"/></svg><span><b>SSH</b><small>Terminal</small></span></button>
    <button class="qa" onclick="go('logs')"><svg><use href="#i-file"/></svg><span><b>Logs</b><small>All logs</small></span></button>
    <button class="qa" onclick="go('services')"><svg><use href="#i-restart"/></svg><span><b>Units</b><small>Restart</small></span></button>
   </div>
  </div>
 </div>

 </section>

<section class="page" id="terminal">
 <div class="card tcard">
  <div class="ttop">
   <div><div class="ttitle">SSH Terminal</div></div>
   <div class="acts">
    <button class="btn" onclick="copySel()"><svg><use href="#i-copy"/></svg>Copy</button>
    <button class="btn" onclick="pasteClip()"><svg><use href="#i-paste"/></svg>Paste</button>
    <button class="btn" onclick="clearTerm()"><svg><use href="#i-clear"/></svg>Clear</button>
    <button class="btn" onclick="toggleSearch()"><svg><use href="#i-search"/></svg>Search</button>
    <button class="btn" onclick="fontSize(-1)">A−</button><button class="btn" onclick="fontSize(1)">A+</button>
    <button class="btn" onclick="saveTerm()"><svg><use href="#i-dl"/></svg>Log</button>
    <button class="btn" onclick="toggleFS()"><svg><use href="#i-ex"/></svg>Full</button>
   </div>
  </div>
  <div class="tabs" id="tabs"><button class="tab on" data-i="0">Terminal 1</button><button class="btn" onclick="addTab()" style="padding:6px 9px">＋ New</button></div>
  <div class="login"><input id="tu" placeholder="Linux username" autocomplete="username"><input id="tp" type="password" placeholder="Linux password" autocomplete="current-password"><button class="btn pri" onclick="connect(activeTerm(),$('tu').value,$('tp').value)"><svg><use href="#i-play"/></svg>Connect</button><button class="btn dan" onclick="disconnect(activeTerm())"><svg><use href="#i-stop"/></svg>Disconnect</button><span class="lstat" id="tstat">Not connected</span></div>
  <div class="search" id="search"><input id="sq" placeholder="Find in terminal…"><button class="btn" onclick="findNext(1)">Next</button><button class="btn" onclick="findNext(-1)">Prev</button><button class="btn" onclick="toggleSearch()">Close</button></div>
  <div class="wrap"><div id="mterm" class="inst"></div></div>
  <div class="tfoot"><span id="conn">● Disconnected</span></div>
 </div>
</section>

<section class="page" id="services">
 <div class="card">
  <div class="hd"><div><h2>Service manager</h2></div><button class="btn" onclick="loadServices()"><svg><use href="#i-ref"/></svg>Refresh</button></div>
  <div style="overflow:auto"><table><thead><tr><th>Unit</th><th>Status</th><th style="text-align:right">Action</th></tr></thead><tbody id="stbl"></tbody></table></div>
 </div>
</section>

<section class="page" id="logs">
 <div class="card">
  <div class="hd"><div><h2>System logs</h2></div><div style="display:flex;gap:7px"><select id="ls" onchange="loadLogs()"><option value="system">System</option><option value="ivt-api">IVT API</option><option value="ivt-link-master">IVT Link Master</option><option value="ivt-heartbeat">Heartbeat</option><option value="ivt-sshd">SSH daemon</option></select><button class="btn" onclick="copyFullLog()"><svg><use href="#i-copy"/></svg>Copy all</button><button class="btn" onclick="downloadLog()"><svg><use href="#i-dl"/></svg>Download</button><button class="btn" onclick="loadLogs()"><svg><use href="#i-ref"/></svg></button></div></div>
  <pre class="logbox" id="lout">Select a log.</pre>
 </div>
</section>

<section class="page" id="system">
 <div class="card">
  <div class="hd"><div><h2>System information</h2></div><button class="btn" onclick="loadSystem()"><svg><use href="#i-ref"/></svg>Refresh</button></div>
  <div class="info" id="sdet"></div>
 </div>
</section>
</main>
</div>
<div class="toast" id="toast"></div>
<script>
const $=id=>document.getElementById(id);
const ti=document.querySelector('#themeBtn use');if(ti)ti.setAttribute('href',document.documentElement.dataset.theme==='dark'?'#i-sun':'#i-moon');
const titles={dash:['Command center',''],terminal:['SSH Terminal',''],services:['Service manager',''],logs:['System logs',''],system:['System information','']};
function toast(m){const e=$('toast');e.textContent=m;e.classList.add('on');setTimeout(()=>e.classList.remove('on'),2600)}
function go(p){document.querySelectorAll('.page').forEach(x=>x.classList.remove('on'));$(p).classList.add('on');document.querySelectorAll('.nav button').forEach(b=>b.classList.toggle('on',b.dataset.p===p));$('ttl').textContent=titles[p][0];$('sub').textContent=titles[p][1];if(p==='terminal')setTimeout(fitAll,120);if(p==='services')loadServices();if(p==='logs')loadLogs();if(p==='system')loadSystem()}
document.querySelectorAll('.nav button').forEach(b=>b.onclick=()=>go(b.dataset.p));
async function jget(u){const r=await fetch(u,{cache:'no-store'});if(!r.ok)throw Error('HTTP '+r.status);return r.json()}
function bytes(n){if(!n)return '0 B';const u=['B','KB','MB','GB','TB'];let i=0;while(n>=1024&&i<u.length-1){n/=1024;i++}return n.toFixed(i?1:0)+' '+u[i]}
function esc(s){return String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]))}
async function loadMetrics(){try{const d=await jget('/api/metrics');$('cpu').textContent=d.load;$('ram').textContent=d.memory_percent+'%';$('ramf').textContent=bytes(d.memory_used)+' / '+bytes(d.memory_total);$('disk').textContent=d.disk.total?Math.round(d.disk.used*100/d.disk.total)+'%':'N/A';$('diskf').textContent=bytes(d.disk.used)+' / '+bytes(d.disk.total);$('rmeter').style.width=d.memory_percent+'%';$('dmeter').style.width=(d.disk.total?Math.round(d.disk.used*100/d.disk.total):0)+'%';$('up').textContent=String(d.uptime).replace('up ','');$('sinfo').innerHTML=[['Host',d.hostname],['Platform',d.platform],['Kernel',d.kernel],['Available',bytes(d.memory_free)]].map(x=>'<div class="il"><span>'+x[0]+'</span><strong>'+esc(x[1])+'</strong></div>').join('')}catch(e){$('sinfo').textContent='Metrics unavailable'}}
async function loadServices(){try{const d=await jget('/api/services');const tag=s=>'<span class="tag '+(s==='active'?'':'off')+'">'+esc(s)+'</span>';$('srows').innerHTML=d.map(s=>'<div class="row"><span class="n"><svg><use href="#i-stack"/></svg>'+esc(s.name)+'</span>'+tag(s.state)+'</div>').join('');$('stbl').innerHTML=d.map(s=>'<tr><td>'+esc(s.name)+'</td><td>'+tag(s.state)+'</td><td style="text-align:right"><button class="btn" onclick="svcAction(\''+s.name+'\',\'restart\')"><svg><use href="#i-restart"/></svg>Restart</button></td></tr>').join('')}catch(e){$('srows').textContent='Services unavailable'}}
async function svcAction(n,a){toast('Sending '+a+' to '+n);try{const r=await fetch('/api/service/'+encodeURIComponent(n)+'/'+a,{method:'POST'});if(!r.ok)throw Error('HTTP '+r.status);toast('Request sent');setTimeout(loadServices,900)}catch(e){toast('Failed: '+e.message)}}
async function loadSystem(){try{const d=await jget('/api/metrics');$('sdet').innerHTML=Object.entries({Hostname:d.hostname,Platform:d.platform,Kernel:d.kernel,'CPU load':d.load,Uptime:d.uptime,'Memory total':bytes(d.memory_total),'Memory used':bytes(d.memory_used),'Memory free':bytes(d.memory_free),'Disk total':bytes(d.disk.total),'Disk used':bytes(d.disk.used)}).map(x=>'<div class="il"><span>'+esc(x[0])+'</span><strong>'+esc(x[1])+'</strong></div>').join('')}catch(e){$('sdet').textContent='Unavailable'}}
async function loadLogs(){try{const n=$('ls').value;const r=await fetch('/api/logs/'+encodeURIComponent(n),{cache:'no-store'});$('lout').textContent=await r.text()}catch(e){$('lout').textContent='Log unavailable'}}
async function fullLog(){return await (await fetch('/api/logs/'+encodeURIComponent($('ls').value),{cache:'no-store'})).text()}
async function copyFullLog(){try{await navigator.clipboard.writeText(await fullLog());toast('Full log copied')}catch(e){toast('Clipboard blocked')}}
async function downloadLog(){const b=new Blob([await fullLog()],{type:'text/plain'});const u=URL.createObjectURL(b);const a=document.createElement('a');a.href=u;a.download='ivt-full.log';a.click();URL.revokeObjectURL(u)}
function bps(v){return v?((v*8/1000000).toFixed(1)+' Mbps'):'N/A'}
async function runSpeed(){const b=$('stbtn');b.disabled=true;$('smsg').textContent='Measuring…';try{const d=await jget('/api/speedtest');if(!d.ok){$('smsg').textContent=d.error||'Test failed'}else{$('sd').textContent=bps(d.download);$('su').textContent=bps(d.upload);$('sp').textContent=d.latency!=null?d.latency.toFixed(2)+' ms':'N/A';$('smsg').textContent=(d.server||'')+' · '+(d.isp||'')+(d.url?' · '+d.url:'')}}catch(e){$('smsg').textContent='Test failed: '+e.message}b.disabled=false}
async function refreshAll(){await Promise.all([loadMetrics(),loadServices()]);if($('system').classList.contains('on'))loadSystem();if($('logs').classList.contains('on'))loadLogs()}
setInterval(refreshAll,5000);refreshAll();

const terms=[];let tabIndex=0,fsize=13;
function makeTerm(id){const t=new Terminal({cursorBlink:true,scrollback:12000,fontSize:fsize,fontFamily:"'JetBrains Mono',monospace",theme:{background:'#0b1320',foreground:'#dce6f5',cursor:'#f6821f',cursorAccent:'#0b1320',selectionBackground:'#2b426788',black:'#0b1320',red:'#ff6b6e',green:'#4ed7a1',yellow:'#f4bd62',blue:'#6c9dff',magenta:'#c792ea',cyan:'#4dd6e8',white:'#dce6f5',brightBlack:'#5b6b82',brightRed:'#ff9093',brightGreen:'#7ae8bb',brightYellow:'#ffd489',brightBlue:'#9bbaff',brightMagenta:'#dcb6ff',brightCyan:'#84e8f2',brightWhite:'#ffffff'}});const f=new FitAddon.FitAddon(),s=new SearchAddon.SearchAddon();t.loadAddon(f);t.loadAddon(s);t.open($(id));const o={term:t,fit:f,search:s,id:id,ws:null,sid:null,stop:false,retry:null};t.onData(d=>{if(o.ws&&o.ws.readyState===1)o.ws.send(JSON.stringify({type:'input',data:d}))});t.onResize(z=>{if(o.ws&&o.ws.readyState===1)o.ws.send(JSON.stringify({type:'resize',cols:z.cols,rows:z.rows}))});terms.push(o);setTimeout(()=>{try{f.fit()}catch(e){}},140);return o}
const mterm=makeTerm('mterm');
function activeTerm(){return terms[tabIndex]||mterm}
function fitAll(){terms.forEach(t=>{try{t.fit.fit()}catch(e){}})}
window.addEventListener('resize',()=>setTimeout(fitAll,120));
function sock(){return (location.protocol==='https:'?'wss://':'ws://')+location.host+'/terminal'}
function status(o,m){$('tstat').textContent=m;$('conn').textContent='● '+m}
function attach(o,mode,extra){if(o.ws)try{o.ws.close()}catch(e){}o.stop=false;const ws=new WebSocket(sock());o.ws=ws;ws.onopen=()=>ws.send(JSON.stringify(Object.assign({type:mode},extra)));ws.onmessage=e=>{let d;try{d=JSON.parse(e.data)}catch(x){o.term.write(e.data);return}if(d.type==='ready'){o.sid=d.session_id;try{localStorage.setItem('ivt-'+o.id,o.sid)}catch(x){}status(o,'Connected · '+(d.username||'Linux'));if(d.resumed)o.term.writeln('\r\n[Session reconnected]\r\n');if(ws.readyState===1)ws.send(JSON.stringify({type:'resize',cols:o.term.cols,rows:o.term.rows}));o.term.focus()}else if(d.type==='output')o.term.write(d.data);else if(d.type==='error'){o.term.writeln('\r\n[ERROR] '+d.message+'\r\n');status(o,'Connection error')}else if(d.type==='closed'){o.term.writeln('\r\n[Process ended]\r\n');o.sid=null}};ws.onclose=()=>{if(o.ws===ws)o.ws=null;if(o.stop){status(o,'Disconnected');return}if(o.sid){status(o,'Reconnecting…');clearTimeout(o.retry);o.retry=setTimeout(()=>resume(o),2200)}else status(o,'Disconnected')};ws.onerror=()=>status(o,'Connection error')}
function resume(o){if(!o.sid){try{o.sid=localStorage.getItem('ivt-'+o.id)}catch(e){}}if(o.sid)attach(o,'resume',{session_id:o.sid})}
function connect(o,u,p){if(!u||!p){toast('Enter Linux username and password');return}o.term.writeln('\r\n[Connecting to IVT Linux…]\r\n');attach(o,'login',{username:u,password:p})}
function disconnect(o){o.stop=true;clearTimeout(o.retry);if(o.ws)try{o.ws.close()}catch(e){}o.ws=null;o.sid=null;try{localStorage.removeItem('ivt-'+o.id)}catch(e){}status(o,'Disconnected')}
function addTab(){if(terms.length>=8){toast('Maximum 8 tabs');return}const i=terms.length,id='xterm'+i;const b=document.createElement('button');b.className='tab';b.dataset.i=String(i);b.textContent='Terminal '+(i+1);b.onclick=()=>selectTab(i);$('tabs').insertBefore(b,$('tabs').lastElementChild);const d=document.createElement('div');d.id=id;d.className='inst';d.style.display='none';$('mterm').parentElement.appendChild(d);makeTerm(id);selectTab(i);$('mterm').parentElement.querySelectorAll('.inst').forEach((x,k)=>x.style.display=k===i?'block':'none')}
function selectTab(i){tabIndex=i;document.querySelectorAll('#tabs .tab').forEach((b,k)=>b.classList.toggle('on',k===i));const all=$('mterm').parentElement.querySelectorAll('.inst');all.forEach((x,k)=>x.style.display=k===i?'block':'none');setTimeout(fitAll,100)}
function clearTerm(){activeTerm().term.clear()}
async function copySel(){const s=activeTerm().term.getSelection();if(!s){toast('Select text first');return}try{await navigator.clipboard.writeText(s);toast('Copied')}catch(e){toast('Clipboard blocked')}}
async function pasteClip(){try{const v=await navigator.clipboard.readText();const o=activeTerm();if(o.ws&&o.ws.readyState===1)o.ws.send(JSON.stringify({type:'input',data:v}));else toast('Connect first')}catch(e){toast('Clipboard blocked')}}
function toggleSearch(){$('search').classList.toggle('on');if($('search').classList.contains('on'))$('sq').focus()}
function findNext(d){const v=$('sq').value;if(!v)return;const ok=d>0?activeTerm().search.findNext(v):activeTerm().search.findPrevious(v);if(!ok)toast('No match')}
function fontSize(d){fsize=Math.max(9,Math.min(24,fsize+d));terms.forEach(o=>{o.term.options.fontSize=fsize;try{o.fit.fit()}catch(e){}})}
function saveTerm(){const o=activeTerm(),b=o.term.buffer.active;let s='';for(let i=0;i<b.length;i++){const l=b.getLine(i);if(l)s+=l.translateToString(true)+'\n'}const u=URL.createObjectURL(new Blob([s],{type:'text/plain'}));const a=document.createElement('a');a.href=u;a.download='ivt-terminal.log';a.click();URL.revokeObjectURL(u)}
function toggleFS(){document.body.classList.toggle('fs');setTimeout(fitAll,150)}
document.addEventListener('keydown',e=>{if(e.key==='Escape'&&document.body.classList.contains('fs')){document.body.classList.remove('fs');setTimeout(fitAll,100)}});
try{const saved=localStorage.getItem('ivt-mterm');if(saved){mterm.sid=saved;resume(mterm)}}catch(e){}
</script>
</body>
</html>
"""

class TerminalSession:
    def __init__(self, token, conn, process, username):
        self.token = token
        self.conn = conn
        self.process = process
        self.username = username
        self.ws = None
        self.buffer = deque()
        self.buffer_size = 0
        self.lock = asyncio.Lock()
        self.closed = False
        self.created = time.time()
        self.reader_task = None

    async def remember(self, text):
        self.buffer.append(text)
        self.buffer_size += len(text.encode("utf-8", errors="replace"))
        while self.buffer and self.buffer_size > SCROLLBACK_LIMIT:
            old = self.buffer.popleft()
            self.buffer_size -= len(old.encode("utf-8", errors="replace"))

    async def send(self, payload):
        async with self.lock:
            ws = self.ws
            if ws is not None and not ws.closed:
                try:
                    await ws.send_json(payload)
                except Exception:
                    self.ws = None

    async def read_output(self):
        try:
            while not self.closed:
                data = await self.process.stdout.read(4096)
                if not data:
                    break
                await self.remember(data)
                await self.send({"type": "output", "data": data})
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            await self.send({"type": "error", "message": str(exc)})
        finally:
            self.closed = True
            await self.send({"type": "closed"})

    async def replay(self, ws):
        async with self.lock:
            if not ws.closed:
                for chunk in self.buffer:
                    await ws.send_json({"type": "output", "data": chunk})

    async def shutdown(self):
        self.closed = True
        try:
            self.process.close()
        except Exception:
            pass
        try:
            self.conn.close()
            await self.conn.wait_closed()
        except Exception:
            pass

def prune_sessions():
    for token in list(SESSIONS.keys()):
        s = SESSIONS[token]
        if s.closed or (s.reader_task and s.reader_task.done()):
            SESSIONS.pop(token, None)

async def dashboard(request):
    return web.Response(text=PAGE, content_type="text/html")

async def health(request):
    return web.Response(text="OK")

async def status(request):
    return web.Response(text=run(["systemctl", "status"]))

async def system_info(request):
    return web.json_response(system_metrics())

async def metrics(request):
    return web.json_response(system_metrics())

async def services(request):
    return web.json_response(service_data())

async def service_action(request):
    name = request.match_info.get("name", "")
    action = request.match_info.get("action", "")
    if name not in ALLOWED_UNITS or action not in ("start", "stop", "restart"):
        raise web.HTTPNotFound()
    try:
        fd = os.open(FIFO, os.O_WRONLY | os.O_NONBLOCK)
        os.write(fd, ("%s:%s\n" % (action, name)).encode())
        os.close(fd)
        return web.json_response({"ok": True, "unit": name, "action": action})
    except Exception as exc:
        return web.json_response({"ok": False, "error": str(exc)}, status=500)

async def logs(request):
    name = request.match_info.get("name", "system")
    try:
        return web.Response(text=read_log(name), content_type="text/plain")
    except ValueError:
        raise web.HTTPNotFound()

async def speed(request):
    return web.json_response(await speedtest_result())

async def create_session(username, password):
    conn = await asyncssh.connect(
        "127.0.0.1", port=22, username=username, password=password,
        known_hosts=None, login_timeout=15
    )
    process = await conn.create_process(
        term_type="xterm-256color", term_size=(120, 35), encoding="utf-8"
    )
    token = secrets.token_urlsafe(32)
    session = TerminalSession(token, conn, process, username)
    SESSIONS[token] = session
    session.reader_task = asyncio.create_task(session.read_output())
    return session

async def terminal(request):
    ws = web.WebSocketResponse(heartbeat=25, max_msg_size=2 * 1024 * 1024, compress=False)
    await ws.prepare(request)
    session = None

    try:
        first = await asyncio.wait_for(ws.receive(), timeout=30)
        if first.type != web.WSMsgType.TEXT:
            await ws.send_json({"type": "error", "message": "Login or resume required"})
            await ws.close()
            return ws

        try:
            data = json.loads(first.data)
        except Exception:
            await ws.send_json({"type": "error", "message": "Invalid request"})
            await ws.close()
            return ws

        mode = data.get("type")

        if mode == "login":
            username = str(data.get("username", "")).strip()
            password = str(data.get("password", ""))
            if not username or not password:
                await ws.send_json({"type": "error", "message": "Username and password required"})
                await ws.close()
                return ws
            if len(username) > 128 or len(password) > 1024:
                await ws.send_json({"type": "error", "message": "Credentials too long"})
                await ws.close()
                return ws
            session = await create_session(username, password)

        elif mode == "resume":
            token = str(data.get("session_id", ""))
            session = SESSIONS.get(token)
            if not session or session.closed:
                await ws.send_json({"type": "error", "message": "Session expired. Log in again."})
                await ws.close()
                return ws

        else:
            await ws.send_json({"type": "error", "message": "Unsupported request"})
            await ws.close()
            return ws

        previous = session.ws
        if previous is not None and previous is not ws and not previous.closed:
            try:
                await previous.close()
            except Exception:
                pass

        session.ws = ws
        await ws.send_json({
            "type": "ready",
            "session_id": session.token,
            "username": session.username,
            "resumed": mode == "resume"
        })

        # Replay buffered output on BOTH first login and resume.
        # Without this, the terminal looks empty even when SSH connected.
        await session.replay(ws)

        async for message in ws:
            if message.type == web.WSMsgType.TEXT:
                try:
                    item = json.loads(message.data)
                except Exception:
                    continue

                if item.get("type") == "input":
                    value = item.get("data", "")
                    if isinstance(value, str) and len(value) <= 65536 and not session.closed:
                        session.process.stdin.write(value)
                        await session.process.stdin.drain()

                elif item.get("type") == "resize":
                    cols = max(20, min(300, int(item.get("cols", 120))))
                    rows = max(5, min(120, int(item.get("rows", 35))))
                    try:
                        session.process.change_terminal_size(cols, rows)
                    except Exception:
                        pass

                elif item.get("type") == "ping":
                    await ws.send_json({"type": "pong"})

            elif message.type == web.WSMsgType.ERROR:
                break

    except asyncssh.PermissionDenied:
        if not ws.closed:
            await ws.send_json({"type": "error", "message": "Linux username or password incorrect"})

    except (asyncio.TimeoutError, asyncio.CancelledError):
        if not ws.closed:
            await ws.send_json({"type": "error", "message": "Connection timed out"})
        if isinstance(__import__("sys").exc_info()[1], asyncio.CancelledError):
            raise

    except Exception as exc:
        if not ws.closed:
            await ws.send_json({"type": "error", "message": str(exc)[:500]})

    finally:
        # A browser disconnect must NOT kill the SSH process.
        if session is not None and session.ws is ws:
            session.ws = None
        prune_sessions()
        if not ws.closed:
            await ws.close()

    return ws

async def cleanup_sessions(app):
    yield
    for session in list(SESSIONS.values()):
        await session.shutdown()
    SESSIONS.clear()

app = web.Application(client_max_size=2 * 1024 * 1024)
app.router.add_get("/", dashboard)
app.router.add_get("/health", health)
app.router.add_get("/api/status", status)
app.router.add_get("/api/sys", system_info)
app.router.add_get("/api/metrics", metrics)
app.router.add_get("/api/services", services)
app.router.add_post("/api/service/{name}/{action}", service_action)
app.router.add_get("/api/logs/{name}", logs)
app.router.add_get("/api/speedtest", speed)
app.router.add_get("/terminal", terminal)
app.cleanup_ctx.append(cleanup_sessions)

if __name__ == "__main__":
    web.run_app(app, host="0.0.0.0", port=PORT, shutdown_timeout=5)
API_EOF

# ==========================================
# IVT LINK MASTER
# ==========================================

RUN cat > /ivt/os/ivt-link-master.py << 'LINK_EOF'
#!/usr/bin/env python3
import os
import json
import time
import queue
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LINK_SECRET = os.environ.get("IVT_LINK_SECRET", "default-secret")
LINK_PORT = int(os.environ.get("LINK_PORT", 8081))
STALE_AFTER = 90

task_queue = queue.Queue()
worker_status = {
    "state": "DISCONNECTED",
    "ram": 0,
    "cpu": 0,
    "last_seen": 0
}

def fresh():
    return worker_status["last_seen"] > 0 and (time.time() - worker_status["last_seen"]) < STALE_AFTER

class L(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        cl = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(cl)

        try:
            data = json.loads(body)
        except Exception:
            self._json(400, {"error": "invalid json"})
            return

        if self.path == "/ivt-link/auth" and data.get("secret") == LINK_SECRET:
            worker_status["state"] = "CONNECTED"
            worker_status["last_seen"] = time.time()
            self._json(200, {"status": "auth_ok"})
            return

        if self.path == "/ivt-link/heartbeat" and data.get("secret") == LINK_SECRET:
            worker_status["last_seen"] = time.time()
            worker_status["ram"] = data.get("ram", 0)
            worker_status["cpu"] = data.get("cpu", 0)
            worker_status["state"] = "CONNECTED"
            self._json(200, {"status": "ok"})
            return

        if self.path == "/ivt-link/task" and data.get("secret") == LINK_SECRET:
            task_queue.put({k: v for k, v in data.items() if k != "secret"})
            self._json(200, {"status": "queued"})
            return

        self._json(200, {"status": "ok"})

    def do_GET(self):
        if self.path == "/ivt-link/poll":
            try:
                task = task_queue.get(timeout=15)
                self._json(200, task)
            except queue.Empty:
                self.send_response(204)
                self.send_header("Content-Length", "0")
                self.end_headers()
            return

        if self.path == "/ivt-link/status":
            if not fresh():
                worker_status["state"] = "DISCONNECTED"
            self._json(200, dict(worker_status))
            return

        self.send_response(404)
        self.send_header("Content-Length", "0")
        self.end_headers()

if __name__ == "__main__":
    print("[IVT-LINK MASTER] Listening on port %d" % LINK_PORT)
    ThreadingHTTPServer(("0.0.0.0", LINK_PORT), L).serve_forever()
LINK_EOF

# ==========================================
# SERVICE UNITS
# ==========================================

RUN cat > /etc/ivt/units/ivt-api.service << 'U1_EOF'
[Unit]
Description=IVT Master API & Dashboard
[Service]
ExecStart=/opt/ivt-venv/bin/python /ivt/os/api.py
Restart=always
RestartSec=2
[Install]
Target=default
U1_EOF

RUN cat > /etc/ivt/units/ivt-link-master.service << 'U2_EOF'
[Unit]
Description=IVT-LINK Master Agent
[Service]
ExecStart=/usr/bin/python3 /ivt/os/ivt-link-master.py
Restart=always
RestartSec=2
[Install]
Target=default
U2_EOF

RUN cat > /etc/ivt/units/ivt-heartbeat.service << 'U3_EOF'
[Unit]
Description=IVT Master Heartbeat
[Service]
ExecStart=/bin/sh -c 'while true; do date +%s > /home/container/.ivt/run/heartbeat; sleep 5; done'
Restart=always
RestartSec=1
[Install]
Target=default
U3_EOF

RUN cat > /etc/ivt/units/ivt-sshd.service << 'U4_EOF'
[Unit]
Description=OpenSSH Server
[Service]
ExecStart=/usr/sbin/sshd -D
Restart=always
RestartSec=2
[Install]
Target=default
U4_EOF

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
    for u in /etc/ivt/units/*.service; do \
      ln -sf "$u" /etc/ivt/targets/default.wants/; \
      ln -sf "$u" /etc/ivt/targets/multi-user.target.wants/; \
      ln -sf "$u" /etc/systemd/system/; \
      ln -sf "$u" /lib/systemd/system/; \
    done && \
    ln -sf /usr/local/bin/systemctl /usr/bin/systemctl && \
    ln -sf /usr/local/bin/journalctl /usr/bin/journalctl && \
    ln -sf /usr/local/bin/service /usr/sbin/service && \
    ln -sf /usr/local/bin/hostnamectl /usr/bin/hostnamectl && \
    echo 'root ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/root && \
    chmod 0440 /etc/sudoers.d/root

WORKDIR /home/container

EXPOSE 22 8080 8081

HEALTHCHECK --interval=30s --timeout=5s --retries=3 CMD curl -sf http://127.0.0.1:8080/health || exit 1

RUN printf '%s\n' \
  '#!/bin/sh' \
  'echo "[ivt] container starting..."' \
  'mkdir -p /run/sshd /var/run/sshd' \
  'exec /ivt/os/init "$@"' \
  > /entrypoint.sh && chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]

