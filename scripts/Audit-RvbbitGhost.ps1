[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $projectRoot 'src\RvbbitGhost.psm1') -Force

$failures = [System.Collections.Generic.List[string]]::new()
$warnings = [System.Collections.Generic.List[string]]::new()

function Add-AuditFailure {
    param([Parameter(Mandatory)][string]$Message)
    $script:failures.Add($Message)
}

function Add-AuditWarning {
    param([Parameter(Mandatory)][string]$Message)
    $script:warnings.Add($Message)
}

function Get-MachineReadableInfo {
    param([Parameter(Mandatory)][string]$Vm)

    $result = Invoke-RgVBox -Arguments @('showvminfo', $Vm, '--machinereadable')
    $values = @{}
    foreach ($line in ($result.Output -split "`r?`n")) {
        if ($line -match '^([^=]+)="(.*)"$') {
            $values[$Matches[1]] = $Matches[2]
        }
        elseif ($line -match '^([^=]+)=(.*)$') {
            $values[$Matches[1]] = $Matches[2]
        }
    }
    return $values
}

function Test-Setting {
    param(
        [Parameter(Mandatory)][hashtable]$Info,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string[]]$Allowed,
        [Parameter(Mandatory)][string]$Vm
    )

    try {
        Assert-RgVmSetting -Info $Info -Key $Key -Allowed $Allowed -Vm $Vm
    }
    catch {
        Add-AuditFailure $_.Exception.Message
    }
}

$operationLock = Enter-RgOperationLock -OperationName 'audit' -TimeoutSeconds 30
try {
Assert-RgWindows
$state = Get-RgState
$release = Get-Content -LiteralPath (Join-Path $projectRoot 'config\release.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if ($state.whonixVersion -ne $release.whonix.version) {
    Add-AuditFailure "Installed Whonix version '$($state.whonixVersion)' differs from pinned release '$($release.whonix.version)'."
}
if (-not $state.vpn.required -or $state.vpn.mode -ne $release.vpn.mode -or $state.vpn.interface -ne $release.vpn.interface) {
    Add-AuditFailure 'Installed VPN policy differs from the pinned release configuration.'
}
try {
    Assert-RgBaseIntegrity -State $state
}
catch {
    Add-AuditFailure $_.Exception.Message
}

try {
    $version = Get-RgVirtualBoxVersion
    if ($version -lt [version]'7.0') {
        Add-AuditFailure "VirtualBox $version is older than the supported minimum 7.0."
    }
}
catch {
    Add-AuditFailure $_.Exception.Message
}

if ($null -ne $state.session) {
    Add-AuditWarning 'A disposable session is registered. Run the audit again after closing it.'
}

if ($null -eq $state.vpn -or -not $state.vpn.providerConfigured) {
    Add-AuditFailure 'OpenVPN-before-Tor has not been attested.'
}
elseif ($null -eq $state.vpn.attestedAtUtc) {
    Add-AuditFailure 'VPN attestation has no timestamp.'
}
else {
    try {
        $attested = [DateTime]::Parse($state.vpn.attestedAtUtc).ToUniversalTime()
        if ($attested -lt [DateTime]::UtcNow.AddDays(-30)) {
            Add-AuditFailure "The last clean-base VPN fail-closed attestation is older than 30 days: $($attested.ToString('u'))"
        }
    }
    catch {
        Add-AuditFailure "VPN attestation timestamp is invalid: $($state.vpn.attestedAtUtc)"
    }
}

foreach ($entry in @($state.base.gateway, $state.base.workstation)) {
    if (-not (Test-RgVmExists -Name $entry.name -Uuid $entry.uuid)) {
        Add-AuditFailure "Base VM identity mismatch: $($entry.name)"
        continue
    }
    if ((Get-RgVmState -Vm $entry.name) -ne 'poweroff') {
        Add-AuditFailure "Base VM must be powered off outside maintenance: $($entry.name)"
    }

    $info = Get-MachineReadableInfo -Vm $entry.name
    Test-Setting -Info $info -Key 'clipboard' -Allowed @('disabled') -Vm $entry.name
    Test-Setting -Info $info -Key 'draganddrop' -Allowed @('disabled') -Vm $entry.name
    Test-Setting -Info $info -Key 'vrde' -Allowed @('off', 'disabled') -Vm $entry.name
    Test-Setting -Info $info -Key 'recording' -Allowed @('off', 'disabled') -Vm $entry.name

    $sharedFolderKeys = @($info.Keys | Where-Object { $_ -like 'SharedFolderNameMachineMapping*' })
    if ($sharedFolderKeys.Count -gt 0) {
        Add-AuditFailure "$($entry.name) has one or more persistent shared folders."
    }

    if ($entry.name -match 'Workstation') {
        Test-Setting -Info $info -Key 'nic1' -Allowed @('intnet') -Vm $entry.name
        foreach ($index in 2..8) {
            Test-Setting -Info $info -Key "nic$index" -Allowed @('none') -Vm $entry.name
        }
    }
    else {
        Test-Setting -Info $info -Key 'nic1' -Allowed @('nat') -Vm $entry.name
        Test-Setting -Info $info -Key 'nic2' -Allowed @('intnet') -Vm $entry.name
        foreach ($index in 3..8) {
            Test-Setting -Info $info -Key "nic$index" -Allowed @('none') -Vm $entry.name
        }
    }
}

foreach ($warning in $warnings) {
    Write-Warning $warning
}
if ($failures.Count -gt 0) {
    foreach ($failure in $failures) {
        Write-Error $failure
    }
    exit 1
}

Write-Host 'Host-visible Rvbbit Ghost controls passed.' -ForegroundColor Green
Write-Host 'In-guest VPN and Tor readiness is not host-verifiable; Start requires a live operator check before Workstation opens.' -ForegroundColor Yellow
}
finally {
    Exit-RgOperationLock -Lock $operationLock
}

