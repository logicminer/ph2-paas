#!/usr/bin/env bash
# bootstrap.sh — Provision a fresh Ubuntu 24.04 box into a PH2 PaaS node.
#
# Prerequisites:
#   1. Clone this repo: git clone <repo-url> /opt/ph2/paas
#   2. Copy .env.example → .env and fill in required values
#   3. Run: sudo bash /opt/ph2/paas/bootstrap.sh
#
# What this does (17 steps):
#   System packages → memory tier → Dokku → Docker network →
#   MariaDB → OLS → Cloudflare tunnel → Nginx gateway →
#   Sudoers → scripts → Portainer → Panel → DNS → Access → Backup cron →
#   Done.

set -euo pipefail

# ─── Pre-flight checks ───────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || { echo "Must run as root: sudo bash bootstrap.sh"; exit 1; }

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${REPO_DIR}/.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "✗ .env not found at ${ENV_FILE}"
  echo "  Copy .env.example → .env and fill in the required values."
  exit 1
fi
source "$ENV_FILE"

# Validate required fields
for VAR in CLOUDFLARE_ACCOUNT_ID CLOUDFLARE_TOKEN DOKKU_GLOBAL_DOMAIN PORTAINER_DOMAIN PANEL_DOMAIN ACCESS_ADMIN_EMAIL; do
  [[ -n "${!VAR:-}" ]] || { echo "✗ ${VAR} is required in .env"; exit 1; }
done

# Set defaults
SCRIPTS_DIR="${SCRIPTS_DIR:-/opt/ph2/scripts}"
BACKUP_DIR="${BACKUP_DIR:-/data/backups}"
OLS_CONTAINER="${OLS_CONTAINER:-litespeed}"
MARIADB_CONTAINER="${MARIADB_CONTAINER:-mariadb}"
WP_NETWORK="${WP_NETWORK:-wp-tier}"
OLS_VERSION="${OLS_VERSION:-1.8.5}"
PHP_VERSION="${PHP_VERSION:-lsphp85}"
PHPMYADMIN_VERSION="${PHPMYADMIN_VERSION:-5.2.3}"
SUDO_USER="${SUDO_USER:-$(logname 2>/dev/null || echo ubuntu)}"

# Auto-detect memory tier sizing
RAM_MB=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)
ZRAM_SIZE_MB="${ZRAM_SIZE_MB:-$(( RAM_MB > 16384 ? 16384 : RAM_MB ))}"
SWAP_SIZE_MB="${SWAP_SIZE_MB:-$(( RAM_MB / 2 ))}"

# Auto-detect box label
CPU_MODEL=$(lscpu 2>/dev/null | grep 'Model name' | sed 's/Model name:.*: //' || echo 'unknown')
BOX_LABEL="${BOX_LABEL:-$(hostname) · ${CPU_MODEL} · ${RAM_MB}MB}"

# Generate secrets if not provided
MARIADB_ROOT_PASSWORD="${MARIADB_ROOT_PASSWORD:-$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | cut -c1-24)}"
OLS_ADMIN_PASSWORD="${OLS_ADMIN_PASSWORD:-$(head -c 16 /dev/urandom | base64 | tr -d '/+=' | cut -c1-16)}"

log() { printf '\033[1;34m▶\033[0m %s\n' "$*"; }
ok()  { printf '\033[1;32m✓\033[0m %s\n' "$*"; }

echo "══════════════════════════════════════════════════════════"
echo "  PH2 PaaS — Bootstrap"
echo "  Box: ${BOX_LABEL}"
echo "  zram: ${ZRAM_SIZE_MB}MB, swap: ${SWAP_SIZE_MB}MB"
echo "  Panel: ${PANEL_DOMAIN}, Portainer: ${PORTAINER_DOMAIN}"
echo "══════════════════════════════════════════════════════════"

