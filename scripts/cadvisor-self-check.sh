#!/bin/bash
# =============================================================
# cadvisor-self-check.sh
# Jalankan ON the target server untuk audit runtime cAdvisor.
#
# Usage:
#   curl -sS http://MONITORING/cadvisor-self-check.sh | bash
#   -- atau --
#   chmod +x cadvisor-self-check.sh && sudo ./cadvisor-self-check.sh
#
# Tidak perlu argumen. Output bisa di-paste ke checklist.
# =============================================================

CADVISOR_PORT="${CADVISOR_PORT:-8192}"

SEP="━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo "$SEP"
echo " cAdvisor Runtime Self-Check — $(hostname -s) @ $(date '+%Y-%m-%d %H:%M:%S')"
echo "$SEP"

# ---------- 1. Environment ----------
echo ""
echo "[ 1/7 ] HOST ENVIRONMENT"
echo "  Hostname    : $(hostname -f 2>/dev/null || hostname)"
echo "  OS          : $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || echo unknown)"
echo "  Kernel      : $(uname -r)"
echo "  cgroup ver  : $(if mountpoint -q /sys/fs/cgroup/unified 2>/dev/null || grep -q "cgroup2" /proc/mounts 2>/dev/null; then echo 'v2'; else echo 'v1'; fi)"
echo "  Docker ver  : $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo 'N/A')"
echo "  cAdvisor container name(s):"
docker ps --filter name=cadvisor --format '    {{.Names}} ({{.Image}}, status={{.Status}})' 2>/dev/null || echo "  N/A"

# ---------- 2. Container inspect ----------
echo ""
echo "[ 2/7 ] CONTAINER IMAGE & ARGS"
CADNAME=$(docker ps --filter name=cadvisor --format '{{.Names}}' 2>/dev/null | head -1)
if [[ -z "$CADNAME" ]]; then
  echo "  !! cAdvisor container not found"
else
  IMAGE=$(docker inspect "$CADNAME" --format '{{.Config.Image}}' 2>/dev/null)
  echo "  Image: $IMAGE"
  echo "  Entrypoint/Cmd:"
  docker inspect "$CADNAME" --format '  {{range .Config.Entrypoint}}  {{.}}{{"\n"}}{{end}}{{range .Config.Cmd}}  {{.}}{{"\n"}}{{end}}' 2>/dev/null

  # Key flags check
  ARGS=$(docker inspect "$CADNAME" --format '{{range .Config.Entrypoint}}{{.}} {{end}}{{range .Config.Cmd}}{{.}} {{end}}' 2>/dev/null)
  check_flag() { echo "$ARGS" | grep -q "$1" && echo "YES" || echo "NO  ← MISSING"; }
  echo "  Key flags:"
  printf "    %-40s %s\n" "-docker_only=true" "$(check_flag docker_only)"
  printf "    %-40s %s\n" "-housekeeping_interval" "$(check_flag housekeeping_interval)"
  printf "    %-40s %s\n" "-logtostderr" "$(check_flag logtostderr)"
fi

# ---------- 3. Mounts ----------
echo ""
echo "[ 3/7 ] VOLUME MOUNTS"
if [[ -n "$CADNAME" ]]; then
  REQUIRED_MOUNTS=(
    ":/rootfs:ro"
    "/var/run:/var/run"
    "/var/run/docker.sock:/var/run/docker.sock"
    "/sys:/sys"
    "/sys/fs/cgroup:/sys/fs/cgroup"
    "/var/lib/docker:/var/lib/docker"
    "/dev/disk:/dev/disk"
  )
  ACTUAL=$(docker inspect "$CADNAME" --format '{{range .Mounts}}  {{.Source}}:{{.Destination}}:{{if .RW}}rw{{else}}ro{{end}}{{"\n"}}{{end}}' 2>/dev/null)
  echo "$ACTUAL"
  echo "  Required mount check:"
  for m in "${REQUIRED_MOUNTS[@]}"; do
    echo "$ACTUAL" | grep -q "${m%%:*}" \
      && printf "    %-40s OK\n" "$m" \
      || printf "    %-40s MISSING\n" "$m"
  done
fi

