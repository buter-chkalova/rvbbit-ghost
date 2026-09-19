[CmdletBinding()]
param(
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $projectRoot 'src\RvbbitGhost.psm1') -Force
$operationLock = Enter-RgOperationLock -OperationName 'stop' -TimeoutSeconds 120
try {
$state = Get-RgState
if ($null -eq $state.session) {
    Clear-RgOrphanSessionVms -State $state
    Write-RgInfo 'No disposable session is registered.'
    exit 0
}

Clear-RgSession -State $state -Force:$Force
$state = Get-RgState
Clear-RgOrphanSessionVms -State $state
Write-RgInfo 'Disposable session was stopped and removed.'
}
finally {
    Exit-RgOperationLock -Lock $operationLock
}
