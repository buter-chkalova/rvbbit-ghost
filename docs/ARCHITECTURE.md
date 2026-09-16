# Architecture

## Components

- `Install-RvbbitGhost.ps1` installs/detects dependencies, downloads the pinned Whonix appliance, verifies its OpenPGP signature, imports and isolates the base VMs.
- `Initialize-RvbbitGhost.ps1` opens the base pair for first-run setup, mandatory OpenVPN-before-Tor configuration, updates and a fail-closed test. It snapshots only after explicit operator attestation.
- `Start-RvbbitGhost.ps1` creates linked clones, assigns a per-session internal network, reapplies isolation settings, starts Gateway then Workstation, and deletes both clones on exit.
- `Stop-RvbbitGhost.ps1` performs crash recovery and disposal.
- `Update-CleanBase.ps1` creates a new clean snapshot after maintenance and another VPN fail-closed attestation.
- `Audit-RvbbitGhost.ps1` performs a read-only pre-engagement check of host-visible security invariants.
- `Uninstall-RvbbitGhost.ps1` removes only state-bound VMs with validated project names and UUIDs.

## Network invariants

```text
Workstation NIC 1 = intnet(rvbbit-<session>)
Workstation NIC 2..8 = none

Gateway NIC 1 = NAT
Gateway NIC 2 = intnet(rvbbit-<session>)
Gateway NIC 3..8 = none

Gateway egress = OpenVPN tun0 -> Tor
```

The VirtualBox NAT adapter is never attached to Workstation. A unique internal network prevents accidental contact with another Whonix pair running on the same host.

## Storage lifecycle

```text
signed OVA -> imported base -> clean snapshot -> linked session disks
                                                   |
                                                   +-> deleted at session end
```

The base contains VPN credentials and clean software state. That is persistent and readable by a sufficiently privileged host; this is a documented trust boundary. Browsing state should exist only in linked-clone differencing disks.

VirtualBox's per-project registry and global logs are redirected with `VBOX_USER_HOME` to `%LOCALAPPDATA%\RvbbitGhost\virtualbox-home`. This improves separation and cleanup but does not suppress Windows Event Log, filesystem journal, pagefile, security-product telemetry, storage remnants or network metadata.

## Supply-chain boundary

The repository does not redistribute Whonix, VirtualBox, Gpg4win, Tor Browser or VPN credentials. Whonix is accepted only when:

1. the key file contains the pinned primary fingerprint;
2. GnuPG returns a valid signature tied to that fingerprint;
3. the OVA originates from the pinned HTTPS URL.

VirtualBox and Gpg4win are installed through exact winget package IDs. The Windows Package Manager manifest verifies installer hashes, but this remains part of the trusted bootstrap path.

## Recovery

State is written atomically after each clone registration. If the launcher exits unexpectedly, the next start refuses to overlap a running session. `Stop-RvbbitGhost.ps1 -Force` uses the saved names and UUIDs, attempts ACPI shutdown, then powers off and unregisters only the session VMs.
