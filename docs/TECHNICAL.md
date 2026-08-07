# 技术文档 — Zapscape（CVE-2026-64561）与热补丁方案

> 本文面向需要了解**漏洞原理、修复逻辑、补丁变体**的读者。
> 部署操作请看 [README.md](../README.md)。

## 1. 漏洞概述

**Zapscape（CVE-2026-64561）** 是 KVM/x86 shadow MMU 在"影子页配额回收
（quota reclaim）递归 zap 路径"中的 use-after-free（UAF）漏洞，
2026-07-11 由 Hyunwoo Kim（@v4bel）报告，2026-08-04 分配 CVE，2026-08-06
披露。

- **影响**：guest 仅凭自身操作即可逃逸到宿主，以宿主内核 root 权限执行
  代码（RCE），或击穿宿主内核造成同物理机所有租户 VM 的 DoS。
- **触发面**：宿主机开启嵌套虚拟化（nested）并接受不可信 guest；
  Intel 侧需同时向 L1 暴露 EPT page-walk length 4 与 5；AMD 侧无此限制。
- **代码范围**：`f95eec9bed76`（2020-07-08，Linux 5.9）引入可利用的
  invariant 破坏，`2abd5287f083`（2026-07-21）修复。
- **上游修复**：`2abd5287f083` "KVM: x86: Check for invalid/obsolete root
  *after* making MMU pages available"。

## 2. 根因分析

### 2.1 漏洞代码模式

`FNAME(page_fault)`（paging_tmpl.h）与 `direct_page_fault()`（mmu.c）在
**配额回收之前**检查根页表（root）是否失效：

```c
	r = RET_PF_RETRY;
	write_lock(&vcpu->kvm->mmu_lock);

	if (is_page_fault_stale(vcpu, fault, mmu_seq))   /* ① 检查 root */
		goto out_unlock;

	r = make_mmu_pages_available(vcpu);              /* ② 配额回收 */
	if (r)
		goto out_unlock;
	r = FNAME(fetch)(vcpu, fault, &walker);          /* ③ 继续建映射 */
```

`②` 的 `kvm_mmu_zap_oldest_mmu_pages()` 在回收时可能通过子页表的递归路径
（该路径只检查 `parent_ptes`、**不检查 `root_count`**）把**正在使用的 root**
标记为 `role.invalid`。随后 `③` 仍在该失效 root 下继续建页表。

### 2.2 攻击链关键步骤

1. **失效 root 上创建子页表**：`kvm_mmu_child_role()` 复制父角色但不清除
   `invalid` 位 → 新子页表继承 `invalid`；
2. **违反不变量**：`kvm_mmu_get_page()` 用无条件的 `list_add()` 把该页挂到
   `active_mmu_pages` —— 而 `f95eec9bed76` 之后内核要求"invalid 影子页
   不得出现在 active 链表"；
3. **双重链表挂载**：该页被递归 zap 时（`__kvm_mmu_prepare_zap_page()` 的
   invalid 分支）用 `list_add()` 再次挂入 `invalid_list` → 同一 `link`
   同时在两条链上；
4. **释放后写入**：页面释放后 `link` 悬垂，PoC 通过两次跨缓存（cross-cache）
   重用把它变成对攻击者可控页面的指针写，进而泄漏 KASLR、篡改链表、
   最终以 `log_wait` + SRCU workqueue + `call_usermodehelper` 链在宿主上
   执行 `/bin/sh -c "umask 022; : > /Zapscape"`。

### 2.3 为什么"顺序"是关键

根因缺陷自 2008 年（`2e53d63acba7` "KVM: MMU: ignore zapped root
pagetables"）就存在，但真正可被利用的 badness 来自 2020 年的
`f95eec9bed76`（invalid 页不得留在 active 链表的不变量）。
因此修复 = 消除"在失效 root 下继续建页"这一行为本身。

## 3. 修复方案（上游 2abd5287f083）

把失效检查移动到 `make_mmu_pages_available()` **之后**；若回收导致 root
失效，返回 `RET_PF_RETRY` 让缺页在全新 root 上重试：

```c
	write_lock(&vcpu->kvm->mmu_lock);

	r = make_mmu_pages_available(vcpu);              /* 先回收 */
	if (r)
		goto out_unlock;

	if (is_page_fault_stale(vcpu, fault, mmu_seq)) { /* 再检查 */
		r = RET_PF_RETRY;
		goto out_unlock;
	}
	r = FNAME(fetch)(vcpu, fault, &walker);
```

