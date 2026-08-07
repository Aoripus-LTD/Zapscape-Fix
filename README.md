# Zapscape-Fix — CVE-2026-64561 KVM 内核热补丁

> **[English](README.en.md) | 简体中文**

给 **CentOS Stream 8 / RHEL 8**（4.18.0 全系列内核）的 KVM 宿主机修复
**CVE-2026-64561（Zapscape）** 漏洞的**内核热补丁**：

**不打补丁的风险**：租户虚拟机（guest）可以仅凭自身操作逃逸到宿主机，以宿主
内核 root 权限执行代码——击穿整台物理机及其上所有虚拟机。

**本项目的补丁**：基于 Linux 上游官方修复（`2abd5287f083`）backport 而来，
通过内核 livepatch 机制**在线生效**：

> ✅ 不重启宿主机　✅ 不重启虚拟机　✅ 不关闭任何虚拟化特性　✅ 全程无感

---

## 目录

- [快速开始](#快速开始)
- [系统要求](#系统要求)
- [部署步骤（推荐手动）](#部署步骤推荐手动)
- [验证补丁是否生效](#验证补丁是否生效)
- [回滚](#回滚)
- [常见问题](#常见问题)
- [项目结构](#项目结构)
- [参考资料](#参考资料)
- [版权与许可](#版权与许可)

---

## 快速开始

在宿主机上依次执行（约 30 分钟，含构建时间）：

```bash
git clone https://github.com/Aoripus-LTD/Zapscape-Fix.git
cd Zapscape-Fix/livepatch

# 1. 构建热补丁模块（自动识别内核形态，无需手工选补丁）
./build-livepatch.sh -s /root/linux-4.18.0-553.6.1.el8_10 -j "$(nproc)"

# 2. 在线加载（约 2 秒，虚拟机无感知）
kpatch load /root/kpatch-out/zapscape_cve_2026_64561.ko

# 3. 确认生效
kpatch list
```

看到 `zapscape_cve_2026_64561 [enabled]` 即部署完成。详细步骤见下方
「[部署步骤](#部署步骤推荐手动)」。

---

## 系统要求

| 项 | 要求 |
|---|---|
| 操作系统 | CentOS Stream 8 / RHEL 8（含 8.0 ~ 8.10 全部分支） |
| 内核 | `4.18.0-*` 任意子版本（已覆盖 `4.18.0-80` ~ `4.18.0-553` 全部代码形态） |
| 权限 | root |
| 依赖 | gcc、make、git、patch、elfutils、openssl-devel、bc、bison、flex、dwarves、kpatch、kernel-devel（与运行内核同版本）、内核源码 RPM |
| 时间 | 首次构建约 20–40 分钟（取决于 CPU 核数） |

> 需要先确认内核支持 livepatch：`grep CONFIG_LIVEPATCH /boot/config-$(uname -r)`
> 应为 `=y`（RHEL 8 / Stream 8 默认开启）。

---

## 部署步骤（推荐手动）

### 第 1 步：安装前置工具

```bash
dnf install -y gcc make git patch elfutils elfutils-devel \
               elfutils-libelf-devel openssl-devel bc bison flex dwarves \
               yum-utils dnf-plugins-core kpatch kpatch-dnf
```

### 第 2 步：安装内核开发包（必须与运行内核一致）

```bash
dnf install -y kernel-devel-$(uname -r)
```

### 第 3 步：获取内核源码

```bash
dnf download --source kernel
rpm2cpio kernel-*.src.rpm | cpio -idmv 'linux*.tar.xz'
tar xf linux-*.tar.xz
```

> 构建脚本需要在源码目录上操作，记下解压出的目录名，例如
> `/root/linux-4.18.0-553.6.1.el8_10`。
> 若 `dnf download --source` 不可用（CentOS Stream 8 已于 2024-05 EOL），
> 请从 [vault.centos.org](https://vault.centos.org/) 手动下载同版本
> `kernel-*.src.rpm`。

### 第 4 步：构建热补丁模块

```bash
cd Zapscape-Fix/livepatch
./build-livepatch.sh -s <第 3 步的源码目录> -j "$(nproc)" -o /root/kpatch-out
```

脚本会自动检测内核代码形态并选择正确的补丁变体，无需手工指定。
构建成功后生成 `/root/kpatch-out/zapscape_cve_2026_64561.ko`。

### 第 5 步：在线加载

```bash
kpatch load /root/kpatch-out/zapscape_cve_2026_64561.ko
```

加载过程约 2 秒，所有任务（包括运行中的虚拟机 vCPU 线程）在安全点切换，
**虚拟机与业务全程无感知**。

### 第 6 步：验证

```bash
cd Zapscape-Fix/livepatch
./verify-livepatch.sh
```

---

## 验证补丁是否生效

```bash
kpatch list
```

```
Loaded patch modules:
zapscape_cve_2026_64561 [enabled]
```

`[enabled]` 即补丁已生效。补丁会替换 KVM 的 4 个缺页处理函数：

```
direct_page_fault,1
paging64_page_fault,1
paging32_page_fault,1
ept_page_fault,1
```

（`/sys/kernel/livepatch/zapscape_cve_2026_64561/kvm/` 下可查看，`,1` 表示已替换）

**实测记录**：2026-08-07 在真实魔方云（CubeCloud）KVM 宿主机上、租户 VM
运行期间完成全流程验证——补丁加载 2 秒完成，VM 的 qemu 进程 PID 不变、
guest uptime 连续、guest 功能完全正常，宿主机全程未重启。

---

## 回滚

```bash
kpatch disable zapscape_cve_2026_64561   # 停用补丁（任务自然回到旧代码）
kpatch unload zapscape_cve_2026_64561    # 卸载模块
```

回滚即时完成，内核本身从不被改写。

> ⚠️ 注意：**宿主机重启后热补丁会失效**，需要重新执行
> `kpatch load /root/kpatch-out/zapscape_cve_2026_64561.ko`。
> 建议把该命令加入开机自启，或使用 `kpatch-dnf` 自动跟随内核更新。

---

## 常见问题

**Q：我用的内核是 4.18.0-XXX 的某个具体版本，支持吗？**
支持。构建脚本会按源码形态自动选择补丁变体，覆盖 RHEL 8.0 ~ 8.10 /
CentOS Stream 8 全部 `4.18.0-*` 内核（变体对照表见
[docs/TECHNICAL.md](docs/TECHNICAL.md)）。

**Q：加载补丁会影响正在运行的虚拟机吗？**
不会。实测中虚拟机（qemu 进程、guest uptime、guest 内服务）全程无感。
补丁只调整 KVM 缺页处理内的两条语句顺序，不改变任何数据结构或虚拟化特性。

**Q：补丁和 Red Hat 官方的关系？**
本补丁是 Linux 上游官方修复（`2abd5287f083`）的 backport。RHEL 8 已停止
维护、没有官方 KLP，因此我们提供自建热补丁方案，机制与 Red Hat 官方 KLP
完全相同（kpatch / CONFIG_LIVEPATCH）。

**Q：仓库里的 one-click.sh 一键脚本能用吗？**
⚠️ **实验性，未经完整测试**。一键脚本（依赖安装 → 构建 → 加载 → 验证）
逻辑与手动步骤等价，但请**优先按本文档手动步骤操作**；使用一键脚本前请
逐行阅读其内容。

**Q：这是攻击工具吗？**
不是。本仓库只包含**防御性**修复补丁与部署脚本。漏洞利用代码（PoC）见
漏洞作者仓库（[V4bel/Zapscape](https://github.com/V4bel/Zapscape)），
请勿对未授权系统使用。

---

## 项目结构

```
Zapscape-Fix/
├── README.md              本文档（中文）
├── README.en.md           英文版
├── LICENSE                GPL-2.0
├── SECURITY.md            安全披露政策
├── docs/
│   ├── TECHNICAL.md       技术细节：漏洞原理、修复、变体对照表（中文）
│   └── ANALYSIS.md        逐行代码证据（英文，面向研究者）
├── patches/               7 个内核代码形态的补丁变体
└── livepatch/
    ├── build-livepatch.sh 构建热补丁模块（自动选变体）
    ├── load-livepatch.sh  加载补丁
    ├── verify-livepatch.sh 验证补丁
    ├── install-deps.sh    自动安装前置环境（辅助）
    └── one-click.sh       一键部署（⚠️ 实验性）
```

---

## 参考资料

- 漏洞 PoC 与技术报告 — <https://github.com/V4bel/Zapscape>
- 上游修复 commit — <https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=2abd5287f083>
- 补丁讨论邮件 — <https://lore.kernel.org/all/20260721102829.313226-1-pbonzini@redhat.com/>
- 引入缺陷的 commit — <https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=f95eec9bed76>
- kpatch 项目 — <https://github.com/dynup/kpatch>

---

## 版权与许可

```
版权 © 2026 安锐普世（北京）科技有限公司
Aoripus (Beijing) Technology Co., Ltd.
联系邮箱：master@aoripus.com
```

- 内核补丁：GPL-2.0（与 Linux 内核一致）
- 脚本与文档：GPL-2.0-or-later
- 本仓库为防御性安全工程，仅供对自有/授权主机加固，无任何担保。
