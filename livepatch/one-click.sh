#!/usr/bin/env bash
#
# one-click.sh — build, load and verify the CVE-2026-64561 (Zapscape)
# live patch in one shot, with zero downtime.
#
# Steps:
#   1. install prerequisites (toolchain, kernel-devel, kernel source RPM)
#   2. build the live-patch module for the running kernel (kpatch-build)
#   3. apply it live (no reboot, no VM restart, no feature disabled)
#   4. verify the patch is active and KVM still works
#
# Usage: ./one-click.sh          (run from the livepatch/ directory as root)
#        ./one-click.sh -cn      (China mainland: fetch kpatch via CDN mirror
#                                 ghproxy.net instead of github.com)
#        SKIP_BUILD=1 ./one-click.sh   (only install deps + load + verify)
#
set -euo pipefail

cd "$(dirname "$0")"

CN_MODE=0
ARGS=()
for arg in "$@"; do
    case "$arg" in
        -cn|--cn|-c) CN_MODE=1 ;;
        *) ARGS+=("$arg") ;;
    esac
done
set -- "${ARGS[@]}"

echo "=============================================================="
echo " Zapscape-Fix (CVE-2026-64561) one-click live patch"
echo " target: $(uname -r)"
[[ "$CN_MODE" -eq 1 ]] && echo " network: China mainland mode (ghproxy.net mirror)"
echo "=============================================================="

[[ "$(id -u)" -eq 0 ]] || { echo "ERROR: run as root" >&2; exit 1; }

# --- 1. prerequisites -----------------------------------------------------
./install-deps.sh

# --- 2. build (unless skipped) -------------------------------------------
KO="/root/kpatch-out/zapscape_cve_2026_64561.ko"
if [[ "${SKIP_BUILD:-0}" != "1" && ! -f "$KO" ]]; then
    SRC="$(ls -d /root/kernel-src/linux-* | head -1)"
    echo ""
    echo "[*] building live-patch module (this takes a while: vmlinux + modules)"
    BUILD_ARGS=(-s "$SRC" -j "$(nproc)" -o /root/kpatch-out)
    [[ "$CN_MODE" -eq 1 ]] && BUILD_ARGS+=(-cn)
    ./build-livepatch.sh "${BUILD_ARGS[@]}"
fi
[[ -f "$KO" ]] || { echo "ERROR: $KO missing — run without SKIP_BUILD" >&2; exit 1; }

# --- 3. apply live --------------------------------------------------------
echo ""
echo "[*] applying live patch (no reboot, no VM restart)..."
if kpatch list 2>/dev/null | grep -q zapscape_cve_2026_64561; then
    echo "[*] patch already loaded"
else
    kpatch load "$KO"
fi

# --- 4. verify ------------------------------------------------------------
echo ""
./verify-livepatch.sh

echo ""
echo "[+] done — CVE-2026-64561 live patch active, zero downtime."
