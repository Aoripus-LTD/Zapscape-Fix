# Security Policy

## Purpose

This repository exists to **mitigate** CVE-2026-64561 (Zapscape) on
CentOS Stream 8 / RHEL 8 KVM hosts via kernel live patching. It is defensive
security engineering: the patches here are a backport of the upstream Linux
KVM fix (`2abd5287f083`).

## Reporting a vulnerability

If you find a problem in this project's patches or scripts:

- **Do not** open a public issue for embargoed or unpatched details.
- Email: 1737562@qq.com
- Include: affected kernel versions, reproduction steps, and (if possible)
  a suggested fix.

We acknowledge reports within 5 business days.

## Responsible use

- Apply these patches only to hosts you own or are authorized to harden.
- The upstream PoC (V4bel/Zapscape) is real exploit code; do not run it
  against systems you do not control.
- Live-patch modules are build-bound to one exact kernel build. Always
  rebuild (`build-livepatch.sh`) after a kernel update; `kpatch-dnf` can
  automate this for you.

## Disclosure timeline (upstream, for reference)

| date | event |
|---|---|
| 2026-07-11 | reported to security@kernel.org |
| 2026-07-21 | fix `2abd5287f083` merged (posted to lore.kernel.org) |
| 2026-08-04 | CVE-2026-64561 assigned |
| 2026-08-06 | embargo ended; PoC + write-up published |