# ─── Step 1: Generate /etc/ph2/env (shared config) ───────────────────────────
log "Step 1/17: Writing /etc/ph2/env"
mkdir -p /etc/ph2
cat > /etc/ph2/env <<PH2ENV
# PH2 PaaS shared config — generated $(date)
CLOUDFLARE_ACCOUNT_ID=${CLOUDFLARE_ACCOUNT_ID}
CLOUDFLARE_TOKEN=${CLOUDFLARE_TOKEN}
DOKKU_GLOBAL_DOMAIN=${DOKKU_GLOBAL_DOMAIN}
PORTAINER_DOMAIN=${PORTAINER_DOMAIN}
PANEL_DOMAIN=${PANEL_DOMAIN}
ACCESS_ADMIN_EMAIL=${ACCESS_ADMIN_EMAIL}
SCRIPTS_DIR=${SCRIPTS_DIR}
BACKUP_DIR=${BACKUP_DIR}
OLS_CONTAINER=${OLS_CONTAINER}
MARIADB_CONTAINER=${MARIADB_CONTAINER}
WP_NETWORK=${WP_NETWORK}
OLS_VERSION=${OLS_VERSION}
PHP_VERSION=${PHP_VERSION}
PHPMYADMIN_VERSION=${PHPMYADMIN_VERSION}
MARIADB_ROOT_PASSWORD=${MARIADB_ROOT_PASSWORD}
OLS_ADMIN_PASSWORD=${OLS_ADMIN_PASSWORD}
BOX_LABEL=${BOX_LABEL}
ZRAM_SIZE_MB=${ZRAM_SIZE_MB}
SWAP_SIZE_MB=${SWAP_SIZE_MB}
PH2ENV
# Append TUNNEL_ID later (step 9) — it's created via API
chmod 600 /etc/ph2/env
ok "/etc/ph2/env written (mode 600)"

# ─── Step 2: System packages ─────────────────────────────────────────────────
log "Step 2/17: Installing system packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ca-certificates curl git python3 openssh-server zram-tools 2>&1 | tail -3

# Docker (official repo)
if ! command -v docker &>/dev/null; then
  log "  Installing Docker..."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>&1 | tail -3
fi
systemctl enable --now docker ssh
ok "System packages installed"

# ─── Step 3: Memory tier (zram + swap) ───────────────────────────────────────
log "Step 3/17: Configuring memory tier (zram ${ZRAM_SIZE_MB}MB + swap ${SWAP_SIZE_MB}MB)"
# zram config
cat > /etc/default/zramswap <<ZRAMCONF
ALGO=lz4
SIZE=${ZRAM_SIZE_MB}
PRIORITY=100
ZRAMCONF
systemctl enable --now zramswap 2>/dev/null || systemctl restart zramswap 2>/dev/null || true

# Disk swap
swapoff /swap.img 2>/dev/null || true
fallocate -l "${SWAP_SIZE_MB}M" /swap.img
chmod 600 /swap.img
mkswap /swap.img
# Update fstab (replace any existing swap line)
sed -i '\:/swap.img:d' /etc/fstab
echo "/swap.img none swap sw,pri=10 0 0" >> /etc/fstab
swapon -p 10 /swap.img 2>/dev/null || true

# Swappiness
grep -q 'vm.swappiness' /etc/sysctl.conf && sed -i 's/^vm.swappiness=.*/vm.swappiness=10/' /etc/sysctl.conf || echo "vm.swappiness=10" >> /etc/sysctl.conf
sysctl vm.swappiness=10 2>/dev/null || true
ok "Memory tier: RAM → zram (pri 100) → swap (pri 10)"

# ─── Step 4: Install Dokku ───────────────────────────────────────────────────
log "Step 4/17: Installing Dokku"
if ! command -v dokku &>/dev/null; then
  wget -qO- https://raw.githubusercontent.com/dokku/dokku/v0.35.17/bootstrap.sh | DOKKU_TAG=v0.35.17 bash 2>&1 | tail -5
fi
dokku domains:set-global "$DOKKU_GLOBAL_DOMAIN" 2>/dev/null || true

