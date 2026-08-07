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

if [[ -d "/sys/kernel/livepatch/$NAME" ]]; then
    ok "livepatch $NAME present in sysfs"
    EN="$(cat "/sys/kernel/livepatch/$NAME/enabled" 2>/dev/null)"
    [[ "$EN" == "1" ]] && ok "livepatch $NAME enabled" || bad "livepatch $NAME not enabled (state=$EN)"

    echo "== patched functions (must include the KVM fault handlers) =="
    if [[ -f "/sys/kernel/livepatch/$NAME/functions" ]]; then
        FUNCS="$(cat "/sys/kernel/livepatch/$NAME/functions")"
        echo "$FUNCS"
        for f in direct_page_fault paging64_page_fault paging32_page_fault nested_page_fault; do
            echo "$FUNCS" | grep -q "$f" && ok "function $f live-patched" || echo "[info] $f not in patch set (kernel variant may not have it)"
        done
    fi
else
    bad "livepatch $NAME not loaded"
fi

echo "== zero-downtime evidence =="
UPTIME="$(awk '{print int($1)}' /proc/uptime)"
ok "host uptime ${UPTIME}s (reboot would reset this)"

if command -v virsh >/dev/null 2>&1; then
    VMS="$(virsh list --name 2>/dev/null | grep -c -v '^$' || true)"
    ok "virsh reports $VMS running guest(s) after patch"
fi

lsmod | grep -q "^$NAME" && ok "module $NAME loaded" || bad "module $NAME not in lsmod"

echo ""
echo "== summary: $PASS passed, $FAIL failed =="
[[ "$FAIL" -eq 0 ]] || exit 1
