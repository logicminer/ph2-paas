#!/usr/bin/env bash
# spawn-wp.sh — Spawn a new WordPress instance on a client TLD.
# MUST be run as root (sudo bash spawn-wp.sh ...). Internal calls assume root.
#
# Architecture:
#   cloudflared tunnel (catch-all) → Dokku Nginx :80 → OLS :8088 → WP site
#   Shared MariaDB, per-site logical DB. Per-site OLS vhost + persistent uploads.
#
# Usage: ./spawn-wp.sh <tld> [--admin-email=you@example.com] [--wp-title="Site Title"] [--json-output=/path]
# Example: ./spawn-wp.sh bobsbakery.com --admin-email=bob@bobsbakery.com

set -euo pipefail

# ─── Load shared config ──────────────────────────────────────────────────────
source /etc/ph2/env

TUNNEL_HOST="${TUNNEL_ID}.cfargotunnel.com"
WP_SITES_DIR="/opt/ols/sites"
NGINX_WP_DIR="/etc/nginx/wp-domains"

# ─── Args ────────────────────────────────────────────────────────────────────
if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <tld> [--admin-email=...] [--wp-title=...] [--json-output=...]"
  exit 1
fi
TLD="$1"; shift
ADMIN_EMAIL="admin@${TLD}"
WP_TITLE="${TLD}"
JSON_OUTPUT=""

for arg in "$@"; do
  case $arg in
    --admin-email=*) ADMIN_EMAIL="${arg#*=}" ;;
    --wp-title=*)    WP_TITLE="${arg#*=}" ;;
    --json-output=*) JSON_OUTPUT="${arg#*=}" ;;
  esac
done

# Derive identifiers from TLD
SAFE_NAME="$(echo "$TLD" | tr '.' '_' | tr -cd 'a-z0-9_')"
DB_NAME="wp_${SAFE_NAME}"
DB_USER="${SAFE_NAME}"
DB_PW="$(head -c 20 /dev/urandom | base64 | tr -d '/+=' | cut -c1-20)"

