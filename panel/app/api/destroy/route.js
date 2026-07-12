import { NextResponse } from 'next/server';
import { spawn } from 'child_process';
import { deleteSite, updateSiteStatus, addLog } from '@/lib/db';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

const DESTROY_SCRIPT = process.env.SCRIPTS_DIR
  ? `${process.env.SCRIPTS_DIR}/destroy-wp.sh`
  : '/opt/ph2/scripts/destroy-wp.sh';

export async function POST(request) {
  let body;
  try {
    body = await request.json();
  } catch {
    return NextResponse.json({ error: 'Invalid JSON body' }, { status: 400 });
  }

  const { domain } = body;
  if (!domain) {
    return NextResponse.json({ error: 'Domain is required' }, { status: 400 });
  }

  updateSiteStatus(domain, 'destroying');

  const encoder = new TextEncoder();
  const stream = new ReadableStream({
    start(controller) {
      const send = (data) => {
        controller.enqueue(encoder.encode(`data: ${JSON.stringify(data)}\n\n`));
      };

      send({ type: 'status', message: `Destroying ${domain}...` });

      const proc = spawn('sudo', ['bash', DESTROY_SCRIPT, domain], {
        cwd: process.env.SCRIPTS_DIR || '/opt/ph2/scripts',
      });

      proc.stdout.on('data', (data) => {
        data.toString().split('\n').filter(l => l.trim()).forEach(line => {
          const clean = line.replace(/\x1b\[[0-9;]*m/g, '');
          addLog(domain, `[destroy] ${clean}`);
          send({ type: 'log', message: clean });
        });
      });

      proc.stderr.on('data', (data) => {
        data.toString().split('\n').filter(l => l.trim()).forEach(line => {
          const clean = line.replace(/\x1b\[[0-9;]*m/g, '');
          send({ type: 'error', message: clean });
        });
      });

      proc.on('close', (code) => {
        if (code === 0) {
          deleteSite(domain);
          send({ type: 'done', message: `${domain} destroyed successfully` });
        } else {
          updateSiteStatus(domain, 'error');
          send({ type: 'error', message: `Destroy failed with exit code ${code}` });
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
