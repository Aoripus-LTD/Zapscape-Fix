#!/usr/bin/env bash
#
# build-livepatch.sh — build a kpatch live-patch module for CVE-2026-64561
# (Zapscape) against the *running* CentOS Stream 8 / RHEL 8 kernel.
#
# Usage:
#   ./build-livepatch.sh -s <kernel-source-dir> [-j N] [-o outdir] [-n name]
#   ./build-livepatch.sh -s <kernel-source-dir> -cn   # China mainland: fetch
#                                                     # kpatch via CDN mirror
#                                                     # (ghproxy.net)
#
# The script is generic across all 4.18.0-* el8 kernels: it detects the KVM
# MMU layout in the source tree and picks the correct patch variant.
#
set -euo pipefail

SRCDIR=""
JOBS="$(nproc)"
OUTDIR="/root/kpatch-out"
NAME="zapscape_cve_2026_64561"
KPATCH_VER="v0.9.7"
CN_MODE=0

usage() {
    sed -n '2,12p' "$0"
    exit 1
}

# Accept -cn / --cn / -c (China mainland mirror mode) before getopts.
ARGS=()
for arg in "$@"; do
    case "$arg" in
        -cn|--cn|-c) CN_MODE=1 ;;
        *) ARGS+=("$arg") ;;
    esac
done
set -- "${ARGS[@]}"

while getopts "s:j:o:n:h" opt; do
    case "$opt" in
        s) SRCDIR="$OPTARG" ;;
        j) JOBS="$OPTARG" ;;
        o) OUTDIR="$OPTARG" ;;
        n) NAME="$OPTARG" ;;
        *) usage ;;
    esac
done

