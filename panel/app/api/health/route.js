import { NextResponse } from 'next/server';
import { execSync } from 'child_process';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export async function GET() {
  const health = {};

  try {
    // Memory (including zram + swap tier)
    const memInfo = execSync("free -h --si", { encoding: 'utf8' });
    const lines = memInfo.split('\n');
    const memLine = lines[1].split(/\s+/);
    const swapLine = lines.find(l => l.startsWith('Swap'))?.split(/\s+/);

    health.memory = {
      total: memLine[1],
      used: memLine[2],
      free: memLine[3],
      shared: memLine[4],
      cache: memLine[5],
      available: memLine[6],
    };

    // Swap shows total across zram + disk swap
    if (swapLine) {
      health.swap = {
        total: swapLine[1],
        used: swapLine[2],
        free: swapLine[3],
      };
    }

    // zram details
    try {
      const swapShow = execSync("swapon --show --noheadings --output=NAME,TYPE,SIZE,USED,PRIO", { encoding: 'utf8' });
      health.swapDevices = swapShow.trim().split('\n').map(l => {
        const parts = l.trim().split(/\s+/);
        return { name: parts[0], type: parts[1], size: parts[2], used: parts[3], prio: parts[4] };
      });
    } catch {}

    // Disk
    const df = execSync("df -h / --output=size,used,avail,pcent --noheadlines", { encoding: 'utf8' });
    const dfParts = df.trim().split(/\s+/);
    health.disk = {
      total: dfParts[0],
      used: dfParts[1],
      avail: dfParts[2],
      percent: dfParts[3],
    };

    // Load average
    const uptime = execSync("uptime", { encoding: 'utf8' }).trim();
    health.uptime = uptime;

    // Container count (via docker ps — requires docker socket or sudo)
    try {
      const containers = execSync("sudo docker ps --format '{{.Names}} {{.Status}}'", { encoding: 'utf8' });
      health.containers = containers.trim().split('\n').filter(l => l).map(l => {
        const parts = l.split(' ');
        return { name: parts[0], status: parts.slice(1).join(' ') };
      });
    } catch {
      health.containers = [];
    }

    // CPU info
    try {
      const cpuModel = execSync("lscpu | grep 'Model name' | sed 's/Model name:.*: //' || true", { encoding: 'utf8' }).trim();
      const cpuCores = execSync("nproc", { encoding: 'utf8' }).trim();
      health.cpu = { model: cpuModel, cores: cpuCores };
    } catch {}

    health.status = 'ok';
    health.timestamp = new Date().toISOString();
  } catch (e) {
    health.status = 'error';
    health.error = e.message;
  }

  return NextResponse.json(health);
}
