<div align="center">

# ⚡ PH2 PaaS

**Self-hosted WordPress + Next.js platform on baremetal. Behind Cloudflare Tunnel. No public IP required.**

[Architecture](docs/ARCHITECTURE.md) · [Bootstrap Guide](docs/BOOTSTRAP.md) · [Operations](docs/OPERATIONS.md)

</div>

---

## What is this?

PH2 PaaS turns any Ubuntu server into a multi-tenant hosting platform for **WordPress** and **Node.js** applications. It's designed for a specific constraint: **you're behind CGNAT (no public IP), and you want Heroku-like deploys for Node plus cPanel-grade WordPress hosting — on one box, behind one tunnel.**

```
                    ┌─────────────────────────────────────────────┐
                    │              Cloudflare Edge                 │
                    │   (TLS terminates, DDoS protection, cache)   │
                    └──────────────────┬──────────────────────────┘
                                       │ outbound tunnel (no open ports)
                    ┌──────────────────▼──────────────────────────┐
                    │            cloudflared daemon                │
                    │       (catch-all ingress → :80)             │
                    └──────────────────┬──────────────────────────┘
                                       │
                    ┌──────────────────▼──────────────────────────┐
                    │           Dokku Nginx :80                   │
                    │     (hostname-based virtual host routing)    │
                    └──────┬──────────┬──────────┬────────────────┘
                           │          │          │
                    ┌──────▼──┐ ┌─────▼────┐ ┌──▼──────────┐
                    │  WP/OLS │ │ Node apps │ │  Panel     │
                    │ :8088   │ │ (Dokku)   │ │ (Next.js)  │
                    │ LSCache │ │ git push  │ │ + SQLite   │
                    └────┬────┘ └──────────┘ └────────────┘
                         │
              ┌──────────┼──────────┐
              │          │          │
        ┌─────▼────┐ ┌──▼────┐ ┌───▼──────┐
        │ MariaDB  │ │ Redis │ │ Portainer│
        │ (shared) │ │(cache)│ │ (Docker) │
        └──────────┘ └───────┘ └──────────┘
```

## Why does this exist?

| Problem | How PH2 PaaS solves it |
|---|---|
| **Behind CGNAT — no public IP** | Cloudflare Tunnel uses outbound-only connections. No port forwarding, no public IP, no dynamic DNS. |
| **WordPress needs to be fast** | OpenLiteSpeed + LSCache (server-level full-page cache) + Redis (object cache). Three cache layers. |
| **Node.js needs git-push deploys** | Dokku gives Heroku-style `git push` deploys with zero-downtime, healthchecks, buildpack auto-detection. |
| **Multiple clients, one box** | Per-site databases, per-site vhosts, per-site credentials. Shared MariaDB + OLS + Redis keep RAM flat. |
| **Don't want to hand-build every server** | One `bootstrap.sh` provisions everything. Parameterized — same scripts run on any machine. |

## Features

- 🌐 **WordPress hosting** via OpenLiteSpeed + PHP 8.5 + LSCache + Redis object cache
- ⚡ **Node.js/Next.js hosting** via Dokku (git-push-to-deploy, zero-downtime)
- 🔒 **Cloudflare Tunnel** — no open inbound ports, works behind CGNAT
- 🗄️ **Shared MariaDB** — one instance, per-site logical databases (RAM-efficient)
- ⚡ **Shared Redis** — object cache for WP (db 0), KV/cache for Node apps (db 1+)
- 🧠 **zram memory tier** — compressed RAM as primary swap, disk swap as overflow only
- 🖥️ **Web control panel** — spawn/destroy sites, view credentials, live deploy logs
- 🐳 **Portainer** — full Docker management (logs, exec, resource stats)
- 🔐 **Cloudflare Access** — email OTP gate on all admin surfaces
- 💾 **Automated backups** — daily DB + files + DNS snapshot, 7 daily + 4 weekly retention
- 📦 **One-command bootstrap** — reproducible on any Ubuntu 24.04 box

## Quick start

```bash
# 1. Clone
git clone https://github.com/<user>/ph2-paas.git
cd ph2-paas

# 2. Configure
cp .env.example .env
nano .env  # fill in Cloudflare creds + domains

# 3. Bootstrap (~10 min)
sudo bash bootstrap.sh
```

After bootstrap, visit your panel URL. That's it — you have a PaaS.

### Prerequisites

- **Ubuntu 24.04** (or similar Debian) — baremetal or VPS
- **Cloudflare account** with your domain(s) added as zones
- **Cloudflare API token** with: `Zone → DNS:Edit`, `Account → Tunnel:Edit`, `Account → Access:Apps:Edit`
- **No public IP needed** — that's the whole point

