[CmdletBinding()]
param(
    [ValidateRange(30, 600)][int]$GatewayStartTimeoutSeconds = 120
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $projectRoot 'src\RvbbitGhost.psm1') -Force

$operationLock = $null
$sessionId = $null
$gatewayName = $null
$workstationName = $null
$workstationUuid = $null

try {
    $operationLock = Enter-RgOperationLock -OperationName 'start' -TimeoutSeconds 30
    $state = Get-RgState
    Assert-RgBaseIntegrity -State $state
    Clear-RgOrphanSessionVms -State $state

    if ($null -ne $state.session) {
        $registered = @()
        foreach ($entry in @($state.session.gateway, $state.session.workstation)) {
            if ($null -ne $entry -and (Test-RgVmExists -Name $entry.name -Uuid $entry.uuid)) {
                $registered += $entry
            }
        }
        $running = @($registered | Where-Object { (Get-RgVmState -Vm $_.name) -notin @('poweroff', 'aborted', 'saved') })
        if ($running.Count -gt 0) {
            throw 'A Rvbbit Ghost session is still running. Use Stop-RvbbitGhost.ps1 to close and discard it.'
        }
        Clear-RgSession -State $state -Force
        $state = Get-RgState
    }

    foreach ($entry in @($state.base.gateway, $state.base.workstation)) {
        if ((Get-RgVmState -Vm $entry.name) -ne 'poweroff') {
            throw "Base VM '$($entry.name)' must be powered off. Base VMs are for maintenance only."
        }
    }

    $sessionId = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' + ([guid]::NewGuid().ToString('N').Substring(0, 8))
    $sessionRoot = Join-Path (Get-RgRuntimeRoot) (Join-Path 'sessions' $sessionId)
    $gatewayName = "Rvbbit-Ghost-Gateway-Session-$sessionId"
    $workstationName = "Rvbbit-Ghost-Workstation-Session-$sessionId"
    $internalNetwork = "rvbbit-$sessionId"
    $state.session = [pscustomobject]@{
        id = $sessionId
        status = 'starting'
        createdAtUtc = [DateTime]::UtcNow.ToString('o')
        startedAtUtc = $null
        gatewayVerifiedAtUtc = $null
        internalNetwork = $internalNetwork
        gateway = $null
        workstation = $null
    }
    Save-RgState -State $state

    try {
        Write-RgInfo 'Creating disposable linked clones from the signed, clean base.'
        $gateway = New-RgLinkedClone `
            -BaseVm $state.base.gateway.name `
            -Snapshot $state.base.gateway.snapshot `
            -CloneName $gatewayName `
            -BaseFolder $sessionRoot
        $state.session.gateway = [pscustomobject]@{ name = $gateway.Name; uuid = $gateway.Uuid }
        Save-RgState -State $state

        $workstation = New-RgLinkedClone `
            -BaseVm $state.base.workstation.name `
            -Snapshot $state.base.workstation.snapshot `
            -CloneName $workstationName `
            -BaseFolder $sessionRoot
        $workstationUuid = $workstation.Uuid
        $state.session.workstation = [pscustomobject]@{ name = $workstation.Name; uuid = $workstation.Uuid }
        Save-RgState -State $state

        Set-RgSessionNetwork -GatewayVm $gatewayName -WorkstationVm $workstationName -InternalNetworkName $internalNetwork
        Set-RgVmIsolation -Vm $gatewayName
        Set-RgVmIsolation -Vm $workstationName

        Invoke-RgVBox -Arguments @('startvm', $gatewayName, '--type', 'gui') | Out-Null
        Write-RgInfo 'Gateway started. Waiting for the VM to reach its running state.'
        Wait-RgVmRunning -Vm $gatewayName -TimeoutSeconds $GatewayStartTimeoutSeconds
        $verifiedAtUtc = Request-RgGatewayReadinessConfirmation -GatewayVm $gatewayName
        $state.session.gatewayVerifiedAtUtc = $verifiedAtUtc
        $state.vpn.lastVerifiedAtUtc = $verifiedAtUtc
        $state.vpn.verificationMethod = 'operator-confirmed-live-check'
        Save-RgState -State $state

        Invoke-RgVBox -Arguments @('startvm', $workstationName, '--type', 'gui') | Out-Null
        Wait-RgVmRunning -Vm $workstationName -TimeoutSeconds 120
        $state.session.status = 'running'
        $state.session.startedAtUtc = [DateTime]::UtcNow.ToString('o')
        Save-RgState -State $state
    }
    catch {
        $launchError = $_
        $latestState = Get-RgState
        if ($null -ne $latestState.session -and $latestState.session.id -eq $sessionId) {
            Write-RgWarn 'Session launch failed. Removing every clone that was registered before the failure.'
            Clear-RgSession -State $latestState -Force
        }
        throw $launchError
    }
}
finally {
    if ($null -ne $operationLock) {
        Exit-RgOperationLock -Lock $operationLock
    }
}

Write-Host @'

Disposable session is running.
Expected path: Windows -> OpenVPN in Whonix-Gateway -> Tor -> Internet.
Use only Tor Browser inside Whonix-Workstation.
Shut down Whonix-Workstation from its guest menu when finished.
Keep this console open: it will remove both session VMs afterward.
'@ -ForegroundColor Green

try {
    while ($true) {
        $latestState = Get-RgState
        if ($null -eq $latestState.session -or $latestState.session.id -ne $sessionId) {
            break
        }
        if (-not (Test-RgVmExists -Name $workstationName -Uuid $workstationUuid)) {
            break
        }
        if ((Get-RgVmState -Vm $workstationName) -in @('poweroff', 'aborted', 'saved')) {
            break
        }
        Start-Sleep -Seconds 5
    }
}
finally {
    $cleanupLock = Enter-RgOperationLock -OperationName 'session cleanup' -TimeoutSeconds 120
    try {
        $latestState = Get-RgState
        if ($null -ne $latestState.session -and $latestState.session.id -eq $sessionId) {
            Write-RgInfo 'Closing and deleting the disposable session VMs.'
            Clear-RgSession -State $latestState -Force
        }
    }
    finally {
        Exit-RgOperationLock -Lock $cleanupLock
    }
}

Write-RgInfo 'Disposable session removed. The clean base and host files were not modified.'
