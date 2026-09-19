[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $projectRoot 'src\RvbbitGhost.psm1') -Force
$operationLock = Enter-RgOperationLock -OperationName 'clean-base maintenance' -TimeoutSeconds 30
try {
$state = Get-RgState
Assert-RgBaseIntegrity -State $state

Write-Host @'

MAINTENANCE MODE
Update Whonix, OpenVPN configuration, Tor and Tor Browser only. Re-test the
TUNNEL_FIREWALL fail-closed behavior. Do not browse, open personal files, or
sign in to accounts. Shut down Workstation, then Gateway, when finished.
The previous clean snapshots are retained as rollback points.
'@ -ForegroundColor Yellow

Start-RgBaseForMaintenance -State $state
Wait-RgBaseShutdown -State $state
$challenge = 'VPN-' + [guid]::NewGuid().ToString('N').Substring(0, 8).ToUpperInvariant()
$answer = Read-Host "Type $challenge only if OpenVPN and the fail-closed test succeeded"
if ($answer -cne $challenge) {
    throw 'VPN readiness was not confirmed. The previous active clean snapshot remains selected.'
}
Set-RgVmIsolation -Vm $state.base.gateway.name
Set-RgVmIsolation -Vm $state.base.workstation.name
$snapshot = New-RgCleanSnapshot -GatewayVm $state.base.gateway.name -WorkstationVm $state.base.workstation.name
$state.base.gateway.snapshot = $snapshot
$state.base.workstation.snapshot = $snapshot
$state.vpn.providerConfigured = $true
$verifiedAtUtc = [DateTime]::UtcNow.ToString('o')
$state.vpn.attestedAtUtc = $verifiedAtUtc
$state.vpn.lastVerifiedAtUtc = $verifiedAtUtc
$state.vpn.verificationMethod = 'operator-confirmed-live-check'
$state.updatedAtUtc = $verifiedAtUtc
Save-RgState -State $state
Write-RgInfo "The active clean base is now '$snapshot'. Older snapshots were retained."
}
finally {
    Exit-RgOperationLock -Lock $operationLock
}
