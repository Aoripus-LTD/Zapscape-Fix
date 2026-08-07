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

- [System Requirements](#system-requirements)
- [Deployment](#deployment)
- [Verifying the Patch](#verifying-the-patch)
- [Rollback](#rollback)
- [FAQ](#faq)
- [Project Layout](#project-layout)
- [References](#references)
- [Copyright & License](#copyright--license)

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

---

## Copyright & License

```
Copyright © 2026 Aoripus (Beijing) Technology Co., Ltd. (安锐普世（北京）科技有限公司)
Contact: master@aoripus.com
```

- Kernel patches: GPL-2.0 (same as the Linux kernel)
- Scripts & documentation: GPL-2.0-or-later
- Defensive security engineering for hardening hosts you own. No warranty.
