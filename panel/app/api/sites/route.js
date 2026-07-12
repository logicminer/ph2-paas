import { NextResponse } from 'next/server';
import { getAllSites } from '@/lib/db';
import { execSync } from 'child_process';
import { readdirSync, existsSync } from 'fs';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

// Merge WP sites from SQLite + Dokku Node apps + OLS vhosts for a unified view
export async function GET() {
  const sites = [];

  // 1. WP sites from SQLite (managed by spawn-wp.sh)
  try {
    const wpSites = getAllSites();
    for (const s of wpSites) {
      sites.push({ ...s, source: 'panel' });
    }
  } catch (e) {
    // DB might not be initialized yet
  }

  // 2. Dokku Node apps (read directory — no root needed)
  try {
    if (existsSync('/var/lib/dokku/data/apps')) {
      const dokkuApps = readdirSync('/var/lib/dokku/data/apps', { withFileTypes: true })
        .filter(d => d.isDirectory())
        .map(d => d.name);
      const globalDomain = process.env.DOKKU_GLOBAL_DOMAIN || 'markethive.life';
      for (const appName of dokkuApps) {
        // Don't duplicate if already in WP list
        if (!sites.find(s => s.domain === appName || s.domain === `${appName}.${globalDomain}`)) {
          sites.push({
            domain: `${appName}.${globalDomain}`,
            type: 'nextjs',
            status: 'active',
            app_name: appName,
            source: 'dokku',
          });
        }
      }
    }
  } catch (e) {
    // Dokku might not be accessible from container
  }

  // 3. OLS vhost directories (WP sites that exist on disk but not in SQLite)
  try {
    if (existsSync('/opt/ols/sites')) {
      const olsSites = readdirSync('/opt/ols/sites', { withFileTypes: true })
        .filter(d => d.isDirectory())
        .map(d => d.name);
      for (const domain of olsSites) {
        if (domain === 'localhost' || domain === 'Example') continue;
        if (!sites.find(s => s.domain === domain)) {
          sites.push({
            domain,
            type: 'wordpress',
            status: 'active',
            source: 'ols',
            docroot: `/opt/ols/sites/${domain}/html`,
          });
        }
      }
    }
  } catch (e) {
    // OLS dir not accessible
  }

  return NextResponse.json({ sites });
}
