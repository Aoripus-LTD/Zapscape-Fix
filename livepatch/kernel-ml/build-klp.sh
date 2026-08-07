#!/bin/bash
# build-klp.sh - build the CVE-2026-64561 (Zapscape) livepatch module
# for kernel-ml 7.1.3/7.1.4 using the in-kernel KLP toolchain
# (objtool klp diff / post-link). No kpatch needed.
#
# Usage:
#   ./build-klp.sh -s <src> [-p <patch>] [-o <outdir>] [-j <jobs>]
#
#   -s  source tree of the RUNNING (vulnerable) kernel, e.g. 7.1.3
#       (must be fully built once: .config/Module.symvers present)
#   -p  backport patch to apply for the "patched" side
#       (default: ../patches/cve-2026-64561-kernel-ml.patch)
#   -o  output directory (default: ./klp-out)
#   -j  make jobs (default: nproc)
#
# The "patched" mmu.o is produced by applying the patch to a COPY of the
# running kernel's source and rebuilding mmu.o - NOT by using a different
# kernel version, whose mmu.c may contain unrelated changes.
#
set -euo pipefail

SRC=""; PATCH=""; OUT=""; JOBS="$(nproc)"
while getopts "s:p:o:j:h" opt; do
  case "$opt" in
    s) SRC="$OPTARG" ;;
    p) PATCH="$OPTARG" ;;
    o) OUT="$OPTARG" ;;
    j) JOBS="$OPTARG" ;;
    h) sed -n '2,18p' "$0"; exit 0 ;;
    *) exit 1 ;;
  esac
done
[ -n "$SRC" ] || { echo "need -s"; exit 1; }
OUT="${OUT:-$(pwd)/klp-out}"
PATCH="${PATCH:-$(dirname "$(readlink -f "$0")")/../../patches/cve-2026-64561-kernel-ml.patch}"
[ -f "$PATCH" ] || { echo "patch not found: $PATCH"; exit 1; }
mkdir -p "$OUT"

echo "==> checking kernel config"
for c in CONFIG_LIVEPATCH CONFIG_KLP_BUILD CONFIG_KALLSYMS_ALL CONFIG_DEBUG_INFO; do
  grep -q "^$c=y" "$SRC/.config" || { echo "missing $c in $SRC/.config"; exit 1; }
done
grep -q '^CONFIG_KVM=' "$SRC/.config" || { echo "CONFIG_KVM not modular in $SRC/.config"; exit 1; }

MMU="$SRC/arch/x86/kvm/mmu/mmu.c"
TMPL="$SRC/arch/x86/kvm/mmu/paging_tmpl.h"
[ -f "$MMU" ] || { echo "kernel source layout unexpected: $MMU missing"; exit 1; }

echo "==> compiling orig mmu.o"
(cd "$SRC" && make -j"$JOBS" arch/x86/kvm/mmu/mmu.o >"$OUT/make-orig.log" 2>&1)
cp "$SRC/arch/x86/kvm/mmu/mmu.o" "$OUT/mmu.o.orig"

echo "==> applying patch + compiling patched mmu.o (then restoring)"
cp "$MMU"  /tmp/zapscape-mmu.c.bak
cp "$TMPL" /tmp/zapscape-tmpl.h.bak
( cd "$SRC" && patch -p1 -f < "$PATCH" >"$OUT/patch.log" 2>&1 \
  && make -j"$JOBS" arch/x86/kvm/mmu/mmu.o >>"$OUT/make-fixed.log" 2>&1 \
  && cp arch/x86/kvm/mmu/mmu.o "$OUT/mmu.o.patched" ) || {
    echo "ERROR: patched mmu.o build failed - see $OUT/patch.log / $OUT/make-fixed.log";
    cp /tmp/zapscape-mmu.c.bak "$MMU"; cp /tmp/zapscape-tmpl.h.bak "$TMPL";
    exit 1; }
cp /tmp/zapscape-mmu.c.bak "$MMU"
cp /tmp/zapscape-tmpl.h.bak "$TMPL"
(cd "$SRC" && make -j"$JOBS" arch/x86/kvm/mmu/mmu.o >/dev/null 2>&1 || true)

OBJTOOL="$SRC/tools/objtool/objtool"
[ -x "$OBJTOOL" ] || { echo "objtool missing; build it: make -C $SRC/tools/objtool"; exit 1; }
# objtool klp requires libxxhash; probe the binary for the subcommand
# (running `objtool klp` without args exits 1 even when supported; and
#  grep -q would SIGPIPE strings, so count matches instead)
if [ "$(strings "$OBJTOOL" | grep -c 'Generate binary diff')" = "0" ]; then
  echo "objtool lacks 'klp' subcommand - install xxhash-devel and rebuild:"
  echo "  dnf install -y xxhash-devel && make -C $SRC/tools/objtool"
  exit 1
fi

echo "==> checksums + objtool klp diff (cwd=$SRC, has Module.symvers)"
(cd "$OUT" && "$OBJTOOL" --checksum mmu.o.orig && "$OBJTOOL" --checksum mmu.o.patched)
(cd "$SRC" && KLP_OBJNAME=kvm "$OBJTOOL" klp diff \
  "$OUT/mmu.o.orig" "$OUT/mmu.o.patched" "$OUT/mmu_klp.o")

echo "==> globalizing patched functions"
(cd "$OUT" && objcopy \
  --globalize-symbol=direct_page_fault \
  --globalize-symbol=paging64_page_fault \
  --globalize-symbol=paging32_page_fault \
  --globalize-symbol=ept_page_fault \
  mmu_klp.o mmu_klp_glob.o && touch .mmu_klp_glob.o.cmd)

echo "==> linking module"
W="$(dirname "$(readlink -f "$0")")"
cp "$W/zapscape_klp_wrapper.c" "$OUT/"
cat > "$OUT/Makefile" <<EOF
obj-m += zapscape_klp.o
zapscape_klp-objs := zapscape_klp_wrapper.o mmu_klp_glob.o
ccflags-y += -I$SRC/arch/x86/kvm
ccflags-y += -I$SRC/arch/x86/kvm/mmu
EOF
make CONFIG_KLP_BUILD= KBUILD_NSDEPS=1 -C "/lib/modules/$(uname -r)/build" \
  M="$OUT" modules >/dev/null 2>&1 || {
    echo "module build failed; try: make CONFIG_KLP_BUILD= KBUILD_NSDEPS=1 -C /lib/modules/\$(uname -r)/build M=$OUT modules V=1"
    exit 1; }

echo "==> objtool klp post-link"
"$OBJTOOL" klp post-link "$OUT/zapscape_klp.ko"

echo
echo "DONE: $OUT/zapscape_klp.ko"
echo "load with: ./load-klp.sh $OUT/zapscape_klp.ko"
