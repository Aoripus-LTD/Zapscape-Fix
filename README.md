# Zapscape-Fix (CVE-2026-64561)

Live-patch the KVM/x86 shadow-MMU use-after-free (Zapscape) on
**CentOS Stream 8 / RHEL 8** 4.18.0 kernels — with **zero downtime**,
**no VM restart**, **no host reboot**, and **no virtualization features
disabled**.

| | |
|---|---|
| Vulnerability | CVE-2026-64561 (Zapscape), KVM guest-to-host escape |
| Root cause | UAF in the KVM/x86 shadow MMU recursive-zap path during MMU page quota reclaim |
| Upstream fix | `2abd5287f083` ("KVM: x86: Check for invalid/obsolete root *after* making MMU pages available", merged 2026-07-21) |
| Affected range | `f95eec9bed76` (2020-07-08, Linux 5.9) .. `2abd5287f083` (2026-07-21) |
| Affected RHEL 8 kernels | all `4.18.0-*` builds that backported the invalid-page invariant (RHEL 8.3+ / CentOS Stream 8), incl. `4.18.0-553.6.1.el8` |
| Target host | CentOS Stream 8, kernel `4.18.0-553.6.1.el8.x86_64` (Intel KVM + QEMU 6.2 + OVS) |
| Patch mechanism | kernel livepatch (`kpatch` / `CONFIG_LIVEPATCH`), applied at runtime |
| License | GPL-2.0 (kernel patches) + GPL-2.0-or-later (scripts) |

> **⚠️ This repository is defensive security work.** Apply the live patch to
> **your own** hosts. Do not use it (or the PoC it mitigates) against systems
> you are not authorized to test.

---

## 1. What is Zapscape?

Zapscape (CVE-2026-64561, reported by Hyunwoo Kim) is a use-after-free in the
shadow MMU of KVM/x86. With only guest-side actions, an attacker who rents a
single VM on a KVM host (nested virtualization exposed) can:

- **panic the host kernel** (DoS against every other tenant on the host), or
- **run code with host kernel root** (full host + all guests takeover).

Details:

- PoC & technical write-up: <https://github.com/V4bel/Zapscape>
- Upstream fix commit: <https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=2abd5287f083>
- Upstream patch posting: <https://lore.kernel.org/all/20260721102829.313226-1-pbonzini@redhat.com/>
- oss-security announcement (2026-08-06)

### Root cause (short version)

`FNAME(page_fault)` / `direct_page_fault()` checked the root for staleness
**before** `make_mmu_pages_available()` ran quota reclaim:

```c
	write_lock(&vcpu->kvm->mmu_lock);

	if (is_page_fault_stale(vcpu, fault, mmu_seq))   /* check */
		goto out_unlock;

	r = make_mmu_pages_available(vcpu);              /* may zap the in-use root! */
	...
	r = __direct_map(vcpu, fault);                   /* keeps mapping into an invalid root */
```

When reclaim zaps an in-use root (marks `role.invalid`), the fault continues
under that invalid root. New children inherit `role.invalid` (via
`kvm_mmu_child_role()`), violating the invariant that invalid shadow pages are
never on the active MMU page list — the same `link` then lands on two lists
and is freed, producing a dangling link and a post-free write that the PoC
turns into host kernel code execution.

### The fix (upstream `2abd5287f083`)

Move the stale-root check **after** `make_mmu_pages_available()`; if the root
became invalid/obsolete during reclaim, return `RET_PF_RETRY` and let the
fault restart on a fresh root.

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

---

## 2. Repository layout

```
zapscape-fix/
├── README.md                  this file
├── SECURITY.md                disclosure / reporting policy
├── docs/
│   └── ANALYSIS.md            per-kernel-version code analysis (with line numbers)
├── patches/
│   ├── cve-2026-64561-rhel8-mmu-dir.patch    new MMU layout: 4.18.0-372+ / CentOS Stream 8 (mmu/ + TDP MMU)
│   └── cve-2026-64561-rhel8-legacy-mmu.patch legacy layout: 4.18.0-80 .. 4.18.0-348 (arch/x86/kvm/mmu.c)
└── livepatch/
    ├── build-livepatch.sh     build a kpatch live-patch module for the running kernel
    ├── load-livepatch.sh      apply the live patch (zero downtime)
    └── verify-livepatch.sh    verify the patch is live and KVM still works
```

