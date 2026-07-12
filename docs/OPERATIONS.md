# Operations Guide

## Spawning a WordPress site

### Via the panel (recommended)
1. Visit `https://<PANEL_DOMAIN>/sites/new`
2. Enter the domain (must be a zone in your Cloudflare account)
3. Optionally set site title + admin email
4. Click "Spawn WordPress" — watch live progress
5. Credentials are saved automatically; view at `/sites/<domain>`

### Via CLI
```bash
sudo bash /opt/ph2/scripts/spawn-wp.sh bobsbakery.com \
  --wp-title="Bob's Bakery" \
  --admin-email=bob@bobsbakery.com
```

**What happens (7 steps, ~60 seconds):**
1. DNS CNAMEs (@ + www) → tunnel, proxied via Cloudflare API
2. MariaDB database + user created (`wp_<domain>`)
3. OLS vhost + `vhconf.conf` created, OLS restarted
4. WordPress core downloaded via WP-CLI
5. `wp-config.php` generated + WP installed (random admin password)
6. LSCache plugin installed + activated
7. Nginx proxy route added + reloaded

**Output:** site URL, admin URL, username, password, DB name, docroot.

### Adding a new client domain not yet on Cloudflare
The domain must be a zone in your CF account first:
1. CF Dashboard → Add a Site → enter domain
2. Update nameservers at the registrar to CF's assigned pair
3. Wait for propagation (minutes to hours)
4. Then spawn as above

## Destroying a WordPress site

### Via the panel
1. Visit `/sites/<domain>`
2. Scroll to "Danger Zone"
3. Click "Destroy Site" → confirm

### Via CLI
```bash
sudo bash /opt/ph2/scripts/destroy-wp.sh bobsbakery.com
```

**What happens (5 steps):**
1. DNS CNAMEs deleted via Cloudflare API
2. MariaDB database + user dropped
3. OLS vhost removed, OLS restarted
4. WP site files deleted (`/opt/ols/sites/<domain>/`)
5. Nginx proxy route removed + reloaded

**⚠ This is permanent.** DB, uploads, themes — all gone. The last backup can restore it if needed.

## Deploying a Node.js / Next.js app

Node apps use Dokku (not OLS). Deploy via git push:

```bash
# On your local machine:
git remote add dokku dokku@<server>:<app-name>
git push dokku main

# On the server (set domain + DNS):
sudo dokku domains:add <app-name> <app-name>.<global-domain>
# Create DNS CNAME → tunnel via CF API or panel
```

Dokku auto-detects Node from `package.json`, runs `npm install` + `npm run build`, starts the container, healthchecks it, and deploys zero-downtime.

For private repos, use a fine-grained PAT in the git URL (read-only, scoped to one repo).

## Backups

### Automatic
Daily at 02:00 via cron (`/etc/cron.d/ph2-backup`). Six components captured:
- MariaDB (all databases)
- WP site files (uploads, themes, plugins)
- OLS config (vhosts)
- Nginx WP configs
- Panel SQLite + Dokku app configs
- Cloudflare DNS snapshot (all zones)

Retention: 7 daily + 4 weekly (Sunday promoted, kept 28 days).

### Manual
```bash
sudo bash /opt/ph2/scripts/backup.sh
```

### Check backup status
```bash
ls -lh /data/backups/
tail -20 /var/log/ph2-backup.log
```

## Restore

```bash
# List available backup dates
ls /data/backups/ph2-backup-*-databases.sql.gz | sed 's/.*ph2-backup-\([0-9]*\)-.*/\1/' | sort -u

# Restore a specific date
sudo bash /opt/ph2/scripts/restore.sh 20260712
```

Restores: DB → WP files → OLS config → Nginx configs → Panel DB. After restore, restart the panel:
```bash
sudo dokku ps:restart panel
```

## OLS WebAdmin

The OLS admin console is on `localhost:7080` (not exposed publicly). Access via SSH tunnel:
```bash
ssh -L 7080:localhost:7080 user@<server>
# Then visit http://localhost:7080 in your browser
```

Password is in `/etc/ph2/env` (`OLS_ADMIN_PASSWORD`).

Use WebAdmin for: PHP version changes, cache tuning, manual vhost edits, log viewing.

## Memory tier monitoring

```bash
# Current swap devices + priorities
swapon --show

# Memory usage
free -h

# zram compression ratio (DATA vs COMPR)
sudo zramctl
```

Expected: zram at priority 100 (used first), disk swap at priority 10 (overflow only).

## Cloudflare Access management

The panel and Portainer are gated by Cloudflare Access (email OTP). To add more admin emails:

1. CF Dashboard → Zero Trust → Access → Applications
2. Find "PH2 Control Panel" and "PH2 Portainer"
3. Edit policy → add emails to the "include" list

API alternative:
```bash
source /etc/ph2/env
# Get the app ID, then update the policy's include array
curl "https://api.cloudflare.com/client/v4/accounts/${CLOUDFLARE_ACCOUNT_ID}/access/apps" \
  -H "Authorization: Bearer ${CLOUDFLARE_TOKEN}"
```

## Common issues

### WP site loads blank page
Likely OLS lsphp deadlock. Check:
```bash
sudo docker exec litespeed tail -20 /usr/local/lsws/logs/error.log
```
If you see `No request delivery notification`, the `vhconf.conf` is missing. Re-run spawn or create it manually (see spawn-wp.sh Step 3).

### New WP site not reachable publicly
1. Check DNS: `dig <domain>` — should resolve to CF edge IPs
2. Check Nginx: `ls /etc/nginx/wp-domains/` — should have a `.conf` for the domain
3. Check OLS vhost: `sudo docker exec litespeed grep -r <domain> /usr/local/lsws/conf/`

### Panel can't see container status
The panel needs Docker socket access. Verify:
```bash
sudo docker exec panel docker ps  # should work from inside the container
```

### Disk filling up (Docker build cache)
```bash
sudo docker system prune -af
sudo docker builder prune -af
```
Consider adding a weekly cron for this.

## Upgrading

### OLS / PHP version
1. Update `OLS_VERSION` or `PHP_VERSION` in `/etc/ph2/env`
2. Update `/opt/ols/.env`
3. `cd /opt/ols && docker compose pull && docker compose up -d`

### Dokku
```bash
sudo apt-get update && sudo apt-get upgrade dokku
```

### Panel
```bash
cd /opt/ph2/paas/panel
git pull  # if updated
git push dokku master
```
