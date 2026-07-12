'use client';

import { useEffect, useState } from 'react';
import Link from 'next/link';

export default function SitesList() {
  const [sites, setSites] = useState([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    async function load() {
      try {
        const res = await fetch('/api/sites');
        const data = await res.json();
        setSites(data.sites || []);
      } catch (e) {
        console.error(e);
      } finally {
        setLoading(false);
      }
    }
    load();
  }, []);

  if (loading) return <div className="text-[#8b909c]">Loading...</div>;

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <h1 className="text-2xl font-bold">Sites</h1>
        <Link href="/sites/new" className="btn btn-primary">+ Spawn WordPress</Link>
      </div>

      {sites.length === 0 ? (
        <div className="card p-8 text-center text-[#8b909c]">
          No sites yet. Spawn your first WordPress site to get started.
        </div>
      ) : (
        <div className="card divide-y divide-[#2a2e3a]">
          {sites.map((site) => (
            <Link
              key={site.domain}
              href={`/sites/${encodeURIComponent(site.domain)}`}
              className="flex items-center justify-between px-4 py-3 hover:bg-[#0f1117] transition-colors"
            >
              <div className="flex items-center gap-3">
                <StatusBadge status={site.status} />
                <div>
                  <div className="font-medium">{site.domain}</div>
                  <div className="text-xs text-[#8b909c]">
                    {site.type === 'wordpress' ? 'WordPress + OLS + LSCache' : 'Next.js / Node (Dokku)'}
                    {site.source === 'panel' && ' · managed'}
                    {site.source === 'dokku' && ' · dokku'}
                    {site.source === 'ols' && ' · on-disk'}
                  </div>
                </div>
              </div>
              <div className="flex items-center gap-3">
                <TypeBadge type={site.type} />
                <a
                  href={`https://${site.domain}`}
                  target="_blank"
                  rel="noopener noreferrer"
                  className="text-[#3b82f6] hover:underline text-sm"
                  onClick={(e) => e.stopPropagation()}
                >
                  Visit ↗
                </a>
              </div>
            </Link>
          ))}
        </div>
      )}
    </div>
  );
}

function StatusBadge({ status }) {
  const cls = status === 'active' ? 'badge-green' : status === 'error' ? 'badge-red' : status === 'destroyed' ? 'badge-red' : 'badge-yellow';
  return <span className={`badge ${cls}`}>{status}</span>;
}

function TypeBadge({ type }) {
  const icon = type === 'wordpress' ? '🅦' : '⬢';
  return <span className="text-lg" title={type}>{icon}</span>;
}
