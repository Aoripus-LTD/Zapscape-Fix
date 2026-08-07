#!/usr/bin/env bash
#
# install-deps.sh — one-shot prerequisite installer for the Zapscape-Fix
# live-patch toolchain on CentOS Stream 8 / RHEL 8.
#
# Installs: build toolchain, kernel-devel for the running kernel, kpatch
# user-space tooling, and the kernel source RPM (extracted to
# /root/kernel-src/).
#
# Usage: ./install-deps.sh
#
set -euo pipefail

KVER="$(uname -r)"

echo "[*] host: $(. /etc/os-release; echo "$PRETTY_NAME")  kernel: $KVER"
[[ "$(id -u)" -eq 0 ]] || { echo "ERROR: run as root" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Toolchain + kpatch tooling
# ---------------------------------------------------------------------------
echo "[*] installing build toolchain and kpatch tooling..."
dnf install -y \
    gcc make git patch \
    elfutils elfutils-devel elfutils-libelf-devel \
    openssl-devel bc bison flex dwarves \
    yum-utils dnf-plugins-core kpatch kpatch-dnf \
    >/dev/null

# ---------------------------------------------------------------------------
# 2. kernel-devel matching the running kernel
# ---------------------------------------------------------------------------
if [[ ! -d "/usr/src/kernels/$KVER" ]]; then
    echo "[*] installing kernel-devel-$KVER ..."
    dnf install -y "kernel-devel-$KVER" >/dev/null
fi

# ---------------------------------------------------------------------------
# 3. Kernel source (exact src.rpm for the running kernel)
# ---------------------------------------------------------------------------
mkdir -p /root/kernel-src
if [[ ! -d /root/kernel-src/linux-* ]]; then
    echo "[*] downloading kernel source RPM for $KVER ..."
    cd /root/kernel-src
    if ! dnf download --source kernel 2>/dev/null && ! yumdownloader --source kernel; then
        echo ""
        echo "ERROR: could not fetch the kernel source RPM." >&2
        echo "CentOS Stream 8 is EOL (2024-05); the default repos are dead." >&2
        echo "Fix: point the repos at a vault mirror, e.g. Aliyun:" >&2
        echo "  sed -i 's|^mirrorlist=|#mirrorlist=|; s|^#baseurl=http://mirror.centos.org|baseurl=http://mirrors.aliyun.com/centos-vault|' \\" >&2
        echo "      /etc/yum.repos.d/CentOS-Stream-*.repo" >&2
        echo "  dnf clean all && dnf makecache" >&2
        echo "or download directly:" >&2
        VER="$(uname -r | sed 's/\.x86_64$//')"
        echo "  curl -O http://mirrors.aliyun.com/centos-vault/8-stream/BaseOS/Source/SPackages/Packages/kernel-${VER}.src.rpm" >&2
        exit 1
    fi
    SRCRPM="$(ls kernel-*.src.rpm | head -1)"
    echo "[*] extracting $SRCRPM ..."
    rpm2cpio "$SRCRPM" | cpio -idmv 'linux*.tar.xz' >/dev/null 2>&1
    tar xf linux-*.tar.xz
    rm -f kernel-*.src.rpm linux-*.tar.xz
fi

SRC="$(ls -d /root/kernel-src/linux-* | head -1)"
echo ""
echo "[+] prerequisites ready:"
echo "    kernel-devel : /usr/src/kernels/$KVER"
echo "    kernel source: $SRC"
echo "    next step    : ./build-livepatch.sh -s $SRC -j $(nproc) -o /root/kpatch-out"
