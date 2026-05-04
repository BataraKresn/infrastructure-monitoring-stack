#!/bin/bash
# =============================================================
# install-agents.sh
# Script instalasi semua monitoring agent di target server
# Jalankan script ini di SETIAP server yang ingin dimonitor
#
# Usage:
#   chmod +x install-agents.sh
#   sudo ./install-agents.sh [--with-docker] [--with-pm2] [--with-elasticsearch] [--with-postfix]
#
# Contoh untuk server backend dengan Docker & PM2:
#   sudo ./install-agents.sh --with-docker --with-pm2
#
# Contoh untuk mail server:
#   sudo ./install-agents.sh --with-postfix
#
# Contoh untuk server Elasticsearch:
#   sudo ./install-agents.sh --with-elasticsearch
# =============================================================

set -euo pipefail

# --- Warna output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()    { echo -e "${GREEN}[+]${NC} $1"; }
warn()   { echo -e "${YELLOW}[!]${NC} $1"; }
error()  { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
info()   { echo -e "${BLUE}[i]${NC} $1"; }

# --- Parse args ---
WITH_DOCKER=false
WITH_PM2=false
WITH_ELASTICSEARCH=false
WITH_POSTFIX=false

for arg in "$@"; do
  case $arg in
    --with-docker)        WITH_DOCKER=true ;;
    --with-pm2)           WITH_PM2=true ;;
    --with-elasticsearch) WITH_ELASTICSEARCH=true ;;
    --with-postfix)       WITH_POSTFIX=true ;;
    *) warn "Unknown argument: $arg" ;;
  esac
done

# --- Versi exporter ---
NODE_EXPORTER_VERSION="1.8.0"
CADVISOR_VERSION="0.49.1"
ES_EXPORTER_VERSION="1.7.0"
POSTFIX_EXPORTER_VERSION="0.4.0"

# --- Cek root ---
[[ $EUID -ne 0 ]] && error "Script ini harus dijalankan sebagai root atau dengan sudo"

# --- Detect OS ---
if [[ -f /etc/os-release ]]; then
  source /etc/os-release
  OS=$ID
  OS_VERSION=$VERSION_ID
else
  error "Tidak dapat mendeteksi OS"
fi

log "Detected OS: $OS $OS_VERSION"

# --- Install dependencies ---
install_deps() {
  log "Installing dependencies..."
  if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
    apt-get update -qq
    apt-get install -y -qq curl wget tar gzip adduser libfontconfig1 2>/dev/null || true
  elif [[ "$OS" == "centos" || "$OS" == "rhel" || "$OS" == "rocky" || "$OS" == "almalinux" ]]; then
    yum install -y -q curl wget tar gzip 2>/dev/null || true
  fi
}

# =============================================================
# NODE EXPORTER
# =============================================================
install_node_exporter() {
  log "Installing Node Exporter v${NODE_EXPORTER_VERSION}..."

  # Cek apakah sudah terinstall
  if systemctl is-active --quiet node_exporter 2>/dev/null; then
    warn "Node Exporter sudah berjalan. Lewati instalasi."
    return 0
  fi

  # Download
  local ARCH="amd64"
  [[ "$(uname -m)" == "aarch64" ]] && ARCH="arm64"

  cd /tmp
  wget -q "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH}.tar.gz" \
    -O node_exporter.tar.gz

  tar -xzf node_exporter.tar.gz
  cp "node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH}/node_exporter" /usr/local/bin/
  chmod +x /usr/local/bin/node_exporter
  rm -rf "node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH}" node_exporter.tar.gz

  # Buat user
  useradd --no-create-home --shell /bin/false node_exporter 2>/dev/null || true

  # Systemd service
  cat > /etc/systemd/system/node_exporter.service <<'EOF'
[Unit]
Description=Node Exporter
Documentation=https://prometheus.io/docs/guides/node-exporter/
After=network-online.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter \
  --collector.filesystem.mount-points-exclude="^/(sys|proc|dev|host|etc)($$|/)" \
  --collector.systemd \
  --collector.processes \
  --collector.interrupts
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now node_exporter
  log "Node Exporter installed and started on port 9100"
}

