# Fitrah Routing Fix — Dokku + WordPress coexistence on a single tunnel

> **Status:** resolved in production. This document records the bug, the wrong fix we
> tried first, the correct fix, and concrete changes the ph2-paas maintainer should
> make so this never happens again.

## TL;DR

When deploying a new Dokku app (Fitrah) alongside existing WordPress sites on a
ph2-paas box, the app was unreachable through the Cloudflare Tunnel. A naive fix
— repointing the tunnel catch-all from `localhost:80` to `localhost:3000` — made
the Dokku app reachable but **hijacked every WordPress site** (`newsph.asia`,
`dalilsalam.com.ph` started serving the Fitrah Next.js app). The root cause is
that bypassing nginx port 80 skips the `/etc/nginx/wp-domains/` routing layer.

**The correct fix is a one-liner on the Dokku app, not a tunnel change:**

```bash
sudo dokku ports:add fitrah http:80:3000
```

The tunnel catch-all must **always** stay on `http://localhost:80`.

## Background: how routing is supposed to work

This is the single front door documented in
[ARCHITECTURE.md §"The four layers"](ARCHITECTURE.md). Traffic flows:

```
Internet → Cloudflare edge (TLS terminates)
        → cloudflared tunnel (catch-all ingress → localhost:80)
        → nginx :80 (hostname-based virtual host routing)
            ├── /etc/nginx/wp-domains/*.conf      → OpenLiteSpeed 127.0.0.1:8088 (WordPress)
            └── /home/dokku/<app>/nginx.conf      → Dokku app container
```

- The tunnel has a **catch-all ingress** to `localhost:80`. Every hostname with a
  CNAME pointing at the tunnel lands here. See
  `templates/cloudflared-config.yml` and `bootstrap.sh` Step 10.
- nginx (installed by Dokku) listens on **port 80** and routes by `Host` header.
- WordPress sites are added by `spawn-wp.sh` Step 8, which drops a
  `/etc/nginx/wp-domains/<domain>.conf` file containing a
  `server { listen 80; proxy_pass http://127.0.0.1:8088; }` block. The gateway is
  wired in by `templates/wp-proxy.conf` → `include /etc/nginx/wp-domains/*.conf;`.
- Dokku apps get a vhost at `/home/dokku/<app>/nginx.conf` (also `listen 80` when
  configured correctly — see the bug below).

The invariant that makes both stacks coexist: **everything reaches nginx on :80,
and nginx decides by hostname.** Break that invariant and WP sites stop working.

## The problem

By default, a freshly-deployed Dokku app's vhost at
`/home/dokku/<app>/nginx.conf` does **not** listen on port 80. Dokku maps the
app's container port (commonly 3000 for Node/Next.js) but leaves the public
listener on a non-80 port. So:

- `curl -H 'Host: fitrah.<domain>' http://localhost:3000` → works (hits the app
  directly).
- `curl -H 'Host: fitrah.<domain>' http://localhost:80` → no matching vhost on
  80, falls through.
- Through the tunnel (which only routes to :80) → **unreachable.**

Symptom: the Fitrah app deployed fine via `git push`, ran healthy inside its
container, but `https://fitrah.<domain>` returned nothing useful through the
tunnel.

## The wrong fix (what we did initially)

We repointed the tunnel catch-all in `/etc/cloudflared/config.yml` from
`http://localhost:80` to `http://localhost:3000`:

```yaml
# WRONG — do not do this
ingress:
  - hostname: ph2.markethive.life
    service: https://localhost:9443
    originRequest:
      noTLSVerify: true
  - service: http://localhost:3000   # ← bad: bypasses nginx :80 entirely
```

Fitrah became reachable. But so did every other hostname on the tunnel — because
the catch-all now went straight to Dokku's app port, **skipping nginx port 80
entirely**. The `/etc/nginx/wp-domains/*.conf` routing layer was never consulted.

Result: `newsph.asia` and `dalilsalam.com.ph` both served the Fitrah Next.js app
instead of WordPress. Full tenant hijack across every WP site on the box.

### Why this is catastrophic

- The tunnel catch-all is the **only** path from the public internet to the box.
  Pointing it anywhere other than nginx :80 means nginx's hostname routing no
  longer arbitrates between tenants.
- It fails silently: there's no error, no crash, no log line that says "your WP
  sites are gone." They just serve the wrong app.
