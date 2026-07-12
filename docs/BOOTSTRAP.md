# Bootstrap Guide — New Machine Setup

## Prerequisites

### 1. Ubuntu 24.04 server
Any baremetal or VPS with root access. Minimum specs:
- 4GB RAM (8GB+ recommended)
- 40GB disk
- 2+ CPU cores
- Internet access (outbound only — no public IP needed)

### 2. Cloudflare account
- Your domain(s) added as zones in Cloudflare (active status)
- An API token with these permissions:
  - **Zone → DNS → Edit** (all zones)
  - **Account → Cloudflare Tunnel → Edit**
  - **Account → Access: Apps and Policies → Edit**

Create at: https://dash.cloudflare.com/profile/api-tokens → Create Custom Token

### 3. This repo
Clone to the new machine:
```bash
git clone <repo-url> /opt/ph2/paas
```

## Setup steps

### Step 1: Configure

```bash
cd /opt/ph2/paas
cp .env.example .env
nano .env
```

Fill in the required fields (see `.env.example` for documentation):
- `CLOUDFLARE_ACCOUNT_ID` — from your CF dashboard sidebar
- `CLOUDFLARE_TOKEN` — the API token you created
- `DOKKU_GLOBAL_DOMAIN` — your base domain (e.g. `markethive.life`)
- `PORTAINER_DOMAIN` — subdomain for Portainer (e.g. `ph2.markethive.life`)
- `PANEL_DOMAIN` — subdomain for the control panel (e.g. `panel.markethive.life`)
- `ACCESS_ADMIN_EMAIL` — email that can log in to panel + Portainer

Leave auto-generated fields blank (MariaDB password, OLS password, tunnel ID).

### Step 2: Bootstrap

```bash
sudo bash bootstrap.sh
```

This runs 17 steps (~10 minutes):
1. Write `/etc/ph2/env` (shared config + auto-generated secrets)
2. Install system packages (Docker, cloudflared, zram-tools, SSH)
3. Configure memory tier (zram + swap)
4. Install Dokku + set global domain
5. Create `wp-tier` Docker network
6. Deploy MariaDB container
7. Deploy OpenLiteSpeed container
8. Install cloudflared
9. Create Cloudflare tunnel + start service
10. Configure Nginx WP gateway
11. Install sudoers entry
12. Install operational scripts
13. Deploy Portainer
14. Deploy control panel (Dokku app)
15. Create DNS CNAMEs for panel + Portainer
16. Create Cloudflare Access policies
17. Set up backup cron

### Step 3: Verify

After bootstrap completes, check the summary output for URLs and credentials. Then:

1. **Visit Portainer** — `https://<PORTAINER_DOMAIN>` → email OTP → set admin password (first visit only)
2. **Visit Panel** — `https://<PANEL_DOMAIN>` → email OTP → dashboard should show box health
3. **Spawn a test site**:
   ```bash
   sudo bash $SCRIPTS_DIR/spawn-wp.sh test.<your-domain> --wp-title="Test Site"
   ```
4. **Check backup works**:
   ```bash
   sudo bash $SCRIPTS_DIR/backup.sh
   ```

## Troubleshooting

### cloudflared won't start
The service needs a generous startup timeout. Bootstrap sets `TimeoutStartSec=120`, but if it still fails:
```bash
journalctl -u cloudflared.service -n 30
systemctl restart cloudflared
```

### OLS lsphp deadlock (WordPress returns blank)
If WP sites load blank pages with `No request delivery notification` in OLS error log, the per-vhost `vhconf.conf` is missing. `spawn-wp.sh` creates this, but if a site was created manually, you need it. See the `vhconf.conf` template in `scripts/spawn-wp.sh` Step 3.

### Panel can't spawn (permission denied)
The panel runs scripts via `sudo`. Verify the sudoers entry:
```bash
cat /etc/sudoers.d/ph2
# Should list all 4 scripts with NOPASSWD for your user
```

### Dokku deploy fails (git push rejected)
The admin SSH key must be registered with Dokku:
```bash
cat /root/.ssh/admin_deploy.pub | dokku ssh-keys:add admin
```

## Post-bootstrap checklist

- [ ] Portainer admin password set (first visit)
- [ ] Panel dashboard loads (box health visible)
- [ ] Test WP site spawned and accessible
- [ ] Backup runs successfully (check `/data/backups/`)
- [ ] Cloudflare Access email received (check OTP flow)
