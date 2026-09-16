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

    if (-not $Info.ContainsKey($Key)) {
        Add-AuditWarning "$Vm did not report '$Key'; verify this control in the VirtualBox UI."
        return
    }
    if ($Info[$Key] -notin $Allowed) {
        Add-AuditFailure "$Vm has unsafe $Key=$($Info[$Key]); expected $($Allowed -join ' or ')."
    }
}

Assert-RgWindows
$state = Get-RgState
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
    $attested = [DateTime]::Parse($state.vpn.attestedAtUtc).ToUniversalTime()
    if ($attested -lt [DateTime]::UtcNow.AddDays(-30)) {
        Add-AuditWarning "The last VPN fail-closed attestation is older than 30 days: $($attested.ToString('u'))"
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
Write-Host 'The Windows host cannot verify the in-guest VPN tunnel without weakening isolation.' -ForegroundColor Yellow
Write-Host 'Repeat the OpenVPN disconnect test inside Whonix-Gateway before the engagement.' -ForegroundColor Yellow

