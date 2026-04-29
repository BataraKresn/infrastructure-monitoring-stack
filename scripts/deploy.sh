#!/bin/bash
# Quick deploy script - jalankan dari monitoring server
# Usage: ./scripts/deploy.sh

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log() { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }

cd "$(dirname "$0")/.."

# Validasi config Prometheus
log "Validating Prometheus config..."
docker run --rm \
  -v "$(pwd)/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro" \
  -v "$(pwd)/prometheus/rules:/etc/prometheus/rules:ro" \
  prom/prometheus:v2.51.2 \
  --config.file=/etc/prometheus/prometheus.yml \
  --check-config

log "Config valid!"

# Deploy / restart stack
if docker compose ps | grep -q "running"; then
  log "Stack sudah berjalan, melakukan reload config..."
  docker compose restart prometheus alertmanager
else
  log "Menjalankan stack monitoring..."
  docker compose up -d
fi

# Tunggu sebentar
sleep 5

# Status
log "Status services:"
docker compose ps

echo ""
warn "Akses:"
warn "  Grafana      → http://$(hostname -I | awk '{print $1}'):3000"
warn "  Prometheus   → http://$(hostname -I | awk '{print $1}'):9090"
warn "  Alertmanager → http://$(hostname -I | awk '{print $1}'):9093"
