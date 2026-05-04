'use strict';

const io = require('@pm2/io');
const { tap } = require('rxjs');

// Note: @Injectable() decorator tidak bisa dipakai di plain JS tanpa Babel/swc.
// File ini menggunakan class biasa — daftarkan langsung ke useGlobalInterceptors().

/**
 * PM2 HTTP metrics interceptor for NestJS (JavaScript).
 *
 * Expected exporter outputs (with pm2-prometheus-exporter):
 * - pm2_http
 * - pm2_http_mean_latency
 * - pm2_http_p95_latency
 *
 * Usage in main.js:
 *   const { Pm2HttpMetricsInterceptor } = require('./nest-pm2-http.interceptor');
 *   app.useGlobalInterceptors(new Pm2HttpMetricsInterceptor());
 */

const httpMeter = io.meter({
  name: 'http',
  id: 'http_meter',
});

/** @type {number[]} */
const latencyWindow = [];
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

/**
 * @param {number} ms
 */
function pushLatency(ms) {
  latencyWindow.push(ms);
  if (latencyWindow.length > MAX_WINDOW) latencyWindow.shift();
}

class Pm2HttpMetricsInterceptor {
  intercept(context, next) {
    if (context.getType() !== 'http') return next.handle();

    const start = process.hrtime.bigint();

    return next.handle().pipe(
      tap({
        next: () => {
          const durationMs = Number(process.hrtime.bigint() - start) / 1_000_000;
          httpMeter.mark();
          pushLatency(durationMs);
        },
        error: () => {
          const durationMs = Number(process.hrtime.bigint() - start) / 1_000_000;
          httpMeter.mark();
          pushLatency(durationMs);
        },
      }),
    );
  }
}

module.exports = { Pm2HttpMetricsInterceptor };
