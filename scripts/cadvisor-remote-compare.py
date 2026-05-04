#!/usr/bin/env python3
# =============================================================
# cadvisor-remote-compare.py
# Jalankan dari monitoring server (hanya pakai curl ke metrics endpoint).
# Tidak butuh SSH. Bandingkan semua server sekaligus dalam 30 detik.
#
# Usage:
#   python3 scripts/cadvisor-remote-compare.py
#
# Tambah / edit server di dict SERVERS di bawah.
# =============================================================

import urllib.request, re, sys
from concurrent.futures import ThreadPoolExecutor, as_completed

SERVERS = {
    "dev-sat-baremetal": "http://100.101.33.66:8192/metrics",
    "cadvisor-mail-svr": "http://100.90.26.89:8192/metrics",
    "server-be-gotham":  "http://100.92.210.98:8192/metrics",
    "baremetal-ubuntu":  "http://100.92.125.27:8192/metrics",
    "gitrepo-sat":       "http://100.82.173.101:8080/metrics",
    "be-leaked-gotham":  "http://100.105.46.41:8080/metrics",
}

TIMEOUT = 10

# Metrics to count series
METRICS = [
    ("cadvisor_version",         r"^cadvisor_version_info"),
    ("cpu_usage",                r"^container_cpu_usage_seconds_total"),
    ("cpu_cfs_burst",            r"^container_cpu_cfs_burst_periods_total"),
    ("cpu_cfs_throttled",        r"^container_cpu_cfs_throttled_periods_total"),
    ("fs_io_time",               r"^container_fs_io_time_seconds_total"),
    ("fs_io_current",            r"^container_fs_io_current"),
    ("fs_usage",                 r"^container_fs_usage_bytes"),
    ("fs_inodes_free",           r"^container_fs_inodes_free"),
    ("mem_working_set",          r"^container_memory_working_set_bytes"),
    ("mem_limit_spec",           r"^container_spec_memory_limit_bytes"),
    ("oom_events",               r"^container_oom_events_total"),
    ("pressure_cpu",             r"^container_pressure_cpu_"),
    ("pressure_mem",             r"^container_pressure_memory_"),
    ("pressure_io",              r"^container_pressure_io_"),
    ("network_rx",               r"^container_network_receive_bytes_total"),
    ("network_errs",             r"^container_network_receive_errors_total"),
]

# Structural checks
STRUCT = [
    ("id=/system.slice/docker-*",  r'id="/system\.slice/docker-'),
    ("id=/docker/*",               r'id="/docker/'),
    ("id=/ (root only)",           r'id="/",'),
    ("fs_usage non-root id",       r'^container_fs_usage_bytes.*id="(?!/)'),
    ("empty compose_service lbl",  r'container_label_com_docker_compose_service=""'),
    ("has compose_service set",    r'container_label_com_docker_compose_service="[^"]'),
]

# Key flags to look for in version_info or metrics
FLAGS = [
    ("-docker_only=true",    r"docker_only"),
    ("cgroup v2 kernel",     r'cgroup2'),
]

COL = 22

def fetch(url):
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "cadvisor-audit/1.0"})
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            return r.read().decode("utf-8", errors="replace")
    except Exception as e:
        return f"ERROR: {e}"

def count(text, pattern):
    return sum(1 for line in text.splitlines() if re.match(pattern, line))

def count_any(text, pattern):
    return sum(1 for line in text.splitlines() if re.search(pattern, line))

def extract_version(text):
    m = re.search(r'cadvisorVersion="([^"]+)"', text)
    return m.group(1) if m else "N/A"

def extract_os(text):
    m = re.search(r'osVersion="([^"]+)"', text)
    return m.group(1) if m else "N/A"

def extract_kernel(text):
    m = re.search(r'kernelVersion="([^"]+)"', text)
    return m.group(1) if m else "N/A"

SEP = "─" * 90

def audit_server(name, url):
    text = fetch(url)
    result = {"name": name, "url": url, "error": None, "data": {}}
    if text.startswith("ERROR:"):
        result["error"] = text
        return result

    result["data"]["cadvisor_version"] = extract_version(text)
    result["data"]["os_version"]       = extract_os(text)
    result["data"]["kernel_version"]   = extract_kernel(text)

    for key, pattern in METRICS:
        result["data"][key] = count(text, pattern)

    for key, pattern in STRUCT:
        result["data"][key] = count_any(text, pattern)

    return result

