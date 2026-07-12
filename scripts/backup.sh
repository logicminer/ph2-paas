#!/usr/bin/env bash
# backup.sh — Daily backup of all WordPress sites (DB + files).
# MUST be run as root. Called by cron at 02:00 daily.
#
# Two-tier retention:
#   - Daily:  kept for 7 days
#   - Weekly: every Sunday's backup kept for 28 days
#
# Usage: ./backup.sh

set -euo pipefail

source /etc/ph2/env

DATE="$(date +%Y%m%d)"
DOW="$(date +%u)"

mkdir -p "$BACKUP_DIR"

echo "[$(date)] PH2 backup starting — $DATE"

# ─── 1. MariaDB dump (all databases) ──────────────────────────────────────────
DB_FILE="${BACKUP_DIR}/ph2-backup-${DATE}-databases.sql.gz"
echo "  → Dumping MariaDB (all databases)..."
docker exec "$MARIADB_CONTAINER" mariadb-dump -uroot -p"$MARIADB_ROOT_PASSWORD" \
  --all-databases --single-transaction --routines --triggers --events 2>/dev/null \
  | gzip > "$DB_FILE"
echo "    ✓ $(ls -lh "$DB_FILE" | awk '{print $5}') → $DB_FILE"

# ─── 2. WordPress site files ─────────────────────────────────────────────────
FILES_FILE="${BACKUP_DIR}/ph2-backup-${DATE}-wp-sites.tar.gz"
if [[ -d /opt/ols/sites ]]; then
  echo "  → Archiving WP site files..."
  tar czf "$FILES_FILE" --exclude='*/html/wp-content/cache/*' -C /opt/ols/sites . 2>/dev/null
  echo "    ✓ $(ls -lh "$FILES_FILE" | awk '{print $5}') → $FILES_FILE"
fi

# ─── 3. OLS config ────────────────────────────────────────────────────────────
OLS_FILE="${BACKUP_DIR}/ph2-backup-${DATE}-ols-config.tar.gz"
if [[ -d /opt/ols/lsws/conf ]]; then
  echo "  → Archiving OLS config..."
  tar czf "$OLS_FILE" -C /opt/ols/lsws conf 2>/dev/null
  echo "    ✓ $(ls -lh "$OLS_FILE" | awk '{print $5}') → $OLS_FILE"
fi

# ─── 4. Nginx WP domain configs ──────────────────────────────────────────────
NGINX_FILE="${BACKUP_DIR}/ph2-backup-${DATE}-nginx-wp.tar.gz"
if [[ -d /etc/nginx/wp-domains ]]; then
  echo "  → Archiving Nginx WP configs..."
  tar czf "$NGINX_FILE" -C /etc/nginx wp-domains conf.d/wp-proxy.conf 2>/dev/null
  echo "    ✓ $(ls -lh "$NGINX_FILE" | awk '{print $5}') → $NGINX_FILE"
fi

# ─── 5. Panel SQLite + Dokku app configs ─────────────────────────────────────
PANEL_FILE="${BACKUP_DIR}/ph2-backup-${DATE}-panel.tar.gz"
echo "  → Archiving panel DB + Dokku configs..."
tar czf "$PANEL_FILE" \
  -C /var/lib/dokku/data panel-data \
  -C /var/lib/dokku/data/apps . \
  -C /var/lib/dokku config 2>/dev/null || true
echo "    ✓ $(ls -lh "$PANEL_FILE" | awk '{print $5}') → $PANEL_FILE"

# ─── 6. Cloudflare credentials snapshot ──────────────────────────────────────
CF_FILE="${BACKUP_DIR}/ph2-backup-${DATE}-cloudflare.json"
echo "  → Snapshotting Cloudflare DNS records..."
python3 -c "
import json, urllib.request
token = '${CLOUDFLARE_TOKEN}'
def api(url):
    req = urllib.request.Request(url, headers={'Authorization': f'Bearer {token}'})
    return json.loads(urllib.request.urlopen(req).read())
zones_resp = api('https://api.cloudflare.com/client/v4/zones?per_page=50')
snapshot = {'zones': [], 'date': '${DATE}'}
for z in zones_resp.get('result', []):
    zone_id = z['id']
    dns = api(f'https://api.cloudflare.com/client/v4/zones/{zone_id}/dns_records?per_page=200')
    snapshot['zones'].append({'name': z['name'], 'id': zone_id, 'status': z['status'], 'dns_records': dns.get('result', [])})
with open('${CF_FILE}', 'w') as f:
    json.dump(snapshot, f, indent=2)
print(f'    ✓ {len(snapshot[\"zones\"])} zones snapshot')
" 2>/dev/null || echo "    ⚠ Cloudflare snapshot failed (non-critical)"

# ─── 7. Retention ────────────────────────────────────────────────────────────
echo "  → Applying retention policy..."
for suffix in databases.sql.gz wp-sites.tar.gz ols-config.tar.gz nginx-wp.tar.gz panel.tar.gz cloudflare.json; do
  find "$BACKUP_DIR" -name "ph2-backup-*-${suffix}" -not -name "ph2-backup-weekly-*" -mtime +7 -delete 2>/dev/null || true
done

if [[ "$DOW" == "7" ]]; then
  echo "  → Sunday — promoting to weekly tier..."
  for suffix in databases.sql.gz wp-sites.tar.gz ols-config.tar.gz nginx-wp.tar.gz panel.tar.gz cloudflare.json; do
    DAILY="${BACKUP_DIR}/ph2-backup-${DATE}-${suffix}"
    WEEKLY="${BACKUP_DIR}/ph2-backup-weekly-${DATE}-${suffix}"
    [[ -f "$DAILY" ]] && cp "$DAILY" "$WEEKLY"
  done
  find "$BACKUP_DIR" -name "ph2-backup-weekly-*" -mtime +28 -delete 2>/dev/null || true
fi

echo "  → Retention applied"
BACKUP_COUNT=$(find "$BACKUP_DIR" -name "ph2-backup-${DATE}-*" | wc -l)
BACKUP_SIZE=$(du -sh "$BACKUP_DIR" 2>/dev/null | awk '{print $1}')
echo "[$(date)] PH2 backup complete — ${BACKUP_COUNT} files this run"
echo "  Backup dir: ${BACKUP_DIR} (${BACKUP_SIZE} total)"
