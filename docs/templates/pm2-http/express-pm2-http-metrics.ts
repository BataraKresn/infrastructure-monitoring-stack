import io from '@pm2/io';
import type { Request, Response, NextFunction } from 'express';

/**
 * PM2 HTTP metrics template for Express.
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

const httpMeanLatency = io.metric({
  name: 'http_mean_latency',
  id: 'http_mean_latency_metric',
  value: () => {
    if (latencyWindow.length === 0) return 0;
    const sum = latencyWindow.reduce((acc, n) => acc + n, 0);
    return Number((sum / latencyWindow.length).toFixed(2));
  },
});

const httpP95Latency = io.metric({
  name: 'http_p95_latency',
  id: 'http_p95_latency_metric',
  value: () => {
    if (latencyWindow.length === 0) return 0;
    const sorted = [...latencyWindow].sort((a, b) => a - b);
    const idx = Math.min(sorted.length - 1, Math.ceil(sorted.length * 0.95) - 1);
    return Number(sorted[idx].toFixed(2));
  },
});

void httpMeanLatency;
void httpP95Latency;

function pushLatency(ms: number): void {
  latencyWindow.push(ms);
  if (latencyWindow.length > MAX_WINDOW) latencyWindow.shift();
}

export function pm2HttpMetricsMiddleware(req: Request, res: Response, next: NextFunction): void {
  const start = process.hrtime.bigint();

  res.on('finish', () => {
    const durationMs = Number(process.hrtime.bigint() - start) / 1_000_000;
    httpMeter.mark();
    pushLatency(durationMs);
  });

  next();
}

/**
 * Usage:
 *
 * import express from 'express';
 * import { pm2HttpMetricsMiddleware } from './express-pm2-http-metrics';
 *
 * const app = express();
 * app.use(pm2HttpMetricsMiddleware);
 */