def main():
    print()
    print("═" * 90)
    print(" cAdvisor Remote Audit — compare all servers from monitoring host")
    print(" No SSH needed — reads metrics endpoint only")
    print("═" * 90)

    results = {}
    print(f"\nFetching metrics from {len(SERVERS)} servers (parallel, timeout={TIMEOUT}s)...\n")
    with ThreadPoolExecutor(max_workers=len(SERVERS)) as ex:
        futs = {ex.submit(audit_server, name, url): name for name, url in SERVERS.items()}
        for f in as_completed(futs):
            r = f.result()
            results[r["name"]] = r
            status = r.get("error") or f"OK ({r['data'].get('cadvisor_version','?')})"
            print(f"  {r['name']:<28} {status}")

    names = list(SERVERS.keys())
    ok = [n for n in names if not results[n]["error"]]
    err = [n for n in names if results[n]["error"]]

    if err:
        print(f"\n⚠  Unreachable: {', '.join(err)}")

    if not ok:
        print("No servers reachable.")
        return

    print()
    print(SEP)
    print(" RUNTIME SUMMARY TABLE")
    print(SEP)

    # Print header
    hdr = f"{'Metric':<32}"
    for n in names:
        label = n[:COL]
        hdr += f"  {label:<{COL}}"
    print(hdr)
    print("─" * (32 + (COL + 2) * len(names)))

    def row(label, key, fn=lambda x: str(x)):
        s = f"{label:<32}"
        vals = []
        for n in names:
            if results[n]["error"]:
                v = "UNREACHABLE"
            else:
                v = fn(results[n]["data"].get(key, 0))
            vals.append(v)

        # Highlight inconsistencies (non-zero values differ)
        unique = set(v for v in vals if v not in ("UNREACHABLE", "0", "N/A"))
        inconsistent = len(unique) > 1

        for v in vals:
            flag = " ◀" if inconsistent and v not in ("UNREACHABLE", "0") and len(unique) > 1 else "  "
            s += f"  {v:<{COL}}{flag[0]}"
        print(s)

    row("cadvisor version",         "cadvisor_version")
    row("kernel version",           "kernel_version")
    row("os version",               "os_version")

    print("─" * (32 + (COL + 2) * len(names)))
    print(f"{'METRIC SERIES COUNT':<32}")
    print("─" * (32 + (COL + 2) * len(names)))

    for key, _ in METRICS:
        row(key, key)

    print("─" * (32 + (COL + 2) * len(names)))
    print(f"{'ID SCOPE & STRUCTURE':<32}")
    print("─" * (32 + (COL + 2) * len(names)))

    for key, _ in STRUCT:
        row(key, key)

    print()
    print(SEP)
    print(" DIAGNOSIS NOTES")
    print(SEP)

    for n in ok:
        d = results[n]["data"]
        issues = []
        ok_items = []

        burst = d.get("cpu_cfs_burst", 0)
        if burst == 0:
            issues.append("cpu_cfs_burst=0 → kernel/cgroup tidak expose metric ini (runtime feature, bukan bug config)")
        else:
            ok_items.append(f"cpu_cfs_burst={burst} series")

        fs_nonroot = d.get("fs_usage non-root id", 0)
        fs_total   = d.get("fs_usage", 0)
        if fs_nonroot == 0 and fs_total > 0:
            ok_items.append(f"fs_usage ada {fs_total} series (di root cgroup id=/ — normal, dashboard sudah ada fallback)")
        elif fs_nonroot > 0:
            ok_items.append(f"fs_usage per-container={fs_nonroot} series")

        svc_set = d.get("has compose_service set", 0)
        if svc_set == 0:
            issues.append("compose_service label kosong semua → cAdvisor tidak membaca label Docker Compose (cek mounts /var/run/docker.sock)")
        else:
            ok_items.append(f"compose_service labels set={svc_set}")

        pressure = d.get("pressure_cpu", 0)
        if pressure == 0:
            issues.append("pressure metrics=0 → PSI tidak tersedia (kernel < 4.20 atau CONFIG_PSI=n)")

        print(f"\n  {n}")
        for msg in ok_items:
            print(f"    ✓ {msg}")
        for msg in issues:
            print(f"    ⚠ {msg}")
        if not issues:
            print(f"    ✓ Tidak ada masalah konfigurasi yang terdeteksi")

    print()
    print(SEP)
    print(" QUICK DIFF (nilai yang BEDA antar server)")
    print(SEP)

    all_keys = [k for k, _ in METRICS] + [k for k, _ in STRUCT]
    diffs = []
    for key in all_keys:
        vals = {}
        for n in ok:
            vals[n] = str(results[n]["data"].get(key, 0))
        if len(set(vals.values())) > 1:
            diffs.append((key, vals))

    if not diffs:
        print("  Semua server identik untuk semua metric counts. ✓")
    else:
        for key, vals in diffs:
            print(f"\n  {key}:")
            for n, v in vals.items():
                marker = " ←" if v != max(vals.values(), key=lambda x: int(x) if x.isdigit() else 0) else "  "
                print(f"    {n:<28} {v}{marker}")

    print()

if __name__ == "__main__":
    main()
