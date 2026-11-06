# Full, verified backup of the CURRENT installation and a fresh upgrade state file.
: "${TARGET_VERSION:?}"
CUR_DIR="$(readlink -f "$LINK")"
CUR_VER="$(basename "$CUR_DIR" | sed 's/^apache-tomcat-//')"
TS="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="${BASE_DIR}/upgrade_backups/${TS}_${CUR_VER}_to_${TARGET_VERSION}"
ARCHIVE="${BACKUP_DIR}/tomcat_${CUR_VER}_full.tar.gz"

mkdir -p "$BACKUP_DIR"
log "Backing up $CUR_DIR -> $ARCHIVE (logs/temp/work excluded)"
tar -czf "$ARCHIVE" -C "$BASE_DIR" \
  --exclude="apache-tomcat-${CUR_VER}/logs/*" \
  --exclude="apache-tomcat-${CUR_VER}/temp/*" \
  --exclude="apache-tomcat-${CUR_VER}/work/*" \
  "apache-tomcat-${CUR_VER}"

LIST="$(tar -tzf "$ARCHIVE")" || fail "Backup archive cannot be read back"
for f in conf/server.xml conf/context.xml; do
  echo "$LIST" | grep -q "apache-tomcat-${CUR_VER}/${f}\$" || fail "Backup is missing $f"
done
echo "$LIST" | grep -q "apache-tomcat-${CUR_VER}/bin/setenv.sh\$" || warn "No bin/setenv.sh in the backup (none existed?)"
sha512sum "$ARCHIVE" > "${ARCHIVE}.sha512"
log "Backup verified: $(du -h "$ARCHIVE" | awk '{print $1}')"

mkdir -p "$STATE_DIR"
[ -f "$STATE_FILE" ] && cp -p "$STATE_FILE" "${STATE_FILE}.prev" || true
cat > "$STATE_FILE" <<EOF
SOURCE_VERSION=${CUR_VER}
SOURCE_DIR=${CUR_DIR}
TARGET_VERSION=${TARGET_VERSION}
TARGET_DIR=${BASE_DIR}/apache-tomcat-${TARGET_VERSION}
BACKUP_DIR=${BACKUP_DIR}
CHANGE_TICKET=${CHANGE_TICKET:-}
STARTED_AT=${TS}
STATUS=backed_up
EOF
log "State written: $STATE_FILE"