# Generate admin SSH key for Dokku
if [[ ! -f /root/.ssh/admin_deploy ]]; then
  mkdir -p /root/.ssh
  ssh-keygen -t ed25519 -f /root/.ssh/admin_deploy -N "" -C "admin@$(hostname)" -q
fi
cat /root/.ssh/admin_deploy.pub | dokku ssh-keys:add admin 2>/dev/null || true
ok "Dokku installed, global domain: ${DOKKU_GLOBAL_DOMAIN}"

# ─── Step 5: Docker network ──────────────────────────────────────────────────
log "Step 5/17: Creating ${WP_NETWORK} Docker network"
docker network create "$WP_NETWORK" 2>/dev/null || true
ok "Network ready"

# ─── Step 6: MariaDB ─────────────────────────────────────────────────────────
log "Step 6/17: Deploying MariaDB"
mkdir -p /opt/ph2/mariadb
# Render compose from template
sed -e "s|\${MARIADB_CONTAINER}|${MARIADB_CONTAINER}|g" \
    -e "s|\${MARIADB_ROOT_PASSWORD}|${MARIADB_ROOT_PASSWORD}|g" \
    -e "s|\${WP_NETWORK}|${WP_NETWORK}|g" \
    "${REPO_DIR}/templates/mariadb-docker-compose.yml" > /opt/ph2/mariadb/docker-compose.yml
cd /opt/ph2/mariadb && docker compose up -d 2>&1 | tail -3
sleep 10
ok "MariaDB: ${MARIADB_CONTAINER} on ${WP_NETWORK}"

# ─── Step 7: OpenLiteSpeed ───────────────────────────────────────────────────
log "Step 7/17: Deploying OpenLiteSpeed"
if [[ ! -d /opt/ols ]]; then
  git clone --depth=1 https://github.com/litespeedtech/ols-docker-env.git /opt/ols 2>&1 | tail -2
fi
# Render .env for OLS
cat > /opt/ols/.env <<OLSENV
TimeZone=UTC
OLS_VERSION=${OLS_VERSION}
PHP_VERSION=${PHP_VERSION}
PHPMYADMIN_VERSION=${PHPMYADMIN_VERSION}
MYSQL_ROOT_PASSWORD=${MARIADB_ROOT_PASSWORD}
MYSQL_DATABASE=
MYSQL_USER=
MYSQL_PASSWORD=
DOMAIN=localhost
OLS_ADMIN_PASSWORD=${OLS_ADMIN_PASSWORD}
OLSENV
# Overwrite compose to fit our architecture (proxy to 8088, no bundled DB)
cp "${REPO_DIR}/templates/ols-docker-compose.yml" /opt/ols/docker-compose.yml
sed -i "s|\${OLS_VERSION}|${OLS_VERSION}|g; s|\${PHP_VERSION}|${PHP_VERSION}|g; s|\${OLS_CONTAINER}|${OLS_CONTAINER}|g; s|\${WP_NETWORK}|${WP_NETWORK}|g" /opt/ols/docker-compose.yml
cd /opt/ols && docker compose up -d 2>&1 | tail -3
sleep 8
ok "OLS: ${OLS_CONTAINER} on port 127.0.0.1:8088"

# ─── Step 8: Cloudflared ─────────────────────────────────────────────────────
log "Step 8/17: Installing cloudflared"
if ! command -v cloudflared &>/dev/null; then
  curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg -o /usr/share/keyrings/cloudflare-main.gpg
  echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared $(lsb_release -cs) main" > /etc/apt/sources.list.d/cloudflared.list
  apt-get update -qq && apt-get install -y -qq cloudflared 2>&1 | tail -3
fi
ok "cloudflared installed"

# ─── Step 9: Create tunnel + start service ───────────────────────────────────
log "Step 9/17: Creating Cloudflare tunnel"
TUNNEL_SECRET=$(head -c 32 /dev/urandom | base64)
TUNNEL_RESP=$(curl -s -X POST "https://api.cloudflare.com/client/v4/accounts/${CLOUDFLARE_ACCOUNT_ID}/cfd_tunnel" \
  -H "Authorization: Bearer ${CLOUDFLARE_TOKEN}" \
  -H "Content-Type: application/json" \
  --data "$(python3 -c "import json,sys; print(json.dumps({'name':'ph2-'"$(hostname)"'','tunnel_secret':sys.argv[1]}))" "$TUNNEL_SECRET")")
