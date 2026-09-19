[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $projectRoot 'src\RvbbitGhost.psm1') -Force
$operationLock = Enter-RgOperationLock -OperationName 'initialize' -TimeoutSeconds 30
try {
$state = Get-RgState

if ($state.status -eq 'ready') {
    Write-RgInfo 'The clean base is already initialized.'
    exit 0
}
if ($state.status -ne 'imported') {
    throw "Unexpected installation status: $($state.status)"
}
foreach ($entry in @($state.base.gateway, $state.base.workstation)) {
    if (-not (Test-RgVmExists -Name $entry.name -Uuid $entry.uuid)) {
        throw "Base VM '$($entry.name)' is missing or has an unexpected UUID."
    }
}

Write-Host @'

The two Whonix base VMs will open for INITIAL SETUP ONLY.

Inside Whonix:
  1. BEFORE enabling Tor, configure a provider-issued OpenVPN profile inside
     Whonix-Gateway using the official guide linked below.
  2. Enable Whonix TUNNEL_FIREWALL (VPN_FIREWALL=1, interface tun0).
  3. Enable/start openvpn@openvpn and verify that it is active.
  4. Test fail-closed behavior: when OpenVPN is stopped, Tor and Workstation
     must lose connectivity; restore OpenVPN and test Tor again.
  5. Complete the Whonix first-run dialogs and apply all updates in both VMs.
  6. Install/update Tor Browser through Tor Browser Downloader in Workstation.
  7. Do not browse or sign in to any account from these base VMs.
  8. Shut down Workstation, then Gateway, using their guest menus.

Official Whonix guide:
https://www.whonix.org/wiki/Tunnels/Connecting_to_a_VPN_before_Tor

This console will wait and then create the clean snapshots.
'@ -ForegroundColor Yellow

Start-RgBaseForMaintenance -State $state
Wait-RgBaseShutdown -State $state
$challenge = 'VPN-' + [guid]::NewGuid().ToString('N').Substring(0, 8).ToUpperInvariant()
$answer = Read-Host "Type $challenge only if OpenVPN-before-Tor AND its fail-closed test both succeeded"
if ($answer -cne $challenge) {
    throw 'VPN readiness was not confirmed. No clean snapshot was created. Rerun initialization after fixing the VPN setup.'
}
Set-RgVmIsolation -Vm $state.base.gateway.name
Set-RgVmIsolation -Vm $state.base.workstation.name
$snapshot = New-RgCleanSnapshot -GatewayVm $state.base.gateway.name -WorkstationVm $state.base.workstation.name
$state.base.gateway.snapshot = $snapshot
$state.base.workstation.snapshot = $snapshot
$state.status = 'ready'
$state.vpn.providerConfigured = $true
$verifiedAtUtc = [DateTime]::UtcNow.ToString('o')
$state.vpn.attestedAtUtc = $verifiedAtUtc
$state.vpn.lastVerifiedAtUtc = $verifiedAtUtc
$state.vpn.verificationMethod = 'operator-confirmed-live-check'
$state.initializedAtUtc = $verifiedAtUtc
Save-RgState -State $state

Write-RgInfo "Clean VPN-before-Tor base snapshot '$snapshot' was created. Run Start-RvbbitGhost.ps1 for disposable browsing sessions."
}
finally {
    Exit-RgOperationLock -Lock $operationLock
}