修复后，回收导致的 root 失效会在 fetch 之前被捕获，`invalid` 子页表
永远不会被创建——双重挂载、悬垂链接、释放后写入的整条链无从开始。

> TDP MMU 分支（`kvm_tdp_mmu_map`）不调用 `make_mmu_pages_available()`，
> 不会触发回收路径，其 `mmu_seq` 检查保持原位即可（RHEL 8.10 形态）。

## 4. 补丁变体对照表（4.18.0 全系列）

RHEL 8 生命周期内 KVM MMU 代码形态多次演进，本项目按**源码形态**提供
7 个补丁变体，`build-livepatch.sh` 自动识别选择：

| 内核时期 | 代码形态特征 | 补丁文件 |
|---|---|---|
| RHEL 8.0–8.2（`4.18.0-80`..`-193`） | 单文件 `mmu.c`，`tdp_page_fault()`，`spin_lock`，`mmu_notifier_retry()` | `cve-2026-64561-rhel8-legacy-mmu.patch` |
| RHEL 8.3（`4.18.0-240`） | `mmu/` 目录（无 TDP MMU），`direct_page_fault()`，`spin_lock`，`mmu_notifier_retry()` | `cve-2026-64561-rhel8-8.3-mmu.patch` |
| RHEL 8.4（`4.18.0-305`） | `mmu/` + TDP MMU，`read/write_lock`，`mmu_notifier_retry()` | `cve-2026-64561-rhel8-8.4-mmu.patch` |
| RHEL 8.5（`4.18.0-348`） | TDP MMU，`mmu_notifier_retry_hva()`，`is_tdp_mmu_root()` | `cve-2026-64561-rhel8-8.5-mmu.patch` |
| Stream 8 `4.18.0-365`/`-383` | TDP MMU，`mmu_notifier_retry_hva()`，`is_tdp_mmu_fault` 变量 | `cve-2026-64561-rhel8-stream365-mmu.patch` |
| Stream 8 `4.18.0-408`/`-448`（≈RHEL 8.7–8.9） | TDP MMU，`is_page_fault_stale()`，无花括号分支 | `cve-2026-64561-rhel8-stream408-mmu.patch` |
| RHEL 8.10 / Stream 8 最终版（`4.18.0-553.x`） | TDP MMU，`is_page_fault_stale()`，花括号分支 | `cve-2026-64561-rhel8-mmu-dir.patch` |

各变体均保持上游 `2abd5287f083` 的语义：先回收、再检查、失效则
`RET_PF_RETRY`。

## 5. 热补丁（livepatch）工作机制

- **kpatch**：Red Hat 官方 KLP 同款工具链（`kpatch-build` + 内核
  `CONFIG_LIVEPATCH`）；
- **构建**：从运行内核的**确切源码**（同版本 src.rpm、同 .config、
  同 gcc）构建 vmlinux，应用补丁后做函数级 diff，生成最小 `.ko`；
- **加载**：livepatch 核心通过 ftrace 在函数入口做重定向，按任务
  （per-task）一致性迁移——每个任务（含 KVM vCPU 线程）在安全点切换，
  因此 VM 无感知；
- **vermagic**：模块与运行内核版本严格一致（如
  `4.18.0-553.6.1.el8`），确保可加载；
- **回滚**：`kpatch disable` 停用重定向，任务自然回到旧代码，即时生效。

## 6. 为什么"通用 4.18.0-XXX"是可行的

livepatch 模块本身与**具体内核构建**绑定（与 Red Hat 官方 KLP 相同——
每个内核版本一个 .ko）。"通用"体现在：

1. **补丁代码通用**：7 个变体覆盖 4.18.0 全系列的所有代码形态；
2. **流程通用**：`build-livepatch.sh` 在任意 `4.18.0-*` 主机上自动完成
   "检测形态 → 选变体 → 构建匹配模块 → 加载"；
3. **无需重启**：整个流程（构建后）在线完成。

## 7. 更多资料

- 逐行代码证据（各版本源码位置、验证细节）：[ANALYSIS.md](ANALYSIS.md)
- 漏洞作者技术报告：<https://github.com/V4bel/Zapscape/blob/main/assets/write-up.md>
- 上游修复：<https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=2abd5287f083>