TUNNEL_ID=$(echo "$TUNNEL_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('result',{}).get('id',''))" 2>/dev/null || echo "")

if [[ -z "$TUNNEL_ID" ]]; then
  echo "  ⚠ Tunnel creation failed. Response: $TUNNEL_RESP"
  echo "  You may need to create the tunnel manually in the CF dashboard."
  TUNNEL_ID="REPLACE_WITH_TUNNEL_ID"
fi
TUNNEL_HOST="${TUNNEL_ID}.cfargotunnel.com"

# Save tunnel secret + write credentials.json
mkdir -p /etc/cloudflared
echo "{\"AccountTag\":\"${CLOUDFLARE_ACCOUNT_ID}\",\"TunnelSecret\":\"${TUNNEL_SECRET}\",\"TunnelID\":\"${TUNNEL_ID}\"}" > /etc/cloudflared/credentials.json
chmod 600 /etc/cloudflared/credentials.json

# Write config.yml
cat > /etc/cloudflared/config.yml <<CFEOF
tunnel: ${TUNNEL_ID}
credentials-file: /etc/cloudflared/credentials.json
protocol: http2
ingress:
  - hostname: ${PORTAINER_DOMAIN}
    service: https://localhost:9443
    originRequest:
      noTLSVerify: true
  - service: http://localhost:80
CFEOF

# Add TUNNEL_ID to /etc/ph2/env
echo "TUNNEL_ID=${TUNNEL_ID}" >> /etc/ph2/env

# Install + start service (with generous timeout)
cloudflared --config /etc/cloudflared/config.yml service install 2>&1 | tail -3 || true
sed -i 's/^TimeoutStartSec=15/TimeoutStartSec=120/' /etc/systemd/system/cloudflared.service 2>/dev/null || true
systemctl daemon-reload
systemctl restart cloudflared.service 2>/dev/null || true
sleep 10
ok "Tunnel: ${TUNNEL_ID} (host: ${TUNNEL_HOST})"

# ─── Step 10: Nginx gateway ──────────────────────────────────────────────────
log "Step 10/17: Configuring Nginx WP gateway"
mkdir -p /etc/nginx/wp-domains
cp "${REPO_DIR}/templates/wp-proxy.conf" /etc/nginx/conf.d/wp-proxy.conf
# Ensure server_names_hash_bucket_size is set (needed for many long domains)
echo "server_names_hash_bucket_size 512;" > /etc/nginx/conf.d/server_names_hash_bucket_size.conf
nginx -t 2>&1 | tail -1 && systemctl reload nginx 2>/dev/null || true
ok "Nginx gateway ready"

# ─── Step 11: Sudoers ────────────────────────────────────────────────────────
log "Step 11/17: Installing sudoers entry"
sed -e "s|__USER__|${SUDO_USER}|g" \
    -e "s|__SCRIPTS_DIR__|${SCRIPTS_DIR}|g" \
    "${REPO_DIR}/templates/sudoers-ph2" > /etc/sudoers.d/ph2
chmod 0440 /etc/sudoers.d/ph2
visudo -cf /etc/sudoers.d/ph2
ok "Sudoers: ${SUDO_USER} can run scripts passwordless"

# ─── Step 12: Install scripts ────────────────────────────────────────────────
log "Step 12/17: Installing operational scripts"
mkdir -p "$SCRIPTS_DIR"
for script in spawn-wp.sh destroy-wp.sh backup.sh restore.sh; do
  cp "${REPO_DIR}/scripts/${script}" "${SCRIPTS_DIR}/${script}"
  chmod +x "${SCRIPTS_DIR}/${script}"
done
ok "Scripts installed to ${SCRIPTS_DIR}"

