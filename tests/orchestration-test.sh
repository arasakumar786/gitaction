#!/usr/bin/env bash
# Tests the host loop / stop-on-failure / auto-rollback logic of scripts/run-rollout.sh
# with the SSH layer replaced by a stub. Needs only bash and coreutils. Run: bash tests/orchestration-test.sh
set -u
SRC="$(cd "$(dirname "$0")/.." && pwd)"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
cp -r "$SRC/scripts" "$SRC/config" "$W/"
mkdir "$W/dist"; printf 'dummy' > "$W/dist/apache-tomcat-10.1.57.tar.gz"

cat > "$W/scripts/lib/ssh.sh" <<'STUB'
BPOMVAULT_SSH_USER=stub
remote_plain() { return 0; }
remote_copy()  { return 0; }
remote_run() {
  local host="$1" step; step="$(basename "$2" .sh)"; local mode=""
  for kv in "$@"; do [[ "$kv" == EXPECT=* ]] && mode="${kv#EXPECT=}"; done
  echo "RUN $step${mode:+($mode)} on $host" >> "$CALLS"
  [[ "${FAIL_AT:-}" == "$step${mode:+:$mode}:$host" || "${FAIL_AT:-}" == "$step:$host" ]] && return 1
  return 0
}
STUB

export ROLE=app ENVIRONMENT=dev TARGET_VERSION=10.1.57 AUTO_ROLLBACK=true CALLS="$W/calls.log"
printf 'h1\nh2\nh3\n' > "$W/hosts.txt"; export HOSTS_FILE="$W/hosts.txt"
pass=0; fail=0

run() { # name mode fail_at expected_rc expected_sequence
  local name="$1" mode="$2" failat="$3" want_rc="$4" want_seq="$5" rc got
  : > "$CALLS"
  ( cd "$W" && FAIL_AT="$failat" MODE="$mode" bash scripts/run-rollout.sh >/dev/null 2>&1 ); rc=$?
  got="$(grep '^RUN' "$CALLS" | sed 's/^RUN //')"
  if [[ "$rc" == "$want_rc" && "$got" == "$want_seq" ]]; then echo "PASS  $name"; pass=$((pass+1))
  else echo "FAIL  $name (rc=$rc, want $want_rc)"; echo "--- got:"; echo "$got"; echo "--- want:"; echo "$want_seq"; fail=$((fail+1)); fi
}
seq() { printf '%s\n' "$@"; }
up() { seq "preflight on $1" "backup on $1" "prepare on $1" "switch on $1" "health(target) on $1"; }

run "dry_run, all hosts ok"                         dry_run  ""                 0 "$(seq 'preflight on h1' 'preflight on h2' 'preflight on h3')"
run "dry_run: preflight fails on h2, h3 untouched"  dry_run  "preflight:h2"      1 "$(seq 'preflight on h1' 'preflight on h2')"
run "upgrade: happy path on three hosts"           upgrade  ""                 0 "$(up h1; up h2; up h3)"
run "upgrade: preflight fails, nothing else runs"   upgrade  "preflight:h1"      1 "preflight on h1"
run "upgrade: backup fails, no prepare or switch"   upgrade  "backup:h1"         1 "$(seq 'preflight on h1' 'backup on h1')"
run "upgrade: prepare fails, no switch"             upgrade  "prepare:h1"        1 "$(seq 'preflight on h1' 'backup on h1' 'prepare on h1')"
run "upgrade: switch fails, auto rollback"          upgrade  "switch:h1"         1 "$(seq 'preflight on h1' 'backup on h1' 'prepare on h1' 'switch on h1' 'rollback on h1' 'health(source) on h1')"
run "upgrade: health fails, auto rollback, h2 safe" upgrade  "health:target:h1"   1 "$(up h1; seq 'rollback on h1' 'health(source) on h1')"
run "rollback mode on all hosts"                    rollback ""                 0 "$(seq 'rollback on h1' 'health(source) on h1' 'rollback on h2' 'health(source) on h2' 'rollback on h3' 'health(source) on h3')"
AUTO_ROLLBACK=false run "upgrade: health fails, auto_rollback=false, no rollback" upgrade "health:target:h1" 1 "$(up h1)"

echo "passed=$pass failed=$fail"; exit "$fail"
