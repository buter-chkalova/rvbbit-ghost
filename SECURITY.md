# Security policy

## Reporting a vulnerability

Do not publish a working exploit, VPN material, assessment evidence, or private user data in a public issue. Open a private [GitHub Security Advisory](https://github.com/buter-chkalova/rvbbit-ghost/security/advisories/new) and include the affected script, version, reproduction steps, and expected security invariant.

## Supported version

Only the current `main` branch is supported before the first stable release. Dependency versions in `config/release.json` are security-sensitive and must be updated through reviewed pull requests.

## Project boundary

Rvbbit Ghost is an orchestration layer, not an anonymity network. Vulnerabilities in Whonix, Tor Browser, OpenVPN, Gpg4win, VirtualBox or Windows should also be reported to their upstream maintainers.

Repository author and maintainer: [@buter-chkalova](https://github.com/buter-chkalova).
