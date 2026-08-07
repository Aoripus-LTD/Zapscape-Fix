#!/usr/bin/env bash
#
# load-livepatch.sh — apply the CVE-2026-64561 live patch with zero downtime.
#
# Usage: ./load-livepatch.sh <zapscape_cve_2026_64561.ko>
#
set -euo pipefail

KO="${1:-/root/kpatch-out/zapscape_cve_2026_64561.ko}"
[[ -f "$KO" ]] || { echo "ERROR: $KO not found" >&2; exit 1; }

NAME="$(basename "$KO" .ko)"

echo "[*] loading live-patch module: $KO"

# Prefer the kpatch tool; fall back to modprobe + sysfs.
if command -v kpatch >/dev/null 2>&1; then
    kpatch load "$KO"
else
    insmod "$KO"
    echo 1 > "/sys/kernel/livepatch/$NAME/enabled"
fi

echo "[*] live-patch status:"
kpatch list 2>/dev/null || cat "/sys/kernel/livepatch/$NAME/enabled"

if [[ -f "/sys/kernel/livepatch/$NAME/enabled" ]] &&
   [[ "$(cat "/sys/kernel/livepatch/$NAME/enabled")" == "1" ]]; then
    echo "[+] CVE-2026-64561 live patch is ACTIVE — no reboot performed"
else
    echo "[-] patch not enabled yet; check dmesg" >&2
    exit 1
fi