# ─── Step 13: Portainer ──────────────────────────────────────────────────────
log "Step 13/17: Deploying Portainer"
docker run -d --name portainer --restart=always \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v portainer_data:/data \
  -p 127.0.0.1:9443:9443 \
  portainer/portainer-ce:latest 2>&1 | tail -2
ok "Portainer on 127.0.0.1:9443"

# ─── Step 14: Panel ──────────────────────────────────────────────────────────
log "Step 14/17: Deploying control panel"
dokku apps:create panel 2>/dev/null || true
dokku domains:add panel "$PANEL_DOMAIN" 2>/dev/null || true
mkdir -p /var/lib/dokku/data/panel-data
dokku storage:mount panel /var/lib/dokku/data/panel-data:/app/data 2>/dev/null || true
# Docker socket + scripts + env for the panel container
dokku docker-options:add panel deploy "-v /var/run/docker.sock:/var/run/docker.sock" 2>/dev/null || true
dokku docker-options:add panel deploy "-v ${SCRIPTS_DIR}/spawn-wp.sh:${SCRIPTS_DIR}/spawn-wp.sh:ro" 2>/dev/null || true
dokku docker-options:add panel deploy "-v ${SCRIPTS_DIR}/destroy-wp.sh:${SCRIPTS_DIR}/destroy-wp.sh:ro" 2>/dev/null || true
dokku docker-options:add panel deploy "-v /etc/ph2/env:/etc/ph2/env:ro" 2>/dev/null || true
# Config vars
dokku config:set panel \
  DATA_DIR=/app/data PORT=3000 \
  SCRIPTS_DIR="$SCRIPTS_DIR" \
  DOKKU_GLOBAL_DOMAIN="$DOKKU_GLOBAL_DOMAIN" \
  BOX_LABEL="$BOX_LABEL" \
  NEXT_PUBLIC_PORTAINER_DOMAIN="$PORTAINER_DOMAIN" \
  2>/dev/null || true

# Push the panel code
cd "${REPO_DIR}/panel"
git init -q 2>/dev/null || true
git add -A && git commit -q -m "panel deploy" --allow-empty 2>/dev/null || true
git remote add dokku dokku@localhost:panel 2>/dev/null || true
GIT_SSH_COMMAND="ssh -i /root/.ssh/admin_deploy -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null" \
  git push dokku main:master 2>&1 | tail -5 || \
GIT_SSH_COMMAND="ssh -i /root/.ssh/admin_deploy -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null" \
  git push dokku master 2>&1 | tail -5
ok "Panel deployed → ${PANEL_DOMAIN}"

# ─── Step 15: DNS CNAMEs ─────────────────────────────────────────────────────
log "Step 15/17: Creating DNS CNAMEs for panel + portainer"

