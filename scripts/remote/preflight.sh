# Read-only checks. Nothing on the server is changed except reading the staged archive.
: "${ARCHIVE_PATH:?}" "${EXPECTED_SHA512:?}" "${TARGET_VERSION:?}"
MIN_FREE_MB="${MIN_FREE_MB:-3072}"

log "Whoami: $(whoami)  Host: $(hostname -f 2>/dev/null || hostname)"
[ "$(whoami)" = "${RUN_AS_USER:-mradmin}" ] || fail "Not running as mradmin"

for t in tar sha512sum curl pgrep readlink df awk sed grep ln mv sort; do
  command -v "$t" >/dev/null 2>&1 || fail "Required tool missing: $t"
done

[ -d "$BASE_DIR" ] && [ -w "$BASE_DIR" ] || fail "$BASE_DIR missing or not writable"
if [ ! -L "$LINK" ]; then
  if [ -d "$LINK" ]; then
    fail "$LINK is a real directory. One-time migration to the symlink layout is required (see the setup guide, Step 6.2 'Symlink layout')."
  fi
  fail "$LINK does not exist"
fi

CUR_DIR="$(readlink -f "$LINK")"
[ -d "$CUR_DIR" ] || fail "$LINK points to a missing directory: $CUR_DIR"
CUR_VER="$(basename "$CUR_DIR" | sed 's/^apache-tomcat-//')"
echo "$CUR_VER" | grep -Eq '^10\.1\.[0-9]+$' || fail "Cannot derive a 10.1.x version from $CUR_DIR (directory must be named apache-tomcat-<version>)"
log "Current Tomcat: $CUR_VER ($CUR_DIR)"

if [ -n "${SOURCE_VERSION:-}" ] && [ "$SOURCE_VERSION" != "$CUR_VER" ]; then
  fail "source_version=$SOURCE_VERSION but the server runs $CUR_VER"
fi
[ "$CUR_VER" != "$TARGET_VERSION" ] || fail "Server already runs $TARGET_VERSION"
HIGHEST="$(printf '%s\n%s\n' "$CUR_VER" "$TARGET_VERSION" | sort -V | tail -1)"
[ "$HIGHEST" = "$TARGET_VERSION" ] || fail "Target $TARGET_VERSION is older than current $CUR_VER (downgrades are not allowed here)"

NEW_DIR="${BASE_DIR}/apache-tomcat-${TARGET_VERSION}"
if [ -e "$NEW_DIR" ] && [ ! -f "$NEW_DIR/.bpom-prepared" ]; then
  fail "$NEW_DIR already exists and was not created by this tool - refusing to overwrite"
fi

FREE_MB="$(df -Pm "$BASE_DIR" | awk 'NR==2{print $4}')"
log "Free space on $BASE_DIR: ${FREE_MB} MB (need ${MIN_FREE_MB})"
[ "$FREE_MB" -ge "$MIN_FREE_MB" ] || fail "Not enough free disk space"

JAVA_HOME_SET="$( (set +eu; . "$CUR_DIR/bin/setenv.sh" >/dev/null 2>&1; echo "${JAVA_HOME:-}") )"
if [ -n "$JAVA_HOME_SET" ]; then JAVA_BIN="$JAVA_HOME_SET/bin/java"; else JAVA_BIN="$(command -v java || true)"; fi
[ -x "$JAVA_BIN" ] || fail "No usable java (JAVA_HOME from setenv.sh: '${JAVA_HOME_SET}')"
JV="$("$JAVA_BIN" -version 2>&1 | awk -F'"' '/version/{print $2; exit}')"
JMAJOR="${JV%%.*}"; [ "$JMAJOR" = "1" ] && JMAJOR=8
log "Java: $JV ($JAVA_BIN)"
[ "$JMAJOR" -ge 17 ] || fail "Java $JV is too old (Java 17+ required)"

[ -f "$ARCHIVE_PATH" ] || fail "Staged archive not found: $ARCHIVE_PATH"
ACTUAL="$(sha512sum "$ARCHIVE_PATH" | awk '{print $1}')"
[ "$ACTUAL" = "$EXPECTED_SHA512" ] || fail "Archive SHA-512 on the server does not match the verified archive"
tar -tzf "$ARCHIVE_PATH" | head -1 | grep -q "^apache-tomcat-${TARGET_VERSION}/" || fail "Archive does not contain apache-tomcat-${TARGET_VERSION}/"
log "Archive staged and checksum verified."

N="$(count_pids)"
if [ "$N" = "0" ]; then
  warn "Tomcat is not currently running (no running baseline to compare against)."
elif [ "$N" = "1" ]; then
  P="$(tomcat_pids)"; H="$(pid_home "$P")"
  log "Running Tomcat PID $P catalina.home=$H"
  [ "$(readlink -f "$H")" = "$CUR_DIR" ] || fail "Running Tomcat (catalina.home=$H) is not the one behind $LINK ($CUR_DIR)"
else
  fail "More than one Tomcat process is running ($N). This tool supports exactly one instance per host."
fi

log "Deployed WARs:"; ls -1 "$CUR_DIR"/webapps/*.war 2>/dev/null | sed 's/^/   /' || log "   (none)"
log "PREFLIGHT PASSED: ${CUR_VER} -> ${TARGET_VERSION}"
