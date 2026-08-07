# CVE-2026-64561 (Zapscape) — code-level analysis on RHEL 8 / CentOS Stream 8 4.18 kernels

All line numbers below were verified against the actual CentOS Stream 8
kernel source RPMs:

| kernel | source tarball | KVM MMU layout |
|---|---|---|
| `4.18.0-553.6.1.el8` (Stream 8 / RHEL 8.10) | `linux-4.18.0-553.6.1.el8_10.tar.xz` | `arch/x86/kvm/mmu/` + TDP MMU |
| `4.18.0-305.el8` (RHEL 8.4) | `linux-4.18.0-305.el8.tar.xz` | `arch/x86/kvm/mmu/` + TDP MMU |

## 1. Vulnerable pattern (both layouts)

Upstream mainline before `2abd5287f083`:

```c
	r = RET_PF_RETRY;
	write_lock(&vcpu->kvm->mmu_lock);

	if (is_page_fault_stale(vcpu, fault))      /* [1] stale check */
		goto out_unlock;

	r = make_mmu_pages_available(vcpu);        /* [2] quota reclaim */
	if (r)
		goto out_unlock;
	r = FNAME(fetch)(vcpu, fault, &walker);    /* [3] keep mapping */
```

The stale check `[1]` runs **before** `[2]`. Quota reclaim
(`kvm_mmu_zap_oldest_mmu_pages()`) can recursively zap the current root
through its children (the recursive path tests `parent_ptes` but **not**
`root_count`), marking it `role.invalid`. `[3]` then keeps mapping into the
invalid root; new children inherit `role.invalid` from the parent role
(`kvm_mmu_child_role()` copies the full role), so an invalid page enters
`active_mmu_pages` via the plain `list_add()` in `kvm_mmu_get_page()`.

### Evidence — `4.18.0-553.6.1.el8` (target host, Stream 8)

`arch/x86/kvm/mmu/mmu.c`:

- L4036-4052 `direct_page_fault()`:
  `is_page_fault_stale()` at L4041, `make_mmu_pages_available()` at L4047,
  `__direct_map()` at L4050 — stale check before reclaim.
- L3979 `is_page_fault_stale()` — obsolete-root check + `mmu_notifier_retry_hva()`.
- L2431 `make_mmu_pages_available()` — calls `kvm_mmu_zap_oldest_mmu_pages()`.
- L2318 `__kvm_mmu_prepare_zap_page()`: `list_add(&sp->link, invalid_list)`
  for already-invalid pages, `list_del(&sp->link)` for pinned roots —
  the backport of `f95eec9bed76` (invalid pages must not stay on the active
  list) **is present**, i.e. the full Zapscape chain applies.
- L2406 `kvm_mmu_zap_oldest_mmu_pages()` — skips `sp->root_count` at top
  level only.

`arch/x86/kvm/mmu/paging_tmpl.h`:

- L901 `FNAME(page_fault)`: `is_page_fault_stale()` before
  L904 `make_mmu_pages_available()` and L907 `FNAME(fetch)` — same pattern.

### Evidence — `4.18.0-305.el8` (RHEL 8.4)

`arch/x86/kvm/mmu/mmu.c`:

- L3684 `direct_page_fault()`: `mmu_notifier_retry()` check before L3726
  `make_mmu_pages_available()`.
- L2337/L2346 `__kvm_mmu_prepare_zap_page()`: `list_add`/`list_del` variant
  of the invalid-page invariant present (same as 8.10).

`arch/x86/kvm/mmu/paging_tmpl.h`:

- L870-873 `FNAME(page_fault)`: `mmu_notifier_retry()` before
  `make_mmu_pages_available()` and `FNAME(fetch)`.

## 2. The fix (upstream `2abd5287f083`)

> "Check for invalid/obsolete root *after* making MMU pages available."

```c
	write_lock(&vcpu->kvm->mmu_lock);

	r = make_mmu_pages_available(vcpu);        /* reclaim first */
	if (r)
		goto out_unlock;

	if (is_page_fault_stale(vcpu, fault)) {    /* re-check root */
		r = RET_PF_RETRY;
		goto out_unlock;
	}
	r = FNAME(fetch)(vcpu, fault, &walker);
```

