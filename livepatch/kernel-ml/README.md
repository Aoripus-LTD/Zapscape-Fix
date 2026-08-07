# Kernel-ML (ELRepo mainline) 7.1.3 / 7.1.4 — Zapscape livepatch

给 **kernel-ml 7.1.3 / 7.1.4**（ELRepo `kernel-ml` mainline 内核，EL 8 上
为 `7.1.x-1.el8.elrepo`）构建并加载 CVE-2026-64561 热补丁。

> 7.1.5+ 已包含上游修复 `2abd5287f083`，**不需要**本方案；直接升级即可。

## 为什么不用 kpatch？

7.1.x 内核已经**移除** kpatch 0.9.x 时代使用的 `klp_reloc` 老格式
（`include/linux/livepatch.h` 中已无 `struct klp_reloc`），改用
`.klp.rela.<objname>.*` 段，由内核 `klp_resolve_symbols()` 在模块加载时
通过 kallsyms 解析。因此必须使用内核原生工具链：

- `CONFIG_LIVEPATCH=y`、`CONFIG_KLP_BUILD=y`（构建期延迟 objtool）
- objtool `klp` 子命令：`klp diff`（函数级对比生成补丁对象）+
  `klp post-link`（链接后把 `__klp_relocs` 转为 `.klp.rela.*` 段）
- `CONFIG_KALLSYMS_ALL=y`（解析 kvm.ko 内部 static 符号）

**兼容性注意**：7.1.x 的 objtool `klp` 需要 `libxxhash`（`dnf install -y
xxhash-devel`）才会编译进二进制（`tools/objtool/Makefile` 的
`BUILD_KLP`）。另外 ELRepo 的 `.config` 已开启
`CONFIG_MODULE_ALLOW_MISSING_NAMESPACE_IMPORTS` 或需要在 make 时传
`KBUILD_NSDEPS=1`，以放行 kvm.ko 符号的 `module:` namespace 检查。

## 原理

| 环节 | 说明 |
|---|---|
| 函数体来源 | 7.1.7 源码中**已修复**的 `direct_page_fault` 与 `FNAME(page_fault)` 三个实例（`paging64/32/ept_page_fault`），与 7.1.3 的唯一差异就是上游修复（已逐字节核对） |
| 补丁对象 | `objtool klp diff <orig.o> <patched.o> <out.o>` 对比 7.1.3 与 7.1.7 编译出的 `mmu.o`，生成含新函数 + `__klp_relocs` 的补丁对象 |
| 符号重定位 | 所有 kvm.ko 内部/带 namespace 的符号一律转为 `.klp.sym.kvm.*`，`post-link` 后成为 `.klp.rela.kvm.*` 段，加载时由内核 livepatch 核心解析（**绕过模块加载器的 namespace 检查**） |
| 注册 | `zapscape_klp_wrapper.c` 提供传统 `klp_patch` 结构 + `klp_enable_patch()` |

## 构建

```bash
# 0) 前置（需与目标内核相同的工具链环境）
dnf install -y gcc make xxhash-devel elfutils-libelf-devel

# 1) 准备源码：7.1.3（目标内核）与 7.1.7（修复函数来源）各一份
#    （ELRepo kernel-ml src.rpm 或 git.kernel.org 标签 v7.1.3 / v7.1.7）

# 2) 构建
./build-klp.sh -s /root/linux-7.1.3 -f /root/linux-7.1.7 -o /root/klp-out

# 产物: /root/klp-out/zapscape_klp.ko
```

`build-klp.sh` 会：
1. 校验两个源码树的 `.config`（LIVEPATCH / KLP_BUILD / KALLSYMS_ALL /
   DEBUG_INFO）与 KVM 模块化；
2. 各自编译 `arch/x86/kvm/mmu/mmu.o`（增量，只需几十秒）；
3. 对两份 `mmu.o` 跑 `objtool --checksum`；
4. 在含 `Module.symvers` 的源码目录下跑
   `KLP_OBJNAME=kvm objtool klp diff`；
5. `objcopy` 将 4 个目标函数 globalize；
6. 用 `zapscape_klp_wrapper.c` + 内核模块构建系统链接成 `.ko`
   （`CONFIG_KLP_BUILD=` 关闭延迟 objtool，`KBUILD_NSDEPS=1` 放行
   namespace 检查）；
7. `objtool klp post-link` 生成最终 `.klp.rela.kvm.*` 段。

## 加载（零停机）

```bash
./load-klp.sh /root/klp-out/zapscape_klp.ko

# 验证
cat /sys/kernel/livepatch/zapscape_klp/enabled        # 1
ls /sys/kernel/livepatch/zapscape_klp/kvm/            # 4 个函数
cat /sys/kernel/livepatch/zapscape_klp/transition     # 0（转换完成）
dmesg | grep livepatch                                # patching complete
```

实测（2026-08-07，CentOS Stream 8 宿主，自编译 7.1.3 内核）：4 个函数
`direct_page_fault` / `paging64_page_fault` / `paging32_page_fault` /
`ept_page_fault` 全部替换成功，transition 完成，宿主上的 KVM 虚拟机全程
零感知（qemu 进程不变、guest uptime 连续）。

## 文件清单

| 文件 | 说明 |
|---|---|
| `build-klp.sh` | 一键构建脚本（自动完成上述 1–7） |
| `load-klp.sh` | 加载 + 自检脚本 |
| `zapscape_klp.c` | 完整 livepatch 源码（含 4 个修复函数体 + klp 结构，可独立 `make -C /lib/modules/7.1.3/build M=... modules` 构建，供参考） |
| `zapscape_klp_wrapper.c` | 模块骨架（与 `mmu_klp_glob.o` 链接的正式方案） |
| `direct_page_fault.txt` 等 | 从 7.1.7 提取的修复函数体（`objtool klp diff` 的替代参考） |
| `hack_objtool.py` | 对 objtool `klp-diff.c` 的必要修复：`KLP_OBJNAME` 环境变量 + `basename()` 导出模块名（7.1.3 的 objtool 默认把补丁对象归属到错误模块名） |
| `hack_modpost.py` | 构建期 hack：给 `Makefile.modpost` 追加 `-N`（放行 `module:` namespace 检查；7.1.x 也可用 `KBUILD_NSDEPS=1` 触发同一 `-N`，无需此文件） |

## 回滚

```bash
echo 0 > /sys/kernel/livepatch/zapscape_klp/enabled   # 停用
rmmod zapscape_klp                                     # 卸载
```
