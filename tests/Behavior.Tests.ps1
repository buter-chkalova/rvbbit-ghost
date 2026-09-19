[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $projectRoot 'src\RvbbitGhost.psm1'
$failures = [System.Collections.Generic.List[string]]::new()
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('RvbbitGhost-Tests-' + [guid]::NewGuid().ToString('N'))
$previousLocalAppData = $env:LOCALAPPDATA
$heldLock = $null

function Assert-Behavior {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )
    if (-not $Condition) {
        $script:failures.Add($Message)
    }
}

function Assert-Throws {
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)][string]$Message,
        [string]$ExpectedMessage
    )

    $threw = $false
    try {
        & $Action
    }
    catch {
        $threw = $true
        if (-not [string]::IsNullOrWhiteSpace($ExpectedMessage)) {
            Assert-Behavior ($_.Exception.Message -like "*$ExpectedMessage*") "$Message (unexpected error: $($_.Exception.Message))"
        }
    }
    Assert-Behavior $threw $Message
}

try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    $env:LOCALAPPDATA = $testRoot
    Remove-Module RvbbitGhost -Force -ErrorAction SilentlyContinue
    Import-Module $modulePath -Force

    $legacyState = [pscustomobject]@{
        schemaVersion = 1
        projectVersion = '0.1.0'
        status = 'imported'
        installedAtUtc = '2026-01-01T00:00:00.0000000Z'
        whonixVersion = '18.2.1.9'
        dependencies = [pscustomobject]@{}
        base = [pscustomobject]@{}
        vpn = [pscustomobject]@{
            required = $true
            mode = 'openvpn-before-tor'
            interface = 'tun0'
            providerConfigured = $false
            attestedAtUtc = $null
        }
        session = $null
    }
    Save-RgState -State $legacyState
    $migratedState = Get-RgState
    Assert-Behavior ($migratedState.schemaVersion -eq 2) 'Legacy state was not migrated to schema version 2.'
    Assert-Behavior ($migratedState.projectVersion -eq '0.2.0') 'Legacy state did not adopt the current project version.'
    Assert-Behavior ($null -ne $migratedState.PSObject.Properties['initializedAtUtc']) 'Migration did not add initializedAtUtc.'
    Assert-Behavior ($null -ne $migratedState.PSObject.Properties['updatedAtUtc']) 'Migration did not add updatedAtUtc.'
    Assert-Behavior ($null -ne $migratedState.vpn.PSObject.Properties['lastVerifiedAtUtc']) 'Migration did not add VPN verification state.'

    $migratedState.initializedAtUtc = '2026-01-02T00:00:00.0000000Z'
    $migratedState.updatedAtUtc = '2026-01-03T00:00:00.0000000Z'
    Save-RgState -State $migratedState
    $savedState = Get-RgState
    $savedInitialized = if ($savedState.initializedAtUtc -is [DateTime]) {
        $savedState.initializedAtUtc.ToUniversalTime()
    } else {
        [DateTime]::Parse($savedState.initializedAtUtc.ToString()).ToUniversalTime()
    }
    $savedUpdated = if ($savedState.updatedAtUtc -is [DateTime]) {
        $savedState.updatedAtUtc.ToUniversalTime()
    } else {
        [DateTime]::Parse($savedState.updatedAtUtc.ToString()).ToUniversalTime()
    }
    $expectedInitialized = [DateTime]::Parse('2026-01-02T00:00:00Z').ToUniversalTime()
    $expectedUpdated = [DateTime]::Parse('2026-01-03T00:00:00Z').ToUniversalTime()
    Assert-Behavior ($savedInitialized -eq $expectedInitialized) 'initializedAtUtc was not persisted.'
    Assert-Behavior ($savedUpdated -eq $expectedUpdated) 'updatedAtUtc was not persisted.'
    $temporaryStateFiles = @(Get-ChildItem -LiteralPath (Get-RgRuntimeRoot) -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\.state-.*\.(tmp|bak)$' })
    Assert-Behavior ($temporaryStateFiles.Count -eq 0) 'Atomic state saving left a transaction file behind.'

    $futureState = [pscustomobject]@{ schemaVersion = 999; vpn = [pscustomobject]@{} }
    Assert-Throws -Action { Save-RgState -State $futureState } -Message 'A future state schema was accepted.' -ExpectedMessage 'Unsupported state schema version'

    $heldLock = Enter-RgOperationLock -OperationName 'behavior test owner' -TimeoutSeconds 0
    $nestedLock = Enter-RgOperationLock -OperationName 'behavior test nested owner' -TimeoutSeconds 0
    Exit-RgOperationLock -Lock $nestedLock
    $worker = [PowerShell]::Create()
    try {
        $workerScript = @'
param($ModulePath, $LocalAppData)
$env:LOCALAPPDATA = $LocalAppData
Import-Module $ModulePath -Force
try {
    $lock = Enter-RgOperationLock -OperationName 'behavior test contender' -TimeoutSeconds 0
    try { 'unexpected-acquisition' } finally { Exit-RgOperationLock -Lock $lock }
}
catch {
    'blocked: ' + $_.Exception.Message
}
'@
        [void]$worker.AddScript($workerScript).AddArgument($modulePath).AddArgument($testRoot)
        $async = $worker.BeginInvoke()
        $workerResult = @($worker.EndInvoke($async) | ForEach-Object { $_.ToString() })
        Assert-Behavior (($workerResult -join "`n") -like '*Another Rvbbit Ghost operation is active*') 'A concurrent operation acquired the global lock.'
    }
    finally {
        $worker.Dispose()
    }
    Exit-RgOperationLock -Lock $heldLock
    $heldLock = $null
    $releasedLock = Enter-RgOperationLock -OperationName 'behavior test after release' -TimeoutSeconds 0
    Exit-RgOperationLock -Lock $releasedLock

    Assert-Throws -Action {
        Assert-RgVmSetting -Info @{} -Key 'nic1' -Allowed @('intnet') -Vm 'Test-VM'
    } -Message 'The audit accepted a missing required VM setting.' -ExpectedMessage 'audit is incomplete'
    Assert-Throws -Action {
        Assert-RgVmSetting -Info @{ nic1 = 'nat' } -Key 'nic1' -Allowed @('intnet') -Vm 'Test-VM'
    } -Message 'The audit accepted an unsafe VM setting.' -ExpectedMessage 'unsafe nic1=nat'
    Assert-RgVmSetting -Info @{ nic1 = 'intnet' } -Key 'nic1' -Allowed @('intnet') -Vm 'Test-VM'

    $expectedFingerprint = '916B8D99C38EAF5E8ADC7A2A8D66066A2EEACCDA'
    $module = Get-Module RvbbitGhost
    & $module {
        param($Fingerprint)
        if (-not (Test-RgVBoxBusyError -Output 'Failed to assign the machine to the session (VBOX_E_VM_ERROR)')) {
            throw 'Known transient VirtualBox lock error was not recognized.'
        }
        if (Test-RgVBoxBusyError -Output 'Permission denied') {
            throw 'A non-transient VirtualBox error was marked retryable.'
        }
        Assert-RgGpgKeyFingerprint -InspectOutput "fpr:::::::::$Fingerprint`:" -ExpectedFingerprint $Fingerprint
        Assert-RgGpgSignatureStatus -VerifyOutput "[GNUPG:] VALIDSIG $Fingerprint 0 0 0 0 0 0 0 0 $Fingerprint" -ExitCode 0 -ExpectedFingerprint $Fingerprint
    } $expectedFingerprint
    Assert-Throws -Action {
        & $module {
            param($Fingerprint)
            Assert-RgGpgKeyFingerprint -InspectOutput 'fpr:::::::::AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA:' -ExpectedFingerprint $Fingerprint
        } $expectedFingerprint
    } -Message 'A signing key with the wrong fingerprint was accepted.' -ExpectedMessage 'does not contain the pinned fingerprint'
    Assert-Throws -Action {
        & $module {
            param($Fingerprint)
            Assert-RgGpgSignatureStatus -VerifyOutput '[GNUPG:] BADSIG 00000000' -ExitCode 1 -ExpectedFingerprint $Fingerprint
        } $expectedFingerprint
    } -Message 'A failed image signature was accepted.' -ExpectedMessage 'signature verification failed'

    & $module {
        $script:BehaviorSaveCount = 0
        Set-Item -Path Function:Test-RgVmExists -Value {
            param([string]$Name, [string]$Uuid)
            return $true
        }
        Set-Item -Path Function:Remove-RgSessionVm -Value {
            param([string]$Name, [string]$Uuid, [switch]$Force)
            if ($Name -like '*Gateway*') {
                throw 'simulated gateway cleanup failure'
            }
        }
        Set-Item -Path Function:Save-RgState -Value {
            param($State)
            $script:BehaviorSaveCount++
        }
    }
    $cleanupState = [pscustomobject]@{
        session = [pscustomobject]@{
            id = '20260101T000000Z-abcdef12'
            workstation = [pscustomobject]@{ name = 'Rvbbit-Ghost-Workstation-Session-20260101T000000Z-abcdef12'; uuid = '11111111-1111-1111-1111-111111111111' }
            gateway = [pscustomobject]@{ name = 'Rvbbit-Ghost-Gateway-Session-20260101T000000Z-abcdef12'; uuid = '22222222-2222-2222-2222-222222222222' }
        }
    }
    Assert-Throws -Action {
        Clear-RgSession -State $cleanupState -Force
    } -Message 'A simulated cleanup failure did not stop cleanup.' -ExpectedMessage 'simulated gateway cleanup failure'
    Assert-Behavior ($null -ne $cleanupState.session) 'Partial cleanup incorrectly cleared the whole session record.'
    Assert-Behavior ($null -eq $cleanupState.session.workstation) 'Partial cleanup did not checkpoint the removed Workstation.'
    Assert-Behavior ($null -ne $cleanupState.session.gateway) 'Partial cleanup lost the Gateway recovery record.'
    $saveCount = & $module { $script:BehaviorSaveCount }
    Assert-Behavior ($saveCount -eq 1) 'Partial cleanup did not save exactly one recovery checkpoint.'
}
finally {
    if ($null -ne $heldLock) {
        Exit-RgOperationLock -Lock $heldLock
    }
    Remove-Module RvbbitGhost -Force -ErrorAction SilentlyContinue
    $env:LOCALAPPDATA = $previousLocalAppData
    if (Test-Path -LiteralPath $testRoot -PathType Container) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

if ($failures.Count -gt 0) {
    throw ($failures -join [Environment]::NewLine)
}

Write-Host 'Behavior tests passed: state migration, locking, audit fail-closed checks, signature rejection, and cleanup recovery.' -ForegroundColor Green