If reclaim zapped the in-use root, the fault is retried with `RET_PF_RETRY`
instead of mapping into an invalid root, so no invalid children are ever
created — the double-list / dangling-link / post-free-write chain cannot
start.

Upstream commit message: the underlying flaw dates back to 2008
(`2e53d63acba7` "KVM: MMU: ignore zapped root pagetables"); the exploitable
invariant violation arrived with `f95eec9bed76` (Linux 5.9, backported into
RHEL 8.3+/8.4+). `2abd5287f083` fixes both.

## 3. Patch variants in this repo

The code shape evolved across RHEL 8 minor releases; every variant moves the
same stale check after `make_mmu_pages_available()`:

| variant (patch file) | function(s) patched | stale check | verified against |
|---|---|---|---|
| `cve-2026-64561-rhel8-legacy-mmu.patch` | `tdp_page_fault()` + `FNAME(page_fault)` | `mmu_notifier_retry()` | 4.18.0-193.el8 (RHEL 8.2) |
| `cve-2026-64561-rhel8-8.3-mmu.patch` | `direct_page_fault()` + `FNAME(page_fault)` | `mmu_notifier_retry()`, `spin_lock` | 4.18.0-240.el8 (RHEL 8.3) |
| `cve-2026-64561-rhel8-8.4-mmu.patch` | `direct_page_fault()` + `FNAME(page_fault)` | `mmu_notifier_retry()`, TDP MMU | 4.18.0-305.el8 (RHEL 8.4) |
| `cve-2026-64561-rhel8-8.5-mmu.patch` | `direct_page_fault()` + `FNAME(page_fault)` | `mmu_notifier_retry_hva()`, `is_tdp_mmu_root()` | 4.18.0-348.el8 (RHEL 8.5) |
| `cve-2026-64561-rhel8-stream365-mmu.patch` | `direct_page_fault()` + `FNAME(page_fault)` | `mmu_notifier_retry_hva()`, `is_tdp_mmu_fault` var | 4.18.0-365.el8 / -383.el8 (Stream 8) |
| `cve-2026-64561-rhel8-stream408-mmu.patch` | `direct_page_fault()` + `FNAME(page_fault)` | `is_page_fault_stale()`, unbraced branch | 4.18.0-408.el8 / -448.el8 (Stream 8) |
| `cve-2026-64561-rhel8-mmu-dir.patch` | `direct_page_fault()` + `FNAME(page_fault)` | `is_page_fault_stale()`, braced branch | 4.18.0-553.6.1.el8 (Stream 8 / RHEL 8.10) |

All variants preserve the exact upstream semantics of `2abd5287f083`:
reclaim first, re-check the root, `RET_PF_RETRY` if stale.  The TDP-MMU
branches keep their `mmu_seq` checks where they are needed (variants where
the TDP branch does not call `make_mmu_pages_available()`).

`build-livepatch.sh` picks the variant automatically by grepping the source
tree for the code shapes above.

## 4. Why a live patch is safe for a busy KVM host

- kpatch uses the in-kernel livepatch core (`CONFIG_LIVEPATCH=y`,
  ftrace-based), the same mechanism Red Hat ships KLP updates with.
- Per-task consistency: every task is migrated at a safe point
  (`klp_transition`), KVM vCPU threads included — no VM sees a stall beyond
  the normal scheduling latency.
- The patch only reorders two statements inside the page-fault handler under
  `mmu_lock`; no data structures, ABI, or hypervisor features change.
- Rollback (`kpatch disable`/`unload`) is instant and returns to the
  original code.

## 5. Verification checklist

1. `uname -r` matches the source tree that was patched.
2. `kpatch list` shows the patch `installed`/`enabled`.
3. `/sys/kernel/livepatch/<name>/enabled` == `1`.
4. KVM guests keep running (uptime unchanged, `virsh list` healthy).
5. Optional: nested-VM smoke test still boots an L2 guest.
