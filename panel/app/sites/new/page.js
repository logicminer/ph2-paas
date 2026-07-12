'use client';

import { useState, useRef } from 'react';
import { useRouter } from 'next/navigation';

export default function SpawnForm() {
  const router = useRouter();
  const [domain, setDomain] = useState('');
  const [wpTitle, setWpTitle] = useState('');
  const [adminEmail, setAdminEmail] = useState('');
  const [spawning, setSpawning] = useState(false);
  const [logs, setLogs] = useState([]);
  const [done, setDone] = useState(false);
  const [error, setError] = useState('');
  const logEndRef = useRef(null);

  async function handleSpawn(e) {
    e.preventDefault();
    if (!domain) return;

    setSpawning(true);
    setLogs([]);
    setDone(false);
    setError('');

    try {
      const res = await fetch('/api/spawn', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          domain: domain.trim(),
          wp_title: wpTitle.trim() || undefined,
          admin_email: adminEmail.trim() || undefined,
        }),
      });

      const reader = res.body.getReader();
      const decoder = new TextDecoder();
      let buffer = '';

      while (true) {
        const { done: readerDone, value } = await reader.read();
        if (readerDone) break;

        buffer += decoder.decode(value, { stream: true });
        const lines = buffer.split('\n\n');
        buffer = lines.pop();

        for (const line of lines) {
          if (line.startsWith('data: ')) {
            try {
              const data = JSON.parse(line.slice(6));
              if (data.type === 'log') {
                setLogs(prev => [...prev, { type: 'stdout', text: data.message }]);
              } else if (data.type === 'error') {
                setLogs(prev => [...prev, { type: 'stderr', text: data.message }]);
              } else if (data.type === 'status') {
                setLogs(prev => [...prev, { type: 'status', text: data.message }]);
              } else if (data.type === 'done') {
                setDone(true);
                if (data.credentials) {
                  setLogs(prev => [...prev, { type: 'done', text: `✓ ${data.message}`, creds: data.credentials }]);
                } else {
                  setLogs(prev => [...prev, { type: 'done', text: data.message }]);
                }
              }
              setTimeout(() => logEndRef.current?.scrollIntoView({ behavior: 'smooth' }), 50);
            } catch {}
          }
        }
      }
    } catch (e) {
      setError(e.message);
    } finally {
      setSpawning(false);
    }
  }

  return (
    <div className="space-y-6 max-w-2xl">
      <h1 className="text-2xl font-bold">Spawn WordPress Site</h1>

      {!spawning && !done && (
        <form onSubmit={handleSpawn} className="card p-6 space-y-4">
          <div>
            <label className="block text-sm font-medium mb-1">Domain / TLD *</label>
            <input
              type="text"
              value={domain}
              onChange={(e) => setDomain(e.target.value)}
              placeholder="bobsbakery.com or shop.markethive.life"
              required
            />
            <p className="text-xs text-[#8b909c] mt-1">
              Must be a zone already in your Cloudflare account. DNS CNAMEs will be auto-created.
            </p>
          </div>
          <div>
            <label className="block text-sm font-medium mb-1">Site Title</label>
            <input
              type="text"
              value={wpTitle}
              onChange={(e) => setWpTitle(e.target.value)}
              placeholder="Bob's Bakery"
            />
          </div>
          <div>
            <label className="block text-sm font-medium mb-1">Admin Email</label>
            <input
              type="email"
              value={adminEmail}
              onChange={(e) => setAdminEmail(e.target.value)}
              placeholder="admin@bobsbakery.com"
            />
            <p className="text-xs text-[#8b909c] mt-1">
              WP admin email. Defaults to admin@{domain || 'domain'} if left blank.
            </p>
          </div>
          <button type="submit" className="btn btn-primary w-full">
            🚀 Spawn WordPress
          </button>
        </form>
      )}

      {(logs.length > 0 || spawning) && (
        <div className="card p-4">
          <div className="flex items-center justify-between mb-3">
            <h2 className="text-sm font-semibold text-[#8b909c]">Spawn Progress</h2>
            {spawning && <span className="badge badge-yellow">running...</span>}
            {done && <span className="badge badge-green">complete</span>}
          </div>
          <div className="space-y-0.5 max-h-96 overflow-y-auto">
            {logs.map((log, i) => (
              <LogLine key={i} log={log} />
            ))}
            <div ref={logEndRef} />
          </div>
          {done && (
            <div className="mt-4 flex gap-2">
              <button onClick={() => router.push('/sites')} className="btn btn-ghost">
                View All Sites
              </button>
              {domain && (
                <a
                  href={`https://${domain}`}
                  target="_blank"
                  rel="noopener noreferrer"
                  className="btn btn-primary"
                >
                  Visit Site ↗
                </a>
              )}
            </div>
          )}
        </div>
      )}

      {error && (
        <div className="card p-4 border-[#ef4444]">
          <p className="text-[#ef4444] text-sm">Error: {error}</p>
        </div>
      )}
    </div>
  );
}

function LogLine({ log }) {
  let color = '#e4e7ec';
  if (log.type === 'stderr') color = '#ef4444';
  if (log.type === 'status') color = '#3b82f6';
  if (log.type === 'done') color = '#22c55e';

  return (
    <div className="log-line" style={{ color }}>
      {log.text}
      {log.creds && (
        <div className="mt-2 ml-4 space-y-1 text-xs" style={{ color: '#8b909c' }}>
          <div>URL: <a href={`https://${log.creds.domain}`} target="_blank" rel="noopener" style={{color:'#3b82f6'}}>{log.creds.domain}</a></div>
          <div>Admin: <span style={{color:'#e4e7ec'}}>{log.creds.wp_admin_user}</span> / <span style={{color:'#e4e7ec'}}>{log.creds.wp_admin_password}</span></div>
          <div>DB: <span style={{color:'#e4e7ec'}}>{log.creds.db_name}</span> (user: {log.creds.db_user})</div>
        </div>
      )}
    </div>
  );
}
