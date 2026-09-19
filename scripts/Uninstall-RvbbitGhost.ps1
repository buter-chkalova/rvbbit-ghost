[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [switch]$RemoveDependencies,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $projectRoot 'src\RvbbitGhost.psm1') -Force
$operationLock = Enter-RgOperationLock -OperationName 'uninstall' -TimeoutSeconds 120
try {
$state = Get-RgState
$runtimeRoot = [IO.Path]::GetFullPath((Get-RgRuntimeRoot))
$expectedRoot = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'RvbbitGhost'))
if ($runtimeRoot -ne $expectedRoot -or (Split-Path -Leaf $runtimeRoot) -ne 'RvbbitGhost') {
    throw "Refusing to remove an unexpected runtime directory: $runtimeRoot"
}

if (-not $PSCmdlet.ShouldProcess('Rvbbit Ghost session VMs, base VMs, snapshots, and runtime files', 'Permanently remove')) {
    return
}

if ($null -ne $state.session) {
    Clear-RgSession -State $state -Force:$Force
}
Clear-RgOrphanSessionVms -State $state

foreach ($entry in @($state.base.workstation, $state.base.gateway)) {
    if ($entry.name -notmatch '^Rvbbit-Ghost-(Gateway|Workstation)-Base$') {
        throw "Refusing to delete base VM with an unexpected name: $($entry.name)"
    }
    if (Test-RgVmExists -Name $entry.name -Uuid $entry.uuid) {
        Stop-RgVm -Vm $entry.name -Force:$Force
        Invoke-RgVBox -Arguments @('unregistervm', $entry.name, '--delete') | Out-Null
    }
}

$remainingDefaultVms = @(Get-RgDefaultVmList)
Remove-Item -LiteralPath $runtimeRoot -Recurse -Force
Write-RgInfo 'Removed Rvbbit Ghost VMs, snapshots, and runtime files. Host documents and Windows settings were not changed.'

if ($RemoveDependencies) {
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($null -eq $winget) {
        Write-RgWarn 'winget is unavailable, so dependencies were left installed.'
        exit 0
    }

    if ($state.dependencies.virtualBoxInstalledByProject) {
        if ($remainingDefaultVms.Count -gt 0) {
            Write-RgWarn 'VirtualBox was left installed because the normal VirtualBox profile contains other registered VMs.'
        }
        else {
            Invoke-RgExternal -FilePath $winget.Source -Arguments @(
                'uninstall', '--id', 'Oracle.VirtualBox', '--exact', '--silent', '--disable-interactivity'
            ) -AllowFailure | Out-Null
        }
    }
    if ($state.dependencies.gpgInstalledByProject) {
        Invoke-RgExternal -FilePath $winget.Source -Arguments @(
            'uninstall', '--id', 'GnuPG.Gpg4win', '--exact', '--silent', '--disable-interactivity'
        ) -AllowFailure | Out-Null
    }
}
}
finally {
    Exit-RgOperationLock -Lock $operationLock
}