# ---------- 4. Devices ----------
echo ""
echo "[ 4/7 ] DEVICES"
if [[ -n "$CADNAME" ]]; then
  docker inspect "$CADNAME" --format '{{range .HostConfig.Devices}}  {{.PathOnHost}} → {{.PathInContainer}}{{"\n"}}{{end}}' 2>/dev/null | head -10
  docker inspect "$CADNAME" --format '{{range .HostConfig.Devices}}{{.PathOnHost}}{{"\n"}}{{end}}' | grep -q "kmsg" \
    && echo "  /dev/kmsg : OK" \
    || echo "  /dev/kmsg : MISSING"
fi

# ---------- 5. Metrics spot-check ----------
echo ""
echo "[ 5/7 ] METRICS SPOT-CHECK (http://127.0.0.1:${CADVISOR_PORT}/metrics)"
if ! curl -s --max-time 5 "http://127.0.0.1:${CADVISOR_PORT}/metrics" -o /tmp/_cadv_metrics 2>/dev/null; then
  echo "  !! Cannot reach cAdvisor on port ${CADVISOR_PORT}"
else
  check_metric() {
    local label="$1" pattern="$2"
    local cnt
    cnt=$(grep -c "$pattern" /tmp/_cadv_metrics 2>/dev/null || echo 0)
    printf "    %-45s %s series\n" "$label" "$cnt"
  }
  check_metric "container_cpu_usage_seconds_total" "^container_cpu_usage_seconds_total"
  check_metric "container_cpu_cfs_burst_periods_total" "^container_cpu_cfs_burst_periods_total"
  check_metric "container_fs_io_time_seconds_total" "^container_fs_io_time_seconds_total"
  check_metric "container_fs_io_current" "^container_fs_io_current"
  check_metric "container_fs_usage_bytes" "^container_fs_usage_bytes"
  check_metric "container_fs_inodes_free" "^container_fs_inodes_free"
  check_metric "container_spec_memory_limit_bytes" "^container_spec_memory_limit_bytes"
  check_metric "container_oom_events_total" "^container_oom_events_total"
  check_metric "container_pressure_*" "^container_pressure_"

  echo ""
  echo "  ID-scope breakdown:"
  A=$(grep -c 'id="/system.slice/docker-' /tmp/_cadv_metrics 2>/dev/null || echo 0)
  B=$(grep -c 'id="/docker/' /tmp/_cadv_metrics 2>/dev/null || echo 0)
  C=$(grep -c 'id="/",' /tmp/_cadv_metrics 2>/dev/null || echo 0)
  D=$(grep -c 'container_label_com_docker_compose_service=""' /tmp/_cadv_metrics 2>/dev/null || echo 0)
  printf "    %-45s %s\n" "id=/system.slice/docker-* (systemd mode)" "$A"
  printf "    %-45s %s\n" "id=/docker/* (cgroupv1 mode)" "$B"
  printf "    %-45s %s\n" "id=/ (root/host only)" "$C"
  printf "    %-45s %s\n" "empty compose_service label" "$D"

  echo ""
  echo "  Container per-cgroup FS exposure (key signal):"
  PERCTX=$(grep "^container_fs_usage_bytes" /tmp/_cadv_metrics 2>/dev/null | grep -v 'id="/"' | wc -l)
  printf "    %-45s %s\n" "container_fs_usage_bytes (non-root id)" "$PERCTX"
  if [[ "$PERCTX" -eq 0 ]]; then
    echo "    ⚠ FS metrics exposed only at root cgroup (id=/)."
    echo "    ⚠ Probable cause: -docker_only=true missing, or /sys/fs/cgroup not mounted."
  fi

  rm -f /tmp/_cadv_metrics
fi

# ---------- 6. cAdvisor version ----------
echo ""
echo "[ 6/7 ] CADVISOR VERSION"
curl -s --max-time 5 "http://127.0.0.1:${CADVISOR_PORT}/metrics" 2>/dev/null | grep "^cadvisor_version_info" | head -2

# ---------- 7. Docker cgroup driver ----------
echo ""
echo "[ 7/7 ] DOCKER CGROUP DRIVER"
docker info --format 'CgroupDriver: {{.CgroupDriver}}  CgroupVersion: {{.CgroupVersion}}' 2>/dev/null

echo ""
echo "$SEP"
echo " Done. Copy output ke checklist untuk compare antar server."
echo "$SEP"