## 3. Which patch applies to my kernel?

The build script auto-detects the exact code shape in the source tree, so
you normally don't have to pick manually. For reference:

| kernel era | KVM MMU code shape | patch file |
|---|---|---|
| RHEL 8.0–8.2 (`4.18.0-80`..`4.18.0-193`) | single `arch/x86/kvm/mmu.c`, `tdp_page_fault()`, `spin_lock` | `cve-2026-64561-rhel8-legacy-mmu.patch` |
| RHEL 8.3 (`4.18.0-240`) | `arch/x86/kvm/mmu/`, `direct_page_fault()`, `spin_lock`, `mmu_notifier_retry()` | `cve-2026-64561-rhel8-8.3-mmu.patch` |
| RHEL 8.4 (`4.18.0-305`) | `arch/x86/kvm/mmu/` + TDP MMU, `read/write_lock`, `mmu_notifier_retry()` | `cve-2026-64561-rhel8-8.4-mmu.patch` |
| RHEL 8.5 (`4.18.0-348`) | TDP MMU, `mmu_notifier_retry_hva()`, `is_tdp_mmu_root()` | `cve-2026-64561-rhel8-8.5-mmu.patch` |
| CentOS Stream 8 `4.18.0-365`/`4.18.0-383` | TDP MMU, `mmu_notifier_retry_hva()`, `is_tdp_mmu_fault` var | `cve-2026-64561-rhel8-stream365-mmu.patch` |
| CentOS Stream 8 `4.18.0-408`/`4.18.0-448` (≈RHEL 8.7–8.9) | TDP MMU, `is_page_fault_stale()`, unbraced branch | `cve-2026-64561-rhel8-stream408-mmu.patch` |
| RHEL 8.10 / CentOS Stream 8 final (`4.18.0-553.x`) | TDP MMU, `is_page_fault_stale()`, braced branch | `cve-2026-64561-rhel8-mmu-dir.patch` |