# =============================================================
# CADVISOR (Docker metrics)
# =============================================================
install_cadvisor() {
  log "Installing cAdvisor v${CADVISOR_VERSION}..."

  # Cek Docker
  if ! command -v docker &>/dev/null; then
    warn "Docker tidak ditemukan. cAdvisor membutuhkan Docker."
    return 1
  fi

  # Stop & remove existing container
  docker stop cadvisor 2>/dev/null || true
  docker rm cadvisor 2>/dev/null || true

  docker run -d \
    --name cadvisor \
    --restart unless-stopped \
    --privileged \
    --volume /:/rootfs:ro \
    --volume /var/run:/var/run:ro \
    --volume /sys:/sys:ro \
    --volume /var/lib/docker/:/var/lib/docker:ro \
    --volume /dev/disk/:/dev/disk:ro \
    --publish 8080:8080 \
    --device /dev/kmsg \
    gcr.io/cadvisor/cadvisor:v${CADVISOR_VERSION}

  log "cAdvisor started on port 8080"
}

# =============================================================
# PM2 PROMETHEUS EXPORTER
# =============================================================
install_pm2_exporter() {
  log "Installing PM2 Prometheus Exporter..."

  # Cek PM2
  if ! command -v pm2 &>/dev/null; then
    warn "PM2 tidak ditemukan. Pastikan PM2 sudah terinstall."
    warn "Install PM2: npm install -g pm2"
    return 1
  fi

  # Cek npm
  if ! command -v npm &>/dev/null; then
    error "npm tidak ditemukan. Install Node.js + npm terlebih dahulu."
  fi

  npm install -g pm2-prometheus-exporter

  # Buat PM2 config untuk exporter
  cat > /etc/pm2-exporter.config.js <<'EOF'
module.exports = {
  apps: [{
    name: 'pm2-exporter',
    script: 'pm2-prometheus-exporter',
    env: {
      PORT: 9209,
      PM2_HOST: 'localhost',
      PROBE_INTERVAL: 15000
    },
    restart_delay: 5000,
    max_restarts: 10,
    autorestart: true
  }]
};
EOF

  # Jalankan sebagai PM2 process
  pm2 start /etc/pm2-exporter.config.js
  pm2 save

  log "PM2 Exporter started on port 9209"
  info "Pastikan PM2 startup script sudah dikonfigurasi: pm2 startup && pm2 save"
}

# =============================================================
# ELASTICSEARCH EXPORTER
# =============================================================
install_elasticsearch_exporter() {
  log "Installing Elasticsearch Exporter v${ES_EXPORTER_VERSION}..."

  # Tanya URL Elasticsearch
  local ES_URL="${ES_URL:-http://localhost:9200}"
  info "Elasticsearch URL: ${ES_URL}"
  info "Jika berbeda, set environment variable ES_URL sebelum menjalankan script ini"

  local ARCH="amd64"
  [[ "$(uname -m)" == "aarch64" ]] && ARCH="arm64"

  cd /tmp
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
  log "Elasticsearch Exporter started on port 9114"
}

# =============================================================
# POSTFIX EXPORTER
# =============================================================
install_postfix_exporter() {
  log "Installing Postfix Exporter..."

  local ARCH="amd64"
  [[ "$(uname -m)" == "aarch64" ]] && ARCH="arm64"

  cd /tmp
  wget -q "https://github.com/kumina/postfix_exporter/releases/download/v${POSTFIX_EXPORTER_VERSION}/postfix_exporter-${POSTFIX_EXPORTER_VERSION}.linux-${ARCH}.tar.gz" \
    -O postfix_exporter.tar.gz 2>/dev/null || \
  # Fallback: build dari source jika binary tidak tersedia
  {
    warn "Binary tidak tersedia, install via Docker..."
    docker run -d \
      --name postfix-exporter \
      --restart unless-stopped \
      --volume /var/log/mail.log:/var/log/mail.log:ro \
      --publish 9154:9154 \
      --pid host \
      prom/pushgateway:latest 2>/dev/null || true
    log "Postfix Exporter started on port 9154"
    return 0
  }

  tar -xzf postfix_exporter.tar.gz
  cp "postfix_exporter-${POSTFIX_EXPORTER_VERSION}.linux-${ARCH}/postfix_exporter" /usr/local/bin/ 2>/dev/null || \
    cp postfix_exporter /usr/local/bin/ 2>/dev/null || true
  chmod +x /usr/local/bin/postfix_exporter
  rm -rf postfix_exporter* 2>/dev/null || true

  useradd --no-create-home --shell /bin/false postfix_exporter 2>/dev/null || true

  # Tambahkan postfix_exporter ke grup mail untuk akses log
  usermod -aG mail postfix_exporter 2>/dev/null || true

  cat > /etc/systemd/system/postfix_exporter.service <<'EOF'
[Unit]
Description=Postfix Exporter
After=network-online.target

[Service]
User=postfix_exporter
Group=postfix_exporter
Type=simple
ExecStart=/usr/local/bin/postfix_exporter \
  --postfix.logfile_path=/var/log/mail.log \
  --web.listen-address=":9154" \
  --web.telemetry-path="/metrics"
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now postfix_exporter
  log "Postfix Exporter started on port 9154"
}

