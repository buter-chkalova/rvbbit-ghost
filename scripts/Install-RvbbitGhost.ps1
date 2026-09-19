[CmdletBinding()]
param(
    [switch]$SkipDependencyInstall,
    [switch]$SkipInitialization,
    [switch]$KeepDownload,
    [switch]$AcceptWhonixLicense
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $projectRoot 'src\RvbbitGhost.psm1') -Force
$operationLock = Enter-RgOperationLock -OperationName 'install' -TimeoutSeconds 30
try {
$release = Get-Content -LiteralPath (Join-Path $projectRoot 'config\release.json') -Raw | ConvertFrom-Json

Assert-RgWindows
$statePath = Get-RgStatePath
if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    $existingState = Get-RgState
    if ($existingState.status -eq 'ready') {
        Write-RgInfo 'Rvbbit Ghost is already installed and initialized.'
        exit 0
    }
    throw "An incomplete installation exists at $statePath. Complete initialization or run Uninstall-RvbbitGhost.ps1 before reinstalling."
}

$virtualBoxInstalledByProject = $false
$gpgInstalledByProject = $false

try {
    Get-RgVBoxManage | Out-Null
}
catch {
    if ($SkipDependencyInstall) { throw }
    Install-RgWingetPackage -PackageId $release.dependencies.virtualBoxWingetId
    $virtualBoxInstalledByProject = $true
}

try {
    Get-RgGpg | Out-Null
}
catch {
    if ($SkipDependencyInstall) { throw }
    Install-RgWingetPackage -PackageId $release.dependencies.gpgWingetId
    $gpgInstalledByProject = $true
}

# Resolve both tools again after installation. This fails closed if an installer requested a reboot.
Get-RgVBoxManage | Out-Null
Get-RgGpg | Out-Null
$virtualBoxVersion = Get-RgVirtualBoxVersion
$minimumVersion = [version]$release.dependencies.minimumVirtualBoxVersion
if ($virtualBoxVersion -lt $minimumVersion) {
    throw "VirtualBox $virtualBoxVersion is too old. Version $minimumVersion or newer is required."
}

$runtimeRoot = Get-RgRuntimeRoot
$downloadRoot = Join-Path $runtimeRoot 'downloads'
New-RgDirectory -Path $downloadRoot
$imageName = Split-Path -Leaf ([uri]$release.whonix.imageUrl).AbsolutePath
$imagePath = Join-Path $downloadRoot $imageName
$signaturePath = "$imagePath.asc"
$keyPath = Join-Path $downloadRoot 'whonix-derivative.asc'

Invoke-RgDownload -Uri $release.whonix.imageUrl -Destination $imagePath
Invoke-RgDownload -Uri $release.whonix.signatureUrl -Destination $signaturePath
Invoke-RgDownload -Uri $release.whonix.keyUrl -Destination $keyPath
Test-RgWhonixSignature `
    -ImagePath $imagePath `
    -SignaturePath $signaturePath `
    -KeyPath $keyPath `
    -ExpectedFingerprint $release.whonix.signingKeyFingerprint

if (-not $AcceptWhonixLicense) {
    Write-Host ''
    Write-Host 'Before import, read the Whonix license and terms:' -ForegroundColor Yellow
    Write-Host 'https://www.whonix.org/wiki/Terms_of_Service'
    $answer = Read-Host 'Type ACCEPT to continue importing the official Whonix appliance'
    if ($answer -cne 'ACCEPT') {
        throw 'Whonix license acceptance was not confirmed. Nothing was imported.'
    }
}

$gatewayBaseName = 'Rvbbit-Ghost-Gateway-Base'
$workstationBaseName = 'Rvbbit-Ghost-Workstation-Base'
$existingNames = @(Get-RgVmList | ForEach-Object { $_.Name })
if ($gatewayBaseName -in $existingNames -or $workstationBaseName -in $existingNames) {
    throw 'A Rvbbit Ghost base VM name is already registered in VirtualBox.'
}

$before = @(Get-RgVmList | ForEach-Object { $_.Uuid })
Write-RgInfo "Importing Whonix $($release.whonix.version). This can take several minutes."
Invoke-RgVBox -Arguments @(
    'import', $imagePath,
    '--vsys', '0', '--eula', 'accept',
    '--vsys', '1', '--eula', 'accept'
) | Out-Null

$newVms = @(Get-RgVmList | Where-Object { $_.Uuid -notin $before })
$gateway = $newVms | Where-Object { $_.Name -match 'Whonix-Gateway' } | Select-Object -First 1
$workstation = $newVms | Where-Object { $_.Name -match 'Whonix-Workstation' } | Select-Object -First 1
if ($null -eq $gateway -or $null -eq $workstation) {
    throw 'Import completed, but the new Whonix Gateway and Workstation VMs could not be identified. Inspect VirtualBox before retrying.'
}

Invoke-RgVBox -Arguments @('modifyvm', $gateway.Uuid, '--name', $gatewayBaseName) | Out-Null
Invoke-RgVBox -Arguments @('modifyvm', $workstation.Uuid, '--name', $workstationBaseName) | Out-Null
Set-RgVmIsolation -Vm $gatewayBaseName
Set-RgVmIsolation -Vm $workstationBaseName

$gateway = Get-RgVmList | Where-Object { $_.Name -eq $gatewayBaseName } | Select-Object -First 1
$workstation = Get-RgVmList | Where-Object { $_.Name -eq $workstationBaseName } | Select-Object -First 1
$state = [pscustomobject]@{
    schemaVersion = 2
    projectVersion = '0.2.0'
    status = 'imported'
    installedAtUtc = [DateTime]::UtcNow.ToString('o')
    initializedAtUtc = $null
    updatedAtUtc = $null
    whonixVersion = $release.whonix.version
    dependencies = [pscustomobject]@{
        virtualBoxInstalledByProject = $virtualBoxInstalledByProject
        gpgInstalledByProject = $gpgInstalledByProject
    }
    base = [pscustomobject]@{
        gateway = [pscustomobject]@{ name = $gateway.Name; uuid = $gateway.Uuid; snapshot = $null }
        workstation = [pscustomobject]@{ name = $workstation.Name; uuid = $workstation.Uuid; snapshot = $null }
    }
    vpn = [pscustomobject]@{
        required = [bool]$release.vpn.required
        mode = $release.vpn.mode
        interface = $release.vpn.interface
        providerConfigured = $false
        attestedAtUtc = $null
        lastVerifiedAtUtc = $null
        verificationMethod = 'operator-confirmed-live-check'
    }
    session = $null
}
Save-RgState -State $state

if (-not $KeepDownload) {
    Remove-Item -LiteralPath $imagePath -Force
    Remove-Item -LiteralPath $signaturePath -Force
}

Write-RgInfo 'Verified Whonix base VMs were imported and host integrations were disabled.'
if ($SkipInitialization) {
    Write-RgWarn 'Initialization was skipped. Run Initialize-RvbbitGhost.ps1 before starting a disposable session.'
    exit 0
}

& (Join-Path $PSScriptRoot 'Initialize-RvbbitGhost.ps1')
}
finally {
    Exit-RgOperationLock -Lock $operationLock
}
