# Zapscape-Fix — CVE-2026-64561 内核热补丁（KVM/x86）

> **[English](README.en.md) | 简体中文**

针对 **CentOS Stream 8 / RHEL 8（4.18.0 全系列内核）** 的 KVM/x86 shadow MMU
use-after-free 漏洞（Zapscape，CVE-2026-64561）提供**通用内核热补丁**：

**零停机 · 不重启宿主机 · 不重启虚拟机 · 不关闭任何虚拟化特性 · 完全无感**

```
版权 © 2026 安锐普世（北京）科技有限公司  Aoripus (Beijing) Technology Co., Ltd.
联系邮箱：master@aoripus.com
```

> **⚠️ 本仓库为防御性安全工作**。请仅对**你自己拥有或获授权**的主机应用该热补丁。
> 切勿在未授权的系统上运行本仓库内容或其对应的 PoC（V4bel/Zapscape）。

---

## 目录

1. [快速开始（一键脚本）](#1-快速开始一键脚本)
2. [前置环境](#2-前置环境)
3. [手动部署（分步）](#3-手动部署分步)
4. [补丁变体与内核版本对应表](#4-补丁变体与内核版本对应表)
5. [漏洞原理与修复](#5-漏洞原理与修复)
6. [实测验证记录（2026-08-07）](#6-实测验证记录2026-08-07)
7. [回滚](#7-回滚)
8. [参考信息](#8-参考信息)
9. [版权与许可](#9-版权与许可)

---

## 1. 快速开始（一键脚本）

在宿主机（CentOS Stream 8 / RHEL 8，root）上：

```bash
git clone https://github.com/Aoripus-LTD/Zapscape-Fix.git
cd Zapscape-Fix/livepatch
./one-click.sh
```

脚本自动完成四步：

| 步骤 | 内容 | 耗时参考 |
|---|---|---|
| 1. 前置环境 | 安装编译工具链、`kernel-devel`（匹配当前内核）、kpatch 工具、下载并解压内核源码 RPM | 2–5 分钟 |
| 2. 构建热补丁 | `kpatch-build` 基于**当前运行内核的确切源码**构建 livepatch 模块（vermagic 精确匹配） | 20–40 分钟（96 核约 25 分钟） |
| 3. 加载补丁 | `kpatch load`，进程迁移在安全点完成，**VM 无感知** | 2 秒 |
| 4. 验证 | 检查补丁状态、被替换函数、KVM 与虚拟机健康 | 即时 |

> 只想加载已有模块时：`SKIP_BUILD=1 ./one-click.sh`

---

## 2. 前置环境

一键脚本会自动处理，手动安装如下：

```bash
# 编译工具链 + kpatch 用户态工具
dnf install -y gcc make git patch elfutils elfutils-devel \
               elfutils-libelf-devel openssl-devel bc bison flex dwarves \
               yum-utils dnf-plugins-core kpatch kpatch-dnf

# 与当前内核精确匹配的开发包（必须与 uname -r 一致）
dnf install -y kernel-devel-$(uname -r)

# 内核源码（构建 livepatch 模块必需，kpatch-build 需要从源码构建 vmlinux）
dnf download --source kernel
rpm2cpio kernel-*.src.rpm | cpio -idmv 'linux*.tar.xz'
tar xf linux-*.tar.xz
```

**内核要求**（宿主机必须满足，全部为 CentOS Stream 8 / RHEL 8 默认配置）：

| 配置项 | 要求 | 说明 |
|---|---|---|
| `CONFIG_LIVEPATCH` | `=y` | 内核实时补丁支持（RHEL 8 默认开启） |
| `CONFIG_KALLSYMS` | `=y` | 符号解析（默认开启） |
| `CONFIG_DEBUG_INFO` | `=y` | kpatch 构建需要 DWARF（默认开启） |
| `CONFIG_MODULE_SIG_FORCE` | 不设置 | 未签名模块可加载（RHEL 8 默认未开启） |

> 注意：CentOS Stream 8 已于 2024-05 结束维护，`dnf download --source kernel`
> 若不可用，可从 vault.centos.org 手动下载对应版本 src.rpm。

---

## 3. 手动部署（分步）

```bash
cd livepatch

# 1) 构建热补丁模块（自动识别内核代码形态并选择补丁变体）
./build-livepatch.sh -s /root/linux-4.18.0-553.6.1.el8_10 -j "$(nproc)" -o /root/kpatch-out

# 2) 加载（零停机）
./load-livepatch.sh /root/kpatch-out/zapscape_cve_2026_64561.ko
#    或：kpatch load /root/kpatch-out/zapscape_cve_2026_64561.ko

# 3) 验证
./verify-livepatch.sh
```

预期输出：

```
Loaded patch modules:
zapscape_cve_2026_64561 [enabled]
```

---

## 4. 补丁变体与内核版本对应表

构建脚本会按源码形态**自动选择**补丁变体，无需手动指定。参考表：

| 内核时期 | KVM MMU 代码形态 | 补丁文件 |
|---|---|---|
| RHEL 8.0–8.2（`4.18.0-80`..`4.18.0-193`） | 单文件 `arch/x86/kvm/mmu.c`，`tdp_page_fault()`，`spin_lock` | `cve-2026-64561-rhel8-legacy-mmu.patch` |
| RHEL 8.3（`4.18.0-240`） | `arch/x86/kvm/mmu/`，`direct_page_fault()`，`spin_lock`，`mmu_notifier_retry()` | `cve-2026-64561-rhel8-8.3-mmu.patch` |
| RHEL 8.4（`4.18.0-305`） | `arch/x86/kvm/mmu/` + TDP MMU，`read/write_lock`，`mmu_notifier_retry()` | `cve-2026-64561-rhel8-8.4-mmu.patch` |
| RHEL 8.5（`4.18.0-348`） | TDP MMU，`mmu_notifier_retry_hva()`，`is_tdp_mmu_root()` | `cve-2026-64561-rhel8-8.5-mmu.patch` |
| Stream 8 `4.18.0-365`/`-383` | TDP MMU，`mmu_notifier_retry_hva()`，`is_tdp_mmu_fault` 变量 | `cve-2026-64561-rhel8-stream365-mmu.patch` |
| Stream 8 `4.18.0-408`/`-448`（≈RHEL 8.7–8.9） | TDP MMU，`is_page_fault_stale()`，无花括号分支 | `cve-2026-64561-rhel8-stream408-mmu.patch` |
| RHEL 8.10 / Stream 8 最终版（`4.18.0-553.x`） | TDP MMU，`is_page_fault_stale()`，花括号分支 | `cve-2026-64561-rhel8-mmu-dir.patch` |

> **关于"通用 4.18.0-XXX"**：livepatch 模块本身与具体内核构建绑定（与 Red Hat 官方
> KLP 一致）。本仓库的**补丁与脚本是通用的**——在任何 `4.18.0-*` 的
> CentOS Stream 8 / RHEL 8 主机上运行 `one-click.sh`，即可为该确切内核构建并加载
> 匹配的模块，全程无需重启。

---

## 5. 漏洞原理与修复

**Zapscape（CVE-2026-64561）** 是 KVM/x86 shadow MMU 在配额回收（quota reclaim）
递归 zap 路径中的 use-after-free。攻击者仅凭 guest 侧操作即可：

- **击穿宿主内核**（同一物理机上所有租户 VM 的 DoS），或
- **以宿主内核 root 权限执行代码**（宿主 + 全部 guest 沦陷，RCE）

### 根因（简述）

`FNAME(page_fault)` / `direct_page_fault()` 在 `make_mmu_pages_available()` 执行
配额回收**之前**检查根页表（root）是否失效：

```c
	write_lock(&vcpu->kvm->mmu_lock);

	if (is_page_fault_stale(vcpu, fault, mmu_seq))   /* ① 检查 */
		goto out_unlock;

	r = make_mmu_pages_available(vcpu);              /* ② 回收——可能 zap 掉使用中的 root！ */
	...
	r = __direct_map(vcpu, fault);                   /* ③ 继续在已失效的 root 下建映射 */
```

回收把使用中的 root 标记为 `role.invalid` 后，`③` 仍继续在该 root 下创建子页表；
子页表通过 `kvm_mmu_child_role()` 继承 `role.invalid`，违反"invalid 影子页不得出现在
active MMU 页表链"的不变量 → 同一 `link` 被挂到两条链表并被释放 → 悬垂指针 +
释放后写入（post-free write），PoC 借此实现宿主内核代码执行。

### 修复（上游 `2abd5287f083`）

把失效检查移到 `make_mmu_pages_available()` **之后**；若回收导致 root 失效，
返回 `RET_PF_RETRY` 让缺页在全新 root 上重试：

```c
	write_lock(&vcpu->kvm->mmu_lock);

	r = make_mmu_pages_available(vcpu);              /* 先回收 */
	if (r)
		goto out_unlock;

	if (is_page_fault_stale(vcpu, fault, mmu_seq)) { /* 再检查 */
		r = RET_PF_RETRY;
		goto out_unlock;
	}
	...
```

### 为什么热补丁安全无感

- kpatch 使用内核自带的 livepatch 核心（ftrace 机制），与 Red Hat 官方 KLP 完全同款；
- 按任务（per-task）一致性迁移：每个任务（含 KVM vCPU 线程）在安全点切换，**VM 无感知**；
- 补丁仅调整缺页处理内的两条语句顺序，不改变任何数据结构、ABI 或虚拟化特性；
- 回滚即时（`kpatch disable`），内核本身从不被改写。

---

## 6. 实测验证记录（2026-08-07）

在真实魔方云（CubeCloud）KVM 宿主机上、**租户 VM 运行期间**完成全流程验证：

| 检查项 | 结果 |
|---|---|
| 宿主机 | CentOS Stream 8，`4.18.0-553.6.1.el8.x86_64`，Intel Xeon 8259CL（KVM + QEMU 6.2.0 + OVS） |
| 漏洞模式确认 | 源码中 `is_page_fault_stale()` 位于 `make_mmu_pages_available()` 之前（`direct_page_fault()` 与 `FNAME(page_fault)`） |
| `f95eec9bed76` 不变量 backport | 已确认（`__kvm_mmu_prepare_zap_page()` 中 invalid 页 `list_add` 分支）——完整攻击面成立 |
| livepatch 前置条件 | `CONFIG_LIVEPATCH=y`、`CONFIG_KALLSYMS=y`、`CONFIG_DEBUG_INFO=y`、`CONFIG_MODULE_SIG_FORCE` 未开启 |
| 补丁模块构建 | `SUCCESS`——vermagic `4.18.0-553.6.1.el8` 与运行内核精确一致 |
| 被替换函数 | `direct_page_fault`、`paging64_page_fault`、`paging32_page_fault`、`ept_page_fault`（均 `,1` = 已替换） |
| 热补丁加载 | `kpatch list` → `zapscape_cve_2026_64561 [enabled]`；转换 **2 秒**完成（dmesg: `patching complete`） |
| 魔方云租户 VM（kvm1792，8 vCPU/8 GiB，guest CentOS Stream 8 `4.18.0-358.el8`） | 补丁前后全程运行：qemu PID 不变（`1072593`）、`virsh domstate` = running、guest uptime 连续（检查时 527 s，无重启）、guest dmesg 干净、guest root shell 与网络（`10.0.0.2/24`）补丁后完全正常 |
| 附加测试 VM（cirros，补丁前启动） | 补丁加载后仍健康运行（验证后已清理） |
| 宿主机重启 | **无**——`/proc/uptime` 全程连续 |
| 虚拟化特性 | **零关闭**——KVM、嵌套虚拟化能力、OVS 均未改动 |
| 回滚 | `kpatch disable/unload` 即时完成（不改写内核） |

---

## 7. 回滚

```bash
kpatch disable zapscape_cve_2026_64561   # 停用（任务自然切换回旧代码）
kpatch unload zapscape_cve_2026_64561    # 卸载模块
```

> 内核本身从不被改写；停用即回到原（有漏洞的）代码，回滚即时且安全。
> **注意**：宿主机重启后热补丁失效，需重新 `kpatch load`（可配置开机自启，
> 或使用 kpatch-dnf 自动跟随内核更新）。

---

## 8. 参考信息

- PoC 与技术报告 — <https://github.com/V4bel/Zapscape>
- 上游修复 commit — <https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=2abd5287f083>
- 补丁讨论 — <https://lore.kernel.org/all/20260721102829.313226-1-pbonzini@redhat.com/>
- 引入缺陷的 commit — <https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=f95eec9bed76>
- CVE-2026-64561（2026-08-04 分配，2026-08-06 披露）
- kpatch — <https://github.com/dynup/kpatch>
- 逐行代码分析见 `docs/ANALYSIS.md`（基于 `linux-4.18.0-553.6.1.el8_10.tar.xz`）

---

## 9. 版权与许可

```
版权 © 2026 安锐普世（北京）科技有限公司
Aoripus (Beijing) Technology Co., Ltd.
联系邮箱：master@aoripus.com
```

- 内核补丁：GPL-2.0（与 Linux 内核一致）
- 脚本与文档：GPL-2.0-or-later
- 本仓库为防御性安全工程，仅供对自有/授权主机进行加固。无任何担保——
  生产环境应用请遵循变更管理流程并先在测试机验证。