[[ -z "$SRCDIR" ]] && usage
[[ -d "$SRCDIR" ]] || { echo "ERROR: source dir $SRCDIR not found" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 0. Locate kpatch-build (either from a kpatch clone or install it)
# ---------------------------------------------------------------------------
KPATCH_URL="https://github.com/dynup/kpatch/archive/refs/tags/${KPATCH_VER}.tar.gz"
if [[ "$CN_MODE" -eq 1 ]]; then
    KPATCH_URL="https://ghproxy.net/${KPATCH_URL#https://}"
    echo "[*] China mainland mode (-cn): fetching kpatch via CDN mirror"
fi
if [[ ! -x /root/kpatch-src/kpatch-build/kpatch-build ]]; then
    echo "[*] fetching kpatch ${KPATCH_VER}"
    dnf install -y git >/dev/null
    cd /root
    curl -sL -o kpatch.tar.gz "$KPATCH_URL"
    tar xzf kpatch.tar.gz
    mv "kpatch-${KPATCH_VER#v}" kpatch-src
    make -C /root/kpatch-src/kpatch-build create-diff-object
fi
KB="/root/kpatch-src/kpatch-build/kpatch-build"

# ---------------------------------------------------------------------------
# 1. Kernel identity + prerequisites
# ---------------------------------------------------------------------------
KVER="$(uname -r)"
echo "[*] running kernel: $KVER"
[[ -d "/usr/src/kernels/$KVER" ]] || {
    echo "ERROR: kernel-devel-$KVER not installed (dnf install -y kernel-devel-\$(uname -r))" >&2
    exit 1
}

grep -q '^CONFIG_LIVEPATCH=y' "/boot/config-$KVER" || {
    echo "ERROR: running kernel has CONFIG_LIVEPATCH disabled — live patching impossible" >&2
    exit 1
}

# ---------------------------------------------------------------------------
# 2. Make the source tree build *this* kernel (vermagic must match)
# ---------------------------------------------------------------------------
cd "$SRCDIR"

# RHEL source tarballs ship EXTRAVERSION empty; the release lives in
# Makefile.rhelver.  The src.rpm is named after the rpm release, but the
# UTS_RELEASE of the running kernel has no trailing build suffix (el8_10
# etc.).  Rebuild the exact EXTRAVERSION from uname.
REL="${KVER#*-}"; REL="${REL%.*}"      # e.g. 553.6.1.el8  (drop .x86_64)
sed -i "s/^EXTRAVERSION.*/EXTRAVERSION = -${REL}/" Makefile
echo "[*] EXTRAVERSION set to: $(grep '^EXTRAVERSION' Makefile)"

# Use the running kernel's .config (it is the authoritative one).
cp "/usr/src/kernels/$KVER/.config" .config

# The src.rpm does not ship certs/rhel.pem; neutralize the key hooks.
sed -i 's|^CONFIG_SYSTEM_TRUSTED_KEYS=.*|CONFIG_SYSTEM_TRUSTED_KEYS=""|;
        s|^CONFIG_SYSTEM_REVOCATION_KEYS=.*|CONFIG_SYSTEM_REVOCATION_KEYS=""|' .config

# ---------------------------------------------------------------------------
# 3. Pick the patch variant for this source tree (auto-detect by code shape)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PATCHES_DIR="$(dirname "$SCRIPT_DIR")/patches"

pick_patch() {
    if [[ ! -f arch/x86/kvm/mmu/mmu.c ]]; then
        # RHEL 8.0-8.2: single arch/x86/kvm/mmu.c, tdp_page_fault()
        echo "$PATCHES_DIR/cve-2026-64561-rhel8-legacy-mmu.patch"
        return
    fi

    if grep -q 'is_page_fault_stale(vcpu, fault, mmu_seq)' arch/x86/kvm/mmu/mmu.c; then
        if grep -q 'if (is_tdp_mmu_fault) {' arch/x86/kvm/mmu/mmu.c; then
            # RHEL 8.10 / CentOS Stream 8 final (4.18.0-553.x): braced branch
            echo "$PATCHES_DIR/cve-2026-64561-rhel8-mmu-dir.patch"
        else
            # CentOS Stream 8 4.18.0-408/448 era: unbraced branch
            echo "$PATCHES_DIR/cve-2026-64561-rhel8-stream408-mmu.patch"
        fi
        return
    fi

    if grep -q 'mmu_notifier_retry_hva' arch/x86/kvm/mmu/mmu.c; then
        if grep -q 'is_tdp_mmu_root(vcpu->kvm' arch/x86/kvm/mmu/mmu.c; then
            # RHEL 8.5 (4.18.0-348.x)
            echo "$PATCHES_DIR/cve-2026-64561-rhel8-8.5-mmu.patch"
        else
            # CentOS Stream 8 4.18.0-365/383 era (is_tdp_mmu_fault variable)
            echo "$PATCHES_DIR/cve-2026-64561-rhel8-stream365-mmu.patch"
        fi
        return
    fi

    if grep -q 'kvm_tdp_mmu_map' arch/x86/kvm/mmu/mmu.c; then
        # RHEL 8.4 (4.18.0-305.x)
        echo "$PATCHES_DIR/cve-2026-64561-rhel8-8.4-mmu.patch"
    else
        # RHEL 8.3 (4.18.0-240.x)
        echo "$PATCHES_DIR/cve-2026-64561-rhel8-8.3-mmu.patch"
    fi
}

PATCH="$(pick_patch)"
echo "[*] detected patch variant: $(basename "$PATCH")"
[[ -f "$PATCH" ]] || { echo "ERROR: $PATCH missing" >&2; exit 1; }

# Sanity-check the patch applies to the pristine tree.
if ! patch -p1 --dry-run -d "$SRCDIR" < "$PATCH" >/dev/null 2>&1; then
    echo "ERROR: patch does not apply cleanly to $SRCDIR" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 4. Build the live-patch module (kpatch-build builds vmlinux itself)
# ---------------------------------------------------------------------------
mkdir -p "$OUTDIR"
echo "[*] building live-patch module (this takes a while: vmlinux + modules)"
"$KB" -s "$SRCDIR" -j "$JOBS" -o "$OUTDIR" -n "$NAME" "$PATCH"

KO="$OUTDIR/$NAME.ko"
[[ -f "$KO" ]] || { echo "ERROR: $KO not produced" >&2; exit 1; }
echo ""
echo "[+] live-patch module ready: $KO"
echo "    apply with:  kpatch load $KO   (or ./load-livepatch.sh $KO)"
