# Restore the previous Tomcat recorded in the state file. Idempotent.
load_state
[ -d "$SOURCE_DIR" ] || fail "Previous installation $SOURCE_DIR is gone - restore from $BACKUP_DIR manually"
CURRENT="$(readlink -f "$LINK")"
log "Rolling back: current=$CURRENT previous=$SOURCE_DIR"

# keep evidence of the failed version before anything else changes
if [ -d "$TARGET_DIR/logs" ]; then
  KEEP="${STATE_DIR}/failed_${TARGET_VERSION}_logs_$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$KEEP"; cp -a "$TARGET_DIR/logs/." "$KEEP/" 2>/dev/null || true
  log "Failed-version logs saved to $KEEP"
fi

if [ "$CURRENT" = "$SOURCE_DIR" ] && [ -n "$(tomcat_pids)" ]; then
  log "Already running the previous version - nothing to switch."
else
  stop_tomcat "$CURRENT"
  point_link_to "$SOURCE_DIR"
  start_tomcat "$LINK"
fi
set_state STATUS rolled_back
log "ROLLED BACK to ${SOURCE_VERSION}"
