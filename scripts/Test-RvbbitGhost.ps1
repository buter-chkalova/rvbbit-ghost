[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$failures = [System.Collections.Generic.List[string]]::new()

function Assert-Check {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        $script:failures.Add($Message)
    }
}

$scriptFiles = @(Get-ChildItem -LiteralPath $projectRoot -Recurse -File | Where-Object { $_.Extension -in @('.ps1', '.psm1') })
foreach ($file in $scriptFiles) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    foreach ($parseError in $errors) {
        $failures.Add("PowerShell parse error in $($file.FullName): $($parseError.Message)")
    }
}

$scriptText = ($scriptFiles | Where-Object { $_.FullName -ne $PSCommandPath } | ForEach-Object {
    Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8
}) -join "`n"
foreach ($prohibitedPattern in @(
    'Clear-EventLog',
    'Remove-EventLog',
    'wevtutil(?:\.exe)?\s+(?:cl|clear-log)',
    'auditpol(?:\.exe)?.*/clear',
    '(?:Stop|Set)-Service[^\r\n]*eventlog'
)) {
    Assert-Check ($scriptText -notmatch $prohibitedPattern) "Prohibited host audit-log manipulation found: $prohibitedPattern"
}

$release = Get-Content -LiteralPath (Join-Path $projectRoot 'config\release.json') -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-Check ($release.schemaVersion -eq 1) 'release.json has an unsupported schemaVersion.'
Assert-Check ($release.whonix.version -match '^\d+\.\d+\.\d+\.\d+$') 'Whonix version is not pinned.'
Assert-Check ($release.whonix.signingKeyFingerprint -eq '916B8D99C38EAF5E8ADC7A2A8D66066A2EEACCDA') 'Whonix fingerprint differs from the reviewed value.'
Assert-Check ($release.vpn.required -eq $true) 'VPN-before-Tor must be mandatory.'
Assert-Check ($release.vpn.mode -eq 'openvpn-before-tor') 'Only the reviewed OpenVPN-before-Tor mode is accepted.'
foreach ($property in @('imageUrl', 'signatureUrl', 'keyUrl')) {
    $uri = [uri]$release.whonix.$property
    Assert-Check ($uri.Scheme -eq 'https') "$property must use HTTPS."
    Assert-Check ($uri.Host -eq 'www.whonix.org') "$property must use the official www.whonix.org host."
}

$moduleText = Get-Content -LiteralPath (Join-Path $projectRoot 'src\RvbbitGhost.psm1') -Raw -Encoding UTF8
foreach ($required in @(
    '--clipboard-mode', '--clipboard-file-transfers', '--drag-and-drop',
    '--audio-enabled', '--usb-ohci', '--vrde', '--recording', 'VALIDSIG',
    "'--nic1', 'intnet'", "'--nic1', 'nat'", "'--options', 'link'", 'VBOX_USER_HOME'
)) {
    Assert-Check ($moduleText.Contains($required)) "Required isolation or verification control is missing: $required"
}

$auditText = Get-Content -LiteralPath (Join-Path $projectRoot 'scripts\Audit-RvbbitGhost.ps1') -Raw -Encoding UTF8
foreach ($required in @("'nic1' -Allowed @('intnet')", "'nic1' -Allowed @('nat')", 'Assert-RgVmSetting')) {
    Assert-Check ($auditText.Contains($required)) "Required audit control is missing: $required"
}

$startText = Get-Content -LiteralPath (Join-Path $projectRoot 'scripts\Start-RvbbitGhost.ps1') -Raw -Encoding UTF8
foreach ($required in @('Wait-RgVmRunning', 'Request-RgGatewayReadinessConfirmation', 'Enter-RgOperationLock')) {
    Assert-Check ($startText.Contains($required)) "Required launch safety control is missing: $required"
}

foreach ($relativePath in @(
    'scripts\Install-RvbbitGhost.ps1',
    'scripts\Initialize-RvbbitGhost.ps1',
    'scripts\Start-RvbbitGhost.ps1',
    'scripts\Stop-RvbbitGhost.ps1',
    'scripts\Update-CleanBase.ps1',
    'scripts\Audit-RvbbitGhost.ps1',
    'scripts\Uninstall-RvbbitGhost.ps1'
)) {
    $operationText = Get-Content -LiteralPath (Join-Path $projectRoot $relativePath) -Raw -Encoding UTF8
    Assert-Check ($operationText.Contains('Enter-RgOperationLock')) "Operation lock acquisition is missing: $relativePath"
    Assert-Check ($operationText.Contains('Exit-RgOperationLock')) "Operation lock release is missing: $relativePath"
}

$readme = Get-Content -LiteralPath (Join-Path $projectRoot 'README.md') -Raw -Encoding UTF8
Assert-Check ($readme -match 'SECURITY: no-absolute-anonymity') 'README must clearly reject an absolute-anonymity guarantee.'
Assert-Check ($readme -match 'SECURITY: no-windows-log-wiping') 'README must disclose that Windows logs are not erased.'
Assert-Check ($readme -match 'VPN.*Tor') 'README must document the mandatory VPN-before-Tor path.'

foreach ($relativePath in @(
    'docs\THREAT-MODEL.md',
    'docs\LOGGING.md',
    'docs\OPSEC.md',
    'docs\AUTHORIZED-PENTESTING.md',
    'docs\ARCHITECTURE.md',
    'docs\REFERENCES.md'
)) {
    Assert-Check (Test-Path -LiteralPath (Join-Path $projectRoot $relativePath) -PathType Leaf) "Required documentation is missing: $relativePath"
}

$textFiles = @(Get-ChildItem -LiteralPath $projectRoot -Recurse -File | Where-Object { $_.Extension -in @('.md', '.ps1', '.psm1', '.json', '.yml', '.yaml', '.cmd') })
foreach ($file in $textFiles) {
    $text = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
    Assert-Check ($text -notmatch '[\u0400-\u04FF]') "Non-English Cyrillic text remains in $($file.FullName)."
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ }
    exit 1
}

& (Join-Path $projectRoot 'tests\Behavior.Tests.ps1')
Write-Host "All $($scriptFiles.Count) PowerShell files parsed successfully; static invariants and behavior tests passed." -ForegroundColor Green
