#!/usr/bin/env bash
set -euo pipefail

# Check whether pm2_http family metrics have real samples (not only HELP/TYPE)
# Usage:
#   ./scripts/check-pm2-http-metrics.sh
#   ./scripts/check-pm2-http-metrics.sh 100.92.210.98:9988 100.101.33.66:9988

TARGETS=("$@")
if [[ ${#TARGETS[@]} -eq 0 ]]; then
  TARGETS=(
    "100.92.210.98:9988"
    "100.101.33.66:9988"
    "100.92.125.27:9988"
  )
fi

ok_count=0
warn_count=0

for target in "${TARGETS[@]}"; do
  echo "============================================================"
  echo "Target: $target"

  if ! body=$(curl -fsS --max-time 8 "http://$target/metrics"); then
    echo "❌ ERROR: tidak bisa akses endpoint /metrics"
    warn_count=$((warn_count + 1))
    continue
  fi

  has_help=false
  has_http_sample=false
  has_mean_sample=false
  has_p95_sample=false
  has_active_requests=false
  has_active_handles=false

  grep -q '^# HELP pm2_http ' <<<"$body" && has_help=true
  grep -Eq '^pm2_http\{' <<<"$body" && has_http_sample=true
  grep -Eq '^pm2_http_mean_latency\{' <<<"$body" && has_mean_sample=true
  grep -Eq '^pm2_http_p95_latency\{' <<<"$body" && has_p95_sample=true
  grep -Eq '^pm2_active_requests\{' <<<"$body" && has_active_requests=true
  grep -Eq '^pm2_active_handles\{' <<<"$body" && has_active_handles=true

  echo "- HELP/TYPE pm2_http exposed       : $has_help"
  echo "- pm2_http sample exists           : $has_http_sample"
  echo "- pm2_http_mean_latency sample     : $has_mean_sample"
  echo "- pm2_http_p95_latency sample      : $has_p95_sample"
  echo "- pm2_active_requests sample       : $has_active_requests"
  echo "- pm2_active_handles sample        : $has_active_handles"

  if $has_http_sample && $has_mean_sample && $has_p95_sample; then
    echo "✅ OK: HTTP metrics real terdeteksi"
    ok_count=$((ok_count + 1))
  else
    echo "⚠️  WARNING: HTTP metrics belum real (kemungkinan masih fallback di dashboard)"
    if $has_help && ! $has_http_sample && ! $has_mean_sample && ! $has_p95_sample; then
      echo "   - Exporter expose HELP/TYPE, tapi belum ada sample nilai HTTP."
      echo "   - Ini biasanya berarti aplikasi PM2 belum mengirim telemetry HTTP (instrumentation belum aktif)."
    fi
    if $has_active_requests || $has_active_handles; then
      echo "   - PM2 runtime metric lain sudah ada -> exporter hidup, masalah kemungkinan di telemetry HTTP app-level."
    fi
    warn_count=$((warn_count + 1))
  fi

done

echo "============================================================"
echo "Summary: OK=$ok_count | WARNING=$warn_count"

if [[ $warn_count -gt 0 ]]; then
  cat <<'EOT'

Langkah lanjut (di server aplikasi terkait):
1) Cek proses PM2 exporter dan log:
   pm2 list
   pm2 logs pm2-prometheus-exporter --lines 100

2) Pastikan app yang dimonitor memang menerima trafik HTTP pada periode observasi.

3) Aktifkan telemetry HTTP di aplikasi (app-level instrumentation) sesuai framework/service Anda,
   lalu restart app PM2 dan re-check endpoint /metrics.

4) Verifikasi dari monitoring server:
   curl -s http://TARGET:PORT/metrics | grep -E '^pm2_http\{|^pm2_http_mean_latency\{|^pm2_http_p95_latency\{'
EOT
fi
