# Threat Model

## Objective

Rvbbit Ghost reduces the risk of linking an authorized research session to the operator's home address and reduces persistent browser state on a Windows host. It combines OpenVPN-before-Tor, Whonix network separation, disabled host integrations, and disposable linked clones.

This is risk reduction, not proof of anonymity.

## Trusted computing base

The following components are trusted. Compromise of any of them can invalidate the design:

- physical computer, CPU, RAM, firmware, and storage controller;
- Windows kernel, administrator account, drivers, security software, and update chain;
- VirtualBox and its kernel drivers;
- Gpg4win used during image verification;
- the verified Whonix base images;
- OpenVPN, Tor, and Tor Browser implementations;
- the VPN provider for source-address confidentiality from Tor;
- the operator's identity separation and operational discipline.

The hypervisor manages guest memory, virtual disks, input, display, and networking. It is therefore impossible to promise that an untrusted hypervisor cannot access guest data. Rvbbit Ghost minimizes persistence and integration; it does not create a cryptographic boundary against VirtualBox or a Windows administrator.

## Protected assets

- the home address from destination sites and Tor entry relays;
- destination domains and HTTPS content from the ISP and VPN provider;
- cookies, history, local storage, and browser cache after normal session disposal;
- host clipboard, microphone, USB devices, and host folders from accidental guest access;
- unrelated VirtualBox machines and the operator's normal VirtualBox profile;
- assessment identity separation between disposable sessions.

## Security controls

1. The Whonix OVA is accepted only after OpenPGP verification against fingerprint `916B 8D99 C38E AF5E 8ADC 7A2A 8D66 066A 2EEA CCDA`.
2. Workstation has only an internal-network adapter. Gateway has one NAT adapter and one session-specific internal-network adapter.
3. OpenVPN starts before Tor in Gateway, and Whonix `TUNNEL_FIREWALL` is expected to block egress when `tun0` is unavailable.
4. Tor Browser remains inside Whonix-Workstation and is not extended or reconfigured by the project.
5. Every session uses new linked clones, VM UUIDs, MAC addresses, and a unique internal-network name.
6. Clipboard, drag and drop, file transfer, shared folders, USB, audio, VRDE, and recording are disabled.
7. Project VirtualBox state is separated from the user's normal profile through `VBOX_USER_HOME`.
8. Session VMs and differencing disks are unregistered and deleted after shutdown.
9. Cleanup validates project-specific VM names and stored UUIDs.
10. A pre-engagement audit verifies host-visible invariants without entering the guest.

## Observers

### Destination service

The service sees a Tor exit address, Tor Browser characteristics, submitted data, and any authenticated account identity. It should not see the home or VPN address when the chain is healthy.

### Internet service provider

The ISP sees the subscriber, access circuit, VPN endpoint, timing, duration, and volume. It should not see destination sites or direct public Tor-relay connections. VPN traffic may still be recognizable by protocol characteristics or active probing.

### VPN provider

The provider sees the source address, account or payment linkage, timing, volume, and Tor connections leaving its network. It should not see final destinations inside the Tor circuit, but timing correlation remains possible.

### Windows and VirtualBox

The host can observe VM processes, memory allocation, execution times, VPN endpoints, and traffic metadata. Windows may record PowerShell, process, crash, network, filesystem, and security-product events. VirtualBox creates configuration and diagnostic data. Project-scoped files are isolated and session VM files are removed, but Windows-level records remain.

### Local post-session examiner

The registered session VM and ordinary Tor Browser profile should no longer exist after successful disposal. The project does not guarantee recovery resistance for storage blocks, SSD over-provisioning, NTFS journals, page files, crash dumps, RAM, backups, or endpoint-security telemetry.

## Out of scope

- compromised or remotely managed hosts;
- hardware implants, DMA attacks, or malicious firmware;
- global passive adversaries and end-to-end traffic correlation;
- identity disclosure through accounts, writing style, payments, contact data, or unique content;
- browser, kernel, hypervisor, or VM-escape zero-days;
- files exported and opened outside Workstation;
- cameras, physical surveillance, screen capture, or host keyloggers;
- legal demands to the ISP, VPN provider, or destination service;
- cryptographic deletion of guest data;
- unapproved activity outside a documented assessment scope.

## Why host audit logs are not disabled

Windows has no verifiable "record nothing" mode. Disabling event collection, endpoint protection, updates, or audit policy weakens the host, creates new artifacts, and still does not prevent the kernel or an administrator from observing the hypervisor. Rvbbit Ghost isolates browser state instead of claiming that host telemetry has ceased.

## Assurance ceiling

Windows with a hosted VirtualBox hypervisor is not the highest-assurance platform for anonymity research. For higher-risk work, use dedicated hardware with Qubes-Whonix or a supported Linux host and keep the research system separate from personal devices. That architectural change provides more value than increasingly aggressive Windows modifications.