# Logging helpers
log() { printf '\033[1;34m▶\033[0m %s\n' "$*"; }
ok()  { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

echo "══════════════════════════════════════════════════════════"
echo "  Spawning WordPress: ${TLD}"
echo "══════════════════════════════════════════════════════════"

# ─── Step 1: DNS CNAMEs ──────────────────────────────────────────────────────
log "Step 1/8: Creating DNS CNAMEs → tunnel"

ZONE_ID=""
ZONE_NAME=""
IFS='.' read -ra PARTS <<< "$TLD"
for (( i=0; i<${#PARTS[@]}; i++ )); do
  CAND="$(IFS=.; echo "${PARTS[*]:$i}")"
  RAW="$(curl -s "https://api.cloudflare.com/client/v4/zones?name=${CAND}" \
    -H "Authorization: Bearer ${CLOUDFLARE_TOKEN}")"
  ZID="$(echo "$RAW" | python3 -c "import json,sys; d=json.load(sys.stdin); r=d.get('result',[]); print(r[0]['id'] if r else '')")"
  if [[ -n "$ZID" ]]; then ZONE_ID="$ZID"; ZONE_NAME="$CAND"; break; fi
done
[[ -z "$ZONE_ID" ]] && die "No zone found for ${TLD} in your Cloudflare account. Add it first."

if [[ "$TLD" == "$ZONE_NAME" ]]; then
  RECORD_NAMES=("@" "www")
else
  PREFIX="${TLD%.${ZONE_NAME}}"
  RECORD_NAMES=("${PREFIX}" "www.${PREFIX}")
fi

for REC in "${RECORD_NAMES[@]}"; do
  curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records" \
    -H "Authorization: Bearer ${CLOUDFLARE_TOKEN}" \
    -H "Content-Type: application/json" \
    --data "$(python3 -c "import json; print(json.dumps({'type':'CNAME','name':'$REC','content':'$TUNNEL_HOST','proxied':True,'comment':'WP site via spawn-wp.sh'}))")" \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print('  ${REC}: OK' if d.get('success') else '  ${REC}: ' + str(d.get('errors')))"
done
ok "DNS records in zone ${ZONE_NAME}"

# ─── Step 2: MariaDB database + user ─────────────────────────────────────────
log "Step 2/8: Creating MariaDB database + user"

docker exec "$MARIADB_CONTAINER" mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" \
  -e "CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; CREATE USER IF NOT EXISTS '$DB_USER'@'%' IDENTIFIED BY '$DB_PW'; GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'%'; FLUSH PRIVILEGES;" 2>&1 | grep -v 'Warning' || true
ok "DB: ${DB_NAME}, user: ${DB_USER}"

# ─── Step 3: OLS vhost ───────────────────────────────────────────────────────
log "Step 3/8: Creating OLS vhost for ${TLD}"

bash -c "cd /opt/ols && ./bin/domain.sh -a ${TLD}" 2>&1 | tail -2 || true
SITE_DOCROOT="${WP_SITES_DIR}/${TLD}/html"
chown -R nobody:nogroup "${WP_SITES_DIR}/${TLD}"

# Create the per-vhost vhconf.conf that domain.sh omits.
docker exec "$OLS_CONTAINER" bash -c "
VH='${TLD}'
VHCONF=\"/usr/local/lsws/conf/vhosts/\${VH}/vhconf.conf\"
mkdir -p \"\$(dirname \"\$VHCONF\")\"
cat > \"\$VHCONF\" <<VHEOF
docRoot                   \$VH_ROOT/html/
index {
  useServer              0
  indexFiles             index.php, index.html
}
scriptHandler {
  add lsapi:lsphp        php
}
rewrite {
  enable                 1
  autoLoadHtaccess       1
}
VHEOF
chown -R lsadm:nogroup \"\$(dirname \"\$VHCONF\")\"
chmod 660 \"\$VHCONF\"
"
docker exec "$OLS_CONTAINER" /usr/local/lsws/bin/lswsctrl restart 2>&1 | tail -1
sleep 3
ok "OLS vhost: ${TLD}"

# ─── Step 4: WordPress core files ────────────────────────────────────────────
log "Step 4/8: Downloading WordPress core"

docker exec -u nobody "$OLS_CONTAINER" wp --path="/var/www/vhosts/${TLD}/html" core download 2>&1 | tail -2
ok "WP core downloaded"

# ─── Step 5: wp-config.php + install ─────────────────────────────────────────
log "Step 5/8: Configuring + installing WordPress"

TMP_PHP="$(mktemp)"
cat > "$TMP_PHP" <<PHP
define('FS_METHOD', 'direct');
define('WP_CACHE', true);
PHP

docker exec -i -u nobody "$OLS_CONTAINER" wp --path="/var/www/vhosts/${TLD}/html" config create \
  --dbname="$DB_NAME" --dbuser="$DB_USER" --dbpass="$DB_PW" \
  --dbhost=mariadb --dbcharset=utf8mb4 --dbcollate=utf8mb4_unicode_ci \
  --extra-php < "$TMP_PHP" 2>&1 | tail -2
rm -f "$TMP_PHP"

WP_ADMIN_USER="admin"
WP_ADMIN_PW="$(head -c 16 /dev/urandom | base64 | tr -d '/+=' | cut -c1-16)"

docker exec -u nobody "$OLS_CONTAINER" wp --path="/var/www/vhosts/${TLD}/html" core install \
  --url="https://${TLD}" --title="$WP_TITLE" \
  --admin_user="$WP_ADMIN_USER" --admin_password="$WP_ADMIN_PW" \
  --admin_email="$ADMIN_EMAIL" 2>&1 | tail -2
ok "WP installed → https://${TLD}/wp-admin"

# ─── Step 6: LSCache plugin ──────────────────────────────────────────────────
log "Step 6/8: Enabling LSCache"

docker exec -u nobody "$OLS_CONTAINER" wp --path="/var/www/vhosts/${TLD}/html" plugin install litespeed-cache --activate 2>&1 | tail -2
ok "LSCache enabled"

# ─── Step 7: Redis object cache ──────────────────────────────────────────────
log "Step 7/8: Enabling Redis object cache"

# Set Redis constants in wp-config.php
docker exec -u nobody "$OLS_CONTAINER" wp --path="/var/www/vhosts/${TLD}/html" config set WP_REDIS_HOST redis --type=constant 2>&1 | tail -1
docker exec -u nobody "$OLS_CONTAINER" wp --path="/var/www/vhosts/${TLD}/html" config set WP_REDIS_PORT 6379 --type=constant 2>&1 | tail -1
docker exec -u nobody "$OLS_CONTAINER" wp --path="/var/www/vhosts/${TLD}/html" config set WP_REDIS_DATABASE 0 --type=constant 2>&1 | tail -1

# Install + activate + enable the object cache drop-in
docker exec -u nobody "$OLS_CONTAINER" wp --path="/var/www/vhosts/${TLD}/html" plugin install redis-cache --activate 2>&1 | tail -2
docker exec -u nobody "$OLS_CONTAINER" wp --path="/var/www/vhosts/${TLD}/html" redis enable 2>&1 | tail -1
ok "Redis object cache enabled (db 0)"

# ─── Step 8: Dokku Nginx proxy route ─────────────────────────────────────────
log "Step 8/8: Adding Nginx proxy route ${TLD} → ${OLS_CONTAINER}:8088"

SAFE_CONF="$(echo "$TLD" | tr '.' '_')"
cat > "${NGINX_WP_DIR}/${SAFE_CONF}.conf" <<NGINXEOF
# WP site: ${TLD} → OpenLiteSpeed
server {
    listen 80;
    server_name ${TLD} www.${TLD};

    set_real_ip_from 172.64.0.0/13;
    real_ip_header CF-Connecting-IP;

    client_max_body_size 64M;

    location / {
        proxy_pass http://127.0.0.1:8088;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Host \$host;
    }
}
NGINXEOF

nginx -t 2>&1 | tail -1
systemctl reload nginx
ok "Nginx routing: ${TLD} → OLS:8088"

# ─── Done ────────────────────────────────────────────────────────────────────
echo "══════════════════════════════════════════════════════════"
echo "  ✓ WordPress spawned: https://${TLD}"
echo "══════════════════════════════════════════════════════════"
echo
echo "  Admin:    https://${TLD}/wp-admin"
echo "  User:     ${WP_ADMIN_USER}"
echo "  Password: ${WP_ADMIN_PW}"
echo "  Email:    ${ADMIN_EMAIL}"
echo
echo "  DB:       ${DB_NAME} (user: ${DB_USER})"
echo "  Docroot:  ${SITE_DOCROOT}"
echo
printf '  \033[1;33m⚠ Save these credentials now.\033[0m\n'

# ─── JSON output (for control panel persistence) ─────────────────────────────
if [[ -n "$JSON_OUTPUT" ]]; then
  python3 -c "
import json
creds = {
    'domain': '${TLD}',
    'type': 'wordpress',
    'status': 'active',
    'wp_admin_user': '${WP_ADMIN_USER}',
    'wp_admin_password': '${WP_ADMIN_PW}',
    'wp_admin_email': '${ADMIN_EMAIL}',
    'wp_title': '''${WP_TITLE}''',
    'db_name': '${DB_NAME}',
    'db_user': '${DB_USER}',
    'db_password': '${DB_PW}',
    'docroot': '${SITE_DOCROOT}',
    'zone': '${ZONE_NAME}',
}
with open('${JSON_OUTPUT}', 'w') as f:
    json.dump(creds, f, indent=2)
print('Credentials written to ${JSON_OUTPUT}')
"
fi
