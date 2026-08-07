# Zapscape-Fix — CVE-2026-64561 Kernel Live Patch (KVM/x86)

> **English | [简体中文](README.md)**

A **kernel live patch** that fixes **CVE-2026-64561 (Zapscape)** on
**CentOS Stream 8 / RHEL 8** KVM hosts (all `4.18.0-*` kernels).

**Without the patch**: a tenant VM (guest) can escape to the host with
guest-side actions alone and execute code with host kernel root — taking
down the physical host and every VM on it.

**This patch**: a backport of the upstream Linux fix (`2abd5287f083`),
applied online via the kernel livepatch mechanism:

> ✅ no host reboot　✅ no VM restart　✅ no virtualization feature disabled
> ✅ fully transparent

---

## Table of Contents

- [Affected CPUs](#affected-cpus)
- [Kernel-ML (ELRepo mainline) Support](#kernel-ml-elrepo-mainline-support)
- [System Requirements](#system-requirements)
- [Deployment](#deployment)
- [Verifying the Patch](#verifying-the-patch)
- [Rollback](#rollback)
- [FAQ](#faq)
- [Project Layout](#project-layout)
- [References](#references)
- [Copyright & License](#copyright--license)

---

## Affected CPUs

Zapscape's trigger conditions differ by platform: **AMD has no extra
hardware requirement** (any CPU with SVM/NPT can trigger it); **Intel must
support 5-level EPT (EPT page-walk length 5, PWL5)** and the host must
expose it to L1 — otherwise the root/child alias cannot be built and this
attack path does not exist.

| platform | CPU family | triggerable (needs the patch) |
|---|---|---|
| Intel | Xeon Scalable 1st Gen — Skylake-SP (4100/5100/6100/8100) | ✗ no |
| Intel | Xeon Scalable 2nd Gen — Cascade Lake (4200/5200/6200/8200) | ✗ no (incl. the 8259CL tested for this repo) |
| Intel | Xeon Scalable 3rd Gen — Ice Lake-SP (4300/5300/6300/8300) | ✓ yes |
| Intel | Xeon Scalable 4th Gen — Sapphire Rapids (8400) | ✓ yes |
| Intel | Xeon Scalable 5th Gen — Emerald Rapids (8500) | ✓ yes |
| Intel | others (Xeon E, Cooper Lake 83xxH, edge SKUs) | verify on the actual box |
| AMD | EPYC 1st–3rd Gen (Naples 7001 / Rome 7002 / Milan 7003) | ✓ yes (no LA57 needed) |
| AMD | EPYC 4th Gen (Genoa/Bergamo/Siena 9004/8004) | ✓ yes |

**Basis**: 5-level paging / 5-level EPT was first implemented by Intel in
the **Ice Lake** microarchitecture (Wikipedia: "Intel 5-level paging"; Intel
white paper *5-Level Paging and 5-Level EPT*, doc 671442). Measured on the
Xeon Platinum 8259CL (Cascade Lake) used for this repo:
`IA32_VMX_EPT_VPID_CAP (MSR 0x48C)` bit 7 (PWL5) = **0**, and
`/proc/cpuinfo` has no `la57` — confirming Cascade Lake and older have no
5-level EPT. AMD's NPT is always a 4-level hardware walk; Zapscape needs no
5-level capability there, so all AMD generations are affected.

> ⚠️ The table is a guide — **measure on your actual box** (vendors/firmware
> may disable features). One command to check whether your Intel host needs
> the patch:

```bash
# Method 1 (simple): check LA57 (5-level paging)
grep -m1 flags /proc/cpuinfo | grep -o la57 && echo "LA57 present -> patch needed" || echo "no LA57 -> most likely not needed"

# Method 2 (direct, Intel only): read EPT capability MSR 0x48C bit 7 (PWL5)
dnf install -y msr-tools && modprobe msr
V=$(rdmsr -p0 0x48c); echo "EPT PWL5 support: $(( (0x$V >> 7) & 1 ))"   # 1=supported (patch needed) 0=not supported
```

> ⚠️ "Not triggerable" ≠ "absolutely safe": it only means the Zapscape Intel
> path does not exist; other KVM shadow-MMU risks remain — keep following
> official security updates.

---

## Kernel-ML (ELRepo mainline) Support

If your host runs an ELRepo `kernel-ml` (mainline) kernel — e.g. because
other CVEs forced a kernel upgrade — Zapscape's fix state depends on the
version:

| kernel-ml version | Zapscape state | action |
|---|---|---|
| 7.1.3 / 7.1.4 | ❌ vulnerable (verified in source) | upgrade to 7.1.7, or apply this repo's patch |
| 7.1.5 / 7.1.6 | ✅ fixed (upstream 2abd5287f083 merged) | nothing to do |
| 7.1.7 | ✅ fixed (verified in source) | nothing to do |

- **Recommended**: upgrade kernel-ml to the current release (7.1.7) — the
  vulnerability is fixed upstream, no live patch needed.
- **Temporary hardening for 7.1.3/7.1.4**: `build-livepatch.sh`
  auto-detects the mainline code shape and picks
  `patches/cve-2026-64561-kernel-ml.patch` (a backport exactly equivalent
  to upstream `2abd5287f083`; verified applicable on 7.1.3/7.1.4 sources
  and rejected on the already-fixed 7.1.7). Same zero-downtime live
  patching.

### Installing kernel-ml in mainland China (ELRepo mirrors)

The official ELRepo repos (elrepo.org) are very slow from mainland China
(measured ~15 kB/s). Use a domestic mirror instead (measured 4 MB/s+):

```bash
# install elrepo-release once
dnf install -y https://www.elrepo.org/elrepo-release-8.el8.elrepo.noarch.rpm

# point elrepo-kernel at the TUNA mirror (USTC works too:
#   https://mirrors.ustc.edu.cn/elrepo/kernel/el8/$basearch/)
awk '
/^\[elrepo-kernel\]/ {ink=1}
/^\[/ && !/^\[elrepo-kernel\]/ {ink=0}
ink && /^baseurl=/ { print "baseurl=https://mirrors.tuna.tsinghua.edu.cn/elrepo/kernel/el8/$basearch/"; next }
ink && /^[[:space:]]/ { next }
ink && /^mirrorlist=/ { print "#" $0; next }
{ print }
' /etc/yum.repos.d/elrepo.repo > /etc/yum.repos.d/elrepo.repo.new && \
mv /etc/yum.repos.d/elrepo.repo.new /etc/yum.repos.d/elrepo.repo

# install the latest mainline kernel (kernel-ml-devel is needed for
# kpatch builds too)
dnf --enablerepo=elrepo-kernel install -y kernel-ml kernel-ml-devel

# confirm the new kernel is the default boot entry
grubby --default-kernel
# expect /boot/vmlinuz-7.1.7-1.el8.elrepo.x86_64
```

> ⚠️ A kernel upgrade **requires a reboot** to take effect; the reboot
> invalidates any live patch loaded on the 4.18 kernel (not needed on the
> fixed 7.1.7). Before rebooting, make sure your VMs are recoverable
> (the 魔方云 panel restarts the VMs it manages).

---

## System Requirements

| item | requirement |
|---|---|
| OS | CentOS Stream 8 / RHEL 8 (8.0 through 8.10) |
| virtualization platform | 智简魔方 魔方云 KVM加强版 ([idcsmart Cloud KVM](https://www.idcsmart.com)) — **tested & verified** |
| kernel | any `4.18.0-*` (all code shapes from `4.18.0-80` to `4.18.0-553` covered) |
| privilege | root |
| dependencies | gcc, make, git, patch, elfutils, openssl-devel, bc, bison, flex, dwarves, kpatch, kernel-devel (matching `uname -r`), kernel source RPM |
| time | first build 20–40 min (CPU-core dependent) |

> The kernel must support livepatch (`CONFIG_LIVEPATCH=y`, default on
> RHEL 8 / Stream 8); deployment step 0 checks this first.

---

## Deployment

### Step 0 — confirm the kernel supports livepatch

```bash
grep CONFIG_LIVEPATCH /boot/config-$(uname -r)
```

Must print `CONFIG_LIVEPATCH=y`; otherwise this kernel cannot be live-patched.

### Step 1 — get this project

```bash
# In mainland China, use the ghproxy mirror (direct GitHub may fail):
#   git clone https://ghproxy.net/github.com/Aoripus-LTD/Zapscape-Fix.git
git clone https://github.com/Aoripus-LTD/Zapscape-Fix.git
cd Zapscape-Fix/livepatch
```

### Step 2 — install the toolchain

```bash
dnf install -y gcc make git patch elfutils elfutils-devel \
               elfutils-libelf-devel openssl-devel bc bison flex dwarves \
               yum-utils dnf-plugins-core kpatch kpatch-dnf
```

### Step 3 — install kernel-devel (must match the running kernel)

```bash
dnf install -y kernel-devel-$(uname -r)
```

### Step 4 — fetch the kernel source ⚠️ important

**CentOS Stream 8 reached EOL on 2024-05-31** — the default repos are dead,
so `dnf download --source kernel` fails on virtually every machine. Use
either method below.

#### Method A: switch dnf to a vault mirror (recommended; the whole dnf works again)

Using the Aliyun mirror (verified working in our test environment):

```bash
# Point Stream 8 repos at the vault snapshot instead of the dead mirrorlist
sed -i 's|^mirrorlist=|#mirrorlist=|; s|^#baseurl=http://mirror.centos.org|baseurl=http://mirrors.aliyun.com/centos-vault|' \
    /etc/yum.repos.d/CentOS-Stream-*.repo

dnf clean all && dnf makecache

# Now the normal command works (it auto-locates the right file)
dnf download --source kernel
```

> The Tsinghua mirror works too: replace `mirrors.aliyun.com/centos-vault`
> with `mirrors.tuna.tsinghua.edu.cn/centos-vault`.

#### Method B: download the source RPM directly with curl

```bash
# URL rule: <mirror>/centos-vault/8-stream/BaseOS/Source/SPackages/Packages/kernel-<kernel-version>.src.rpm
# kernel-version = uname -r without the trailing .x86_64, e.g.:
curl -O http://mirrors.aliyun.com/centos-vault/8-stream/BaseOS/Source/SPackages/Packages/kernel-4.18.0-553.6.1.el8.src.rpm

# or build it for your own kernel automatically:
VER=$(uname -r | sed 's/\.x86_64$//')
curl -O "http://mirrors.aliyun.com/centos-vault/8-stream/BaseOS/Source/SPackages/Packages/kernel-${VER}.src.rpm"
```

#### Extract the source

```bash
rpm2cpio kernel-*.src.rpm | cpio -idmv 'linux*.tar.xz'
tar xf linux-*.tar.xz
SRC=$(ls -d /root/linux-* | head -1)
echo "kernel source dir: $SRC"
```

### Step 5 — build the live-patch module

```bash
./build-livepatch.sh -s "$SRC" -j "$(nproc)"
```

> In mainland China append `-cn` (kpatch fetched via the ghproxy mirror):
> `./build-livepatch.sh -s "$SRC" -j "$(nproc)" -cn`

The script auto-detects the kernel code shape and picks the correct patch
variant; nothing to choose manually. Output:
`/root/kpatch-out/zapscape_cve_2026_64561.ko`.

### Step 6 — apply online

```bash
kpatch load /root/kpatch-out/zapscape_cve_2026_64561.ko
```

Takes about 2 seconds; every task (including live vCPU threads) migrates at
a safe point — **VMs and workloads are unaware**.

### Step 7 — verify

```bash
./verify-livepatch.sh
```

---

## Verifying the Patch

```bash
kpatch list
```

```
Loaded patch modules:
zapscape_cve_2026_64561 [enabled]
```

The patch replaces 4 KVM page-fault handlers:

```
direct_page_fault,1
paging64_page_fault,1
paging32_page_fault,1
ept_page_fault,1
```

(listed under `/sys/kernel/livepatch/zapscape_cve_2026_64561/kvm/`, `,1` =
replaced)

**Verified in production shape on 2026-08-07**: on a real 智简魔方
魔方云 KVM加强版 (idcsmart Cloud KVM) host with a tenant VM running —
patch transition completed in 2 s, VM qemu PID unchanged, guest uptime
continuous, guest fully functional, host never rebooted.

---

## Rollback

```bash
kpatch disable zapscape_cve_2026_64561   # deactivate (tasks return to old code)
kpatch unload zapscape_cve_2026_64561    # unload the module
```

Instant rollback; the kernel itself is never rewritten.

> ⚠️ **A host reboot invalidates the live patch** — reload with
> `kpatch load /root/kpatch-out/zapscape_cve_2026_64561.ko` afterwards, or use
> kpatch-dnf to follow kernel updates automatically.

---

## FAQ

**Q: Does it support my specific 4.18.0-XXX kernel?**
Yes. The build script auto-selects the patch variant by code shape,
covering every RHEL 8.0–8.10 / CentOS Stream 8 `4.18.0-*` kernel
(variant table: [docs/TECHNICAL.md](docs/TECHNICAL.md)).

**Q: `dnf download --source kernel` fails / package not found?**
Expected after the Stream 8 EOL. Switch the repos to a vault mirror
(Deployment step 4, method A) or download the RPM directly by URL
(method B).

**Q: Does loading the patch affect running VMs?**
No. Verified live: the qemu process, guest uptime and in-guest services are
unaffected. The patch only reorders two statements in the KVM page-fault
path; no data structures or virtualization features change.

**Q: Relation to Red Hat?**
This is a backport of the official upstream fix (`2abd5287f083`). RHEL 8 is
EOL and has no official KLP, so we provide a self-built live patch using the
same mechanism as Red Hat's official KLP (kpatch / CONFIG_LIVEPATCH).

**Q: Is one-click.sh safe to use?**
⚠️ **Experimental, not fully tested.** Its logic mirrors the manual steps,
but please **follow the manual steps above**; read the script before use.

**Q: Is this an attack tool?**
No. This repository contains only **defensive** fixes and deployment
scripts. The exploit (PoC) lives in the researcher's repo
([V4bel/Zapscape](https://github.com/V4bel/Zapscape)) — never use it
against systems you do not own.

---

## Project Layout

```
Zapscape-Fix/
├── README.md              this document (Chinese default)
├── README.en.md           English version
├── LICENSE                GPL-2.0
├── SECURITY.md            disclosure policy
├── docs/
│   ├── TECHNICAL.md       vulnerability, fix, variant table (Chinese)
│   └── ANALYSIS.md        line-level code evidence (English, for researchers)
├── patches/               7 patch variants for all 4.18.0 code shapes
└── livepatch/
    ├── build-livepatch.sh  build the module (auto variant selection, -cn)
    ├── load-livepatch.sh   apply the patch
    ├── verify-livepatch.sh verify the patch
    ├── install-deps.sh     prerequisite installer (helper)
    └── one-click.sh        one-shot deployment (⚠️ experimental)
```

---

## References

- PoC & technical write-up — <https://github.com/V4bel/Zapscape>
- Upstream fix — <https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=2abd5287f083>
- Patch discussion — <https://lore.kernel.org/all/20260721102829.313226-1-pbonzini@redhat.com/>
- Introducing commit — <https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=f95eec9bed76>
- kpatch — <https://github.com/dynup/kpatch>
- "Affected CPUs" sources:
  - Wikipedia: Intel 5-level paging (first implemented in Ice Lake) — <https://en.wikipedia.org/wiki/Intel_5-level_paging>
  - Intel white paper *5-Level Paging and 5-Level EPT* (doc 671442) — <https://www.intel.com/content/www/us/en/content-details/671442/5-level-paging-and-5-level-ept-white-paper.html>
  - `IA32_VMX_EPT_VPID_CAP` bit layout (`VMX_EPT_PAGE_WALK_4_BIT`/`_5_BIT`, Linux header `arch/x86/include/asm/vmx.h`)
  - KVM L1 EPT-cap passthrough logic (Linux `arch/x86/kvm/vmx/nested.c`)
  - Measured for this repo: Xeon Platinum 8259CL MSR 0x48C bit 7 (PWL5) = 0 (see table above)

---

## Acknowledgements

Thanks to **林枫云（四川）网络科技有限公司 (LinFengYun)** for providing the
verification/test server for this work right after the PoC disclosure.

---

## Copyright & License

- **Copyright**: © 2026 Aoripus (Beijing) Technology Co., Ltd. · 安锐普世（北京）科技有限公司
- **Contact**: master@aoripus.com
- **Kernel patches**: GPL-2.0 (same as the Linux kernel)
- **Scripts & documentation**: GPL-2.0-or-later
- **Disclaimer**: defensive security engineering for hardening hosts you own; no warranty.
