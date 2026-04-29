# =============================================================
# TUTORIAL: Monitoring Stack Setup
# Prometheus + Grafana + Alertmanager
# =============================================================

## Daftar Isi
1. [Arsitektur](#arsitektur)
2. [Setup Monitoring Server](#1-setup-monitoring-server)
3. [Install Agent – Node Exporter](#2-install-node-exporter-semua-server)
4. [Install Agent – Docker (cAdvisor)](#3-install-cadvisor-server-dengan-docker)
5. [Install Agent – PM2 Exporter](#4-install-pm2-exporter-server-dengan-pm2)
6. [Install Agent – Elasticsearch Exporter](#5-install-elasticsearch-exporter)
7. [Install Agent – Mail Server (Postfix)](#6-install-postfix-exporter-mail-svr)
8. [Konfigurasi IP di Prometheus](#7-konfigurasi-ip-prometheus)
9. [Akses Grafana & Import Dashboard](#8-akses-grafana--import-dashboard)
10. [Konfigurasi Alertmanager (Email)](#9-konfigurasi-alertmanager-email)
11. [Troubleshooting](#10-troubleshooting)

---

## Arsitektur

```
┌─────────────────────────────────────────────────────────┐
│                  MONITORING SERVER                       │
│                                                          │
│  ┌────────────┐  ┌───────────┐  ┌────────────────────┐  │
│  │ Prometheus │  │  Grafana  │  │   Alertmanager     │  │
│  │  :9090     │  │  :3000    │  │      :9093         │  │
│  └────────────┘  └───────────┘  └────────────────────┘  │
│  ┌─────────────────────┐                                 │
│  │  Blackbox Exporter  │                                 │
│  │       :9115         │                                 │
│  └─────────────────────┘                                 │
└─────────────────────────────────────────────────────────┘
         │ scrape metrics
         ▼
┌──────────────────────────────┐
│  SETIAP SERVER YANG DIMONITOR │
│                               │
│  node_exporter   :9100        │
│  cAdvisor        :8080  (jika ada Docker)
│  pm2-exporter    :9209  (jika ada PM2)
│  es_exporter     :9114  (jika ada ES)
│  postfix_exporter:9154  (jika mail server)
└──────────────────────────────┘
```

**Server yang dimonitor:**
| Server | Env | Exporter yang diinstall |
|---|---|---|
| dev-sat-baremetal | development | node, cadvisor, pm2 |
| server-be-gotham | production | node, cadvisor, pm2 |
| be-leaked-gotham | production | node, cadvisor, pm2, elasticsearch |
| baremetal-ubuntu | production | node, cadvisor, pm2 |
| mail-svr | production | node, postfix |

---

## 1. Setup Monitoring Server

> Jalankan di server khusus monitoring (bisa VPS baru atau server yang ada).

### 1.1 Install Docker & Docker Compose

```bash
# Ubuntu/Debian
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
newgrp docker

# Install Docker Compose plugin
sudo apt-get install -y docker-compose-plugin

# Verifikasi
docker --version
docker compose version
```

### 1.2 Clone/copy folder monitoring

```bash
# Copy folder monitoring ke server
scp -r ./monitoring user@monitoring-server:/opt/monitoring
# atau
git clone <your-repo> /opt/monitoring

cd /opt/monitoring
```

### 1.3 Konfigurasi environment

```bash
cp .env.example .env   # atau edit langsung .env
nano .env
```

Edit nilai berikut:
```env
GRAFANA_ADMIN_PASSWORD=PasswordAmanAnda123!
GRAFANA_DOMAIN=monitoring.yourcompany.com   # domain atau IP monitoring server
```

### 1.4 Edit IP server di prometheus.yml

Buka `prometheus/prometheus.yml` dan ganti semua komentar `# CHANGE` dengan IP/hostname server Anda:

```bash
nano prometheus/prometheus.yml
```

Contoh:
```yaml
# Ganti:
- targets: ["dev-sat-baremetal:9100"]
# Dengan IP aktual:
- targets: ["192.168.1.10:9100"]
```

### 1.5 Jalankan stack monitoring

```bash
cd /opt/monitoring
docker compose up -d

# Cek status
docker compose ps

# Lihat logs
docker compose logs -f prometheus
docker compose logs -f grafana
```

### 1.6 Buka firewall monitoring server

```bash
# UFW
sudo ufw allow 3000/tcp comment "Grafana"
sudo ufw allow 9090/tcp comment "Prometheus"
sudo ufw allow 9093/tcp comment "Alertmanager"
# JANGAN ekspos port 9100 ke publik
```

---

## 2. Install Node Exporter (Semua Server)

> Jalankan di **setiap server** yang ingin dimonitor.

### Cara 1: Menggunakan script otomatis (disarankan)

```bash
# Copy script ke server target
scp scripts/install-agents.sh user@TARGET_SERVER:/tmp/

# SSH ke server target
ssh user@TARGET_SERVER

# Jalankan script
# Untuk server backend dengan Docker & PM2:
sudo MONITORING_SERVER_IP=<IP_MONITORING_SERVER> \
  bash /tmp/install-agents.sh --with-docker --with-pm2

# Untuk mail server:
sudo MONITORING_SERVER_IP=<IP_MONITORING_SERVER> \
  bash /tmp/install-agents.sh --with-postfix

# Untuk server Elasticsearch:
sudo ES_URL=http://localhost:9200 \
  MONITORING_SERVER_IP=<IP_MONITORING_SERVER> \
  bash /tmp/install-agents.sh --with-elasticsearch
```

### Cara 2: Manual

```bash
# Download node_exporter
cd /tmp
NODE_VERSION="1.8.0"
wget https://github.com/prometheus/node_exporter/releases/download/v${NODE_VERSION}/node_exporter-${NODE_VERSION}.linux-amd64.tar.gz

tar -xzf node_exporter-${NODE_VERSION}.linux-amd64.tar.gz
sudo cp node_exporter-${NODE_VERSION}.linux-amd64/node_exporter /usr/local/bin/
sudo chmod +x /usr/local/bin/node_exporter

# Buat user
sudo useradd --no-create-home --shell /bin/false node_exporter

# Buat systemd service
sudo nano /etc/systemd/system/node_exporter.service
```

Isi file service:
```ini
[Unit]
Description=Node Exporter
After=network-online.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter \
  --collector.filesystem.mount-points-exclude="^/(sys|proc|dev|host|etc)($$|/)" \
  --collector.systemd \
  --collector.processes
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now node_exporter

# Verifikasi
curl http://localhost:9100/metrics | head -20
```

---

## 3. Install cAdvisor (Server dengan Docker)

> Untuk: dev-sat-baremetal, server-be-gotham, be-leaked-gotham, baremetal-ubuntu

### Menggunakan Docker (cara termudah)

```bash
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
  gcr.io/cadvisor/cadvisor:v0.49.1

# Verifikasi
curl http://localhost:8080/metrics | head -5
```

### Atau tambahkan ke docker-compose.yml server tersebut

```yaml
services:
  # ... services lain ...

  cadvisor:
    image: gcr.io/cadvisor/cadvisor:v0.49.1
    container_name: cadvisor
    restart: unless-stopped
    privileged: true
    volumes:
      - /:/rootfs:ro
      - /var/run:/var/run:ro
      - /sys:/sys:ro
      - /var/lib/docker/:/var/lib/docker:ro
      - /dev/disk/:/dev/disk:ro
    devices:
      - /dev/kmsg
    ports:
      - "8080:8080"
```

---

## 4. Install PM2 Exporter (Server dengan PM2)

> Untuk: dev-sat-baremetal, server-be-gotham, be-leaked-gotham, baremetal-ubuntu

### Prasyarat: Pastikan PM2 sudah terinstall

```bash
# Cek PM2
pm2 --version

# Install PM2 jika belum ada
npm install -g pm2
```

### Install PM2 Prometheus Exporter

```bash
# Install exporter
npm install -g pm2-prometheus-exporter

# Buat config
cat > /home/$USER/pm2-exporter.config.js << 'EOF'
module.exports = {
  apps: [{
    name: 'pm2-prometheus-exporter',
    script: 'pm2-prometheus-exporter',
    env: {
      PORT: 9209,
      PROBE_INTERVAL: 15000
    },
    restart_delay: 5000,
    autorestart: true
  }]
};
EOF

# Jalankan
pm2 start /home/$USER/pm2-exporter.config.js
pm2 save

# Pastikan PM2 startup dikonfigurasi
pm2 startup
# Jalankan perintah yang diminta oleh PM2 startup
pm2 save

# Verifikasi
curl http://localhost:9209/metrics | head -10
```

### Contoh output metrics PM2

```
pm2_up{name="api-server",id="0"} 1
pm2_up{name="worker",id="1"} 1
pm2_restart_count{name="api-server"} 2
pm2_memory_bytes{name="api-server"} 52428800
pm2_cpu_percent{name="api-server"} 1.5
```

---

## 5. Install Elasticsearch Exporter

> Untuk: be-leaked-gotham (atau server tempat Elasticsearch berjalan)

```bash
ES_VERSION="1.7.0"
cd /tmp
wget https://github.com/prometheus-community/elasticsearch_exporter/releases/download/v${ES_VERSION}/elasticsearch_exporter-${ES_VERSION}.linux-amd64.tar.gz

tar -xzf elasticsearch_exporter-${ES_VERSION}.linux-amd64.tar.gz
sudo cp elasticsearch_exporter-${ES_VERSION}.linux-amd64/elasticsearch_exporter /usr/local/bin/
sudo chmod +x /usr/local/bin/elasticsearch_exporter

sudo useradd --no-create-home --shell /bin/false elasticsearch_exporter

# Sesuaikan ES_URL dengan URL Elasticsearch Anda
ES_URL="http://localhost:9200"
# Jika ES dengan auth:
# ES_URL="http://user:password@localhost:9200"

sudo tee /etc/systemd/system/elasticsearch_exporter.service <<EOF
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
  --web.listen-address=":9114"
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now elasticsearch_exporter

# Verifikasi
curl http://localhost:9114/metrics | grep "elasticsearch_cluster_health_status"
```

### Elasticsearch dengan Docker

Jika Elasticsearch berjalan via Docker, tambahkan ke `docker-compose.yml` di server tersebut:

```yaml
  elasticsearch-exporter:
    image: prometheuscommunity/elasticsearch-exporter:v1.7.0
    container_name: elasticsearch-exporter
    restart: unless-stopped
    command:
      - "--es.uri=http://elasticsearch:9200"  # nama service ES di docker network
      - "--es.all"
      - "--es.indices"
      - "--es.shards"
    ports:
      - "9114:9114"
```

---

## 6. Install Postfix Exporter (mail-svr)

```bash
# Cara termudah: gunakan Docker
docker run -d \
  --name postfix-exporter \
  --restart unless-stopped \
  --pid host \
  --volume /var/log/mail.log:/var/log/mail.log:ro \
  --publish 9154:9154 \
  prom/postfix-exporter:latest \
  --postfix.logfile_path=/var/log/mail.log

# Jika log Postfix ada di syslog (Ubuntu baru):
# Pastikan rsyslog mencatat ke /var/log/mail.log
sudo tee -a /etc/rsyslog.d/50-mail.conf << 'EOF'
mail.*  /var/log/mail.log
EOF
sudo systemctl restart rsyslog

# Verifikasi
curl http://localhost:9154/metrics | grep postfix
```

---

## 7. Konfigurasi IP Prometheus

Setelah semua agent terinstall, edit `prometheus/prometheus.yml` di **monitoring server**:

```bash
cd /opt/monitoring
nano prometheus/prometheus.yml
```

Ganti setiap `# CHANGE` dengan IP aktual:

```yaml
# Contoh dev-sat-baremetal dengan IP 192.168.10.10
- job_name: "node-dev-sat-baremetal"
  static_configs:
    - targets: ["192.168.10.10:9100"]   # ganti hostname/IP

- job_name: "cadvisor-dev-sat-baremetal"
  static_configs:
    - targets: ["192.168.10.10:8080"]

- job_name: "pm2-dev-sat-baremetal"
  static_configs:
    - targets: ["192.168.10.10:9209"]
```

Setelah edit, reload Prometheus (tanpa restart):

```bash
docker compose exec prometheus wget -O- -q 'http://localhost:9090/-/reload' --post-data=''
# atau
curl -X POST http://localhost:9090/-/reload
```

### Verifikasi di Prometheus UI

1. Buka `http://MONITORING_SERVER:9090/targets`
2. Semua target harus berstatus **UP** (hijau)
3. Jika ada yang **DOWN**, cek koneksi dari monitoring server ke target server

---

## 8. Akses Grafana & Import Dashboard

### Login Grafana

- URL: `http://MONITORING_SERVER:3000`
- Username: `admin`
- Password: (sesuai `.env` file)

### Import Dashboard yang Direkomendasikan

Buka Grafana → **Dashboards** → **Import** → masukkan ID:

| Dashboard | ID Grafana | Kegunaan |
|---|---|---|
| Node Exporter Full | **1860** | System metrics semua server |
| cAdvisor + Docker | **14282** | Docker container metrics |
| PM2 Monitoring | **14572** | PM2 process metrics |
| Elasticsearch | **14191** | Elasticsearch cluster health |
| Blackbox Exporter | **7587** | HTTP/TCP/SMTP probe |
| Alertmanager | **9578** | Alert overview |

#### Langkah import:
1. Klik **+** → **Import**
2. Masukkan ID dashboard
3. Pilih datasource: **Prometheus**
4. Klik **Import**

---

## 9. Konfigurasi Alertmanager (Email)

Edit `alertmanager/alertmanager.yml`:

```bash
nano alertmanager/alertmanager.yml
```

Sesuaikan:
```yaml
global:
  smtp_smarthost: "mail-svr:587"              # IP:port SMTP server
  smtp_from: "alertmanager@yourcompany.com"   # Pengirim
  smtp_auth_username: "alert@yourcompany.com" # Username SMTP
  smtp_auth_password: "smtp_password"          # Password SMTP

receivers:
  - name: "critical-receiver"
    email_configs:
      - to: "oncall@yourcompany.com"   # Email penerima alert critical
```

Reload Alertmanager:
```bash
curl -X POST http://localhost:9093/-/reload
```

### Tes alert email

```bash
# Kirim test alert ke Alertmanager
curl -H "Content-Type: application/json" -d '[{
  "labels": {
    "alertname": "TestAlert",
    "severity": "critical",
    "server": "test-server"
  },
  "annotations": {
    "summary": "Test alert dari Alertmanager"
  }
}]' http://localhost:9093/api/v1/alerts
```

---

## 10. Troubleshooting

### Target Prometheus berstatus DOWN

```bash
# Test koneksi dari monitoring server ke target
curl http://TARGET_IP:9100/metrics

# Cek firewall di target server
sudo ufw status
sudo iptables -L -n | grep 9100

# Cek service berjalan di target server
systemctl status node_exporter
```

### cAdvisor tidak bisa diakses

```bash
# Cek container berjalan
docker ps | grep cadvisor

# Lihat logs
docker logs cadvisor

# Jika error permission:
docker run --privileged ...  # pastikan flag --privileged ada
```

### PM2 Exporter tidak jalan

```bash
# Cek PM2 list
pm2 list

# Restart exporter
pm2 restart pm2-prometheus-exporter

# Lihat logs
pm2 logs pm2-prometheus-exporter
```

### Grafana tidak bisa connect ke Prometheus

```bash
# Cek dari container Grafana
docker exec -it grafana wget -O- http://prometheus:9090/-/healthy

# Cek network Docker
docker network ls
docker network inspect monitoring_monitoring
```

### Prometheus config error

```bash
# Validasi config sebelum apply
docker run --rm \
  -v $(pwd)/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml \
  prom/prometheus:v2.51.2 \
  --config.file=/etc/prometheus/prometheus.yml \
  --check-config
```

### Melihat semua metrics yang tersedia

```bash
# Di Prometheus UI
http://MONITORING_SERVER:9090

# Query: semua metrics dari server tertentu
{server="server-be-gotham"}

# Query: status semua targets
up
```

---

## Referensi Port

| Port | Service | Instalasi di |
|------|---------|-------------|
| 3000 | Grafana | Monitoring server |
| 9090 | Prometheus | Monitoring server |
| 9093 | Alertmanager | Monitoring server |
| 9115 | Blackbox Exporter | Monitoring server |
| 9100 | Node Exporter | Semua server target |
| 8080 | cAdvisor | Server dengan Docker |
| 9209 | PM2 Exporter | Server dengan PM2 |
| 9114 | Elasticsearch Exporter | Server dengan ES |
| 9154 | Postfix Exporter | mail-svr |
