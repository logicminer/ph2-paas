import { NextResponse } from 'next/server';
import { spawn } from 'child_process';
import { insertSite, updateSiteStatus, addLog } from '@/lib/db';
import { readFileSync } from 'fs';
import { join } from 'path';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

const SPAWN_SCRIPT = process.env.SCRIPTS_DIR
  ? `${process.env.SCRIPTS_DIR}/spawn-wp.sh`
  : '/opt/ph2/scripts/spawn-wp.sh';

export async function POST(request) {
  let body;
  try {
    body = await request.json();
  } catch {
    return NextResponse.json({ error: 'Invalid JSON body' }, { status: 400 });
  }

  const { domain, wp_title, admin_email } = body;
  if (!domain) {
    return NextResponse.json({ error: 'Domain is required' }, { status: 400 });
  }

  // Build args for spawn-wp.sh
  const args = [domain];
  if (admin_email) args.push(`--admin-email=${admin_email}`);
  if (wp_title) args.push(`--wp-title=${wp_title}`);

  // Temp file for JSON credential output
  const tmpJson = `/tmp/spawn-${Date.now()}.json`;
  args.push(`--json-output=${tmpJson}`);

  // Mark as provisioning in DB
  updateSiteStatus(domain, 'provisioning');

  const encoder = new TextEncoder();
  const stream = new ReadableStream({
    start(controller) {
      const send = (data) => {
        controller.enqueue(encoder.encode(`data: ${JSON.stringify(data)}\n\n`));
      };

      send({ type: 'status', message: `Spawning WordPress for ${domain}...` });

      // Run as sudo (passwordless via sudoers entry)
      const proc = spawn('sudo', ['bash', SPAWN_SCRIPT, ...args], {
        cwd: process.env.SCRIPTS_DIR || '/opt/ph2/scripts',
      });

      proc.stdout.on('data', (data) => {
        const lines = data.toString().split('\n').filter(l => l.trim());
        lines.forEach(line => {
          // Strip ANSI color codes for clean display
          const clean = line.replace(/\x1b\[[0-9;]*m/g, '');
          addLog(domain, clean);
          send({ type: 'log', message: clean });
        });
      });

      proc.stderr.on('data', (data) => {
        const lines = data.toString().split('\n').filter(l => l.trim());
        lines.forEach(line => {
          const clean = line.replace(/\x1b\[[0-9;]*m/g, '');
          addLog(domain, clean, 'stderr');
          send({ type: 'error', message: clean });
        });
      });

      proc.on('close', (code) => {
        if (code === 0) {
          // Read the JSON credentials file
          try {
            const creds = JSON.parse(readFileSync(tmpJson, 'utf8'));
            insertSite(creds);
            send({ type: 'done', message: 'WordPress spawned successfully', credentials: creds });
          } catch (e) {
            send({ type: 'done', message: 'Spawn completed but credential capture failed' });
            updateSiteStatus(domain, 'active');
          }
        } else {
          updateSiteStatus(domain, 'error');
          send({ type: 'error', message: `Spawn failed with exit code ${code}` });
        }
        controller.close();
      });
    },
  });

  return new Response(stream, {
    headers: {
      'Content-Type': 'text/event-stream',
      'Cache-Control': 'no-cache',
      'Connection': 'keep-alive',
    },
  });
}
