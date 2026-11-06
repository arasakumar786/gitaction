# Prepended to every remote script. Runs on the server as mradmin.
set -euo pipefail
BASE_DIR="${BASE_DIR:-/app/platform/tomcat}"
LINK_NAME="${LINK_NAME:-tomcat}"
LINK="${BASE_DIR}/${LINK_NAME}"
STATE_DIR="${BASE_DIR}/upgrade_state"
STATE_FILE="${STATE_DIR}/last_upgrade.env"

log()  { printf '[%s] %s\n' "$(hostname -s)" "$*"; }
warn() { printf '::warning::[%s] %s\n' "$(hostname -s)" "$*"; }
fail() { printf '::error::[%s] %s\n' "$(hostname -s)" "$*"; exit 1; }

tomcat_pids() { pgrep -u "$(id -u)" -f 'org.apache.catalina.startup.Bootstrap' || true; }
count_pids()  { local n; n=$(tomcat_pids | grep -c . || true); echo "${n:-0}"; }
pid_home()    { tr '\0' '\n' < "/proc/$1/cmdline" | sed -n 's/^-Dcatalina.home=//p' | head -1; }

set_state() {  # KEY VALUE
  mkdir -p "$STATE_DIR"; touch "$STATE_FILE"
  if grep -q "^$1=" "$STATE_FILE"; then sed -i "s|^$1=.*|$1=$2|" "$STATE_FILE"
  else echo "$1=$2" >> "$STATE_FILE"; fi
}
load_state() {
  [ -f "$STATE_FILE" ] || fail "No upgrade state at $STATE_FILE (nothing recorded to work from)"
  set -a; . "$STATE_FILE"; set +a
}

wait_for_process() {  # seconds
  local t="$1" w=0
  while [ -z "$(tomcat_pids)" ] && [ "$w" -lt "$t" ]; do sleep 2; w=$((w+2)); done
  [ -n "$(tomcat_pids)" ] || fail "Tomcat process did not appear within ${t}s"
}

stop_tomcat() {  # $1 = CATALINA_HOME whose shutdown.sh is used
  local home="$1" waited=0
  if [ -z "$(tomcat_pids)" ]; then log "Tomcat is not running."; return 0; fi
  log "Graceful shutdown via ${home}/bin/shutdown.sh"
  "${home}/bin/shutdown.sh" >/dev/null 2>&1 || warn "shutdown.sh returned non-zero"
  while [ -n "$(tomcat_pids)" ] && [ "$waited" -lt "${STOP_TIMEOUT:-90}" ]; do sleep 3; waited=$((waited+3)); done
  if [ -n "$(tomcat_pids)" ]; then
    warn "Still running after ${waited}s - sending SIGTERM"
    kill $(tomcat_pids) 2>/dev/null || true; sleep 15
  fi
  if [ -n "$(tomcat_pids)" ]; then
    if [ "${ALLOW_FORCE_KILL:-false}" = "true" ]; then
      warn "Still running - sending SIGKILL (allow_force_kill=true)"
      kill -9 $(tomcat_pids) 2>/dev/null || true; sleep 5
    else
      fail "Tomcat will not stop. Investigate, or re-run with allow_force_kill=true."
    fi
  fi
  [ -z "$(tomcat_pids)" ] || fail "Tomcat is still running after all stop attempts"
  log "Tomcat stopped."
}

start_tomcat() {  # $1 = CATALINA_HOME
  log "Starting Tomcat from $1"
  "$1/bin/startup.sh" >/dev/null 2>&1 || fail "startup.sh failed"
  wait_for_process 60
}

point_link_to() {  # $1 = target directory (atomic swap)
  ln -sfn "$1" "${LINK}.new"
  mv -Tf "${LINK}.new" "${LINK}"
  log "${LINK} -> $(readlink "${LINK}")"
}
