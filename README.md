# Rvbbit Ghost
> [!NOTE]
> Project status: experimental research prototype. Static and mocked behavior checks pass, but end-to-end behavior depends on the Windows host, VirtualBox version, Whonix version, VPN provider, and operator configuration.
[![CI](https://github.com/buter-chkalova/rvbbit-ghost/actions/workflows/ci.yml/badge.svg)](https://github.com/buter-chkalova/rvbbit-ghost/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Windows%2010%20%7C%2011-0078D6)](#requirements)

Rvbbit Ghost is a Windows 10/11 launcher for disposable Whonix research sessions. It is intended for authorized security assessments, privacy research, and controlled laboratory work.

The enforced traffic design is:

```text
Whonix-Workstation -> Whonix-Gateway -> OpenVPN -> Tor -> Internet
```

Whonix-Workstation has no direct Internet adapter. Each session is built as a pair of temporary linked clones and is destroyed when the session ends.

> [!IMPORTANT]
> Rvbbit Ghost does not guarantee perfect or "100%" anonymity. No Windows-hosted virtual machine can make that guarantee. Windows and the hypervisor remain inside the trusted computing base and can observe process, storage, timing, memory, and network metadata. Tor Browser itself does not claim perfect anonymity.
<!-- SECURITY: no-absolute-anonymity -->

> [!WARNING]
> This project does not erase Windows Event Logs, disable Defender, tamper with audit records, or falsify execution history. Project-owned VirtualBox data is isolated and disposable session files are removed, but host-level records and forensic remnants may remain.
<!-- SECURITY: no-windows-log-wiping -->

## Security properties

- Downloads the pinned Whonix LXQt appliance from `whonix.org`.
- Verifies the Whonix OVA with GnuPG and a pinned upstream signing-key fingerprint before import.
- Requires OpenVPN to be configured inside Whonix-Gateway before Tor is enabled.
- Requires Whonix `TUNNEL_FIREWALL` and an operator-confirmed fail-closed test.
- Connects Workstation only to a per-session VirtualBox internal network.
- Disables clipboard sharing, clipboard file transfer, drag and drop, shared folders, audio, USB, VRDE, and VirtualBox recording.
- Stores the project VirtualBox registry and project-level logs in an isolated `VBOX_USER_HOME`.
- Uses clean snapshots only as immutable linked-clone sources.
- Removes session VMs and differencing disks after shutdown.
- Detects and removes orphaned project session VMs after interrupted launches.
- Validates VM names and UUIDs before any destructive cleanup.
- Serializes installation, launch, stop, maintenance, audit, and uninstall mutations with a cross-process lock.
- Migrates existing state to the current schema and replaces `state.json` atomically.
- Leaves unrelated VirtualBox profiles and host documents untouched.

## Visibility by observer

| Observer | Still visible | Intended to remain hidden |
|---|---|---|
| Destination site | Tor exit address, submitted data, account identity | Home and VPN addresses |
| ISP | Subscriber line, VPN endpoint, timing and volume | Destination sites and direct connections to public Tor relays |
| VPN provider | Source address, timing, volume, Tor traffic leaving the VPN | Final destinations inside the Tor circuit |
| Windows / VirtualBox | VM execution, resource use, VPN endpoint, timing and volume | Tor Browser profile contents after session disposal; encrypted application content |
| Tor entry relay | VPN exit address | Home address and final destination |

An ISP necessarily knows the subscriber and access line. A VPN can hide destination routing and public Tor relay addresses from the ISP, but it cannot hide the existence or physical termination of the subscriber connection. The VPN provider becomes an additional correlation point.

## Requirements

- Windows 11 x64, or a Windows 10 x64 edition that is still receiving Microsoft security updates through ESU or an applicable LTSC lifecycle. Unpatched Windows 10 installations are not supported.
- Intel VT-x or AMD-V enabled in firmware.
- 8 GB RAM recommended.
- At least 25 GB free space recommended for downloads, base images, snapshots, and updates.
- Windows Package Manager (`winget`), or current manual installations of VirtualBox and Gpg4win.
- A VPN account that supplies a standard OpenVPN profile. Proprietary provider clients are not installed in Whonix.
- An authorized engagement and a documented rules-of-engagement scope.

Whonix officially supports VirtualBox on Windows, but its documentation recommends Linux-based hosts for stronger privacy requirements and Qubes-Whonix for the strongest supported isolation. Rvbbit Ghost therefore treats Windows as a practical research host, not a high-assurance anonymity boundary.

## Installation

1. Clone or download this repository.
2. Run `Install.cmd` as the intended Windows user. Dependency installers may request elevation.
3. Review the Whonix terms and type `ACCEPT` to import the signed appliance.
4. In Whonix-Gateway, configure OpenVPN **before enabling Tor** by following the [Whonix VPN-before-Tor guide](https://www.whonix.org/wiki/Tunnels/Connecting_to_a_VPN_before_Tor):
   - use the `tun0` interface;
   - set `VPN_FIREWALL=1` in `/usr/local/etc/whonix_firewall.d/50_user.conf`;
   - configure and enable `openvpn@openvpn`;
   - verify VPN connectivity;
   - stop OpenVPN and confirm that Tor and Workstation lose connectivity;
   - restart OpenVPN and verify Tor again.
5. Update both Whonix VMs and install or update Tor Browser with Tor Browser Downloader.
6. Shut down Workstation, then Gateway, from inside the guest operating systems.
7. Enter the one-time challenge shown by the initializer only after the fail-closed test succeeds. The launcher then creates clean snapshots.

VPN setup cannot be safely hard-coded: profiles, certificates, endpoints, and authentication differ by provider, and secrets must never be committed to a public repository.

## Pre-engagement audit

Before an assessment, run:

```powershell
.\scripts\Audit-RvbbitGhost.ps1
```

The audit checks the pinned release configuration, base VM identity, clean snapshots, power state, network adapters, host-integration controls, and VPN attestation. A missing required VirtualBox setting, invalid timestamp, or clean-base attestation older than 30 days fails the audit. It cannot inspect the live VPN tunnel from the Windows host without weakening guest isolation.

## Starting a session

Run `Start.cmd`. The launcher creates a new Gateway and Workstation pair, reapplies the network and host-integration policy, starts Gateway first, and waits for it to reach the running state. Workstation remains powered off until the operator performs the live OpenVPN, `tun0`, Tor, and fail-closed checks in Gateway and enters the one-time challenge. This gate records an operator confirmation; it is not host-side proof of the guest tunnel.

Use only Tor Browser inside Workstation. Shut down Workstation from its guest menu when finished. The launcher then stops Gateway and deletes both session VMs and their differencing disks.

If the console or host was interrupted, run:

```powershell
.\scripts\Stop-RvbbitGhost.ps1 -Force
```

The next launch never resumes an old browsing session.

## Updating the clean base

Run:

```powershell
.\scripts\Update-CleanBase.ps1
```

Use maintenance mode only for Whonix, OpenVPN, Tor, and Tor Browser updates. Repeat the VPN fail-closed test and shut down both VMs. A new clean snapshot becomes active; older snapshots are retained as rollback points.

## Data retention

Host documents are not modified. Browsing data inside disposable Workstation clones is intentionally non-persistent. Do not store the only copy of assessment evidence inside a session VM.

For authorized evidence collection, use an engagement-approved remote evidence system over the anonymized session and verify the upload before shutdown. Rvbbit Ghost does not provide a host shared folder because that would create a direct persistence and data-exposure channel.

## Uninstallation

```powershell
.\scripts\Uninstall-RvbbitGhost.ps1
```

This removes project base VMs, project session VMs, snapshots, and `%LOCALAPPDATA%\RvbbitGhost`. VirtualBox and Gpg4win remain installed by default. To request removal of dependencies installed by this project:

```powershell
.\scripts\Uninstall-RvbbitGhost.ps1 -RemoveDependencies
```

VirtualBox is retained if the normal VirtualBox profile contains unrelated registered VMs.

## Repository validation

```powershell
.\scripts\Test-RvbbitGhost.ps1
```

The test suite parses every PowerShell file, checks pinned release metadata, official download origins, and critical isolation invariants, and exercises state migration, atomic persistence, lock contention, audit failures, signature rejection, and partial-cleanup recovery. VirtualBox and Whonix end-to-end validation still requires a configured Windows test host.

## Explicit limitations

- A compromised Windows host, administrator, VirtualBox driver, firmware, or hardware defeats this design.
- A hypervisor cannot be both untrusted and unable to observe guest memory or I/O.
- Global traffic observers may perform timing and volume correlation across VPN and Tor boundaries.
- Account login, reused identifiers, behavioral patterns, payments, or unique content can identify an operator independently of the network path.
- Opening downloaded files on Windows can bypass the protected environment.
- VM deletion is not cryptographic media erasure. Storage journals, backups, SSD behavior, crash dumps, page files, and RAM remnants are outside the disposal guarantee.
- VPN-before-Tor changes who can observe the source connection; it does not automatically increase anonymity in every threat model.
- This project does not include offensive tools, authorization, or permission to test third-party systems.

Read [Threat Model](docs/THREAT-MODEL.md), [Logging and Data Disposal](docs/LOGGING.md), [Operational Security](docs/OPSEC.md), [Authorized Pentest Use](docs/AUTHORIZED-PENTESTING.md), and [Architecture](docs/ARCHITECTURE.md) before use.

## License and trademarks

Rvbbit Ghost scripts are licensed under the MIT License. Whonix, Tor Browser, Gpg4win, OpenVPN, and Oracle VirtualBox are not redistributed by this repository and remain governed by their own licenses. Rvbbit Ghost is not affiliated with Whonix, The Tor Project, OpenVPN Inc., or Oracle.

## Author

[buter-chkalova](https://github.com/buter-chkalova)

Security research focused on offensive and defensive security, system visibility, and controlled experimentation.

Related projects:

- [Project RVBBIT](https://github.com/buter-chkalova/project-rvbbit)
- [RVBBIT Arsenal](https://github.com/buter-chkalova/rvbbit-arsenal)
- [RvbbitSafe](https://github.com/buter-chkalova/RvbbitSafe)

Issues and security reports should use the repository channels described in [SECURITY.md](SECURITY.md).
