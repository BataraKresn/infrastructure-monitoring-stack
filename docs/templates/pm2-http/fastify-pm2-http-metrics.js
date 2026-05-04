'use strict';

const io = require('@pm2/io');

/**
 * PM2 HTTP metrics hooks for Fastify (JavaScript).
 *
 * Expected exporter outputs (with pm2-prometheus-exporter):
 * - pm2_http
 * - pm2_http_mean_latency
 * - pm2_http_p95_latency
 *
 * Usage:
 *   const { registerPm2HttpMetrics } = require('./fastify-pm2-http-metrics');
 *   registerPm2HttpMetrics(app);
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
 * @param {import('fastify').FastifyInstance} app
 */
function registerPm2HttpMetrics(app) {
  app.addHook('onRequest', async (req) => {
    req._startAt = process.hrtime.bigint();
  });

  app.addHook('onResponse', async (req) => {
    if (!req._startAt) return;
    const durationMs = Number(process.hrtime.bigint() - req._startAt) / 1_000_000;
    httpMeter.mark();
    pushLatency(durationMs);
  });
}

module.exports = { registerPm2HttpMetrics };
