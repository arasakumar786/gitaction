# Verifies the running Tomcat. EXPECT=target|source selects which version must be running.
: "${EXPECT:?}" "${HEALTH_BASE_URL:?}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-420}"
load_state
if [ "$EXPECT" = "target" ]; then WANT_DIR="$TARGET_DIR"; else WANT_DIR="$SOURCE_DIR"; fi

# 1. exactly one process, running from the expected directory
[ "$(count_pids)" = "1" ] || fail "Expected exactly one Tomcat process, found $(count_pids)"
P="$(tomcat_pids)"; H="$(pid_home "$P")"
[ "$(readlink -f "$H")" = "$(readlink -f "$WANT_DIR")" ] || fail "Running catalina.home=$H, expected $WANT_DIR"
log "Process OK: PID $P catalina.home=$H"

END=$((SECONDS + HEALTH_TIMEOUT))

# 2. every WAR gets exploded by Tomcat
for war in "$LINK"/webapps/*.war; do
  [ -e "$war" ] || continue
  name="$(basename "$war" .war)"
  while [ ! -d "$LINK/webapps/$name" ] && [ "$SECONDS" -lt "$END" ]; do sleep 5; done
  [ -d "$LINK/webapps/$name" ] || fail "$name.war was not deployed within ${HEALTH_TIMEOUT}s"
done
log "All WARs deployed."

# 3. HTTP checks: one line per endpoint  "<path> <allowed,codes>"
check_endpoint() {
  local code
  code="$(curl -k -s -o /dev/null -w '%{http_code}' --max-time 15 "${HEALTH_BASE_URL}$1" || true)"
  LAST_CODE="${code:-000}"
  case ",$2," in *",${LAST_CODE},"*) return 0 ;; esac
  return 1
}
while read -r path codes; do
  [ -n "${path:-}" ] || continue
  until check_endpoint "$path" "$codes"; do
    [ "$SECONDS" -lt "$END" ] || fail "Health check failed: ${HEALTH_BASE_URL}${path} returned ${LAST_CODE}, expected one of ${codes}"
    sleep 10
  done
  log "HTTP OK: ${path} -> ${LAST_CODE}"
done <<< "${HEALTH_ENDPOINTS:-}"

# 4. startup log scan
LOGF="$LINK/logs/catalina.out"
if [ -f "$LOGF" ]; then
  # catalina.out is appended across restarts (important after a rollback), so only look at
  # the part written since the most recent Tomcat start ("Server version name:" line).
  RECENT="$(mktemp)"
  tac "$LOGF" | sed '/Server version name:/q' | tac > "$RECENT" || true
  FATAL='OutOfMemoryError|Error deploying web application|startup failed due to previous errors'
  if grep -Eq "$FATAL" "$RECENT"; then
    grep -E "$FATAL" "$RECENT" | head -10
    rm -f "$RECENT"; fail "Fatal startup messages found in $LOGF (since the last start)"
  fi
  S="$(grep -c 'SEVERE' "$RECENT" || true)"
  [ "${S:-0}" = "0" ] || { warn "$S SEVERE line(s) since the last start - review (first 5 below)"; grep 'SEVERE' "$RECENT" | head -5; }
  rm -f "$RECENT"
else
  warn "$LOGF not found"
fi
log "HEALTH PASSED (${EXPECT})"
