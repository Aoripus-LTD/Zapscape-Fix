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

- [Quick Start](#quick-start)
- [System Requirements](#system-requirements)
- [Deployment (manual, recommended)](#deployment-manual-recommended)
- [Verifying the Patch](#verifying-the-patch)
- [Rollback](#rollback)
- [FAQ](#faq)
- [Project Layout](#project-layout)
- [References](#references)
- [Copyright & License](#copyright--license)

---

## Quick Start

On the host (about 30 minutes including the build):

```bash
# In mainland China, clone via the CDN mirror (direct GitHub may fail):
#   git clone https://cdn.akaere.online/github.com/Aoripus-LTD/Zapscape-Fix.git
git clone https://github.com/Aoripus-LTD/Zapscape-Fix.git
cd Zapscape-Fix/livepatch

# 1. build the live-patch module (-s points at the source directory you
#    extracted in Deployment step 3, e.g. /root/linux-4.18.0-553.6.1.el8_10,
#    matching THIS host's kernel version; the script auto-detects the
#    code shape and picks the variant)
#    In mainland China append -cn (fetches kpatch via the CDN mirror):
#    ./build-livepatch.sh -s /root/linux-<your-kernel-source-dir> -j "$(nproc)" -cn
./build-livepatch.sh -s /root/linux-<your-kernel-source-dir> -j "$(nproc)"

# 2. apply online (~2 seconds, VMs are unaware)
kpatch load /root/kpatch-out/zapscape_cve_2026_64561.ko

# 3. confirm
kpatch list
```

`zapscape_cve_2026_64561 [enabled]` means deployment is complete. Full
steps in [Deployment](#deployment-manual-recommended) below.

### Mainland China network

The scripts accept a `-cn` flag: every download that normally uses
`github.com` is redirected to the `cdn.akaere.online/github.com` mirror;
everything else is identical:

```bash
./build-livepatch.sh -s /root/linux-<your-kernel-source-dir> -j "$(nproc)" -cn   # build (mirror)
./one-click.sh -cn                                                               # one-shot (experimental, mirror)
```

> `dnf` repositories (gcc, kernel-devel, ...) use whatever the system is
> configured with; if dnf is slow, configure a domestic mirror yourself —
> the scripts do not touch your dnf configuration.

> **On multi-version support**: patches and scripts are generic — run the
> same flow on any `4.18.0-*` CentOS Stream 8 / RHEL 8 host and it builds
> and loads a module matching that host's **current kernel** (build output
> is bound to the kernel version and cannot be shared across versions;
> every code shape from `4.18.0-193` to `4.18.0-553` has been verified
> applicable, and `4.18.0-553.6.1` completed the full zero-downtime
> verification).

---

## System Requirements

| item | requirement |
|---|---|
| OS | CentOS Stream 8 / RHEL 8 (8.0 through 8.10) |
| kernel | any `4.18.0-*` (all code shapes from `4.18.0-80` to `4.18.0-553` covered) |
| privilege | root |
| dependencies | gcc, make, git, patch, elfutils, openssl-devel, bc, bison, flex, dwarves, kpatch, kernel-devel (matching `uname -r`), kernel source RPM |
| time | first build 20–40 min (CPU-core dependent) |

> Check livepatch support first: `grep CONFIG_LIVEPATCH /boot/config-$(uname -r)`
> should be `=y` (default on RHEL 8 / Stream 8).

---

## Deployment (manual, recommended)

### Step 1 — install the toolchain

```bash
dnf install -y gcc make git patch elfutils elfutils-devel \
               elfutils-libelf-devel openssl-devel bc bison flex dwarves \
               yum-utils dnf-plugins-core kpatch kpatch-dnf
```

### Step 2 — install kernel-devel (must match the running kernel)

```bash
dnf install -y kernel-devel-$(uname -r)
```

### Step 3 — fetch the kernel source

```bash
dnf download --source kernel
rpm2cpio kernel-*.src.rpm | cpio -idmv 'linux*.tar.xz'
tar xf linux-*.tar.xz
```

> Remember the extracted directory name (e.g. `/root/linux-4.18.0-553.6.1.el8_10`).
> If `dnf download --source` is unavailable (CentOS Stream 8 reached EOL in
> 2024-05), grab the matching `kernel-*.src.rpm` from
> [vault.centos.org](https://vault.centos.org/).

### Step 4 — build the live-patch module

```bash
cd Zapscape-Fix/livepatch
./build-livepatch.sh -s <source dir from step 3> -j "$(nproc)" -o /root/kpatch-out
```

The script auto-detects the kernel code shape and picks the correct patch
variant. Output: `/root/kpatch-out/zapscape_cve_2026_64561.ko`.

### Step 5 — apply online

```bash
kpatch load /root/kpatch-out/zapscape_cve_2026_64561.ko
```

Takes about 2 seconds; every task (including live vCPU threads) migrates at
a safe point — **VMs and workloads are unaware**.

### Step 6 — verify

```bash
cd Zapscape-Fix/livepatch
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

**Verified in production shape on 2026-08-07**: on a real CubeCloud
(魔方云) KVM host with a tenant VM running — patch transition completed in
2 s, VM qemu PID unchanged, guest uptime continuous, guest fully
functional, host never rebooted.

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
    ├── build-livepatch.sh  build the module (auto variant selection)
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

---

## Copyright & License

```
Copyright © 2026 Aoripus (Beijing) Technology Co., Ltd. (安锐普世（北京）科技有限公司)
Contact: master@aoripus.com
```

- Kernel patches: GPL-2.0 (same as the Linux kernel)
- Scripts & documentation: GPL-2.0-or-later
- Defensive security engineering for hardening hosts you own. No warranty.