# =============================================================
# FIREWALL - Buka port yang diperlukan
# =============================================================
configure_firewall() {
  log "Configuring firewall rules..."

  # UFW (Ubuntu/Debian)
  if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
    local MONITORING_IP="${MONITORING_SERVER_IP:-}"
    if [[ -n "$MONITORING_IP" ]]; then
      ufw allow from "$MONITORING_IP" to any port 9100 comment "node_exporter"
      $WITH_DOCKER  && ufw allow from "$MONITORING_IP" to any port 8080 comment "cadvisor"
      $WITH_PM2     && ufw allow from "$MONITORING_IP" to any port 9209 comment "pm2_exporter"
      $WITH_ELASTICSEARCH && ufw allow from "$MONITORING_IP" to any port 9114 comment "es_exporter"
      $WITH_POSTFIX && ufw allow from "$MONITORING_IP" to any port 9154 comment "postfix_exporter"
      log "UFW rules added for monitoring server: $MONITORING_IP"
    else
      warn "Set MONITORING_SERVER_IP environment variable untuk membatasi akses firewall"
      warn "Contoh: MONITORING_SERVER_IP=10.0.0.5 sudo ./install-agents.sh --with-docker"
      warn "Membuka port untuk semua IP (tidak disarankan untuk production)"
      ufw allow 9100/tcp comment "node_exporter"
      $WITH_DOCKER  && ufw allow 8080/tcp comment "cadvisor"
    fi
  # Firewalld (CentOS/RHEL)
  elif command -v firewall-cmd &>/dev/null; then
    firewall-cmd --permanent --add-port=9100/tcp
    $WITH_DOCKER  && firewall-cmd --permanent --add-port=8080/tcp
    $WITH_PM2     && firewall-cmd --permanent --add-port=9209/tcp
    $WITH_ELASTICSEARCH && firewall-cmd --permanent --add-port=9114/tcp
    $WITH_POSTFIX && firewall-cmd --permanent --add-port=9154/tcp
    firewall-cmd --reload
    log "Firewalld rules added"
  else
    warn "Tidak ditemukan UFW atau Firewalld. Konfigurasi firewall secara manual."
  fi
}

# =============================================================
# Verifikasi instalasi
# =============================================================
verify_installation() {
  log "Verifying installations..."
  echo ""
  echo "======================================"
  echo " STATUS MONITORING AGENTS"
  echo "======================================"

  check_port() {
    local name=$1
    local port=$2
    if curl -s --max-time 3 "http://localhost:${port}/metrics" > /dev/null 2>&1; then
      echo -e "  ${GREEN}✓${NC} $name (port $port) - RUNNING"
    else
      echo -e "  ${RED}✗${NC} $name (port $port) - NOT RUNNING"
    fi
  }

  check_port "Node Exporter" 9100
  $WITH_DOCKER  && check_port "cAdvisor" 8080
  $WITH_PM2     && check_port "PM2 Exporter" 9209
  $WITH_ELASTICSEARCH && check_port "Elasticsearch Exporter" 9114
  $WITH_POSTFIX && check_port "Postfix Exporter" 9154
  echo "======================================"
}

# =============================================================
# MAIN
# =============================================================
main() {
  echo ""
  echo "============================================="
  echo "  Monitoring Agents Installer"
  echo "  Server: $(hostname)"
  echo "============================================="
  echo ""
  info "Options: Docker=$WITH_DOCKER | PM2=$WITH_PM2 | Elasticsearch=$WITH_ELASTICSEARCH | Postfix=$WITH_POSTFIX"
  echo ""

  install_deps
  install_node_exporter

  $WITH_DOCKER        && install_cadvisor
  $WITH_PM2           && install_pm2_exporter
  $WITH_ELASTICSEARCH && install_elasticsearch_exporter
  $WITH_POSTFIX       && install_postfix_exporter

  configure_firewall
  verify_installation

  echo ""
  log "Instalasi selesai! Tambahkan server ini ke prometheus.yml di monitoring server."
}

main "$@"
