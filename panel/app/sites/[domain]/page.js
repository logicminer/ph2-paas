'use client';

import { useEffect, useState, use } from 'react';
import { useRouter } from 'next/navigation';

export default function SiteDetail({ params }) {
  const domain = decodeURIComponent(use(params).domain);
  const router = useRouter();
  const [site, setSite] = useState(null);
  const [loading, setLoading] = useState(true);
  const [showCreds, setShowCreds] = useState(false);
  const [showDbCreds, setShowDbCreds] = useState(false);
  const [destroying, setDestroying] = useState(false);
  const [destroyLogs, setDestroyLogs] = useState([]);
  const [confirmDestroy, setConfirmDestroy] = useState(false);

  useEffect(() => {
    async function load() {
      try {
        const res = await fetch('/api/sites');
        const data = await res.json();
        const s = (data.sites || []).find(s => s.domain === domain);
        setSite(s || null);
      } catch (e) {
        console.error(e);
      } finally {
        setLoading(false);
      }
    }
    load();
  }, [domain]);

  async function handleDestroy() {
    setDestroying(true);
    setDestroyLogs([]);
    setConfirmDestroy(false);

    try {
      const res = await fetch('/api/destroy', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ domain }),
      });

      const reader = res.body.getReader();
      const decoder = new TextDecoder();
      let buffer = '';

      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        buffer += decoder.decode(value, { stream: true });
        const lines = buffer.split('\n\n');
        buffer = lines.pop();
        for (const line of lines) {
          if (line.startsWith('data: ')) {
            try {
              const data = JSON.parse(line.slice(6));
              setDestroyLogs(prev => [...prev, data]);
            } catch {}
          }
        }
      }
      // After destroy completes, go back to sites list
      setTimeout(() => router.push('/sites'), 2000);
    } catch (e) {
      setDestroyLogs(prev => [...prev, { type: 'error', message: e.message }]);
    } finally {
      setDestroying(false);
    }
  }

  if (loading) return <div className="text-[#8b909c]">Loading...</div>;
  if (!site) return <div className="text-[#8b909c]">Site not found: {domain}</div>;

  const isWP = site.type === 'wordpress';

  return (
    <div className="space-y-6 max-w-3xl">
      {/* Header */}
      <div className="flex items-start justify-between">
        <div>
          <div className="flex items-center gap-3 mb-1">
            <h1 className="text-2xl font-bold">{domain}</h1>
            <span className={`badge ${site.status === 'active' ? 'badge-green' : site.status === 'error' ? 'badge-red' : 'badge-yellow'}`}>
              {site.status}
            </span>
          </div>
          <p className="text-sm text-[#8b909c]">
            {isWP ? 'WordPress + OpenLiteSpeed + LSCache' : 'Next.js / Node (Dokku)'}
            {site.source && ` · source: ${site.source}`}
          </p>
        </div>
      </div>

      {/* Quick actions */}
      <div className="flex gap-3 flex-wrap">
        <a href={`https://${domain}`} target="_blank" rel="noopener noreferrer" className="btn btn-primary">
          Visit Site ↗
        </a>
        {isWP && (
          <a href={`https://${domain}/wp-admin`} target="_blank" rel="noopener noreferrer" className="btn btn-ghost">
            WP Admin ↗
          </a>
        )}
        <a href={`https://${process.env.NEXT_PUBLIC_PORTAINER_DOMAIN || 'ph2.markethive.life'}`} target="_blank" rel="noopener noreferrer" className="btn btn-ghost">
          Portainer ↗
        </a>
      </div>

      {/* WP Credentials */}
      {isWP && site.wp_admin_password && (
        <div className="card p-4">
          <div className="flex items-center justify-between mb-3">
            <h2 className="text-sm font-semibold">WordPress Admin Credentials</h2>
            <button onClick={() => setShowCreds(!showCreds)} className="btn btn-ghost text-xs">
              {showCreds ? '🙈 Hide' : '👁 Show'}
            </button>
          </div>
          <div className="space-y-2 text-sm">
            <CredRow label="Admin URL" value={`https://${domain}/wp-admin`} link />
            <CredRow label="Username" value={site.wp_admin_user} hidden={!showCreds} />
            <CredRow label="Password" value={site.wp_admin_password} hidden={!showCreds} copyable />
            <CredRow label="Email" value={site.wp_admin_email} hidden={!showCreds} />
            {site.wp_title && <CredRow label="Site Title" value={site.wp_title} />}
          </div>
        </div>
      )}

      {/* Database info */}
      {isWP && site.db_name && (
        <div className="card p-4">
          <div className="flex items-center justify-between mb-3">
            <h2 className="text-sm font-semibold">Database (MariaDB)</h2>
            {site.db_password && (
              <button onClick={() => setShowDbCreds(!showDbCreds)} className="btn btn-ghost text-xs">
                {showDbCreds ? '🙈 Hide' : '👁 Show'}
              </button>
            )}
          </div>
          <div className="space-y-2 text-sm">
            <CredRow label="Database" value={site.db_name} />
            <CredRow label="User" value={site.db_user} />
            {site.db_password && <CredRow label="Password" value={site.db_password} hidden={!showDbCreds} copyable />}
            <CredRow label="Host" value="mariadb (internal)" />
          </div>
        </div>
      )}

      {/* Filesystem */}
      {site.docroot && (
        <div className="card p-4">
          <h2 className="text-sm font-semibold mb-2">Filesystem</h2>
          <div className="text-sm">
            <CredRow label="Docroot" value={site.docroot} mono />
            {site.zone && <CredRow label="Cloudflare Zone" value={site.zone} />}
            {site.created_at && <CredRow label="Created" value={site.created_at} />}
          </div>
        </div>
      )}

      {/* Destroy zone */}
      {isWP && site.source === 'panel' && (
        <div className="card p-4 border-[#ef4444]">
          <h2 className="text-sm font-semibold text-[#ef4444] mb-3">Danger Zone</h2>
          {!confirmDestroy && !destroying ? (
            <button onClick={() => setConfirmDestroy(true)} className="btn btn-danger">
              🗑 Destroy Site
            </button>
          ) : destroying ? (
            <div className="space-y-1">
              {destroyLogs.map((log, i) => (
                <div key={i} className="log-line" style={{
                  color: log.type === 'error' ? '#ef4444' : log.type === 'done' ? '#22c55e' : '#8b909c'
                }}>
                  {log.message}
                </div>
              ))}
            </div>
          ) : (
            <div>
              <p className="text-sm text-[#ef4444] mb-3">
                This will permanently delete: DNS records, database, all files, uploads, and Nginx config for <strong>{domain}</strong>.
                This cannot be undone.
              </p>
              <div className="flex gap-2">
                <button onClick={handleDestroy} className="btn btn-danger">
                  Yes, destroy it permanently
                </button>
                <button onClick={() => setConfirmDestroy(false)} className="btn btn-ghost">
                  Cancel
                </button>
              </div>
            </div>
          )}
        </div>
      )}

      <div>
        <button onClick={() => router.push('/sites')} className="text-sm text-[#8b909c] hover:text-[#e4e7ec]">
          ← Back to sites
        </button>
      </div>
    </div>
  );
}

function CredRow({ label, value, hidden, copyable, link, mono }) {
  const [copied, setCopied] = useState(false);

  function copy() {
    navigator.clipboard.writeText(value);
    setCopied(true);
    setTimeout(() => setCopied(false), 1500);
  }

  const display = hidden ? '••••••••••••' : value;

  return (
    <div className="flex items-center justify-between gap-4 py-1">
      <span className="text-[#8b909c] text-xs whitespace-nowrap">{label}</span>
      <div className="flex items-center gap-2 ml-auto">
        {link ? (
          <a href={value} target="_blank" rel="noopener noreferrer" className="text-[#3b82f6] hover:underline font-mono text-xs">
            {value}
          </a>
        ) : (
          <span className={mono ? 'font-mono text-xs' : 'text-xs'}>{display}</span>
        )}
        {copyable && !hidden && (
          <button onClick={copy} className="text-xs text-[#8b909c] hover:text-[#e4e7ec]">
            {copied ? '✓' : '📋'}
          </button>
        )}
      </div>
    </div>
  );
}
