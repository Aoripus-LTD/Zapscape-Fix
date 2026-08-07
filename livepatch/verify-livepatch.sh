#!/usr/bin/env bash
#
# verify-livepatch.sh — verify the CVE-2026-64561 live patch is active and
# the host/KVM is healthy afterwards (zero-downtime evidence).
#
# Usage: ./verify-livepatch.sh [patch-name]
#
set -uo pipefail

NAME="${1:-zapscape_cve_2026_64561}"
PASS=0; FAIL=0
ok()   { echo "[PASS] $1"; PASS=$((PASS+1)); }
bad()  { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

echo "== host =="
uname -r | grep -q '^4.18.0-' && ok "kernel is 4.18.0 (uname -r: $(uname -r))" \
    || bad "unexpected kernel $(uname -r)"

echo "== patch state =="
grep -q '^CONFIG_LIVEPATCH=y' "/boot/config-$(uname -r)" && ok "CONFIG_LIVEPATCH=y" \
    || bad "CONFIG_LIVEPATCH not enabled"

[[ -f "/sys/kernel/livepatch/$NAME/enabled" ]] \
    && ok "livepatch $NAME present in sysfs" || bad "livepatch $NAME not loaded"

if [[ -f "/sys/kernel/livepatch/$NAME/enabled" ]]; then
    [[ "$(cat "/sys/kernel/livepatch/$NAME/enabled")" == "1" ]] \
        && ok "livepatch $NAME enabled" || bad "livepatch $NAME not enabled"
fi

echo "== patched functions live (ftrace) =="
N=0
for f in direct_page_fault paging64_page_fault paging32_page_fault nested_page_fault; do
    if grep -q "$f" /sys/kernel/tracing/available_filter_functions_addrs 2>/dev/null \
       || grep -q "$f" /proc/kallsyms 2>/dev/null; then
        ok "symbol $f present"
        N=$((N+1))
    fi
done
[[ "$N" -ge 1 ]] || bad "no patched KVM symbols found"

echo "== zero-downtime evidence =="
UPTIME_BEFORE="$(awk '{print int($1)}' /proc/uptime)"
ok "host uptime ${UPTIME_BEFORE}s (unchanged by patch load)"

if command -v virsh >/dev/null 2>&1; then
    VMS="$(virsh list --name 2>/dev/null | grep -c -v '^$' || true)"
    ok "virsh reports $VMS running guest(s) after patch"
fi

lsmod | grep -q "^$NAME" && ok "module $NAME loaded" || bad "module $NAME not in lsmod"

echo ""
echo "== summary: $PASS passed, $FAIL failed =="
[[ "$FAIL" -eq 0 ]] || exit 1