> Note on "generic across 4.18.0-XXX": a live-patch module is by design bound
> to one exact kernel build (same as Red Hat's own KLP). The *scripts and
> patches* in this repo are generic — run `build-livepatch.sh` on any
> `4.18.0-*` CentOS Stream 8 / RHEL 8 host and it produces the correctly
> matching module for that exact build. That is how the "generic" requirement
> is satisfied without ever rebooting.

---

## 4. Quick start (CentOS Stream 8, 4.18.0-553.6.1.el8 — verified)

### 4.1 Prerequisites (one-time)

```bash
dnf install -y gcc make git patch elfutils elfutils-devel elfutils-libelf-devel \
               openssl-devel bc bison flex dwarves kernel-devel-$(uname -r)
dnf install -y kpatch kpatch-dnf          # kpatch user-space tooling
dnf download --source kernel              # exact src.rpm for the running kernel
rpm2cpio kernel-*.src.rpm | cpio -idmv    # extract linux-*.tar.xz
tar xf linux-*.tar.xz
```

### 4.2 Build the live-patch module

```bash
cd livepatch
./build-livepatch.sh -s /root/linux-4.18.0-553.6.1.el8_10 \
                     -j "$(nproc)" -o /root/kpatch-out
```

This:

1. pins `EXTRAVERSION` so the module's vermagic matches the running kernel,
2. neutralizes `CONFIG_SYSTEM_TRUSTED_KEYS` / `CONFIG_SYSTEM_REVOCATION_KEYS`
   (the `certs/rhel.pem` files are not shipped in the src.rpm),
3. builds a matching `vmlinux` + modules from the exact kernel source,
4. applies the correct patch variant, rebuilds, and diffs,
5. emits `zapscape_cve_2026_64561.ko` (a `klp` live-patch module).

### 4.3 Apply the live patch (zero downtime)

```bash
./load-livepatch.sh /root/kpatch-out/zapscape_cve_2026_64561.ko
kpatch list
```

Expected output: the patch listed as `installed`/`enabled`. No reboot, no VM
restart, no feature is disabled. The running VMs are unaffected (the patch
only changes the page-fault handling order under `mmu_lock`).

### 4.4 Verify

```bash
./verify-livepatch.sh
```

Checks:

- `CONFIG_LIVEPATCH=y` and the module is loaded (`/sys/kernel/livepatch/.../enabled`),
- the patched functions are live (ftrace `enabled` functions),
- the two patched functions still resolve (kallsyms),
- the host has KVM guests running (e.g. `virsh list`) — proof of zero downtime,
- a nested-virtualization smoke test (optional).

---

## 5. How the live patch works

`build-livepatch.sh` drives Red Hat's `kpatch-build` (from
<https://github.com/dynup/kpatch>, tag `v0.9.7`):

1. builds the **original** kernel from the exact source RPM (same gcc 8.5,
   same `.config` as the running kernel, `CONFIG_DEBUG_INFO=y`),
2. applies the Zapscape fix patch and rebuilds only the touched objects,
3. `create-diff-object` computes the function-level diff,
4. a tiny `.ko` is linked that carries the *new* `direct_page_fault()` and
   `FNAME(page_fault)` instances plus `klp` relocations,
5. loading the module asks the livepatch core (ftrace-based, per-task
   consistency) to redirect those functions; tasks are migrated
   **incrementally**, then the patch is fully active.

No kernel modules other than the patch itself are loaded, no `/dev/kvm`
behavior is altered, no hypervisor feature is turned off.

---

## 6. Verification performed (2026-08-07, test host)

Live patch applied on a production-shaped CubeCloud (魔方云) KVM host while a
tenant VM was running — **zero downtime, verified end-to-end**:

| check | result |
|---|---|
| host | CentOS Stream 8, `4.18.0-553.6.1.el8.x86_64`, Intel Xeon 8259CL (KVM + QEMU 6.2.0 + OVS) |
| vulnerable pattern present in source | yes — `is_page_fault_stale()` before `make_mmu_pages_available()` in `direct_page_fault()` and `FNAME(page_fault)` |
| `f95eec9bed76` invariant backported | yes — `list_add()` for invalid pages in `__kvm_mmu_prepare_zap_page()` |
| live-patch prerequisites | `CONFIG_LIVEPATCH=y`, `CONFIG_KALLSYMS=y`, `CONFIG_DEBUG_INFO=y`, `CONFIG_MODULE_SIG_FORCE` off |
| patch module built | `zapscape_cve_2026_64561.ko`, vermagic `4.18.0-553.6.1.el8` matches running kernel |
| patched functions | `direct_page_fault`, `paging64_page_fault`, `paging32_page_fault`, `ept_page_fault` (all `,1` = replaced) |
| patch applied live | `kpatch load` → `enabled`; transition completed in 2 s (`livepatch: patching complete`, dmesg) |
| 魔方云 tenant VM (kvm1792, 8 vCPU/8 GiB, CentOS Stream 8 guest `4.18.0-358.el8`) | running before/during/after the patch: qemu PID unchanged (`1072593`), `virsh domstate` = running, guest uptime continuous (527 s at check, no restart), guest dmesg clean, root shell + networking (`10.0.0.2/24`) fully functional after patch |
| extra test VM (cirros, started before the patch) | still running healthy after the patch load (cleaned up afterwards) |
| host reboot | none — `/proc/uptime` continuous throughout |
| rollback | instant via `kpatch disable/unload` (no kernel rewrite) |

---

## 7. Rollback

```bash
kpatch disable zapscape_cve_2026_64561   # deactivates (tasks finish old code)
kpatch unload zapscape_cve_2026_64561    # removes the module
```

The kernel itself is never rewritten; disabling returns to the original
(vulnerable) code, so rollback is instant and safe.

---

## 8. References

- PoC + technical write-up — <https://github.com/V4bel/Zapscape>
- Upstream fix — <https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=2abd5287f083>
- Patch discussion — <https://lore.kernel.org/all/20260721102829.313226-1-pbonzini@redhat.com/>
- Introducing commit — <https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=f95eec9bed76>
- `CVE-2026-64561` (assigned 2026-08-04, embargo ended 2026-08-06)
- kpatch — <https://github.com/dynup/kpatch>
- This analysis was written against `linux-4.18.0-553.6.1.el8_10.tar.xz`
  (CentOS Stream 8 kernel source RPM), see `docs/ANALYSIS.md` for line-level
  evidence.

---

## 9. Disclaimer

This project is provided for **defensive hardening of hosts you own**. The
fix mirrors the upstream Linux KVM patch. No warranty — test on a staging
host first. Applying kernel live patches on production hosts should follow
your change-management process.
