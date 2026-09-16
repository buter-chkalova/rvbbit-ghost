# Logging and Data Disposal

Rvbbit Ghost limits persistence of project-owned session data. It does not promise a log-free Windows host and does not delete or alter operating-system audit records.

## Removed at normal session shutdown

- disposable Whonix Gateway and Workstation linked clones;
- their registered VirtualBox machine definitions and differencing disks;
- the project session-state file after validated cleanup;
- browser profile, cookies, history, cache, and local storage contained only in the disposable Workstation clone.

Cleanup is limited to project-specific VM names and recorded UUIDs. Unrelated VirtualBox profiles, virtual machines, and host documents are outside the deletion scope.

## Retained by design

- signed Whonix download artifacts, base VMs, and clean snapshots needed to create later sessions;
- the project configuration and VirtualBox registry under `%LOCALAPPDATA%\RvbbitGhost`;
- maintenance and installation state needed to verify the base environment;
- engagement evidence deliberately exported by the operator.

Project removal is available through `Uninstall-RvbbitGhost.ps1`. Uninstallation is ordinary file deletion, not cryptographic media sanitization.

## Host records not cleared

The project does not clear, disable, suppress, or rewrite:

- Windows Event Log or audit policy;
- PowerShell, Windows Defender, firewall, DNS-client, or endpoint-security records;
- Prefetch, NTFS USN Journal, page file, hibernation file, crash dumps, restore points, or backups;
- router, ISP, VPN-provider, Tor-relay, destination-service, or customer records;
- VirtualBox or Windows artifacts outside the project-owned session storage.

Selective deletion for the period of a browsing session would be anti-forensic, would damage authorized-assessment evidence, and could itself create suspicious records. It also cannot provide a verifiable absence of traces because the Windows kernel, hypervisor, security products, storage stack, and external observers remain capable of recording activity.

## Safer isolation choices

For work that must not share history with a personal Windows installation:

1. Use dedicated assessment hardware with full-disk encryption and no personal accounts or data.
2. Prefer Qubes-Whonix or a supported Linux host when the threat model requires stronger host isolation.
3. Follow written rules of engagement for source attribution, activity logging, evidence retention, and teardown.
4. Treat shutdown as disposal of the browser VM state, not proof that every physical or external trace was erased.
5. Rebuild dedicated media under an approved sanitization policy when the engagement requires end-of-project decommissioning.

These controls reduce persistence and cross-contamination without weakening the host audit trail or making an unsupported anonymity claim.
