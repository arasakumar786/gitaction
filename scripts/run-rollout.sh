#!/usr/bin/env bash
# Orchestrates dry_run / upgrade / rollback host by host. Stops at the first failed host.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=lib/ssh.sh
source scripts/lib/ssh.sh

: "${MODE:?}" "${ROLE:?}" "${ENVIRONMENT:?}" "${HOSTS_FILE:?}"
BASE_DIR="${BASE_DIR:-/app/platform/tomcat}"
LINK_NAME="${LINK_NAME:-tomcat}"
AUTO_ROLLBACK="${AUTO_ROLLBACK:-true}"
ALLOW_FORCE_KILL="${ALLOW_FORCE_KILL:-false}"
HEALTH_BASE_URL="${HEALTH_BASE_URL:-http://localhost:8080}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-420}"
TARGET_VERSION="${TARGET_VERSION:-}"
SOURCE_VERSION="${SOURCE_VERSION:-}"
STAGE_DIR="/tmp/bpom-tomcat-upgrade-${GITHUB_RUN_ID:-local}"
REMOTE="scripts/remote"

summary() { echo "$*" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"; }

HEALTH_ENDPOINTS=""
if [[ -f "config/health/${ROLE}.txt" ]]; then
  HEALTH_ENDPOINTS="$(grep -Ev '^[[:space:]]*(#|$)' "config/health/${ROLE}.txt" || true)"
fi
PRESERVE_PATHS="$(grep -Ev '^[[:space:]]*(#|$)' config/preserve-paths.txt 2>/dev/null || true)"
if [[ "$MODE" != "dry_run" && -z "$HEALTH_ENDPOINTS" ]]; then
  echo "::error::config/health/${ROLE}.txt has no endpoints. Refusing to ${MODE} without a health check."
  exit 1
fi

ARCHIVE_FILE=""; ARCHIVE_SHA=""; REMOTE_ARCHIVE=""
if [[ "$MODE" != "rollback" ]]; then
  ARCHIVE_FILE="dist/apache-tomcat-${TARGET_VERSION}.tar.gz"
  [[ -f "$ARCHIVE_FILE" ]] || { echo "::error::$ARCHIVE_FILE not found"; exit 1; }
  ARCHIVE_SHA="$(sha512sum "$ARCHIVE_FILE" | awk '{print $1}')"
  REMOTE_ARCHIVE="${STAGE_DIR}/$(basename "$ARCHIVE_FILE")"
fi

COMMON_VARS=(
  "BASE_DIR=${BASE_DIR}" "LINK_NAME=${LINK_NAME}"
  "TARGET_VERSION=${TARGET_VERSION}" "SOURCE_VERSION=${SOURCE_VERSION}"
  "ALLOW_FORCE_KILL=${ALLOW_FORCE_KILL}"
)

# NOTE: process_host runs inside "if process_host ...", where bash IGNORES set -e.
# Every step below therefore ends with an explicit "|| return 1".
stage_archive() {
  local h="$1"
  remote_plain "$h" "rm -rf '${STAGE_DIR}' && mkdir -m 755 '${STAGE_DIR}'" || return 1
  remote_copy "$h" "$ARCHIVE_FILE" "${STAGE_DIR}/" || return 1
  remote_plain "$h" "chmod 644 '${STAGE_DIR}'/*" || return 1
}
cleanup_stage() { remote_plain "$1" "rm -rf '${STAGE_DIR}'" >/dev/null 2>&1 || true; }

run_health() {  # host expect(target|source)
  remote_run "$1" "${REMOTE}/health.sh" "${COMMON_VARS[@]}" \
    "EXPECT=$2" "HEALTH_BASE_URL=${HEALTH_BASE_URL}" "HEALTH_TIMEOUT=${HEALTH_TIMEOUT}" \
    "HEALTH_ENDPOINTS=${HEALTH_ENDPOINTS}"
}

do_rollback() {  # host
  remote_run "$1" "${REMOTE}/rollback.sh" "${COMMON_VARS[@]}" && run_health "$1" source
}

process_host() {
  local h="$1"
  case "$MODE" in
    dry_run)
      stage_archive "$h" || return 1
      remote_run "$h" "${REMOTE}/preflight.sh" "${COMMON_VARS[@]}" \
        "ARCHIVE_PATH=${REMOTE_ARCHIVE}" "EXPECTED_SHA512=${ARCHIVE_SHA}" || return 1
      ;;
    upgrade)
      stage_archive "$h" || return 1
      remote_run "$h" "${REMOTE}/preflight.sh" "${COMMON_VARS[@]}" \
        "ARCHIVE_PATH=${REMOTE_ARCHIVE}" "EXPECTED_SHA512=${ARCHIVE_SHA}" || return 1
      remote_run "$h" "${REMOTE}/backup.sh"  "${COMMON_VARS[@]}" "CHANGE_TICKET=${CHANGE_TICKET:-}" || return 1
      remote_run "$h" "${REMOTE}/prepare.sh" "${COMMON_VARS[@]}" \
        "ARCHIVE_PATH=${REMOTE_ARCHIVE}" "PRESERVE_PATHS=${PRESERVE_PATHS}" || return 1
      # From here the live service is affected. Roll back if requested.
      if remote_run "$h" "${REMOTE}/switch.sh" "${COMMON_VARS[@]}" && run_health "$h" target; then
        :
      else
        echo "::error::Switch or health check failed on $h"
        if [[ "$AUTO_ROLLBACK" == "true" ]]; then
          echo "::warning::Rolling $h back to the previous Tomcat"
          do_rollback "$h" || echo "::error::AUTOMATIC ROLLBACK FAILED on $h - manual intervention required"
        fi
        return 1
      fi
      ;;
    rollback)
      do_rollback "$h"
      ;;
    *) echo "::error::Unknown mode $MODE"; return 1 ;;
  esac
}

summary "## Tomcat ${MODE} - ${ENVIRONMENT} / ${ROLE}"
summary "Target: \`${TARGET_VERSION:-n/a}\` | Change: \`${CHANGE_TICKET:-n/a}\` | Actor: \`${GITHUB_ACTOR:-local}\`"
summary ""
summary "| Host | Result |"
summary "|---|---|"

FAILED=0
while read -r host; do
  [[ -n "$host" ]] || continue
  echo "::group::${MODE} on ${host}"
  if process_host "$host"; then
    echo "::endgroup::"; echo "OK: $host"; summary "| ${host} | OK |"
    [[ "$MODE" == "rollback" ]] || cleanup_stage "$host"
  else
    echo "::endgroup::"; echo "::error::FAILED: $host - stopping, remaining hosts were not touched"
    summary "| ${host} | FAILED |"; FAILED=1
    break
  fi
done < "$HOSTS_FILE"

exit "$FAILED"