create_cname() {
  local SUBDOMAIN="$1" ZONE_DOMAIN="$2"
  # Resolve zone
  local ZID
  ZID=$(curl -s "https://api.cloudflare.com/client/v4/zones?name=${ZONE_DOMAIN}" \
    -H "Authorization: Bearer ${CLOUDFLARE_TOKEN}" \
    | python3 -c "import json,sys; d=json.load(sys.stdin); r=d.get('result',[]); print(r[0]['id'] if r else '')" 2>/dev/null)
  [[ -z "$ZID" ]] && { echo "  ⚠ Zone ${ZONE_DOMAIN} not found"; return 1; }

  local REC_NAME
  REC_NAME="${SUBDOMAIN%.${ZONE_DOMAIN}}"  # strip zone to get the record prefix
  curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${ZID}/dns_records" \
    -H "Authorization: Bearer ${CLOUDFLARE_TOKEN}" \
    -H "Content-Type: application/json" \
    --data "{\"type\":\"CNAME\",\"name\":\"${REC_NAME}\",\"content\":\"${TUNNEL_HOST}\",\"proxied\":true}" \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print('  ${SUBDOMAIN}: OK' if d.get('success') else '  ${SUBDOMAIN}: ' + str(d.get('errors')))" 2>/dev/null
}

# Panel domain
PANEL_ZONE="${PANEL_DOMAIN#*.}"  # strip first label to get zone
create_cname "$PANEL_DOMAIN" "$PANEL_ZONE" || true
# Portainer domain
PT_ZONE="${PORTAINER_DOMAIN#*.}"
create_cname "$PORTAINER_DOMAIN" "$PT_ZONE" || true
ok "DNS CNAMEs created"

# ─── Step 16: Cloudflare Access policies ─────────────────────────────────────
log "Step 16/17: Creating Cloudflare Access policies"

create_access() {
  local APP_DOMAIN="$1" APP_NAME="$2"
  local APP_ID
  APP_ID=$(curl -s -X POST "https://api.cloudflare.com/client/v4/accounts/${CLOUDFLARE_ACCOUNT_ID}/access/apps" \
    -H "Authorization: Bearer ${CLOUDFLARE_TOKEN}" \
    -H "Content-Type: application/json" \
    --data "{\"name\":\"${APP_NAME}\",\"domain\":\"${APP_DOMAIN}\",\"type\":\"self_hosted\",\"session_duration\":\"24h\"}" \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('result',{}).get('id',''))" 2>/dev/null)
  [[ -z "$APP_ID" ]] && { echo "  ⚠ Access app creation failed for ${APP_DOMAIN}"; return 1; }
  curl -s -X POST "https://api.cloudflare.com/client/v4/accounts/${CLOUDFLARE_ACCOUNT_ID}/access/apps/${APP_ID}/policies" \
    -H "Authorization: Bearer ${CLOUDFLARE_TOKEN}" \
    -H "Content-Type: application/json" \
    --data "{\"name\":\"Allow admin\",\"decision\":\"allow\",\"include\":[{\"email\":{\"email\":\"${ACCESS_ADMIN_EMAIL}\"}}]}" \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print('  policy: OK' if d.get('success') else '  policy: ' + str(d.get('errors')))" 2>/dev/null
}

create_access "$PANEL_DOMAIN" "PH2 Control Panel" || true
create_access "$PORTAINER_DOMAIN" "PH2 Portainer" || true
ok "Access policies created (email OTP → ${ACCESS_ADMIN_EMAIL})"

# ─── Step 17: Backup cron ────────────────────────────────────────────────────
log "Step 17/17: Setting up backup cron"
sed "s|__SCRIPTS_DIR__|${SCRIPTS_DIR}|g" "${REPO_DIR}/templates/cron-ph2-backup" > /etc/cron.d/ph2-backup
chmod 0644 /etc/cron.d/ph2-backup
mkdir -p "$BACKUP_DIR"
ok "Backup cron: daily 02:00, 7 daily + 4 weekly retention"

# ─── Done ────────────────────────────────────────────────────────────────────
echo "══════════════════════════════════════════════════════════"
echo "  ✓ PH2 PaaS bootstrap complete!"
echo "══════════════════════════════════════════════════════════"
echo
echo "  Control panel:  https://${PANEL_DOMAIN}"
echo "  Portainer:      https://${PORTAINER_DOMAIN}"
echo "  Both gated by Cloudflare Access (email OTP → ${ACCESS_ADMIN_EMAIL})"
echo
echo "  Credentials saved to /etc/ph2/env (root-only):"
echo "    MariaDB root: (in /etc/ph2/env)"
echo "    OLS admin:    (in /etc/ph2/env)"
echo "    Tunnel ID:    ${TUNNEL_ID}"
echo
echo "  Scripts: ${SCRIPTS_DIR}/"
echo "    spawn-wp.sh <domain>     — provision a WP site"
echo "    destroy-wp.sh <domain>   — tear down a WP site"
echo "    backup.sh                — run backup manually"
echo "    restore.sh <YYYYMMDD>    — restore from backup"
echo
echo "  Next: Set up Portainer admin password at https://${PORTAINER_DOMAIN}"
echo "  Then: Spawn your first site at https://${PANEL_DOMAIN}"
