# =============================================================
# Per-server Installation Commands
# Copy-paste commands untuk setiap server
# =============================================================

# ============================
# dev-sat-baremetal (DEV)
# ============================
# SSH ke server, lalu:

sudo MONITORING_SERVER_IP=<IP_MONITORING> \
  bash /tmp/install-agents.sh --with-docker --with-pm2

# ============================
# server-be-gotham (PROD)
# ============================

sudo MONITORING_SERVER_IP=<IP_MONITORING> \
  bash /tmp/install-agents.sh --with-docker --with-pm2

# ============================
# be-leaked-gotham (PROD)
# ============================

sudo MONITORING_SERVER_IP=<IP_MONITORING> \
  ES_URL=http://localhost:9200 \
  bash /tmp/install-agents.sh --with-docker --with-pm2 --with-elasticsearch

# ============================
# baremetal-ubuntu (PROD)
# ============================

sudo MONITORING_SERVER_IP=<IP_MONITORING> \
  bash /tmp/install-agents.sh --with-docker --with-pm2

# ============================
# mail-svr (MAIL)
# ============================

sudo MONITORING_SERVER_IP=<IP_MONITORING> \
  bash /tmp/install-agents.sh --with-postfix
