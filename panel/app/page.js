'use client';

import { useEffect, useState } from 'react';
import Link from 'next/link';

export default function Dashboard() {
  const [health, setHealth] = useState(null);
  const [sites, setSites] = useState([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    async function load() {
      try {
        const [hRes, sRes] = await Promise.all([
          fetch('/api/health'),
          fetch('/api/sites'),
        ]);
        setHealth(await hRes.json());
        const sData = await sRes.json();
        setSites(sData.sites || []);
      } catch (e) {
        console.error(e);
      } finally {
        setLoading(false);
      }
    }
    load();
    const interval = setInterval(load, 15000);
    return () => clearInterval(interval);
  }, []);

  if (loading) {
    return <div className="text-[#8b909c]">Loading...</div>;
  }

  const wpSites = sites.filter(s => s.type === 'wordpress');
  const nodeSites = sites.filter(s => s.type === 'nextjs');

  return (
    <div className="space-y-6">
      <h1 className="text-2xl font-bold">Dashboard</h1>

      {/* Quick stats */}
      <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
        <StatCard label="WP Sites" value={wpSites.length} icon="🌐" />
        <StatCard label="Node Apps" value={nodeSites.length} icon="⚡" />
        <StatCard
          label="Memory"
          value={health?.memory ? `${health.memory.used} / ${health.memory.total}` : '—'}
          sub={health?.memory?.available ? `${health.memory.available} avail` : ''}
          icon="💾"
        />
        <StatCard
          label="Disk"
          value={health?.disk ? `${health.disk.used} / ${health.disk.total}` : '—'}
          sub={health?.disk?.percent || ''}
          icon="📀"
        />
      </div>

      {/* Memory tier detail */}
      {health?.swapDevices && (
        <div className="card p-4">
          <h2 className="text-sm font-semibold text-[#8b909c] mb-3">Memory Tier (Swap Devices)</h2>
          <div className="space-y-2">
            {health.swapDevices.map((sd, i) => (
              <div key={i} className="flex items-center justify-between text-sm">
                <div className="flex items-center gap-2">
                  <span className="badge badge-blue">prio {sd.prio}</span>
                  <span className="font-mono">{sd.name}</span>
                  <span className="text-[#8b909c]">{sd.type}</span>
                </div>
                <div className="text-[#8b909c]">
                  {sd.used} / {sd.size}
                </div>
              </div>
            ))}
          </div>
        </div>
      )}

      {/* Containers */}
      {health?.containers?.length > 0 && (
        <div className="card p-4">
          <h2 className="text-sm font-semibold text-[#8b909c] mb-3">Running Containers</h2>
          <div className="grid grid-cols-2 md:grid-cols-3 gap-2">
            {health.containers.map((c, i) => (
              <div key={i} className="flex items-center justify-between text-sm bg-[#0f1117] rounded-lg px-3 py-2">
                <span className="font-mono">{c.name}</span>
                <span className={c.status.includes('Up') ? 'text-[#22c55e]' : 'text-[#ef4444]'}>
                  {c.status.split(' ')[0]}
                </span>
              </div>
            ))}
          </div>
        </div>
      )}

      {/* System info */}
      {health?.cpu && (
        <div className="card p-4">
          <h2 className="text-sm font-semibold text-[#8b909c] mb-2">System</h2>
          <div className="text-sm space-y-1 text-[#8b909c]">
            <div>CPU: <span className="text-[#e4e7ec]">{health.cpu.model} ({health.cpu.cores} cores)</span></div>
            <div>Uptime: <span className="text-[#e4e7ec] font-mono text-xs">{health.uptime}</span></div>
          </div>
        </div>
      )}

      <div className="flex gap-3">
        <Link href="/sites" className="btn btn-ghost">View All Sites</Link>
        <Link href="/sites/new" className="btn btn-primary">+ Spawn WordPress</Link>
      </div>
    </div>
  );
}

function StatCard({ label, value, sub, icon }) {
  return (
    <div className="card p-4">
      <div className="flex items-center gap-2 text-[#8b909c] text-sm mb-1">
        <span>{icon}</span>
        {label}
      </div>
      <div className="text-xl font-bold">{value}</div>
      {sub && <div className="text-xs text-[#8b909c] mt-1">{sub}</div>}
    </div>
  );
}
