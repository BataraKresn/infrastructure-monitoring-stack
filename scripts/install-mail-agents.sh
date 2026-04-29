#!/bin/bash
# =============================================================
# install-mail-agents.sh
# Install agent monitoring untuk mail server berbasis Docker (mailcow)
#
# Jalankan di mail server (contoh: mail-svr)
# Target utama: cAdvisor + Node Exporter (via Docker)
#
# Usage:
#   chmod +x install-mail-agents.sh
#   sudo ./install-mail-agents.sh [--server-name NAME]
#
# Port yang dibuka:
#   8192 - cAdvisor
#   8193 - Node Exporter
#
# Catatan:
#   - Untuk mailcow (postfix/dovecot/rspamd di Docker), script ini TIDAK
#     menginstall postfix_exporter berbasis log host.
#   - Monitoring protokol mail disarankan via Blackbox Exporter
#     (SMTP/Submission/SMTPS/IMAPS).
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

SERVER_NAME="mail-svr"

# --- Parse args ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --server-name)
      shift
      [[ $# -eq 0 ]] && error "Nilai untuk --server-name wajib diisi"
      SERVER_NAME="$1"
      ;;
    --server-name=*)
      SERVER_NAME="${1#*=}"
      ;;
    *)
      warn "Unknown argument: $1"
      ;;
  esac
  shift
done

# --- Cek root ---
[[ $EUID -ne 0 ]] && error "Script ini harus dijalankan sebagai root atau dengan sudo"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_AGENT_SCRIPT="${SCRIPT_DIR}/install-docker-pm2-agents.sh"

detect_mailcow() {
  if command -v docker &>/dev/null; then
    if docker ps --format '{{.Names}}' | grep -Eiq 'mailcow|postfix-mailcow|dovecot-mailcow|rspamd-mailcow'; then
      log "Terdeteksi stack mailcow/dockerized mail services"
      return 0
    fi
  fi
  warn "Mailcow tidak terdeteksi otomatis, tetap lanjut install agent umum"
  return 1
}

install_core_agents() {
  [[ -x "$DOCKER_AGENT_SCRIPT" ]] || chmod +x "$DOCKER_AGENT_SCRIPT"
  [[ -f "$DOCKER_AGENT_SCRIPT" ]] || error "Script tidak ditemukan: $DOCKER_AGENT_SCRIPT"

  log "Menjalankan installer cAdvisor + Node Exporter..."
  bash "$DOCKER_AGENT_SCRIPT" --server-name "$SERVER_NAME"
}

print_prometheus_snippets() {
  local SERVER_IP
  SERVER_IP=$(hostname -I | awk '{print $1}')

  echo ""
  echo "======================================"
  echo " PROMETHEUS CONFIG (MAIL-SVR)"
  echo "======================================"
  info "Tambahkan/ubah target berikut di prometheus.yml (monitoring server):"
  echo ""
  echo "  - job_name: 'node-${SERVER_NAME}'"
  echo "    static_configs:"
  echo "      - targets: ['${SERVER_IP}:8193']"
  echo "        labels:"
  echo "          env: 'production'"
  echo "          server: '${SERVER_NAME}'"
  echo "          role: 'mail'"
  echo ""
  echo "  - job_name: 'cadvisor-${SERVER_NAME}'"
  echo "    static_configs:"
  echo "      - targets: ['${SERVER_IP}:8192']"
  echo "        labels:"
  echo "          env: 'production'"
  echo "          server: '${SERVER_NAME}'"
  echo "          role: 'mail'"
  echo ""
  info "Untuk mail protocol monitoring, gunakan blackbox probes:"
  echo ""
  echo "  - SMTP 25 (MTA)"
  echo "  - Submission 587 (client send)"
  echo "  - SMTPS 465"
  echo "  - IMAPS 993"
  echo ""
}

main() {
  echo ""
  echo "============================================="
  echo "  Mail Server Agent Installer"
  echo "  Server: $(hostname)"
  echo "  Server Name: ${SERVER_NAME}"
  echo "  Target: cAdvisor + Node Exporter"
  echo "============================================="
  echo ""

  detect_mailcow || true
  install_core_agents
  print_prometheus_snippets

  log "Selesai! Mail server agent aktif (cAdvisor + Node Exporter)."
}

main "$@"
