# Builds the new Tomcat next to the old one. The live service is NOT touched.
: "${ARCHIVE_PATH:?}"
load_state
OLD="$SOURCE_DIR"; NEW="$TARGET_DIR"

if [ -e "$NEW" ]; then
  [ -f "$NEW/.bpom-prepared" ] || fail "$NEW exists and was not created by this tool"
  log "Removing previous unfinished prepare at $NEW"
  rm -rf "$NEW"
fi
tar -xzf "$ARCHIVE_PATH" -C "$BASE_DIR"
[ -d "$NEW" ] || fail "Extraction did not create $NEW"
log "Extracted $(basename "$NEW")"

# ── 1. Configuration: keep site-specific files, keep NEW defaults for the rest ─────────
for f in server.xml context.xml tomcat-users.xml; do
  if [ -f "$OLD/conf/$f" ]; then cp -p "$OLD/conf/$f" "$NEW/conf/$f"; log "conf/$f carried over"; fi
done
if [ -d "$OLD/conf/Catalina" ]; then mkdir -p "$NEW/conf/Catalina"; cp -a "$OLD/conf/Catalina/." "$NEW/conf/Catalina/"; log "conf/Catalina carried over"; fi
# anything else in old conf that the new distribution does not ship (keystores, extra files); never overwrites
BEFORE="$(ls -1 "$NEW/conf" | sort)"; cp -an "$OLD/conf/." "$NEW/conf/" 2>/dev/null || true
AFTER="$(ls -1 "$NEW/conf" | sort)"
EXTRA="$(comm -13 <(echo "$BEFORE") <(echo "$AFTER") || true)"; [ -z "$EXTRA" ] || { log "Extra conf files carried over:"; echo "$EXTRA" | sed 's/^/   /'; }

# Report differences in files where the NEW default was kept, so a human can review them
REPORT="${BACKUP_DIR}/config-differences.txt"; : > "$REPORT"
for f in web.xml catalina.properties logging.properties catalina.policy; do
  [ -f "$OLD/conf/$f" ] && diff -u "$OLD/conf/$f" "$NEW/conf/$f" >> "$REPORT" 2>&1 || true
done
log "Differences between old and new default config saved to $REPORT ($(wc -l < "$REPORT") lines)"

# ── 2. Libraries and scripts present in the old install but not in the new distribution ─
BEFORE="$(ls -1 "$NEW/lib" | sort)"; cp -an "$OLD/lib/." "$NEW/lib/" 2>/dev/null || true
AFTER="$(ls -1 "$NEW/lib" | sort)"
COPIED_LIBS="$(comm -13 <(echo "$BEFORE") <(echo "$AFTER") || true)"
log "Libraries carried over into lib/:"; if [ -n "$COPIED_LIBS" ]; then echo "$COPIED_LIBS" | sed 's/^/   /'; else echo "   (none)"; fi
[ -f "$OLD/bin/setenv.sh" ] && { cp -p "$OLD/bin/setenv.sh" "$NEW/bin/setenv.sh"; log "bin/setenv.sh carried over"; } || warn "Old install had no bin/setenv.sh"
cp -an "$OLD/bin/." "$NEW/bin/" 2>/dev/null || true
chmod 750 "$NEW"/bin/*.sh

# ── 3. Webapps: WARs only (exploded copies regenerate); drop default samples the old install had removed ─
cp -p "$OLD"/webapps/*.war "$NEW/webapps/" 2>/dev/null || warn "No WAR files found in $OLD/webapps"
for d in docs examples host-manager manager ROOT; do
  if [ ! -e "$OLD/webapps/$d" ] && [ ! -e "$OLD/webapps/$d.war" ]; then rm -rf "$NEW/webapps/$d"; fi
done
log "WARs in new webapps:"; ls -1 "$NEW"/webapps/*.war 2>/dev/null | sed 's/^/   /' || true

# ── 4. Extra paths listed in config/preserve-paths.txt (relative to the Tomcat directory) ─
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  case "$rel" in /*|*..*) fail "Unsafe preserve path: $rel" ;; esac
  if [ -e "$OLD/$rel" ]; then mkdir -p "$(dirname "$NEW/$rel")"; cp -a "$OLD/$rel" "$NEW/$rel"; log "Preserved $rel"
  else warn "Preserve path not found in old install: $rel"; fi
done <<< "${PRESERVE_PATHS:-}"

# ── 5. Syntax check of the migrated configuration with the new binaries ─────────────
log "Running catalina.sh configtest on the new install"
CATALINA_HOME="$NEW" CATALINA_BASE="$NEW" "$NEW/bin/catalina.sh" configtest >/tmp/configtest.$$ 2>&1 || { cat /tmp/configtest.$$; rm -f /tmp/configtest.$$; fail "configtest failed - the migrated configuration is not valid for $TARGET_VERSION"; }
rm -f /tmp/configtest.$$

touch "$NEW/.bpom-prepared"
set_state STATUS prepared
log "PREPARE DONE. Live service untouched."
