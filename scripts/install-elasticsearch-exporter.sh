#!/bin/bash
# =============================================================
# install-elasticsearch-exporter.sh
# Install Elasticsearch Exporter untuk Prometheus monitoring
#
# Jalankan di server yang menjalankan Elasticsearch
# Target: baremetal-ubuntu (atau server ES lainnya)
#
# Usage:
#   chmod +x install-elasticsearch-exporter.sh
#   sudo ./install-elasticsearch-exporter.sh
#
# Opsional - set URL Elasticsearch jika bukan localhost:9200:
#   ES_URL=http://localhost:9200 sudo ./install-elasticsearch-exporter.sh
#
# Port yang dibuka: 9114 (elasticsearch_exporter)
# =============================================================

set -euo pipefail

# --- Warna output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()   { echo -e "${GREEN}[+]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
info()  { echo -e "${BLUE}[i]${NC} $1"; }

ES_EXPORTER_VERSION="1.7.0"
ES_URL="${ES_URL:-http://localhost:9200}"

# --- Cek root ---
[[ $EUID -ne 0 ]] && error "Script ini harus dijalankan sebagai root atau dengan sudo"

# --- Detect OS ---
if [[ -f /etc/os-release ]]; then
  source /etc/os-release
  OS=$ID
else
  error "Tidak dapat mendeteksi OS"
fi

log "Detected OS: $OS"
log "Elasticsearch URL: $ES_URL"

# --- Install dependencies ---
install_deps() {
  log "Installing dependencies..."
  if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
    apt-get update -qq
    apt-get install -y -qq curl wget tar gzip 2>/dev/null || true
  elif [[ "$OS" == "centos" || "$OS" == "rhel" || "$OS" == "rocky" || "$OS" == "almalinux" ]]; then
    yum install -y -q curl wget tar gzip 2>/dev/null || true
  fi
}

# =============================================================
# ELASTICSEARCH EXPORTER
# =============================================================
install_elasticsearch_exporter() {
  log "Installing Elasticsearch Exporter v${ES_EXPORTER_VERSION}..."

  if systemctl is-active --quiet elasticsearch_exporter 2>/dev/null; then
    warn "Elasticsearch Exporter sudah berjalan. Lewati instalasi."
    return 0
  fi

  # Cek apakah Elasticsearch berjalan
  if ! curl -s --max-time 5 "${ES_URL}" > /dev/null 2>&1; then
    warn "Elasticsearch tidak dapat dijangkau di ${ES_URL}"
    warn "Pastikan Elasticsearch sudah berjalan sebelum menginstall exporter"
    read -r -p "Lanjutkan instalasi? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { warn "Instalasi dibatalkan."; exit 0; }
  fi

  local ARCH="amd64"
  [[ "$(uname -m)" == "aarch64" ]] && ARCH="arm64"

  cd /tmp
  log "Downloading elasticsearch_exporter..."
  wget -q "https://github.com/prometheus-community/elasticsearch_exporter/releases/download/v${ES_EXPORTER_VERSION}/elasticsearch_exporter-${ES_EXPORTER_VERSION}.linux-${ARCH}.tar.gz" \
    -O es_exporter.tar.gz

  tar -xzf es_exporter.tar.gz
  cp "elasticsearch_exporter-${ES_EXPORTER_VERSION}.linux-${ARCH}/elasticsearch_exporter" /usr/local/bin/
  chmod +x /usr/local/bin/elasticsearch_exporter
  rm -rf "elasticsearch_exporter-${ES_EXPORTER_VERSION}.linux-${ARCH}" es_exporter.tar.gz

  useradd --no-create-home --shell /bin/false elasticsearch_exporter 2>/dev/null || true

  cat > /etc/systemd/system/elasticsearch_exporter.service <<EOF
[Unit]
Description=Elasticsearch Exporter
Documentation=https://github.com/prometheus-community/elasticsearch_exporter
After=network-online.target

[Service]
User=elasticsearch_exporter
Group=elasticsearch_exporter
Type=simple
ExecStart=/usr/local/bin/elasticsearch_exporter \\
  --es.uri=${ES_URL} \\
  --es.all \\
  --es.indices \\
  --es.indices_settings \\
  --es.shards \\
  --es.snapshots \\
  --web.listen-address=":9114" \\
  --web.telemetry-path="/metrics"
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now elasticsearch_exporter
  log "Elasticsearch Exporter installed and started on port 9114"
}

# =============================================================
# FIREWALL
# =============================================================
configure_firewall() {
  log "Configuring firewall for port 9114..."
  local MONITORING_IP="${MONITORING_SERVER_IP:-}"

  if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
    if [[ -n "$MONITORING_IP" ]]; then
      ufw allow from "$MONITORING_IP" to any port 9114 comment "elasticsearch_exporter"
      log "UFW: port 9114 dibuka untuk $MONITORING_IP"
    else
      warn "Set MONITORING_SERVER_IP untuk membatasi akses firewall"
      warn "Contoh: MONITORING_SERVER_IP=10.0.0.5 sudo ./install-elasticsearch-exporter.sh"
      ufw allow 9114/tcp comment "elasticsearch_exporter"
      warn "Port 9114 dibuka untuk semua IP"
    fi
  elif command -v firewall-cmd &>/dev/null; then
    firewall-cmd --permanent --add-port=9114/tcp
    firewall-cmd --reload
    log "Firewalld: port 9114 dibuka"
  else
    warn "UFW/Firewalld tidak ditemukan. Buka port 9114 secara manual."
  fi
}

# =============================================================
# VERIFIKASI
# =============================================================
verify_installation() {
  echo ""
  echo "======================================"
  echo " STATUS ELASTICSEARCH EXPORTER"
  echo "======================================"

  sleep 2

  if curl -s --max-time 5 "http://localhost:9114/metrics" > /dev/null 2>&1; then
    echo -e "  ${GREEN}✓${NC} Elasticsearch Exporter (port 9114) - RUNNING"
  else
    echo -e "  ${RED}✗${NC} Elasticsearch Exporter (port 9114) - NOT RUNNING"
    warn "Cek logs: journalctl -u elasticsearch_exporter -n 30"
  fi

  echo "======================================"
  echo ""
  info "Tambahkan scrape config berikut ke prometheus.yml di monitoring server:"
  echo ""
  echo "  - job_name: 'elasticsearch'"
  echo "    static_configs:"
  echo "      - targets: ['$(hostname -I | awk '{print $1}'):9114']"
  echo "        labels:"
  echo "          instance: '$(hostname)'"
  echo ""
}

# =============================================================
# MAIN
# =============================================================
main() {
  echo ""
  echo "============================================="
  echo "  Elasticsearch Exporter Installer"
  echo "  Server: $(hostname)"
  echo "  ES URL: $ES_URL"
  echo "============================================="
  echo ""

  install_deps
  install_elasticsearch_exporter
  configure_firewall
  verify_installation

  log "Selesai! Elasticsearch Exporter siap di-scrape oleh Prometheus."
}

main "$@"
