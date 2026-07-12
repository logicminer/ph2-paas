#!/usr/bin/env bash
# restore.sh — Restore a PH2 PaaS backup set.
# MUST be run as root.
#
# Usage: ./restore.sh <YYYYMMDD>
# Example: ./restore.sh 20260712
#
# Restores from $BACKUP_DIR/ph2-backup-<DATE>-* files:
#   1. MariaDB databases (all)
#   2. WordPress site files
#   3. OLS config (vhosts)
#   4. Nginx WP configs
#   5. Panel SQLite + Dokku app configs
#
# Does NOT restore: Cloudflare DNS (that's the cloudflare.json snapshot for
# reference/replay via a separate script if needed).

set -euo pipefail

source /etc/ph2/env

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <YYYYMMDD>"
  echo "Available backup dates:"
  ls "$BACKUP_DIR"/ph2-backup-*-databases.sql.gz 2>/dev/null | \
    sed 's/.*ph2-backup-\([0-9]*\)-databases.*/  \1/' | sort -u
  exit 1
fi
DATE="$1"

log() { printf '\033[1;34m▶\033[0m %s\n' "$*"; }
ok()  { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

# Verify backup exists
DB_FILE="${BACKUP_DIR}/ph2-backup-${DATE}-databases.sql.gz"
[[ -f "$DB_FILE" ]] || die "No backup found for ${DATE}. Available: $(ls "$BACKUP_DIR"/ph2-backup-*-databases.sql.gz 2>/dev/null | sed 's/.*ph2-backup-\([0-9]*\)-.*/\1/' | sort -u | tr '\n' ' ')"

echo "══════════════════════════════════════════════════════════"
echo "  Restoring PH2 backup: ${DATE}"
echo "══════════════════════════════════════════════════════════"

# ─── 1. MariaDB ──────────────────────────────────────────────────────────────
log "Step 1/5: Restoring MariaDB databases"
zcat "$DB_FILE" | docker exec -i "$MARIADB_CONTAINER" mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" 2>/dev/null
ok "Databases restored"

# ─── 2. WordPress site files ─────────────────────────────────────────────────
log "Step 2/5: Restoring WP site files"
FILES_FILE="${BACKUP_DIR}/ph2-backup-${DATE}-wp-sites.tar.gz"
if [[ -f "$FILES_FILE" ]]; then
  mkdir -p /opt/ols/sites
  tar xzf "$FILES_FILE" -C /opt/ols/sites 2>/dev/null
  chown -R nobody:nogroup /opt/ols/sites
  ok "WP files restored"
else
  echo "  (no WP sites archive found — skipping)"
fi

# ─── 3. OLS config ────────────────────────────────────────────────────────────
log "Step 3/5: Restoring OLS config"
OLS_FILE="${BACKUP_DIR}/ph2-backup-${DATE}-ols-config.tar.gz"
if [[ -f "$OLS_FILE" ]]; then
  mkdir -p /opt/ols/lsws
  tar xzf "$OLS_FILE" -C /opt/ols/lsws 2>/dev/null
  docker exec "$OLS_CONTAINER" /usr/local/lsws/bin/lswsctrl restart 2>&1 | tail -1 || true
  ok "OLS config restored"
else
  echo "  (no OLS config archive — skipping)"
fi

# ─── 4. Nginx WP configs ─────────────────────────────────────────────────────
log "Step 4/5: Restoring Nginx WP configs"
NGINX_FILE="${BACKUP_DIR}/ph2-backup-${DATE}-nginx-wp.tar.gz"
if [[ -f "$NGINX_FILE" ]]; then
  tar xzf "$NGINX_FILE" -C /etc/nginx 2>/dev/null
  nginx -t 2>&1 | tail -1
  systemctl reload nginx
  ok "Nginx configs restored"
else
  echo "  (no Nginx archive — skipping)"
fi

# ─── 5. Panel SQLite + Dokku configs ─────────────────────────────────────────
log "Step 5/5: Restoring panel DB + Dokku configs"
PANEL_FILE="${BACKUP_DIR}/ph2-backup-${DATE}-panel.tar.gz"
if [[ -f "$PANEL_FILE" ]]; then
  mkdir -p /var/lib/dokku/data/panel-data
  tar xzf "$PANEL_FILE" -C /var/lib/dokku/data 2>/dev/null
  ok "Panel + Dokku configs restored"
  echo "  → Restart panel to pick up restored DB:"
  echo "    dokku ps:restart panel"
else
  echo "  (no panel archive — skipping)"
fi

echo "══════════════════════════════════════════════════════════"
echo "  ✓ Restore complete from ${DATE}"
echo "══════════════════════════════════════════════════════════"
