#!/bin/bash
# CentOS 6 / Apache 2.2 maintenance SSL vhost generator
set -euo pipefail
CONF_DIR=/etc/httpd/conf.d
SOURCE="$CONF_DIR/ssl.cms.conf"
DISABLED="$SOURCE.disabled"
TARGET="$CONF_DIR/ssl.maintenance.conf"
TEMPLATE=${1:-/tmp/ssl.maintenance.conf.template}

if [ "$(id -u)" -ne 0 ]; then echo 'Run as root' >&2; exit 1; fi
for file in "$SOURCE" "$TEMPLATE"; do
  [ -f "$file" ] || { echo "Missing: $file" >&2; exit 1; }
done
[ ! -e "$DISABLED" ] || { echo "Already exists: $DISABLED" >&2; exit 1; }
[ ! -e "$TARGET" ] || { echo "Already exists: $TARGET (refusing overwrite)" >&2; exit 1; }
command -v awk >/dev/null
command -v apachectl >/dev/null
[ "$(grep -c '#SSL_SETTINGS#' "$TEMPLATE")" -eq 1 ] || { echo 'Template must contain exactly one #SSL_SETTINGS#' >&2; exit 1; }

tmpdir=$(mktemp -d /tmp/maintenance-ssl.XXXXXX)
renamed=0
installed=0
cleanup() {
  status=$?
  if [ "$status" -ne 0 ]; then
    if [ "$renamed" -eq 1 ]; then mv "$DISABLED" "$SOURCE" || true; fi
    if [ "$installed" -eq 1 ]; then rm -f "$TARGET"; fi
    echo 'Failed; original config restored (if moved).' >&2
  fi
  rm -rf "$tmpdir"
}
trap cleanup EXIT

# Parse each original VirtualHost independently. Reject ambiguous or unsupported SSL vhosts.
awk -v dir="$tmpdir" '
function fail(s) { print "ERROR: " s > "/dev/stderr"; exit 2 }
/^[[:space:]]*<VirtualHost[[:space:]]/ {
 if (inside) fail("nested VirtualHost")
 inside=1; n++; file=sprintf("%s/vhost.%04d",dir,n)
 names=0; cert=0; key=0; chain=0
 next
}
/^[[:space:]]*<\/VirtualHost[[:space:]]*>/ {
 if (!inside) fail("unmatched VirtualHost end")
 if (names != 1 || cert != 1 || key != 1) fail("vhost " n " needs exactly one ServerName, certificate and key")
 inside=0; next
}
inside {
 line=$0
 if (line ~ /^[[:space:]]*#/) next
 if (line ~ /^[[:space:]]*ServerName[[:space:]]+/) {names++; print line >> file}
 else if (line ~ /^[[:space:]]*ServerAlias[[:space:]]+/) print line >> file
 else if (line ~ /^[[:space:]]*SSLCertificateFile[[:space:]]+/) {cert++; print line >> file}
 else if (line ~ /^[[:space:]]*SSLCertificateKeyFile[[:space:]]+/) {key++; print line >> file}
 else if (line ~ /^[[:space:]]*SSLCertificateChainFile[[:space:]]+/) {chain++; if(chain>1) fail("duplicate chain"); print line >> file}
}
END { if (inside) fail("unterminated VirtualHost"); if(n==0) fail("no VirtualHosts") ; print n > dir "/count" }
' "$SOURCE"

count=$(cat "$tmpdir/count")
# Header outside vhost, then one copy of template vhost per original vhost.
awk '/^[[:space:]]*<VirtualHost[[:space:]]/{exit} {print}' "$TEMPLATE" > "$tmpdir/header"
awk 'BEGIN{p=0} /^[[:space:]]*<VirtualHost[[:space:]]/{p=1} p{print}' "$TEMPLATE" > "$tmpdir/vhost-template"
[ -s "$tmpdir/vhost-template" ] || { echo 'Missing VirtualHost in template' >&2; exit 1; }
cat "$tmpdir/header" > "$tmpdir/generated"
for ((i=1;i<=count;i++)); do
  settings=$(printf '%s/vhost.%04d' "$tmpdir" "$i")
  awk -v settings="$settings" '
    /^[[:space:]]*#SSL_SETTINGS#[[:space:]]*$/ {
      while ((getline line < settings)>0) print line
      close(settings); next
    }
    {print}
  ' "$tmpdir/vhost-template" >> "$tmpdir/generated"
done
chmod 644 "$tmpdir/generated"
# Move original only after successful generation; validate before Apache reload.
mv "$SOURCE" "$DISABLED"
renamed=1
cp "$tmpdir/generated" "$TARGET"
installed=1
if ! apachectl configtest; then exit 1; fi
echo "Generated $count SSL VirtualHost(s): $TARGET"
echo "Original preserved: $DISABLED"
echo 'Configuration syntax OK. Review httpd -S, then run: service httpd restart'
