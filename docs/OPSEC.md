# Operational Security

Network isolation cannot compensate for identifying behavior. Apply the following rules during authorized work.

## Identity separation

1. Do not use personal accounts, familiar aliases, personal email addresses, phone numbers, or reused credentials.
2. Keep one assessment identity per disposable session.
3. Do not mix personal browsing and assessment activity on the same host at the same time.
4. Avoid distinctive language, schedules, screen dimensions, and repetitive behavioral patterns when they matter to the threat model.
5. Assume account registration, payment, recovery email, and VPN subscription metadata can identify the operator.

## Browser discipline

1. Use only the Tor Browser installed by Whonix.
2. Do not add extensions, plugins, fonts, certificates, or custom `about:config` changes.
3. Do not ignore Tor Browser security warnings.
4. Prefer HTTPS and verify destination names.
5. Do not use BitTorrent over Tor.
6. Do not open downloaded documents on the Windows host. External applications can make non-Tor requests or reveal document metadata.

## Host and data discipline

1. Use a dedicated, fully patched machine when the engagement risk justifies it.
2. Do not run the project on an employer-managed or monitored endpoint unless the rules of engagement explicitly permit it.
3. Use full-disk encryption on the host, secure boot, and a strong local account credential. These controls protect powered-off storage; they do not hide activity from a running host.
4. Do not enable shared clipboard, folders, USB, audio, drag and drop, or Guest Additions integration.
5. Never keep the only copy of evidence inside a disposable VM.
6. Send authorized evidence to an approved remote repository through the protected session and verify integrity before shutdown.
7. Do not place VPN profiles, keys, certificates, passwords, or client evidence in this repository.

## VPN selection

Rvbbit Ghost does not endorse a provider or claim that a "no logs" statement is independently provable. The provider must supply a standard OpenVPN profile using current cryptography. Avoid solutions that require a proprietary desktop client inside Whonix.

A VPN subscription can be linked through the source address, registration email, payment method, support history, or timing. Anonymous payment alone does not remove those correlations.

## Mandatory fail-closed test

Perform this test after installation, after every VPN change, and before sensitive work:

1. Confirm `openvpn@openvpn` is active and `tun0` exists in Gateway.
2. Confirm Tor is connected and Workstation reaches the Tor check service.
3. Stop OpenVPN in Gateway.
4. Confirm Tor and all Workstation Internet access fail.
5. Start OpenVPN and wait for `tun0`.
6. Restart or reload Tor if required and confirm connectivity.

Do not type `VPN-READY` and do not continue the engagement if step 4 fails.

## Session closeout

1. Upload and verify approved evidence.
2. Log out of assessment systems where the rules of engagement require it.
3. Shut down Workstation from inside the guest.
4. Keep the launcher open until it confirms that both disposable VMs were deleted.
5. If interrupted, run `Stop-RvbbitGhost.ps1 -Force` and then `Audit-RvbbitGhost.ps1` before the next session.

