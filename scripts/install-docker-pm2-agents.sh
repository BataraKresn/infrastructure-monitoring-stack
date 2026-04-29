#!/bin/bash
# =============================================================
# install-docker-pm2-agents.sh
# Install cAdvisor (Docker metrics) + Node Exporter (host metrics)
#
# Jalankan di setiap server yang ingin dimonitor
# Target: server-be-gotham, be-leaked-gotham, baremetal-ubuntu, dev-sat-baremetal
#
# Usage:
#   chmod +x install-docker-pm2-agents.sh
#   sudo ./install-docker-pm2-agents.sh [--skip-docker] [--skip-node] [--server-name NAME]
#
# Default: install keduanya. Gunakan flag untuk melewati salah satu.
# --server-name : suffix nama container (default: hostname)
#   Contoh: --server-name mail-svr  → cadvisor-mail-svr, node-exporter-mail-svr
#
# Port yang dibuka:
#   8192 - cAdvisor (Docker metrics)
#   8193 - Node Exporter
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

CADVISOR_VERSION="0.49.1"
NODE_EXPORTER_IMAGE="prom/node-exporter:latest"

# --- Parse args ---
SKIP_DOCKER=false
SKIP_NODE=false
SERVER_NAME=""

for arg in "$@"; do
  case $arg in
    --skip-docker)       SKIP_DOCKER=true ;;
    --skip-node)         SKIP_NODE=true ;;
    --server-name=*)     SERVER_NAME="${arg#*=}" ;;
    --server-name)       shift; SERVER_NAME="$1" ;;
    *) warn "Unknown argument: $arg" ;;
  esac
done

# Default server name = hostname (sanitized)
[[ -z "$SERVER_NAME" ]] && SERVER_NAME=$(hostname -s | tr '[:upper:]' '[:lower:]' | tr '_' '-')

CADVISOR_NAME="cadvisor-${SERVER_NAME}"
NODE_EXPORTER_NAME="node-exporter-${SERVER_NAME}"

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

# --- Install dependencies ---
install_deps() {
  log "Installing dependencies..."
  if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
    apt-get update -qq
    apt-get install -y -qq curl wget 2>/dev/null || true
  elif [[ "$OS" == "centos" || "$OS" == "rhel" || "$OS" == "rocky" || "$OS" == "almalinux" ]]; then
    yum install -y -q curl wget 2>/dev/null || true
  fi
}

# =============================================================
# CADVISOR (Docker metrics)
# =============================================================
install_cadvisor() {
  log "Installing cAdvisor v${CADVISOR_VERSION}..."

  if ! command -v docker &>/dev/null; then
    warn "Docker tidak ditemukan. Install Docker terlebih dahulu."
    warn "Lewati instalasi cAdvisor."
    return 1
  fi

  # Cek apakah sudah berjalan
  if docker inspect "${CADVISOR_NAME}" &>/dev/null 2>&1; then
    warn "Container ${CADVISOR_NAME} sudah ada. Menghapus dan menginstall ulang..."
    docker stop "${CADVISOR_NAME}" 2>/dev/null || true
    docker rm "${CADVISOR_NAME}" 2>/dev/null || true
  fi

  # Deteksi Docker root dir agar kompatibel jika data-root bukan /var/lib/docker
  local DOCKER_ROOT_DIR
  DOCKER_ROOT_DIR=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo "/var/lib/docker")
  [[ -z "$DOCKER_ROOT_DIR" ]] && DOCKER_ROOT_DIR="/var/lib/docker"

  log "Docker root dir detected: ${DOCKER_ROOT_DIR}"

  log "Starting cAdvisor container (${CADVISOR_NAME})..."
  docker run -d \
    --name "${CADVISOR_NAME}" \
    --restart unless-stopped \
    --privileged \
    --volume /:/rootfs:ro \
    --volume /var/run:/var/run:ro \
    --volume /sys:/sys:ro \
    --volume "${DOCKER_ROOT_DIR}:/var/lib/docker:ro" \
    --volume /dev/disk/:/dev/disk:ro \
    --publish 8192:8080 \
    --device /dev/kmsg \
    --env DOCKER_HOST=unix:///var/run/docker.sock \
    --health-cmd='wget -q -T 5 -O - http://localhost:8192/metrics >/dev/null || exit 1' \
    --health-interval=30s \
    --health-timeout=10s \
    --health-retries=3 \
    gcr.io/cadvisor/cadvisor:v${CADVISOR_VERSION}

  log "cAdvisor started: ${CADVISOR_NAME} on port 8192"
}

