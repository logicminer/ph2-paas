#!/usr/bin/env bash
# destroy-wp.sh — Tear down a WordPress instance.
# MUST be run as root. Mirror of spawn-wp.sh.
#
# Usage: ./destroy-wp.sh <tld>
# ⚠ DESTRUCTIVE. All site data (DB, uploads, files) is permanently deleted.

set -euo pipefail

source /etc/ph2/env

TUNNEL_HOST="${TUNNEL_ID}.cfargotunnel.com"
WP_SITES_DIR="/opt/ols/sites"
NGINX_WP_DIR="/etc/nginx/wp-domains"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <tld>"; exit 1
fi
TLD="$1"

SAFE_NAME="$(echo "$TLD" | tr '.' '_' | tr -cd 'a-z0-9_')"
DB_NAME="wp_${SAFE_NAME}"
DB_USER="${SAFE_NAME}"
SAFE_CONF="$(echo "$TLD" | tr '.' '_')"

log() { printf '\033[1;34m▶\033[0m %s\n' "$*"; }
ok()  { printf '\033[1;32m✓\033[0m %s\n' "$*"; }

echo "══════════════════════════════════════════════════════════"
echo "  Destroying WordPress: ${TLD}"
echo "══════════════════════════════════════════════════════════"

# ─── Step 1: Remove DNS CNAMEs ───────────────────────────────────────────────
log "Step 1/5: Removing DNS CNAMEs"

ZONE_ID=""
ZONE_NAME=""
IFS='.' read -ra PARTS <<< "$TLD"
for (( i=0; i<${#PARTS[@]}; i++ )); do
  CAND="$(IFS=.; echo "${PARTS[*]:$i}")"
  ZID="$(curl -s "https://api.cloudflare.com/client/v4/zones?name=${CAND}" \
    -H "Authorization: Bearer ${CLOUDFLARE_TOKEN}" \
    | python3 -c "import json,sys; d=json.load(sys.stdin); r=d.get('result',[]); print(r[0]['id'] if r else '')")"
  if [[ -n "$ZID" ]]; then ZONE_ID="$ZID"; ZONE_NAME="$CAND"; break; fi
done

if [[ -n "$ZONE_ID" ]]; then
  REC_IDS=$(curl -s "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records?type=CNAME&content=${TUNNEL_HOST}&per_page=100" \
    -H "Authorization: Bearer ${CLOUDFLARE_TOKEN}" \
    | python3 -c "
import json,sys
d=json.load(sys.stdin)
for r in d.get('result',[]):
    if '${TUNNEL_HOST}' in r.get('content',''):
        print(r['id'])
")
  for RID in $REC_IDS; do
    curl -s -X DELETE "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${RID}" \
      -H "Authorization: Bearer ${CLOUDFLARE_TOKEN}" \
      | python3 -c "import json,sys; d=json.load(sys.stdin); print('  deleted:', d.get('success'))" 2>/dev/null || true
  done
  ok "DNS records removed from ${ZONE_NAME}"
else
  echo "  (no zone found — skipping DNS cleanup)"
fi

# ─── Step 2: Drop MariaDB database + user ────────────────────────────────────
log "Step 2/5: Dropping MariaDB database + user"

docker exec "$MARIADB_CONTAINER" mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" \
  -e "DROP DATABASE IF EXISTS \`$DB_NAME\`; DROP USER IF EXISTS '$DB_USER'@'%'; FLUSH PRIVILEGES;" 2>&1 | grep -v 'Warning' || true
ok "DB dropped: ${DB_NAME}"

# ─── Step 3: Remove OLS vhost ────────────────────────────────────────────────
log "Step 3/5: Removing OLS vhost"

bash -c "cd /opt/ols && ./bin/domain.sh -D ${TLD}" 2>&1 | tail -2 || true
docker exec "$OLS_CONTAINER" rm -rf "/usr/local/lsws/conf/vhosts/${TLD}" 2>/dev/null || true
docker exec "$OLS_CONTAINER" /usr/local/lsws/bin/lswsctrl restart 2>&1 | tail -1 || true
ok "OLS vhost removed"

# ─── Step 4: Remove WordPress files ──────────────────────────────────────────
log "Step 4/5: Removing WordPress files"

rm -rf "${WP_SITES_DIR}/${TLD}" 2>/dev/null || true
ok "Site files removed"

# ─── Step 5: Remove Nginx proxy route ────────────────────────────────────────
log "Step 5/5: Removing Nginx proxy route"

rm -f "${NGINX_WP_DIR}/${SAFE_CONF}.conf" 2>/dev/null || true
nginx -t 2>&1 | tail -1
systemctl reload nginx
ok "Nginx route removed"

echo "══════════════════════════════════════════════════════════"
echo "  ✓ WordPress destroyed: ${TLD}"
echo "══════════════════════════════════════════════════════════"
