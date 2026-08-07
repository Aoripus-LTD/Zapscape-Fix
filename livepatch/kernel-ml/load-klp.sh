#!/bin/bash
# load-klp.sh - load and self-check the Zapscape livepatch for kernel-ml
# Usage: ./load-klp.sh <zapscape_klp.ko>
set -euo pipefail
KO="${1:?usage: $0 <zapscape_klp.ko>}"

echo "==> loading $KO"
insmod "$KO"
sleep 2

echo "==> livepatch status"
[ "$(cat /sys/kernel/livepatch/zapscape_klp/enabled)" = "1" ] || { echo "FAIL: not enabled"; exit 1; }
echo "enabled: 1"
echo "transition: $(cat /sys/kernel/livepatch/zapscape_klp/transition)"

echo "patched object 'kvm':"
[ "$(cat /sys/kernel/livepatch/zapscape_klp/kvm/patched)" = "1" ] || { echo "FAIL: kvm object not patched"; exit 1; }
echo "  kvm/patched: 1"
echo "patched functions (registered in klp object 'kvm'):"
ls /sys/kernel/livepatch/zapscape_klp/kvm/ | grep 'page_fault' || true

# authoritative check: kallsyms must show the new function bodies owned by
# this livepatch module (the originals stay in kvm.ko, ftrace redirects calls)
for f in direct_page_fault paging64_page_fault paging32_page_fault ept_page_fault; do
  grep -qE " t $f[[:space:]].*\[zapscape_klp\]" /proc/kallsyms || { echo "FAIL: $f not owned by zapscape_klp"; exit 1; }
  echo "  $f: replaced (new body in [zapscape_klp])"
done

echo "==> dmesg"
dmesg | grep -E 'livepatch: .*(enabling|complete)' | tail -3

echo
echo "OK - CVE-2026-64561 livepatch active. No reboot/VM restart needed."
