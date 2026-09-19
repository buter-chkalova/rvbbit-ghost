# Changelog

## 0.2.0 - 2026-09-19

- Added backward-compatible state-schema migration and atomic state replacement.
- Added a cross-process operation lock with emergency stop compatibility.
- Replaced fixed Gateway delays with VM-state polling and a per-session live readiness gate before Workstation starts.
- Changed missing VirtualBox audit settings and stale clean-base VPN attestations to audit failures.
- Added behavior tests for state migration, lock contention, audit failures, signature rejection, and partial-cleanup recovery.
- Added cleanup checkpoints so a failed teardown retains the remaining VM identity for recovery.
- Added bounded retries for transient VirtualBox machine-lock errors on idempotent read and configuration commands.

## 0.1.0 - 2026-09-17

- Initial Windows 10/11 launcher based on signed Whonix 18.2.1.9 images.
- Mandatory OpenVPN-before-Tor configuration with Whonix TUNNEL_FIREWALL attestation.
- Disposable linked-clone sessions and isolated VirtualBox profile.
- Host integration hardening, crash recovery, maintenance snapshots and scoped uninstall.
- English threat model, operational guidance, authorized-assessment policy and upstream references.
- Host-visible pre-engagement audit for VM identity, networking, snapshots and integration controls.
- Explicit project authorship and host logging/data-disposal boundaries.