# =============================================================
# NODE EXPORTER (Host metrics)
# =============================================================
install_node_exporter() {
  log "Installing Node Exporter container (${NODE_EXPORTER_IMAGE})..."

  if ! command -v docker &>/dev/null; then
    warn "Docker tidak ditemukan. Install Docker terlebih dahulu."
    warn "Lewati instalasi Node Exporter."
    return 1
  fi

  if docker inspect "${NODE_EXPORTER_NAME}" &>/dev/null 2>&1; then
    warn "Container ${NODE_EXPORTER_NAME} sudah ada. Menghapus dan menginstall ulang..."
    docker stop "${NODE_EXPORTER_NAME}" 2>/dev/null || true
    docker rm "${NODE_EXPORTER_NAME}" 2>/dev/null || true
  fi

  docker run -d \
    --name "${NODE_EXPORTER_NAME}" \
    --restart unless-stopped \
    --net host \
    --pid host \
    -v "/:/host:ro,rslave" \
    ${NODE_EXPORTER_IMAGE} \
    --path.rootfs=/host \
    --web.listen-address=":8193"

  log "Node Exporter started: ${NODE_EXPORTER_NAME} on port 8193"
}

# =============================================================
# FIREWALL
# =============================================================
configure_firewall() {
  log "Configuring firewall..."
  local MONITORING_IP="${MONITORING_SERVER_IP:-}"

  open_port_ufw() {
    local port=$1
    local name=$2
    if [[ -n "$MONITORING_IP" ]]; then
      ufw allow from "$MONITORING_IP" to any port "$port" comment "$name"
      log "UFW: port $port dibuka untuk $MONITORING_IP"
    else
      ufw allow "${port}/tcp" comment "$name"
      warn "Port $port dibuka untuk semua IP"
    fi
  }

  if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
    [[ "$SKIP_DOCKER" == "false" ]] && open_port_ufw 8192 "cadvisor"
    [[ "$SKIP_NODE" == "false" ]]   && open_port_ufw 8193 "node_exporter"
    if [[ -z "$MONITORING_IP" ]]; then
      warn "Set MONITORING_SERVER_IP untuk membatasi akses firewall"
      warn "Contoh: MONITORING_SERVER_IP=10.0.0.5 sudo ./install-docker-pm2-agents.sh"
    fi
  elif command -v firewall-cmd &>/dev/null; then
    [[ "$SKIP_DOCKER" == "false" ]] && firewall-cmd --permanent --add-port=8192/tcp
    [[ "$SKIP_NODE" == "false" ]]   && firewall-cmd --permanent --add-port=8193/tcp
    firewall-cmd --reload
    log "Firewalld rules added"
  else
    warn "UFW/Firewalld tidak ditemukan."
    warn "Buka port secara manual: 8192 (cAdvisor), 8193 (Node Exporter)"
  fi
}

# =============================================================
# VERIFIKASI
# =============================================================
verify_installation() {
  echo ""
  echo "======================================"
  echo " STATUS SERVER AGENTS"
  echo "======================================"

  sleep 3

  check_port() {
    local name=$1
    local port=$2
    if curl -s --max-time 5 "http://localhost:${port}/metrics" > /dev/null 2>&1; then
      echo -e "  ${GREEN}✓${NC} $name (port $port) - RUNNING"
    else
      echo -e "  ${RED}✗${NC} $name (port $port) - NOT RUNNING"
    fi
  }

  [[ "$SKIP_DOCKER" == "false" ]] && check_port "cAdvisor" 8192
  [[ "$SKIP_NODE" == "false" ]]   && check_port "Node Exporter" 8193

  echo "======================================"
  echo ""

  local SERVER_IP
  SERVER_IP=$(hostname -I | awk '{print $1}')

  info "Tambahkan scrape config berikut ke prometheus.yml di monitoring server:"
  echo ""
  if [[ "$SKIP_DOCKER" == "false" ]]; then
    echo "  - job_name: 'cadvisor'"
    echo "    static_configs:"
    echo "      - targets: ['${SERVER_IP}:8192']"
    echo "        labels:"
    echo "          instance: '$(hostname)'"
    echo ""
  fi
  if [[ "$SKIP_NODE" == "false" ]]; then
    echo "  - job_name: 'node'"
    echo "    static_configs:"
    echo "      - targets: ['${SERVER_IP}:8193']"
    echo "        labels:"
    echo "          instance: '$(hostname)'"
    echo ""
  fi
}

# =============================================================
# MAIN
# =============================================================
main() {
  echo ""
  echo "============================================="
  echo "  cAdvisor + Node Exporter Installer"
  echo "  Server: $(hostname)"
  echo "  Server Name: ${SERVER_NAME}"
  echo "  Container cAdvisor: ${CADVISOR_NAME}"
  echo "  Container Node Exporter: ${NODE_EXPORTER_NAME}"
  echo "  Install cAdvisor: $( [[ "$SKIP_DOCKER" == "false" ]] && echo "YES" || echo "NO (--skip-docker)" )"
  echo "  Install Node Exporter: $( [[ "$SKIP_NODE" == "false" ]] && echo "YES" || echo "NO (--skip-node)" )"
  echo "============================================="
  echo ""

  install_deps
  [[ "$SKIP_DOCKER" == "false" ]] && install_cadvisor
  [[ "$SKIP_NODE" == "false" ]]   && install_node_exporter
  configure_firewall
  verify_installation

  log "Selesai! Agents siap di-scrape oleh Prometheus."
}

main "$@"
