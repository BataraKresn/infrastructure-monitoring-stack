'use strict';

const io = require('@pm2/io');

/**
 * PM2 HTTP metrics middleware for Express (JavaScript).
 *
 * Expected exporter outputs (with pm2-prometheus-exporter):
 * - pm2_http
 * - pm2_http_mean_latency
 * - pm2_http_p95_latency
 *
 * Usage:
 *   const { pm2HttpMetricsMiddleware } = require('./express-pm2-http-metrics');
 *   app.use(pm2HttpMetricsMiddleware);
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

/**
 * @param {import('express').Request} req
 * @param {import('express').Response} res
 * @param {import('express').NextFunction} next
 */
function pm2HttpMetricsMiddleware(req, res, next) {
  const start = process.hrtime.bigint();

  res.on('finish', () => {
    const durationMs = Number(process.hrtime.bigint() - start) / 1_000_000;
    httpMeter.mark();
    pushLatency(durationMs);
  });

  next();
}

module.exports = { pm2HttpMetricsMiddleware };
