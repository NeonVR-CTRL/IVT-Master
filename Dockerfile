
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
# IVT MASTER PREMIUM DASHBOARD + SSH
# ==========================================

RUN cat > /ivt/os/api.py << 'API_EOF'
#!/opt/ivt-venv/bin/python
import os
import re
import json
import time
import uuid
import asyncio
import secrets
import subprocess
from collections import deque
from aiohttp import web
import asyncssh

PORT = int(os.environ.get("PORT", 8080))
SESSIONS = {}
SCROLLBACK_LIMIT = 2 * 1024 * 1024

def run(cmd, timeout=5):
    try:
        result = subprocess.run(
            cmd, capture_output=True, text=True, timeout=timeout
        )
        return result.stdout.strip()
    except Exception as exc:
        return f"ERROR: {exc}"

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
    names = [
        "ivt-api",
        "ivt-link-master",
        "ivt-heartbeat",
        "ivt-sshd"
    ]
    result = []
    for name in names:
        state = run(["systemctl", "is-active", name + ".service"])
        result.append({
            "name": name,
            "state": state if state else "unknown"
        })
    return result

def log_tail(name, lines=150):
    allowed = {
        "system", "ivt-api", "ivt-link-master",
        "ivt-heartbeat", "ivt-sshd"
    }
    if name not in allowed:
        raise ValueError("Unknown log")
    path = f"/home/container/.ivt/log/{name}.log"
    try:
        with open(path, "r", errors="replace") as f:
            return "".join(deque(f, maxlen=lines))
    except FileNotFoundError:
        return "No log entries yet."