## Spawning a WordPress site

**Via the panel:**
1. Open `https://panel.yourdomain.com/sites/new`
2. Enter the domain, click "Spawn WordPress"
3. Watch live progress, get credentials

**Via CLI:**
```bash
sudo bash /opt/ph2/scripts/spawn-wp.sh bobsbakery.com \
  --wp-title="Bob's Bakery" \
  --admin-email=bob@bobsbakery.com
```

The 8-step spawn (~60 seconds):
```
1. DNS CNAMEs (@ + www) → tunnel        5. wp-config.php + WordPress install
2. MariaDB database + user               6. LSCache plugin (page caching)
3. OLS vhost + vhconf.conf               7. Redis object cache plugin
4. WordPress core download               8. Nginx proxy route
```

## Deploying a Node.js app

```bash
git remote add dokku dokku@yourserver:myapp
git push dokku main
```

Dokku auto-detects Node, runs `npm install` + `npm run build`, healthchecks, deploys zero-downtime.

## The caching stack

```
Request → Cloudflare edge cache (served at edge — fastest)
       → OLS LSCache (full-page cache at server level)
       → Redis object cache (DB query/post/options cache)
       → MariaDB (source of truth)
```

Three cache layers, each catching what the one above misses.

## Repository structure

```
ph2-paas/
├── bootstrap.sh                 # One-command provisioner (18 steps)
├── .env.example                 # All required inputs, documented
├── scripts/
│   ├── spawn-wp.sh             # Provision a WP site (8 steps)
│   ├── destroy-wp.sh           # Tear down a WP site
│   ├── backup.sh               # Daily backup (6 components)
│   └── restore.sh              # Restore from a backup set
├── panel/                       # Next.js control panel (SQLite)
│   ├── app/                     # Dashboard, sites, spawn form, detail
│   └── lib/db.js               # Database schema
├── templates/                   # Config templates (env-substituted)
│   ├── mariadb-docker-compose.yml
│   ├── ols-docker-compose.yml
│   ├── redis-docker-compose.yml
│   ├── cloudflared-config.yml
│   └── ...
└── docs/
    ├── ARCHITECTURE.md          # Full system design
    ├── BOOTSTRAP.md             # New machine setup
    └── OPERATIONS.md            # Day-to-day operations
```

All scripts read from a shared `/etc/ph2/env` file. **No hardcoded values** — the same scripts run identically on every machine.

## Capacity

| Box spec | Comfortable capacity |
|---|---|
| 16GB RAM, 6 cores (zram-boosted) | ~10-14 mixed apps, or ~15-20 WP-only sites |
| 32GB RAM (upgrade) | ~20-28 mixed apps |

RAM is the binding constraint. The zram tier effectively expands usable memory ~40% for compressible workloads (PHP/Node compress 2-3x).

## Security

- Panel + Portainer behind **Cloudflare Access** (email OTP, 24h session)
- All secrets in `/etc/ph2/env` (mode 600, root-only)
- OLS WebAdmin on localhost only (SSH tunnel to access)
- Scripts run via scoped sudoers entries (passwordless for automation, restricted to specific scripts)
- No inbound ports — cloudflared is outbound-only

## Documentation

| Doc | What's in it |
|---|---|
| [Architecture](docs/ARCHITECTURE.md) | The four layers (edge/routing/app/data), memory tier, credential flow, networking |
| [Bootstrap Guide](docs/BOOTSTRAP.md) | Step-by-step new machine setup with troubleshooting |
| [Operations](docs/OPERATIONS.md) | Spawn, destroy, deploy Node apps, backup, restore, OLS admin, common issues |

## Tech stack

| Component | Technology | Why |
|---|---|---|
| WordPress server | OpenLiteSpeed 1.8.5 + PHP 8.5 | LSCache — server-level full-page caching, LSAPI lower overhead than PHP-FPM |
| Node.js PaaS | Dokku 0.35 | Git-push deploys, MIT-licensed, no feature gates |
| Database | MariaDB 11.4 | Shared instance, per-site logical DBs (RAM-efficient) |
| Cache | Redis 7 | Object cache for WP, KV for Node apps |
| Tunnel | cloudflared | Outbound-only, defeats CGNAT |
| Control panel | Next.js 14 + SQLite | Lightweight, matches the deployed stack |
| Container management | Portainer CE | Docker UI, logs, exec, stats |
| Memory tier | zram (lz4) + disk swap | Compressed RAM as primary swap |

## License

MIT

---

<div align="center">

Built for [Markethive](https://markethive.life)

</div>