- It affects every tenant on the box, not just the new app.

## The correct fix

### Step 1 — make the Dokku app listen on port 80

Add a port map so the app's vhost listens on 80, coexisting with the WP vhosts:

```bash
sudo dokku ports:add fitrah http:80:3000
```

Format is `http:<host_port>:<container_port>`. After this,
`/home/dokku/fitrah/nginx.conf` contains `listen 80;`, which sits alongside the
`listen 80;` blocks in `/etc/nginx/wp-domains/*.conf`. nginx now has vhosts for
both Fitrah and the WP sites on the same port and routes each by `Host` header.

Verify:

```bash
# Vhost should now show listen 80
grep 'listen' /home/dokku/fitrah/nginx.conf
sudo nginx -t && sudo systemctl reload nginx
```

### Step 2 — restore the tunnel catch-all to port 80

Revert `/etc/cloudflared/config.yml` to its original, correct shape (as generated
by `bootstrap.sh` Step 10):

```yaml
tunnel: <TUNNEL_ID>
credentials-file: /etc/cloudflared/credentials.json
protocol: http2
ingress:
  - hostname: ph2.markethive.life
    service: https://localhost:9443
    originRequest:
      noTLSVerify: true
  - service: http://localhost:80   # ← catch-all: nginx front door (WP + Dokku)
```

Restart cloudflared:

```bash
sudo systemctl restart cloudflared
```

### Step 3 — verify both stacks

```bash
# WP sites return WordPress (look for a WP-specific header / login form)
curl -sI https://newsph.asia/ | head -5
curl -sI https://dalilsalam.com.ph/ | head -5

# Dokku app returns the app
curl -sI https://fitrah.<domain>/ | head -5
```

All three should now resolve correctly through the same tunnel.

## Hard rule

> **The tunnel catch-all MUST route to `http://localhost:80`. Never to
> `localhost:3000`, the Dokku app port, or anything else.**

nginx on :80 is the single front door that arbitrates between WordPress tenants
and Dokku apps. Bypassing it breaks multi-tenancy.

If a Dokku app is unreachable through the tunnel, the fix is always
`dokku ports:add <app> http:80:<container_port>` — never a tunnel change.

## Suggested ph2-paas improvements

These are concrete recommendations for the ph2-paas maintainer. Each maps to a
specific file in this repo.

### 1. `bootstrap.sh` — document the Dokku port-map requirement

`bootstrap.sh` Step 4 installs Dokku and sets the global domain, but never
mentions that Dokku apps need a port map on 80 to be reachable through the
tunnel. Anyone following the bootstrap and then `git push`-ing their first app
will hit the exact bug we hit.

Suggested addition — a comment block after the Dokku global-domain line
(`bootstrap.sh` ~line 147, `dokku domains:set-global ...`):

```bash
# NOTE: Dokku apps are NOT reachable through the tunnel by default.
# Each app must publish a listener on host port 80 so nginx's catch-all
# vhost routes to it:
#     sudo dokku ports:add <app> http:80:<container_port>
# (e.g. http:80:3000 for a Node/Next.js app on the default port.)
# Never repoint the tunnel catch-all to the app's container port —
# that bypasses nginx :80 and hijacks every WP site on the box.
```

### 2. Tunnel ingress — make the port-80 rule explicit and hard

The catch-all in `templates/cloudflared-config.yml` and `bootstrap.sh` Step 10 is
correct today, but there is nothing warning a future operator against changing
it. That's exactly the trap we fell into.

Suggested changes:

- In `templates/cloudflared-config.yml`, expand the comment to call out the
  invariant and the consequence of violating it:

  ```yaml
  # ──────────────────────────────────────────────────────────────────────
  # HARD RULE: the catch-all MUST point at http://localhost:80 (nginx).
  # nginx on :80 is the single front door that routes WP sites
  # (/etc/nginx/wp-domains/*.conf → OLS :8088) AND Dokku apps
  # (/home/dokku/<app>/nginx.conf → app container) by hostname.
  #
  # NEVER change this to localhost:3000 or any Dokku app port. Doing so
  # bypasses nginx and makes every hostname on the tunnel serve whichever
  # Dokku app listens on that port — i.e. full WP-tenant hijack.
  # ──────────────────────────────────────────────────────────────────────
  - service: http://localhost:80
  ```

