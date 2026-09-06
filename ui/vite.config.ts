import { readFile } from 'node:fs/promises';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { defineConfig, type Plugin } from 'vite';
import react from '@vitejs/plugin-react';
import { projectDiagnostics, projectMaintenance, projectNetwork } from './src/api/managementProjection';
import type { DiagnosticsSnapshot, MaintenanceSnapshot, NetworkSnapshot } from './src/types';

const execFileAsync = promisify(execFile);
const SAFE_SSH_TARGET = /^[A-Za-z0-9._-]+$/;

function sendJson(response: import('node:http').ServerResponse, status: number, payload: unknown) {
  response.statusCode = status;
  response.setHeader('Content-Type', 'application/json');
  response.setHeader('Cache-Control', 'no-store');
  response.end(JSON.stringify(payload));
}

async function readRemote(target: string, method: 'status' | 'events' | 'connections' | 'config_get' | 'components_get' | 'operation_get' | 'network_get' | 'maintenance_get' | 'diagnostics_get') {
  const { stdout } = await execFileAsync('ssh', [
    '-o', 'BatchMode=yes',
    '-o', 'PasswordAuthentication=no',
    '-o', 'ConnectTimeout=8',
    target,
    `ubus -S call opl-netfleet ${method}`,
  ], { timeout: 20_000, maxBuffer: 4 * 1024 * 1024 });
  const payload = JSON.parse(stdout) as { ok?: boolean; error?: string; result?: unknown };
  if (payload.ok !== true || payload.result == null) throw new Error(payload.error || `${method}_read_failed`);
  return payload.result;
}

function liveBridgePlugin(target?: string, targetLabel = '设备'): Plugin {
  const validTarget = target && SAFE_SSH_TARGET.test(target) ? target : null;
  return {
    name: 'netfleet-live-readonly-bridge',
    configureServer(server) {
      server.middlewares.use('/__netfleet_live/meta', (_request, response) => {
        sendJson(response, 200, {
          available: validTarget !== null,
          source: validTarget ? {
            mode: 'live', label: '设备实时只读', target_label: targetLabel, read_only: true,
          } : null,
        });
      });
      server.middlewares.use('/__netfleet_live/snapshot', async (request, response) => {
        if (request.method !== 'GET') return sendJson(response, 405, { error: 'method_not_allowed' });
        if (!validTarget) return sendJson(response, 404, { error: 'live_target_not_configured' });

        const started = Date.now();
        let status: unknown;
        let events: unknown;
        let config: unknown;
        const errors: { status?: string; events?: string; config?: string } = {};
        try {
          status = await readRemote(validTarget, 'status');
        } catch {
          errors.status = '设备状态读取失败';
        }
        try {
          events = await readRemote(validTarget, 'events');
        } catch {
          errors.events = '设备事件读取失败';
        }
        try {
          config = await readRemote(validTarget, 'config_get');
        } catch {
          errors.config = '设备配置读取失败';
        }
        sendJson(response, status || events || config ? 200 : 502, {
          status,
          events,
          config,
          errors,
          source: {
            mode: 'live',
            label: '设备实时只读',
            target_label: targetLabel,
            read_only: true,
            connected: Boolean(status || events),
            fetched_at: Math.floor(Date.now() / 1000),
            duration_ms: Date.now() - started,
          },
        });
      });
      server.middlewares.use('/__netfleet_live/connections', async (request, response) => {
        if (request.method !== 'GET') return sendJson(response, 405, { error: 'method_not_allowed' });
        if (!validTarget) return sendJson(response, 404, { error: 'live_target_not_configured' });
        try {
          sendJson(response, 200, await readRemote(validTarget, 'connections'));
        } catch {
          sendJson(response, 502, { error: 'connections_read_failed' });
        }
      });
      for (const [path, method] of [['components', 'components_get'], ['operation', 'operation_get']] as const) {
        server.middlewares.use(`/__netfleet_live/${path}`, async (request, response) => {
          if (request.method !== 'GET') return sendJson(response, 405, { error: 'method_not_allowed' });
          if (!validTarget) return sendJson(response, 404, { error: 'live_target_not_configured' });
          try {
            sendJson(response, 200, await readRemote(validTarget, method));
          } catch {
            sendJson(response, 502, { error: `${path}_read_unavailable` });
          }
        });
      }
      const managementReads = {
        network: async () => projectNetwork(await readRemote(validTarget!, 'network_get') as NetworkSnapshot),
        maintenance: async () => projectMaintenance(await readRemote(validTarget!, 'maintenance_get') as MaintenanceSnapshot),
        diagnostics: async () => projectDiagnostics(await readRemote(validTarget!, 'diagnostics_get') as DiagnosticsSnapshot),
      };
      for (const [path, read] of Object.entries(managementReads)) {
        server.middlewares.use(`/__netfleet_live/${path}`, async (request, response) => {
          if (request.method !== 'GET') return sendJson(response, 405, { error: 'method_not_allowed' });
          if (!validTarget) return sendJson(response, 404, { error: 'live_target_not_configured' });
          try { sendJson(response, 200, await read()); }
          catch { sendJson(response, 502, { error: `${path}_read_unavailable` }); }
        });
      }
    },
  };
}

function privateFixturePlugin(path?: string): Plugin {
  return {
    name: 'netfleet-private-fixture',
    configureServer(server) {
      server.middlewares.use('/__netfleet_fixture', async (_request, response) => {
        if (!path) {
          response.statusCode = 204;
          response.end();
          return;
        }
        try {
          const parsed = JSON.parse(await readFile(path, 'utf8')) as { status?: unknown; events?: unknown };
          if (!parsed.status || !parsed.events) throw new Error('fixture_requires_status_and_events');
          response.setHeader('Content-Type', 'application/json');
          response.setHeader('Cache-Control', 'no-store');
          response.end(JSON.stringify(parsed));
        } catch (error) {
          response.statusCode = 422;
          response.end(JSON.stringify({ error: error instanceof Error ? error.message : 'fixture_unreadable' }));
        }
      });
    },
  };
}

export default defineConfig(({ command }) => {
  return {
    plugins: [react(),
      liveBridgePlugin(process.env.NETFLEET_UI_TARGET, process.env.NETFLEET_UI_TARGET_LABEL || '设备'),
      privateFixturePlugin(process.env.NETFLEET_UI_FIXTURE),
    ],
    define: {
      'process.env.NODE_ENV': JSON.stringify(command === 'build' ? 'production' : 'development'),
    },
    base: './',
    server: {
      port: 4173,
      strictPort: false,
    },
    build: {
      outDir: 'dist',
    },
  };
});
