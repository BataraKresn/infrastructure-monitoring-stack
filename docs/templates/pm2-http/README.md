# PM2 HTTP Instrumentation Templates (Express / Nest / Fastify)

Template ini membantu aplikasi PM2 mengirim telemetry HTTP agar `pm2-prometheus-exporter` bisa mengekspor metrik berikut:

- `pm2_http`
- `pm2_http_mean_latency`
- `pm2_http_p95_latency`

## 1) Dependency minimal

Di repo aplikasi target:

- `@pm2/io`

## 2) Pilih template sesuai stack

| Framework | TypeScript | JavaScript (non-TS) |
|-----------|-----------|---------------------|
| Express   | `express-pm2-http-metrics.ts` | `express-pm2-http-metrics.js` |
| NestJS    | `nest-pm2-http.interceptor.ts` | `nest-pm2-http.interceptor.js` |
| Fastify   | `fastify-pm2-http-metrics.ts` | `fastify-pm2-http-metrics.js` |

> **Catatan NestJS JS**: Karena decorator `@Injectable()` butuh transpiler, versi JS menggunakan class biasa.
> Daftarkan langsung ke `app.useGlobalInterceptors(new Pm2HttpMetricsInterceptor())` di `main.js`.

## 3) Tempel + register di startup app

Pastikan hook/interceptor dipasang sekali saat app bootstrap.

## 4) Restart app PM2

Setelah deploy:

- restart aplikasi PM2
- restart `pm2-prometheus-exporter` (jika perlu)

## 5) Verifikasi dari monitoring server

Gunakan checker:

`./scripts/check-pm2-http-metrics.sh <TARGET_IP:PORT>`

Jika sukses, status akan menunjukkan sample untuk:

- `pm2_http`
- `pm2_http_mean_latency`
- `pm2_http_p95_latency`

## Catatan operasional

- Nilai mean/p95 di template menggunakan rolling window sederhana in-memory.
- Jika traffic nol, nilai bisa 0 (normal).
- Untuk multi-instance PM2 (cluster), metrik akan per instance process.
