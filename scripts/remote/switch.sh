# Stop the old Tomcat, atomically repoint the symlink to the new version, start it.
load_state
[ -f "$TARGET_DIR/.bpom-prepared" ] || fail "$TARGET_DIR was not prepared"
[ "$(readlink -f "$LINK")" = "$SOURCE_DIR" ] || fail "$LINK no longer points at $SOURCE_DIR"

set_state STATUS switching
stop_tomcat "$SOURCE_DIR"
point_link_to "$TARGET_DIR"
start_tomcat "$LINK"

P="$(tomcat_pids | head -1)"; H="$(pid_home "$P")"
[ "$(readlink -f "$H")" = "$(readlink -f "$TARGET_DIR")" ] || fail "Tomcat started from $H instead of $TARGET_DIR"
set_state STATUS switched
log "SWITCHED to ${TARGET_VERSION}: PID $P catalina.home=$H"