PAGE = r"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="theme-color" content="#090d17">
<title>IVT Master | Control Center</title>
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/xterm@5.3.0/css/xterm.css">
<style>
:root {
 --bg:#090d17; --panel:#111827; --panel2:#151f30;
 --line:#253247; --text:#e9effa; --muted:#8d9bb2;
 --blue:#6c8cff; --cyan:#54d9e8; --green:#38d6a3;
 --red:#ff657a; --amber:#f4bd62;
 --radius:15px;
}
*{box-sizing:border-box}
html{scroll-behavior:smooth}
body{
 margin:0;background:
 radial-gradient(ellipse at 15% -10%,rgba(72,105,210,.16),transparent 38%),
 radial-gradient(ellipse at 95% 0%,rgba(42,195,204,.09),transparent 30%),
 var(--bg);
 color:var(--text);font-family:Inter,ui-sans-serif,system-ui,-apple-system,
 BlinkMacSystemFont,"Segoe UI",sans-serif;min-height:100vh;
}
button,input{font:inherit}
button{cursor:pointer}
.shell{display:grid;grid-template-columns:245px minmax(0,1fr);min-height:100vh}
.sidebar{
 position:sticky;top:0;height:100vh;padding:23px 15px;
 background:rgba(12,18,30,.94);border-right:1px solid var(--line);
 display:flex;flex-direction:column;gap:25px;
}
.brand{display:flex;align-items:center;gap:12px;padding:4px 8px}
.brandmark{
 width:40px;height:40px;border-radius:13px;display:grid;place-items:center;
 background:linear-gradient(140deg,#688cff,#39c9d7);
 color:#07111e;font-size:20px;font-weight:900;
 box-shadow:0 7px 25px #526fe844
}
.brandname{font-size:15px;font-weight:850;letter-spacing:.08em}
.brandname small{display:block;color:var(--muted);font-size:10px;letter-spacing:.16em;margin-top:3px}
.navlabel{font-size:10px;font-weight:800;letter-spacing:.16em;color:#687891;padding:0 11px;margin-bottom:8px}
.nav{display:grid;gap:5px}
.nav button{
 width:100%;display:flex;align-items:center;gap:12px;text-align:left;
 padding:11px 12px;border:1px solid transparent;border-radius:10px;
 background:transparent;color:#9aa9bf;font-size:13px;font-weight:650;
}
.nav button:hover,.nav button.active{
 color:white;background:#1a2940;border-color:#2a3c59;
}
.nav .ico{width:20px;text-align:center;font-size:16px}
.sidebottom{margin-top:auto;border:1px solid var(--line);background:#101a2a;border-radius:12px;padding:13px}
.sidebottom strong{font-size:12px}
.sidebottom p{font-size:11px;color:var(--muted);line-height:1.5;margin:7px 0 0}
main{min-width:0;padding:27px clamp(16px,3vw,38px) 45px}
.topbar{display:flex;justify-content:space-between;align-items:center;gap:15px;margin-bottom:26px}
.eyebrow{color:var(--cyan);font-size:10px;font-weight:850;letter-spacing:.18em;text-transform:uppercase}
h1{font-size:clamp(23px,3vw,31px);letter-spacing:-.04em;margin:5px 0 0}
.sub{font-size:12px;color:var(--muted);margin-top:6px}
.topright{display:flex;align-items:center;gap:10px}
.livepill{border:1px solid #235b4b;color:#73e6bb;background:#102c27;padding:8px 11px;border-radius:30px;font-size:11px;font-weight:750}
.live-dot{display:inline-block;width:7px;height:7px;background:var(--green);border-radius:50%;margin-right:7px;box-shadow:0 0 10px var(--green)}
.iconbtn,.btn{
 border:1px solid var(--line);background:#172235;color:#dce7f8;
 border-radius:9px;padding:9px 12px;font-size:12px;font-weight:700;
}
.iconbtn:hover,.btn:hover{border-color:#526b9a;background:#1c2b43}
.btn.primary{background:linear-gradient(120deg,#627ff0,#4772dc);border-color:transparent;color:white}
.btn.danger{background:#351c29;border-color:#693246;color:#ff9baa}
.grid{display:grid;gap:14px}
.metrics{grid-template-columns:repeat(4,minmax(0,1fr));margin-bottom:15px}
.card{
 min-width:0;background:linear-gradient(145deg,rgba(21,32,50,.97),rgba(15,23,37,.97));
 border:1px solid var(--line);border-radius:var(--radius);padding:17px;
 box-shadow:0 10px 35px #00000016;
}
.metric-head{display:flex;justify-content:space-between;align-items:center;color:var(--muted);font-size:11px;font-weight:700}
.metric-icon{width:31px;height:31px;border-radius:10px;display:grid;place-items:center;background:#243655;color:#9db7ff;font-size:16px}
.metric-value{font-size:26px;font-weight:850;letter-spacing:-.04em;margin:12px 0 4px}
.metric-foot{font-size:10px;color:var(--muted)}
.sectionhead{display:flex;justify-content:space-between;align-items:center;gap:12px;margin-bottom:13px}
.sectionhead h2{font-size:15px;margin:0;letter-spacing:-.02em}
.sectionhead p{font-size:11px;color:var(--muted);margin:5px 0 0}
.overview{grid-template-columns:minmax(0,1.35fr) minmax(260px,.8fr);margin-bottom:15px}
.service-list{display:grid;gap:9px}
.service-row{display:flex;align-items:center;justify-content:space-between;padding:11px 12px;background:#101a2a;border:1px solid #202e43;border-radius:10px;gap:10px}
.service-name{font-size:12px;font-weight:700}
.service-state{font-size:10px;font-weight:800;border-radius:30px;padding:5px 8px;background:#143329;color:#71e6b9}
.service-state.off{background:#3a202a;color:#ff9baa}
.info-list{display:grid;gap:12px}
.info-line{display:flex;justify-content:space-between;gap:12px;font-size:11px}
.info-line span:first-child{color:var(--muted)}
.info-line strong{text-align:right;overflow-wrap:anywhere}
.page{display:none}
.page.active{display:block}
.terminal-card{padding:0;overflow:hidden}
.terminal-top{
 display:flex;align-items:center;justify-content:space-between;gap:10px;
 padding:13px 15px;border-bottom:1px solid var(--line);flex-wrap:wrap
}
.terminal-title{font-size:13px;font-weight:800}
.terminal-sub{font-size:10px;color:var(--muted);margin-top:3px}
.terminal-actions{display:flex;gap:6px;flex-wrap:wrap}
.terminal-actions button{padding:7px 9px;font-size:11px}
.tabs{display:flex;align-items:center;gap:6px;padding:9px 12px;border-bottom:1px solid var(--line);overflow-x:auto}
.tab{white-space:nowrap;border:1px solid transparent;background:transparent;color:#899bb6;border-radius:8px;padding:7px 10px;font-size:11px}
.tab.active{background:#1d2c43;color:white;border-color:#344969}
.terminal-login{display:flex;gap:8px;align-items:center;flex-wrap:wrap;padding:11px 14px;background:#101a29;border-bottom:1px solid var(--line)}
.terminal-login input{
 width:155px;max-width:100%;background:#0b1220;color:white;border:1px solid #34445e;
 border-radius:8px;padding:9px 11px;outline:none;font-size:12px
}
.terminal-login input:focus{border-color:var(--blue);box-shadow:0 0 0 3px #6c8cff22}
.login-status{font-size:10px;color:var(--muted);margin-left:auto}
.term-wrap{background:#080d16;padding:10px 12px;min-height:390px}
.terminal-instance{height:390px;min-width:0}
.terminal-instance .xterm{height:100%;padding:4px}
.terminal-instance .xterm-viewport{overflow-y:auto!important}
.terminal-foot{display:flex;justify-content:space-between;gap:10px;flex-wrap:wrap;padding:9px 14px;border-top:1px solid var(--line);font-size:10px;color:var(--muted)}
.searchbar{display:none;padding:8px 13px;background:#101a29;border-top:1px solid var(--line)}
.searchbar.open{display:flex;gap:7px}
.searchbar input{flex:1;min-width:0;background:#0b1220;color:white;border:1px solid var(--line);border-radius:8px;padding:8px}
.table{width:100%;border-collapse:collapse;font-size:11px}
.table th,.table td{text-align:left;padding:12px 9px;border-bottom:1px solid var(--line)}
.table th{color:var(--muted);font-size:10px;text-transform:uppercase;letter-spacing:.1em}
.logbox{white-space:pre-wrap;overflow-wrap:anywhere;background:#080d16;border:1px solid var(--line);border-radius:10px;padding:14px;min-height:300px;max-height:65vh;overflow:auto;font:11px/1.6 ui-monospace,monospace;color:#b9c9df}
.logcontrols{display:flex;gap:8px;flex-wrap:wrap;margin-bottom:12px}
select,.field{background:#0c1422;color:white;border:1px solid var(--line);border-radius:8px;padding:9px;font-size:12px}
.toast{position:fixed;right:20px;bottom:20px;background:#1d2d44;border:1px solid #405778;border-radius:10px;padding:12px 16px;font-size:12px;z-index:100;box-shadow:0 10px 35px #0008;display:none}
.toast.show{display:block}
.empty{color:var(--muted);font-size:12px;padding:20px;text-align:center}
body.fullscreen-terminal main{padding:0}
body.fullscreen-terminal .sidebar,body.fullscreen-terminal .topbar,
body.fullscreen-terminal #dashboardPage,body.fullscreen-terminal #servicesPage,
body.fullscreen-terminal #logsPage,body.fullscreen-terminal #systemPage{display:none!important}
body.fullscreen-terminal .shell{display:block}
body.fullscreen-terminal .terminal-card{border:0;border-radius:0;min-height:100vh}
body.fullscreen-terminal .term-wrap{height:calc(100vh - 150px)}
body.fullscreen-terminal .terminal-instance{height:calc(100vh - 170px)}
@media(max-width:950px){
 .shell{grid-template-columns:75px minmax(0,1fr)}
 .sidebar{padding:18px 9px;align-items:center}
 .brand{padding:0}.brandname,.navlabel,.navtext,.sidebottom{display:none}
 .nav{width:100%}.nav button{justify-content:center;padding:12px 5px}
 .metrics{grid-template-columns:repeat(2,minmax(0,1fr))}
}
@media(max-width:650px){
 .shell{display:block}
 .sidebar{position:sticky;z-index:10;top:0;width:100%;height:auto;padding:9px 12px;border-right:0;border-bottom:1px solid var(--line);flex-direction:row;justify-content:space-between}
 .brandmark{width:34px;height:34px}
 .nav{display:flex;gap:3px;width:auto}
 .nav button{width:39px;height:39px}
 main{padding:18px 12px 35px}
 .topbar{align-items:flex-start}
 .overview{grid-template-columns:1fr}
 .metrics{gap:9px}
 .metric-value{font-size:22px}
 .terminal-instance{height:340px}
 .term-wrap{min-height:340px;padding:6px}
 .terminal-login input{width:calc(50% - 5px)}
 .login-status{width:100%;margin-left:0}
}
</style>
</head>
<body>
<div class="shell">
<aside class="sidebar">
 <div class="brand">
  <div class="brandmark">IV</div>
  <div class="brandname">IVT MASTER<small>CONTROL CENTER</small></div>
 </div>
 <div style="width:100%">
  <div class="navlabel">WORKSPACE</div>
  <nav class="nav">
   <button class="active" data-page="dashboard"><span class="ico">◫</span><span class="navtext">Overview</span></button>
   <button data-page="terminal"><span class="ico">⌘</span><span class="navtext">Terminal</span></button>
   <button data-page="services"><span class="ico">▤</span><span class="navtext">Services</span></button>
   <button data-page="logs"><span class="ico">≡</span><span class="navtext">System logs</span></button>
   <button data-page="system"><span class="ico">◈</span><span class="navtext">System info</span></button>
  </nav>
 </div>
 <div class="sidebottom">
  <strong>IVT MASTER</strong>
  <p>Server control interface<br>Secure SSH over WebSocket</p>
 </div>
</aside>

<main>
<header class="topbar">
 <div>
  <div class="eyebrow">IVT / MASTER NODE</div>
  <h1 id="pageTitle">Command center</h1>
  <div class="sub" id="pageSubtitle">Your server at a glance.</div>
 </div>
 <div class="topright">
  <div class="livepill"><span class="live-dot"></span>LIVE STATUS</div>
  <button class="iconbtn" onclick="refreshAll()" title="Refresh">↻</button>
 </div>
</header>

<section class="page active" id="dashboardPage">
 <div class="grid metrics">
  <div class="card"><div class="metric-head">CPU LOAD <span class="metric-icon">⌁</span></div><div class="metric-value" id="cpuValue">—</div><div class="metric-foot">System load average</div></div>
  <div class="card"><div class="metric-head">MEMORY USED <span class="metric-icon">▥</span></div><div class="metric-value" id="ramValue">—</div><div class="metric-foot" id="ramFoot">Reading memory</div></div>
  <div class="card"><div class="metric-head">STORAGE USED <span class="metric-icon">▣</span></div><div class="metric-value" id="diskValue">—</div><div class="metric-foot" id="diskFoot">Root filesystem</div></div>
  <div class="card"><div class="metric-head">UPTIME <span class="metric-icon">◷</span></div><div class="metric-value" id="uptimeValue" style="font-size:18px">—</div><div class="metric-foot">Current boot session</div></div>
 </div>

 <div class="grid overview">
  <div class="card">
   <div class="sectionhead"><div><h2>Service health</h2><p>Core IVT services</p></div><button class="btn" onclick="showPage('services')">Manage services →</button></div>
   <div class="service-list" id="serviceList"><div class="empty">Loading services…</div></div>
  </div>
  <div class="card">
   <div class="sectionhead"><div><h2>System overview</h2><p>Runtime information</p></div></div>
   <div class="info-list" id="systemSummary"><div class="empty">Loading…</div></div>
  </div>
 </div>

 <div class="card terminal-card">
  <div class="terminal-top">
   <div><div class="terminal-title">Quick terminal</div><div class="terminal-sub">Interactive Linux SSH session</div></div>
   <div class="terminal-actions"><button class="btn" onclick="showPage('terminal')">Open full terminal ↗</button></div>
  </div>
  <div class="terminal-login">
   <input id="quickUser" placeholder="Linux username" autocomplete="username">
   <input id="quickPass" type="password" placeholder="Linux password" autocomplete="current-password">
   <button class="btn primary" onclick="connectQuick()">Connect SSH</button>
   <span class="login-status" id="quickStatus">Not connected</span>
  </div>
  <div class="term-wrap"><div id="quickTerminal" class="terminal-instance"></div></div>
 </div>
</section>

<section class="page" id="terminalPage">
 <div class="card terminal-card">
  <div class="terminal-top">
   <div><div class="terminal-title">SSH Terminal</div><div class="terminal-sub">Persistent server-side sessions · reconnect enabled</div></div>
   <div class="terminal-actions">
    <button class="btn" onclick="copyTerminal()">▣ Copy</button>
    <button class="btn" onclick="pasteTerminal()">▤ Paste</button>
    <button class="btn" onclick="clearTerminal()">⌫ Clear</button>
    <button class="btn" onclick="toggleSearch()">⌕ Search</button>
    <button class="btn" onclick="changeFont(-1)">A−</button>
    <button class="btn" onclick="changeFont(1)">A+</button>
    <button class="btn" onclick="downloadTerminal()">↓ Logs</button>
    <button class="btn" onclick="toggleFullscreen()">⛶</button>
   </div>
  </div>
  <div class="tabs" id="terminalTabs">
   <button class="tab active" data-tab="0">Terminal 1</button>
   <button class="btn" onclick="addTerminal()" style="padding:6px 10px">＋ New tab</button>
  </div>
  <div class="terminal-login">
   <input id="termUser" placeholder="Linux username" autocomplete="username">
   <input id="termPass" type="password" placeholder="Linux password" autocomplete="current-password">
   <button class="btn primary" onclick="connectMain()">Connect SSH</button>
   <button class="btn danger" onclick="disconnectMain()">Disconnect</button>
   <span class="login-status" id="mainStatus">Not connected</span>
  </div>
  <div class="searchbar" id="searchBar">
   <input id="terminalSearch" placeholder="Find text in terminal…" onkeydown="if(event.key==='Enter')searchNext()">
   <button class="btn" onclick="searchNext()">Next</button>
   <button class="btn" onclick="searchPrevious()">Previous</button>
   <button class="btn" onclick="toggleSearch()">Close</button>
  </div>
  <div class="term-wrap"><div id="mainTerminal" class="terminal-instance"></div></div>
  <div class="terminal-foot"><span id="terminalConnection">● Disconnected</span><span>SSH · xterm.js · WebSocket</span></div>
 </div>
 <div class="card" style="margin-top:14px">
  <div class="sectionhead"><div><h2>Terminal tips</h2><p>Keyboard and session shortcuts</p></div></div>
  <div class="info-list">
   <div class="info-line"><span>Copy selected text</span><strong>Ctrl + Shift + C or Copy</strong></div>
   <div class="info-line"><span>Paste clipboard</span><strong>Ctrl + Shift + V or Paste</strong></div>
   <div class="info-line"><span>Clear visible screen</span><strong>Clear button · does not kill process</strong></div>
   <div class="info-line"><span>Reconnect</span><strong>Automatic after temporary disconnect</strong></div>
   <div class="info-line"><span>Session</span><strong>Server-side while this instance remains running</strong></div>
  </div>
 </div>
</section>

<section class="page" id="servicesPage">
 <div class="card">
  <div class="sectionhead"><div><h2>Service manager</h2><p>Inspect the core IVT services</p></div><button class="btn" onclick="loadServices()">↻ Refresh</button></div>
  <div style="overflow-x:auto"><table class="table"><thead><tr><th>Service</th><th>Status</th></tr></thead><tbody id="servicesTable"></tbody></table></div>
 </div>
</section>

<section class="page" id="logsPage">
 <div class="card">
  <div class="sectionhead"><div><h2>System logs</h2><p>Recent service output</p></div><button class="btn" onclick="loadLogs()">↻ Refresh</button></div>
  <div class="logcontrols">
   <select id="logSelect" onchange="loadLogs()">
    <option value="system">System</option>
    <option value="ivt-api">IVT API</option>
    <option value="ivt-link-master">IVT Link Master</option>
    <option value="ivt-heartbeat">Heartbeat</option>
    <option value="ivt-sshd">SSH daemon</option>
   </select>
   <button class="btn" onclick="downloadLogs()">↓ Download</button>
  </div>
  <pre class="logbox" id="logOutput">Select a log.</pre>
 </div>
</section>

<section class="page" id="systemPage">
 <div class="card">
  <div class="sectionhead"><div><h2>System information</h2><p>Host and runtime details</p></div><button class="btn" onclick="loadSystem()">↻ Refresh</button></div>
  <div class="info-list" id="systemDetails"></div>
 </div>
</section>
</main>
</div>
<div class="toast" id="toast"></div>

<script src="https://cdn.jsdelivr.net/npm/xterm@5.3.0/lib/xterm.js"></script>
<script src="https://cdn.jsdelivr.net/npm/@xterm/addon-fit@0.10.0/lib/addon-fit.js"></script>
<script src="https://cdn.jsdelivr.net/npm/@xterm/addon-search@0.15.0/lib/addon-search.js"></script>
<script>
const $=id=>document.getElementById(id);
const pageNames={
 dashboard:["Command center","Your server at a glance."],
 terminal:["SSH Terminal","Persistent interactive Linux terminal."],
 services:["Service manager","Monitor your IVT services."],
 logs:["System logs","Inspect recent service output."],
 system:["System information","Host and runtime details."]
};
function toast(message){
 const el=$("toast");el.textContent=message;el.classList.add("show");
 setTimeout(()=>el.classList.remove("show"),2600);
}
function showPage(name){
 document.querySelectorAll(".page").forEach(p=>p.classList.remove("active"));
 $(name+"Page").classList.add("active");
 document.querySelectorAll(".nav button").forEach(b=>b.classList.toggle("active",b.dataset.page===name));
 $("pageTitle").textContent=pageNames[name][0];
 $("pageSubtitle").textContent=pageNames[name][1];
 if(name==="terminal")setTimeout(()=>fitAll(),100);
 if(name==="services")loadServices();
 if(name==="logs")loadLogs();
 if(name==="system")loadSystem();
}
document.querySelectorAll(".nav button").forEach(b=>b.addEventListener("click",()=>showPage(b.dataset.page)));

async function getJSON(url){
 const response=await fetch(url,{cache:"no-store"});
 if(!response.ok)throw new Error("HTTP "+response.status);
 return response.json();
}
function bytes(n){
 if(!n)return "0 B";
 const units=["B","KB","MB","GB","TB"];
 let i=0;while(n>=1024&&i<units.length-1){n/=1024;i++}
 return n.toFixed(i?1:0)+" "+units[i];
}
async function loadMetrics(){
 try{
  const d=await getJSON("/api/metrics");
  $("cpuValue").textContent=d.load;
  $("ramValue").textContent=d.memory_percent+"%";
  $("ramFoot").textContent=bytes(d.memory_used)+" / "+bytes(d.memory_total);
  $("diskValue").textContent=d.disk.total?Math.round(d.disk.used*100/d.disk.total)+"%":"N/A";
  $("diskFoot").textContent=bytes(d.disk.used)+" / "+bytes(d.disk.total);
  $("uptimeValue").textContent=d.uptime.replace("up ","");
  $("systemSummary").innerHTML=[
   ["Hostname",d.hostname],["Platform",d.platform],["Kernel",d.kernel],
   ["Memory available",bytes(d.memory_free)]
  ].map(([k,v])=>`<div class="info-line"><span>${k}</span><strong>${escapeHTML(v)}</strong></div>`).join("");
 }catch(e){$("systemSummary").textContent="Unable to load metrics"}
}
function escapeHTML(s){
 return String(s??"").replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
}
async function loadServices(){
 try{
  const d=await getJSON("/api/services");
  $("serviceList").innerHTML=d.map(s=>`<div class="service-row"><span class="service-name">${escapeHTML(s.name)}</span><span class="service-state ${s.state==="active"?"":"off"}">${escapeHTML(s.state)}</span></div>`).join("");
  $("servicesTable").innerHTML=d.map(s=>`<tr><td>${escapeHTML(s.name)}</td><td><span class="service-state ${s.state==="active"?"":"off"}">${escapeHTML(s.state)}</span></td></tr>`).join("");
 }catch(e){$("serviceList").textContent="Unable to load services"}
}
async function loadSystem(){
 try{
  const d=await getJSON("/api/metrics");
  $("systemDetails").innerHTML=Object.entries({
   Hostname:d.hostname,Platform:d.platform,Kernel:d.kernel,
   "CPU load":d.load,Uptime:d.uptime,
   "Total memory":bytes(d.memory_total),"Used memory":bytes(d.memory_used),
   "Free memory":bytes(d.memory_free),
   "Disk total":bytes(d.disk.total),"Disk used":bytes(d.disk.used)
  }).map(([k,v])=>`<div class="info-line"><span>${escapeHTML(k)}</span><strong>${escapeHTML(v)}</strong></div>`).join("");
 }catch(e){$("systemDetails").textContent="Unable to load system information"}
}
async function loadLogs(){
 try{
  const name=$("logSelect").value;
  const r=await fetch("/api/logs/"+encodeURIComponent(name));
  $("logOutput").textContent=await r.text();
  $("logOutput").scrollTop=$("logOutput").scrollHeight;
 }catch(e){$("logOutput").textContent="Unable to load log"}
}
async function refreshAll(){
 await Promise.all([loadMetrics(),loadServices()]);
 if($("systemPage").classList.contains("active"))loadSystem();
 if($("logsPage").classList.contains("active"))loadLogs();
}
setInterval(refreshAll,5000);
refreshAll();

const terminalInstances=[];
let activeTab=0;
let fontSize=14;
function makeTerminal(elementId){
 const term=new Terminal({
  cursorBlink:true,convertEol:false,scrollback:10000,
  fontSize,fontFamily:"'Cascadia Code','SFMono-Regular',Consolas,monospace",
  allowProposedApi:true,
  theme:{
   background:"#080d16",foreground:"#dce7f5",
   cursor:"#67e5ce",selectionBackground:"#38547d88",
   black:"#111827",red:"#ff657a",green:"#38d6a3",
   yellow:"#f4bd62",blue:"#7796ff",magenta:"#c29aff",
   cyan:"#54d9e8",white:"#dce7f5",
   brightBlack:"#6e7e96",brightRed:"#ff8796",
   brightGreen:"#62e8b5",brightYellow:"#ffd48a",
   brightBlue:"#9cb1ff",brightMagenta:"#d7baff",
   brightCyan:"#7debf4",brightWhite:"#ffffff"
  }
 });
 const fit=new FitAddon.FitAddon();
 const search=new SearchAddon.SearchAddon();
 term.loadAddon(fit);term.loadAddon(search);
 term.open($(elementId));
 const item={term,fit,search,ws:null,session:null,intentional:false,retry:null,elementId};
 term.onData(data=>{
  if(item.ws&&item.ws.readyState===WebSocket.OPEN){
   item.ws.send(JSON.stringify({type:"input",data}));
  }
 });
 term.onResize(size=>{
  if(item.ws&&item.ws.readyState===WebSocket.OPEN){
   item.ws.send(JSON.stringify({type:"resize",cols:size.cols,rows:size.rows}));
  }
 });
 terminalInstances.push(item);
 setTimeout(()=>{try{fit.fit()}catch(e){}},150);
 return item;
}
const quick=makeTerminal("quickTerminal");
const mainTerm=makeTerminal("mainTerminal");
function activeTerminal(){return terminalInstances[activeTab+2]||mainTerm}
function fitAll(){
 terminalInstances.forEach(t=>{try{t.fit.fit()}catch(e){}});
}
window.addEventListener("resize",()=>setTimeout(fitAll,100));

function socketURL(){return (location.protocol==="https:"?"wss://":"ws://")+location.host+"/terminal"}
function setStatus(item,message){
 if(item===quick)$("quickStatus").textContent=message;
 else $("mainStatus").textContent=message;
 $("terminalConnection").textContent="● "+message;
}
function attachSocket(item,mode,payload){
 if(item.ws)item.ws.close();
 item.intentional=false;
 const ws=new WebSocket(socketURL());
 item.ws=ws;
 ws.onopen=()=>ws.send(JSON.stringify({type:mode,...payload}));
 ws.onmessage=event=>{
  let data;
  try{data=JSON.parse(event.data)}catch(e){item.term.write(event.data);return}
  if(data.type==="ready"){
   item.session=data.session_id;
   try{localStorage.setItem("ivt-session-"+item.elementId,item.session)}catch(e){}
   setStatus(item,"Connected · "+(data.username||"Linux"));
   item.term.focus();
   if(data.resumed)item.term.writeln("\r\n[Session reconnected]\r\n");
   if(item.ws===ws&&item.ws.readyState===WebSocket.OPEN){
    item.ws.send(JSON.stringify({type:"resize",cols:item.term.cols,rows:item.term.rows}));
   }
  }else if(data.type==="output"){
   item.term.write(data.data);
  }else if(data.type==="error"){
   item.term.writeln("\r\n[ERROR] "+data.message+"\r\n");
   setStatus(item,"Authentication / connection error");
  }else if(data.type==="closed"){
   item.term.writeln("\r\n[SSH process ended]\r\n");
   item.session=null;
  }
 };
 ws.onclose=()=>{
  if(item.ws===ws)item.ws=null;
  if(item.intentional){setStatus(item,"Disconnected");return}
  if(item.session){
   setStatus(item,"Connection lost · reconnecting");
   clearTimeout(item.retry);
   item.retry=setTimeout(()=>resumeSession(item),2500);
  }else setStatus(item,"Disconnected");
 };
 ws.onerror=()=>setStatus(item,"Connection error");
}
function resumeSession(item){
 if(!item.session){
  try{item.session=localStorage.getItem("ivt-session-"+item.elementId)}catch(e){}
 }
 if(item.session){
  attachSocket(item,"resume",{session_id:item.session});
 }
}
function connectItem(item,user,password){
 if(!user||!password){toast("Enter your Linux username and password");return}
 item.term.writeln("\r\n[Connecting to IVT Linux...]\r\n");
 attachSocket(item,"login",{username:user,password});
}
function connectQuick(){
 connectItem(quick,$("quickUser").value,$("quickPass").value);
}
function connectMain(){
 connectItem(mainTerm,$("termUser").value,$("termPass").value);
}
function disconnectItem(item){
 item.intentional=true;clearTimeout(item.retry);
 if(item.ws)item.ws.close();
 item.ws=null;item.session=null;
 try{localStorage.removeItem("ivt-session-"+item.elementId)}catch(e){}
 setStatus(item,"Disconnected");
}
function disconnectMain(){disconnectItem(mainTerm)}
function addTerminal(){
 if(terminalInstances.length>=8){toast("Maximum of eight terminal tabs");return}
 const index=terminalInstances.length-2;
 const id="extraTerminal"+index;
 const tab=document.createElement("button");
 tab.className="tab";tab.textContent="Terminal "+(index+2);
 tab.dataset.tab=String(index+1);
 tab.onclick=()=>selectTerminal(index+1);
 $("terminalTabs").insertBefore(tab,$("terminalTabs").lastElementChild);
 const div=document.createElement("div");
 div.id=id;div.className="terminal-instance";div.style.display="none";
 $("mainTerminal").parentElement.appendChild(div);
 const item=makeTerminal(id);
 item.term.writeln("IVT terminal ready. Connect using your Linux credentials.");
 selectTerminal(index+1);
}
function selectTerminal(index){
 activeTab=index;
 document.querySelectorAll("#terminalTabs .tab").forEach((b,i)=>b.classList.toggle("active",i===index));
 terminalInstances.slice(2).forEach((t,i)=>$(t.elementId).style.display=i===index?"block":"none");
 setTimeout(fitAll,100);
}
function clearTerminal(){activeTerminal().term.clear()}
async function copyTerminal(){
 const item=activeTerminal();
 const selection=item.term.getSelection();
 if(!selection){toast("Select terminal text first");return}
 try{await navigator.clipboard.writeText(selection);toast("Copied")}
 catch(e){toast("Clipboard permission unavailable")}
}
async function pasteTerminal(){
 const item=activeTerminal();
 try{
  const value=await navigator.clipboard.readText();
  if(item.ws&&item.ws.readyState===WebSocket.OPEN){
   item.ws.send(JSON.stringify({type:"input",data:value}));
  }else toast("Connect the terminal first");
 }catch(e){toast("Allow clipboard access in your browser")}
}
function toggleSearch(){
 $("searchBar").classList.toggle("open");
 if($("searchBar").classList.contains("open"))$("terminalSearch").focus();
}
function searchNext(){
 const item=activeTerminal();
 const q=$("terminalSearch").value;
 if(q&&!item.search.findNext(q))toast("No further match");
}
function searchPrevious(){
 const item=activeTerminal();
 const q=$("terminalSearch").value;
 if(q&&!item.search.findPrevious(q))toast("No previous match");
}
function changeFont(delta){
 fontSize=Math.max(9,Math.min(24,fontSize+delta));
 terminalInstances.forEach(t=>{t.term.options.fontSize=fontSize;try{t.fit.fit()}catch(e){}});
}
function downloadTerminal(){
 const text=activeTerminal().term.buffer.active;
 let content="";
 for(let i=0;i<text.length;i++){
  const line=text.getLine(i);
  if(line)content+=line.translateToString(true)+"\n";
 }
 const blob=new Blob([content],{type:"text/plain"});
 const url=URL.createObjectURL(blob);
 const a=document.createElement("a");a.href=url;a.download="ivt-terminal.log";a.click();
 URL.revokeObjectURL(url);
}
function downloadLogs(){
 const content=$("logOutput").textContent;
 const blob=new Blob([content],{type:"text/plain"});
 const url=URL.createObjectURL(blob);
 const a=document.createElement("a");a.href=url;a.download="ivt-system.log";a.click();
 URL.revokeObjectURL(url);
}
function toggleFullscreen(){
 document.body.classList.toggle("fullscreen-terminal");
 setTimeout(fitAll,150);
}
document.addEventListener("keydown",e=>{
 if(e.key==="Escape"&&document.body.classList.contains("fullscreen-terminal")){
  document.body.classList.remove("fullscreen-terminal");setTimeout(fitAll,100);
 }
});
async function connectOnRefresh(){
 try{
  const saved=localStorage.getItem("ivt-session-mainTerminal");
  if(saved){mainTerm.session=saved;resumeSession(mainTerm)}
 }catch(e){}
}
connectOnRefresh();
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

async def logs(request):
    name = request.match_info.get("name", "system")
    try:
        return web.Response(text=log_tail(name), content_type="text/plain")
    except ValueError:
        raise web.HTTPNotFound()

async def create_session(username, password):
    conn = await asyncssh.connect(
        "127.0.0.1",
        port=22,
        username=username,
        password=password,
        known_hosts=None,
        login_timeout=15
    )
    process = await conn.create_process(
        term_type="xterm-256color",
        term_size=(120, 35),
        encoding="utf-8"
    )
    token = secrets.token_urlsafe(32)
    session = TerminalSession(token, conn, process, username)
    SESSIONS[token] = session
    session.reader_task = asyncio.create_task(session.read_output())
    return session

async def terminal(request):
    ws = web.WebSocketResponse(
        heartbeat=25,
        max_msg_size=2 * 1024 * 1024,
        compress=False
    )
    await ws.prepare(request)

    session = None

    try:
        first = await asyncio.wait_for(ws.receive(), timeout=30)
        if first.type != web.WSMsgType.TEXT:
            await ws.send_json({"type": "error", "message": "Login or session resume required"})
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
                await ws.send_json({"type": "error", "message": "Username and password are required"})
                await ws.close()
                return ws

            if len(username) > 128 or len(password) > 1024:
                await ws.send_json({"type": "error", "message": "Credentials are too long"})
                await ws.close()
                return ws

            session = await create_session(username, password)

        elif mode == "resume":
            token = str(data.get("session_id", ""))
            session = SESSIONS.get(token)
            if not session or session.closed:
                await ws.send_json({"type": "error", "message": "Session no longer exists. Please log in again."})
                await ws.close()
                return ws

        else:
            await ws.send_json({"type": "error", "message": "Unsupported terminal request"})
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

        if mode == "resume":
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
        # IMPORTANT:
        # A WebSocket disconnect does NOT close the SSH process.
        # The session remains in SESSIONS for browser reconnection.
        if session is not None and session.ws is ws:
            session.ws = None
        if not ws.closed:
            await ws.close()

    return ws

async def cleanup_sessions(app):
    # Sessions are intentionally not expired just because they are idle.
    # They end when the SSH process exits or the container shuts down.
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
app.router.add_get("/api/logs/{name}", logs)
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
