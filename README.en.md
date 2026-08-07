# Zapscape-Fix — CVE-2026-64561 Kernel Live Patch (KVM/x86)

> **English | [简体中文](README.md)**

Generic kernel live patch for the KVM/x86 shadow-MMU use-after-free
(Zapscape, CVE-2026-64561) on **CentOS Stream 8 / RHEL 8 (all 4.18.0
kernels)**:

**Zero downtime · no host reboot · no VM restart · no virtualization feature
disabled · fully transparent**

```
Copyright © 2026 Aoripus (Beijing) Technology Co., Ltd. (安锐普世（北京）科技有限公司)
Contact: master@aoripus.com
```

> **⚠️ This repository is defensive security work.** Apply the live patch only
> to hosts you own or are authorized to harden. Do not use this content (or the
> PoC it mitigates, V4bel/Zapscape) against systems you are not authorized to
> test.

---

## Table of Contents

1. [Quick Start (one-click script)](#1-quick-start-one-click-script)
2. [Prerequisites](#2-prerequisites)
3. [Manual Deployment (step by step)](#3-manual-deployment-step-by-step)
4. [Patch Variants vs. Kernel Versions](#4-patch-variants-vs-kernel-versions)
5. [Root Cause & The Fix](#5-root-cause--the-fix)
6. [Verification Record (2026-08-07)](#6-verification-record-2026-08-07)
7. [Rollback](#7-rollback)
8. [References](#8-references)
9. [Copyright & License](#9-copyright--license)

---

## 1. Quick Start (one-click script)

On the host (CentOS Stream 8 / RHEL 8, root):

```bash
git clone https://github.com/Aoripus-LTD/Zapscape-Fix.git
cd Zapscape-Fix/livepatch
./one-click.sh
```

The script performs four steps automatically:

| Step | What it does | Typical time |
|---|---|---|
| 1. Prerequisites | installs the build toolchain, `kernel-devel` (matching the running kernel), kpatch tooling; downloads & extracts the exact kernel source RPM | 2–5 min |
| 2. Build patch | `kpatch-build` builds the live-patch module from the **exact source of the running kernel** (vermagic matches precisely) | 20–40 min (~25 min on 96 cores) |
| 3. Apply patch | `kpatch load`; tasks migrate at safe points, **VMs are unaware** | 2 s |
| 4. Verify | checks patch state, replaced functions, KVM and VM health | instant |

> To only load an existing module: `SKIP_BUILD=1 ./one-click.sh`

---

## 2. Prerequisites

The one-click script handles everything; manual installation:

```bash
# toolchain + kpatch user-space tooling
dnf install -y gcc make git patch elfutils elfutils-devel \
               elfutils-libelf-devel openssl-devel bc bison flex dwarves \
               yum-utils dnf-plugins-core kpatch kpatch-dnf

# kernel-devel must match uname -r exactly
dnf install -y kernel-devel-$(uname -r)

# kernel source (required by kpatch-build to build a matching vmlinux)
dnf download --source kernel
rpm2cpio kernel-*.src.rpm | cpio -idmv 'linux*.tar.xz'
tar xf linux-*.tar.xz
```

**Kernel requirements** (all are CentOS Stream 8 / RHEL 8 defaults):

| Config | Requirement | Note |
|---|---|---|
| `CONFIG_LIVEPATCH` | `=y` | kernel live-patching support (default on RHEL 8) |
| `CONFIG_KALLSYMS` | `=y` | symbol resolution (default) |
| `CONFIG_DEBUG_INFO` | `=y` | kpatch-build needs DWARF (default) |
| `CONFIG_MODULE_SIG_FORCE` | not set | unsigned modules loadable (default on RHEL 8) |

> Note: CentOS Stream 8 reached EOL in 2024-05. If `dnf download --source
> kernel` is unavailable, fetch the matching src.rpm manually from
> vault.centos.org.

---

## 3. Manual Deployment (step by step)

```bash
cd livepatch

# 1) build the live-patch module (auto-detects the kernel code shape)
./build-livepatch.sh -s /root/linux-4.18.0-553.6.1.el8_10 -j "$(nproc)" -o /root/kpatch-out

# 2) apply (zero downtime)
./load-livepatch.sh /root/kpatch-out/zapscape_cve_2026_64561.ko
#    or: kpatch load /root/kpatch-out/zapscape_cve_2026_64561.ko

# 3) verify
./verify-livepatch.sh
```

Expected output:

```
Loaded patch modules:
zapscape_cve_2026_64561 [enabled]
```

---

## 4. Patch Variants vs. Kernel Versions

The build script **auto-selects** the variant by inspecting the source code
shape; you normally don't pick manually. Reference table:

| kernel era | KVM MMU code shape | patch file |
|---|---|---|
| RHEL 8.0–8.2 (`4.18.0-80`..`4.18.0-193`) | single `arch/x86/kvm/mmu.c`, `tdp_page_fault()`, `spin_lock` | `cve-2026-64561-rhel8-legacy-mmu.patch` |
| RHEL 8.3 (`4.18.0-240`) | `arch/x86/kvm/mmu/`, `direct_page_fault()`, `spin_lock`, `mmu_notifier_retry()` | `cve-2026-64561-rhel8-8.3-mmu.patch` |
| RHEL 8.4 (`4.18.0-305`) | `arch/x86/kvm/mmu/` + TDP MMU, `read/write_lock`, `mmu_notifier_retry()` | `cve-2026-64561-rhel8-8.4-mmu.patch` |
| RHEL 8.5 (`4.18.0-348`) | TDP MMU, `mmu_notifier_retry_hva()`, `is_tdp_mmu_root()` | `cve-2026-64561-rhel8-8.5-mmu.patch` |
| Stream 8 `4.18.0-365`/`-383` | TDP MMU, `mmu_notifier_retry_hva()`, `is_tdp_mmu_fault` var | `cve-2026-64561-rhel8-stream365-mmu.patch` |
| Stream 8 `4.18.0-408`/`-448` (≈RHEL 8.7–8.9) | TDP MMU, `is_page_fault_stale()`, unbraced branch | `cve-2026-64561-rhel8-stream408-mmu.patch` |
| RHEL 8.10 / Stream 8 final (`4.18.0-553.x`) | TDP MMU, `is_page_fault_stale()`, braced branch | `cve-2026-64561-rhel8-mmu-dir.patch` |

> On "generic across 4.18.0-XXX": a live-patch module is by design bound to one
> exact kernel build (same as Red Hat's own KLP). The **patches and scripts in
> this repo are generic** — run `one-click.sh` on any `4.18.0-*` CentOS Stream 8
> / RHEL 8 host and it produces and loads the correctly matching module for
> that exact build, with no reboot ever.

---

## 5. Root Cause & The Fix

**Zapscape (CVE-2026-64561)** is a use-after-free in the KVM/x86 shadow MMU
recursive-zap path during MMU page quota reclaim. With guest-side actions
alone, an attacker can:

- **panic the host kernel** (DoS against every tenant VM on the same host), or
- **execute code with host kernel root** (full host + all guests compromise, RCE)

### Root cause (short version)

`FNAME(page_fault)` / `direct_page_fault()` checked root staleness **before**
`make_mmu_pages_available()` ran quota reclaim:

```c
	write_lock(&vcpu->kvm->mmu_lock);

	if (is_page_fault_stale(vcpu, fault, mmu_seq))   /* ① check */
		goto out_unlock;

	r = make_mmu_pages_available(vcpu);              /* ② reclaim — may zap the in-use root! */
	...
	r = __direct_map(vcpu, fault);                   /* ③ keeps mapping into an invalid root */
```

When reclaim marks the in-use root `role.invalid`, `③` keeps creating children
under it. Children inherit `role.invalid` via `kvm_mmu_child_role()`, violating
the invariant that invalid shadow pages never sit on the active MMU page list
→ the same `link` lands on two lists and is freed → dangling link + post-free
write, which the PoC turns into host kernel code execution.

### The fix (upstream `2abd5287f083`)

Move the stale check **after** `make_mmu_pages_available()`; if the root became
invalid during reclaim, return `RET_PF_RETRY` and restart the fault on a fresh
root:

```c
	write_lock(&vcpu->kvm->mmu_lock);

	r = make_mmu_pages_available(vcpu);              /* reclaim first */
	if (r)
		goto out_unlock;

	if (is_page_fault_stale(vcpu, fault, mmu_seq)) { /* re-check */
		r = RET_PF_RETRY;
		goto out_unlock;
	}
	...
```

### Why the live patch is safe & transparent

- kpatch uses the in-kernel livepatch core (ftrace), the exact mechanism Red Hat
  ships KLP updates with;
- per-task consistency: every task (KVM vCPU threads included) migrates at a
  safe point — **VMs are unaware**;
- the patch only reorders two statements inside the page-fault handler; no data
  structures, ABI, or hypervisor features change;
- instant rollback (`kpatch disable`); the kernel itself is never rewritten.

---

## 6. Verification Record (2026-08-07)

End-to-end verification on a real CubeCloud (魔方云) KVM host **while a tenant
VM was running**:

| check | result |
|---|---|
| host | CentOS Stream 8, `4.18.0-553.6.1.el8.x86_64`, Intel Xeon 8259CL (KVM + QEMU 6.2.0 + OVS) |
| vulnerable pattern confirmed | `is_page_fault_stale()` before `make_mmu_pages_available()` in `direct_page_fault()` and `FNAME(page_fault)` |
| `f95eec9bed76` invariant backported | yes — `list_add()` for invalid pages in `__kvm_mmu_prepare_zap_page()` (full attack surface present) |
| live-patch prerequisites | `CONFIG_LIVEPATCH=y`, `CONFIG_KALLSYMS=y`, `CONFIG_DEBUG_INFO=y`, `CONFIG_MODULE_SIG_FORCE` off |
| patch module built | `SUCCESS` — vermagic `4.18.0-553.6.1.el8` matches the running kernel exactly |
| patched functions | `direct_page_fault`, `paging64_page_fault`, `paging32_page_fault`, `ept_page_fault` (all `,1` = replaced) |
| patch applied live | `kpatch list` → `zapscape_cve_2026_64561 [enabled]`; transition completed in **2 s** (dmesg: `patching complete`) |
| 魔方云 tenant VM (kvm1792, 8 vCPU/8 GiB, guest CentOS Stream 8 `4.18.0-358.el8`) | running before/during/after: qemu PID unchanged (`1072593`), `virsh domstate` = running, guest uptime continuous (527 s at check, no restart), guest dmesg clean, guest root shell + networking (`10.0.0.2/24`) fully functional after patch |
| extra test VM (cirros, started before the patch) | still healthy after the patch load (cleaned up afterwards) |
| host reboot | **none** — `/proc/uptime` continuous throughout |
| virtualization features | **nothing disabled** — KVM, nested-virt capability, OVS untouched |
| rollback | instant via `kpatch disable/unload` (no kernel rewrite) |

---

## 7. Rollback

```bash
kpatch disable zapscape_cve_2026_64561   # deactivates (tasks finish old code)
kpatch unload zapscape_cve_2026_64561    # removes the module
```

> The kernel itself is never rewritten; disabling returns to the original
> (vulnerable) code, so rollback is instant and safe.
> **Note:** a host reboot invalidates the live patch — reload with
> `kpatch load` afterwards (or use kpatch-dnf to follow kernel updates).

---

## 8. References

- PoC + technical write-up — <https://github.com/V4bel/Zapscape>
- Upstream fix — <https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=2abd5287f083>
- Patch discussion — <https://lore.kernel.org/all/20260721102829.313226-1-pbonzini@redhat.com/>
- Introducing commit — <https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=f95eec9bed76>
- CVE-2026-64561 (assigned 2026-08-04, disclosed 2026-08-06)
- kpatch — <https://github.com/dynup/kpatch>
- Line-level code analysis: `docs/ANALYSIS.md` (based on
  `linux-4.18.0-553.6.1.el8_10.tar.xz`)

---

## 9. Copyright & License

```
Copyright © 2026 Aoripus (Beijing) Technology Co., Ltd. (安锐普世（北京）科技有限公司)
Contact: master@aoripus.com
```

- Kernel patches: GPL-2.0 (same as the Linux kernel)
- Scripts & documentation: GPL-2.0-or-later
- This repository is defensive security engineering for hardening hosts you
  own. No warranty — follow your change-management process and test on a
  staging host first.
