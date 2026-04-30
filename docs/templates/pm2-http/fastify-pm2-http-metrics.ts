import io from '@pm2/io';
import type { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify';

/**
 * PM2 HTTP metrics template for Fastify.
 *
 * Expected exporter outputs (with pm2-prometheus-exporter):
 * - pm2_http
 * - pm2_http_mean_latency
 * - pm2_http_p95_latency
 */

const httpMeter = io.meter({
  name: 'http',
  id: 'http_meter',
});

const latencyWindow: number[] = [];
const MAX_WINDOW = 2000;

io.metric({
  name: 'http_mean_latency',
  id: 'http_mean_latency_metric',
  value: () => {
    if (latencyWindow.length === 0) return 0;
    const sum = latencyWindow.reduce((acc, n) => acc + n, 0);
    return Number((sum / latencyWindow.length).toFixed(2));
  },
});

io.metric({
  name: 'http_p95_latency',
  id: 'http_p95_latency_metric',
  value: () => {
    if (latencyWindow.length === 0) return 0;
    const sorted = [...latencyWindow].sort((a, b) => a - b);
    const idx = Math.min(sorted.length - 1, Math.ceil(sorted.length * 0.95) - 1);
    return Number(sorted[idx].toFixed(2));
  },
});

function pushLatency(ms: number): void {
  latencyWindow.push(ms);
  if (latencyWindow.length > MAX_WINDOW) latencyWindow.shift();
}

export function registerPm2HttpMetrics(app: FastifyInstance): void {
  app.addHook('onRequest', async (req: FastifyRequest) => {
    (req as FastifyRequest & { _startAt?: bigint })._startAt = process.hrtime.bigint();
  });

  app.addHook('onResponse', async (req: FastifyRequest, _reply: FastifyReply) => {
    const start = (req as FastifyRequest & { _startAt?: bigint })._startAt;
    if (!start) return;

    const durationMs = Number(process.hrtime.bigint() - start) / 1_000_000;
    httpMeter.mark();
    pushLatency(durationMs);
  });
}

/**
 * Usage:
 *
 * const app = Fastify();
 * registerPm2HttpMetrics(app);
 */