- In `README.md`, add a short "Routing architecture" subsection (near the
  existing ASCII diagram, around line 45) spelling out the chain
  `tunnel → :80 → nginx → (WP via wp-domains OR Dokku via app vhosts)` and the
  rule that the tunnel catch-all is fixed to :80.

- In `docs/ARCHITECTURE.md` §"2. Routing layer — Dokku Nginx (port 80)", add an
  explicit "Never bypass port 80" note alongside the existing routing table, and
  cross-link to this document.

### 3. `spawn-wp.sh` / `destroy-wp.sh` — no change needed

These scripts are unaffected by the bug. They add/remove files in
`/etc/nginx/wp-domains/`, which are `listen 80;` vhosts and route correctly as
long as the tunnel points at :80. No action required; called out here so future
readers know we checked.

### 4. Add a post-deploy WP health check to the panel

This hijack was invisible to monitoring — no container crashed, no probe failed.
A Dokku deploy silently broke every WP site. The panel should catch this
automatically.

Suggested behavior: after any `dokku ps:rebuild` / `git push` to a Dokku app
(the panel can subscribe to Dokku's `post-deploy` app hook, or run a check on a
cron), iterate every site in the panel's SQLite store and verify it still looks
like WordPress. A cheap signal:

```bash
# Each WP site should return a WP-specific marker, not the Dokku app's HTML.
curl -sI "https://${domain}/wp-login.php" | grep -qi 'wp-login\|wordpress'
```

If any WP domain returns non-WP content after a deploy, raise an alert on the
panel dashboard and, optionally, roll back the deploy. This would have flagged
the Fitrah hijack within seconds.

A minimal first version: a `scripts/health-check.sh` that the panel's existing
cron can call, plus a red banner on the dashboard when it fails. Fits the same
shape as the existing `backup.sh` / `restore.sh` scripts in `/opt/ph2/scripts/`.

### 5. Docs — make the routing architecture explicit

The routing chain is currently implicit (split across the README diagram and
`ARCHITECTURE.md` §2). Make it a first-class, copy-pasteable statement so it's
the first thing an operator reads before touching the tunnel:

```
Cloudflare Tunnel (catch-all, fixed to :80)
  → nginx :80 (single front door, hostname routing)
      ├─ WP domain  → /etc/nginx/wp-domains/<domain>.conf → OLS 127.0.0.1:8088
      └─ Dokku app  → /home/dokku/<app>/nginx.conf        → app container
```

Add this to `README.md` near the existing diagram and to `docs/OPERATIONS.md`
§"Deploying a Node.js / Next.js app" (around line 58), right where a new Dokku
user lands. The OPERATIONS.md section currently shows `git push` and
`dokku domains:add` but never shows the required `dokku ports:add ... http:80:...`
step — that's the gap that produced this bug.

## Summary of commands

| Action | Command |
|---|---|
| Make a Dokku app reachable through the tunnel | `sudo dokku ports:add <app> http:80:<container_port>` |
| Verify the app vhost listens on 80 | `grep listen /home/dokku/<app>/nginx.conf` |
| Reload nginx after port-map change | `sudo nginx -t && sudo systemctl reload nginx` |
| Restore the tunnel front door | set `service: http://localhost:80` in `/etc/cloudflared/config.yml`, then `sudo systemctl restart cloudflared` |
| Verify a WP site still serves WP | `curl -sI https://<domain>/wp-login.php \| grep -i wordpress` |

## Files referenced

- `/etc/cloudflared/config.yml` — tunnel ingress (catch-all must stay on :80)
- `/etc/nginx/conf.d/wp-proxy.conf` → `include /etc/nginx/wp-domains/*.conf;`
- `/etc/nginx/wp-domains/<domain>.conf` — per-WP-site `listen 80;` vhost
- `/home/dokku/<app>/nginx.conf` — per-Dokku-app vhost (needs `listen 80;`)
- `bootstrap.sh` Step 4 (Dokku install) and Step 10 (tunnel config)
- `scripts/spawn-wp.sh` Step 8 (nginx WP vhost) and `scripts/destroy-wp.sh`
- `templates/cloudflared-config.yml`, `templates/wp-proxy.conf`
- `docs/ARCHITECTURE.md` §"2. Routing layer — Dokku Nginx (port 80)"
- `docs/OPERATIONS.md` §"Deploying a Node.js / Next.js app"
