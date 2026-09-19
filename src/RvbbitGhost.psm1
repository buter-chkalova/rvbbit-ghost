Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ProjectVersion = '0.2.0'
$script:StateSchemaVersion = 2
$script:RuntimeRoot = Join-Path $env:LOCALAPPDATA 'RvbbitGhost'
$script:StatePath = Join-Path $script:RuntimeRoot 'state.json'
$script:VBoxHome = Join-Path $script:RuntimeRoot 'virtualbox-home'

function Write-RgInfo {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "[Rvbbit Ghost] $Message" -ForegroundColor Cyan
}

function Write-RgWarn {
    param([Parameter(Mandatory)][string]$Message)
    Write-Warning "[Rvbbit Ghost] $Message"
}

function Get-RgRuntimeRoot {
    return $script:RuntimeRoot
}

function Get-RgStatePath {
    return $script:StatePath
}

function Get-RgVBoxHome {
    return $script:VBoxHome
}

function Assert-RgWindows {
    if ($env:OS -ne 'Windows_NT') {
        throw 'Rvbbit Ghost supports Windows 10 and Windows 11 on x64 hardware only.'
    }

    if (-not [Environment]::Is64BitOperatingSystem) {
        throw 'A 64-bit Windows installation is required.'
    }

    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    if ($os.Caption -notmatch 'Windows (10|11)') {
        throw "Unsupported host operating system: $($os.Caption)"
    }
    if ($os.Caption -match 'Windows 10') {
        Write-RgWarn 'Windows 10 reached general end of support. Continue only if this edition is receiving current security updates through ESU or an applicable LTSC lifecycle.'
    }

    $cpu = Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1
    if ($null -ne $cpu.VirtualizationFirmwareEnabled -and -not $cpu.VirtualizationFirmwareEnabled) {
        Write-RgWarn 'Firmware virtualization is reported as disabled. Enable Intel VT-x or AMD-V in UEFI/BIOS before starting the VMs.'
    }
}

function New-RgDirectory {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Add-RgNoteProperty {
    param(
        [Parameter(Mandatory)]$InputObject,
        [Parameter(Mandatory)][string]$Name,
        $Value
    )

    if ($null -eq $InputObject.PSObject.Properties[$Name]) {
        $InputObject | Add-Member -MemberType NoteProperty -Name $Name -Value $Value
    }
}

function Repair-RgStateSchema {
    param([Parameter(Mandatory)]$State)

    Add-RgNoteProperty -InputObject $State -Name 'schemaVersion' -Value 1
    $schemaVersion = [int]$State.schemaVersion
    if ($schemaVersion -lt 1 -or $schemaVersion -gt $script:StateSchemaVersion) {
        throw "Unsupported state schema version: $schemaVersion"
    }

    Add-RgNoteProperty -InputObject $State -Name 'initializedAtUtc' -Value $null
    Add-RgNoteProperty -InputObject $State -Name 'updatedAtUtc' -Value $null
    Add-RgNoteProperty -InputObject $State -Name 'projectVersion' -Value $script:ProjectVersion
    if ($null -ne $State.vpn) {
        Add-RgNoteProperty -InputObject $State.vpn -Name 'lastVerifiedAtUtc' -Value $null
        Add-RgNoteProperty -InputObject $State.vpn -Name 'verificationMethod' -Value 'operator-confirmed-live-check'
    }

    $State.schemaVersion = $script:StateSchemaVersion
    $State.projectVersion = $script:ProjectVersion
    return $State
}

function Get-RgState {
    if (-not (Test-Path -LiteralPath $script:StatePath -PathType Leaf)) {
        throw "Rvbbit Ghost is not installed. Run scripts\Install-RvbbitGhost.ps1 first."
    }

    try {
        $state = Get-Content -LiteralPath $script:StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        throw "Rvbbit Ghost state is unreadable or invalid: $($_.Exception.Message)"
    }

    return Repair-RgStateSchema -State $state
}

function Save-RgState {
    param([Parameter(Mandatory)]$State)

    New-RgDirectory -Path $script:RuntimeRoot
    $State = Repair-RgStateSchema -State $State
    $transactionId = [guid]::NewGuid().ToString('N')
    $temporaryPath = Join-Path $script:RuntimeRoot ('.state-' + $transactionId + '.tmp')
    $backupPath = Join-Path $script:RuntimeRoot ('.state-' + $transactionId + '.bak')
    $encoding = [Text.UTF8Encoding]::new($false)
    try {
        [IO.File]::WriteAllText($temporaryPath, ($State | ConvertTo-Json -Depth 12), $encoding)
        if (Test-Path -LiteralPath $script:StatePath -PathType Leaf) {
            [IO.File]::Replace($temporaryPath, $script:StatePath, $backupPath, $true)
        }
        else {
            [IO.File]::Move($temporaryPath, $script:StatePath)
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
        if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
            Remove-Item -LiteralPath $backupPath -Force
        }
    }
}

function Get-RgOperationMutexName {
    $normalizedRoot = [IO.Path]::GetFullPath($script:RuntimeRoot).ToUpperInvariant()
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = [BitConverter]::ToString($sha256.ComputeHash([Text.Encoding]::UTF8.GetBytes($normalizedRoot))).Replace('-', '')
    }
    finally {
        $sha256.Dispose()
    }
    return "Local\RvbbitGhost-Operation-$($hash.Substring(0, 24))"
}

function Enter-RgOperationLock {
    param(
        [Parameter(Mandatory)][string]$OperationName,
        [ValidateRange(0, 3600)][int]$TimeoutSeconds = 30
    )

    $mutex = [Threading.Mutex]::new($false, (Get-RgOperationMutexName))
    $acquired = $false
    try {
        try {
            $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds))
        }
        catch [Threading.AbandonedMutexException] {
            $acquired = $true
            Write-RgWarn 'Recovered the operation lock after an interrupted Rvbbit Ghost process.'
        }

        if (-not $acquired) {
            throw "Another Rvbbit Ghost operation is active. '$OperationName' could not acquire the operation lock within $TimeoutSeconds seconds."
        }

        return [pscustomobject]@{
            Mutex = $mutex
            OperationName = $OperationName
            Released = $false
        }
    }
    catch {
        if (-not $acquired) {
            $mutex.Dispose()
        }
        throw
    }
}

function Exit-RgOperationLock {
    param($Lock)

    if ($null -eq $Lock -or $Lock.Released) {
        return
    }

    $Lock.Mutex.ReleaseMutex()
    $Lock.Mutex.Dispose()
    $Lock.Released = $true
}

function Get-RgVBoxManage {
    $command = Get-Command VBoxManage.exe -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }

    $candidates = @(
        (Join-Path $env:ProgramFiles 'Oracle\VirtualBox\VBoxManage.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Oracle\VirtualBox\VBoxManage.exe')
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }

    throw 'VBoxManage.exe was not found. Install Oracle VirtualBox or rerun the installer without -SkipDependencyInstall.'
}

function Get-RgGpg {
    $command = Get-Command gpg.exe -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }

    $candidates = @(
        (Join-Path $env:ProgramFiles 'GnuPG\bin\gpg.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'GnuPG\bin\gpg.exe'),
        (Join-Path $env:ProgramFiles 'Gpg4win\bin\gpg.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Gpg4win\bin\gpg.exe')
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }

    throw 'gpg.exe was not found. Install Gpg4win or rerun the installer without -SkipDependencyInstall.'
}

function Invoke-RgExternal {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$AllowFailure
    )

    $output = & $FilePath @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $text = ($output | Out-String).TrimEnd()
    if (-not $AllowFailure -and $exitCode -ne 0) {
        throw "Command failed with exit code $exitCode.`nFile: $FilePath`nArguments: $($Arguments -join ' ')`n$text"
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = $text
    }
}

function Invoke-RgVBox {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$AllowFailure,
        [switch]$RetryOnBusy,
        [ValidateRange(1, 60)][int]$BusyTimeoutSeconds = 15
    )

    New-RgDirectory -Path $script:VBoxHome
    # Keep the VirtualBox registry and global logs scoped to Rvbbit Ghost instead
    # of mixing them with the user's normal VirtualBox profile.
    $env:VBOX_USER_HOME = $script:VBoxHome
    $vbox = Get-RgVBoxManage
    if (-not $RetryOnBusy) {
        return Invoke-RgExternal -FilePath $vbox -Arguments $Arguments -AllowFailure:$AllowFailure
    }

    $deadline = [DateTime]::UtcNow.AddSeconds($BusyTimeoutSeconds)
    do {
        $result = Invoke-RgExternal -FilePath $vbox -Arguments $Arguments -AllowFailure
        if ($result.ExitCode -eq 0) {
            return $result
        }
        if (-not (Test-RgVBoxBusyError -Output $result.Output) -or [DateTime]::UtcNow -ge $deadline) {
            if ($AllowFailure) {
                return $result
            }
            throw "Command failed with exit code $($result.ExitCode).`nFile: $vbox`nArguments: $($Arguments -join ' ')`n$($result.Output)"
        }
        Start-Sleep -Milliseconds 500
    } while ($true)
}

function Test-RgVBoxBusyError {
    param([Parameter(Mandatory)][string]$Output)

    return $Output -match '(?i)(VBOX_E_OBJECT_IN_USE|failed to assign the machine to the session|machine .* is already locked)'
}

function Install-RgWingetPackage {
    param([Parameter(Mandatory)][string]$PackageId)

    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($null -eq $winget) {
        throw "Windows Package Manager (winget) is required to install $PackageId automatically. Install App Installer from Microsoft, or install the dependency manually."
    }

    Write-RgInfo "Installing dependency $PackageId with winget. The publisher installer may request elevation."
    $arguments = @(
        'install', '--id', $PackageId, '--exact', '--source', 'winget',
        '--accept-source-agreements', '--accept-package-agreements',
        '--silent', '--disable-interactivity'
    )
    Invoke-RgExternal -FilePath $winget.Source -Arguments $arguments | Out-Null
}

function Get-RgVirtualBoxVersion {
    $result = Invoke-RgVBox -Arguments @('--version')
    if ($result.Output -notmatch '^(\d+)\.(\d+)') {
        throw "Could not parse VirtualBox version: $($result.Output)"
    }

    return [version]::new([int]$Matches[1], [int]$Matches[2])
}

function Get-RgVmList {
    $result = Invoke-RgVBox -Arguments @('list', 'vms')
    $items = @()
    foreach ($line in ($result.Output -split "`r?`n")) {
        if ($line -match '^"(.*)" \{([0-9a-fA-F-]+)\}$') {
            $items += [pscustomobject]@{
                Name = $Matches[1]
                Uuid = $Matches[2].ToLowerInvariant()
            }
        }
    }
    return $items
}

function Get-RgDefaultVmList {
    $savedHome = $env:VBOX_USER_HOME
    try {
        Remove-Item Env:VBOX_USER_HOME -ErrorAction SilentlyContinue
        $vbox = Get-RgVBoxManage
        $result = Invoke-RgExternal -FilePath $vbox -Arguments @('list', 'vms')
        $items = @()
        foreach ($line in ($result.Output -split "`r?`n")) {
            if ($line -match '^"(.*)" \{([0-9a-fA-F-]+)\}$') {
                $items += [pscustomobject]@{
                    Name = $Matches[1]
                    Uuid = $Matches[2].ToLowerInvariant()
                }
            }
        }
        return $items
    }
    finally {
        if ([string]::IsNullOrWhiteSpace($savedHome)) {
            Remove-Item Env:VBOX_USER_HOME -ErrorAction SilentlyContinue
        }
        else {
            $env:VBOX_USER_HOME = $savedHome
        }
    }
}

function Test-RgVmExists {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Uuid
    )

    $vm = Get-RgVmList | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    if ($null -eq $vm) {
        return $false
    }
    if (-not [string]::IsNullOrWhiteSpace($Uuid) -and $vm.Uuid -ne $Uuid.ToLowerInvariant()) {
        return $false
    }
    return $true
}

function Get-RgVmState {
    param([Parameter(Mandatory)][string]$Vm)

    $result = Invoke-RgVBox -Arguments @('showvminfo', $Vm, '--machinereadable') -RetryOnBusy
    foreach ($line in ($result.Output -split "`r?`n")) {
        if ($line -match '^VMState="([^"]+)"$') {
            return $Matches[1]
        }
    }
    throw "Could not determine the state of VM '$Vm'."
}

function Wait-RgVmStopped {
    param(
        [Parameter(Mandatory)][string]$Vm,
        [int]$TimeoutSeconds = 90
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $state = Get-RgVmState -Vm $Vm
        if ($state -in @('poweroff', 'aborted', 'saved')) {
            return $state
        }
        Start-Sleep -Seconds 2
    } while ([DateTime]::UtcNow -lt $deadline)

    return Get-RgVmState -Vm $Vm
}

function Wait-RgVmRunning {
    param(
        [Parameter(Mandatory)][string]$Vm,
        [ValidateRange(5, 600)][int]$TimeoutSeconds = 120
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $state = Get-RgVmState -Vm $Vm
        if ($state -eq 'running') {
            return
        }
        if ($state -in @('poweroff', 'aborted', 'saved')) {
            throw "VM '$Vm' entered state '$state' before it became ready for operator verification."
        }
        Start-Sleep -Seconds 2
    } while ([DateTime]::UtcNow -lt $deadline)

    throw "VM '$Vm' did not reach the running state within $TimeoutSeconds seconds."
}

function Request-RgGatewayReadinessConfirmation {
    param([Parameter(Mandatory)][string]$GatewayVm)

    if ((Get-RgVmState -Vm $GatewayVm) -ne 'running') {
        throw "Gateway VM '$GatewayVm' is not running."
    }

    $challenge = 'READY-' + [guid]::NewGuid().ToString('N').Substring(0, 8).ToUpperInvariant()
    Write-Host @'

Before Workstation is allowed to start, verify inside this session's Gateway:
  1. openvpn@openvpn is active and tun0 exists.
  2. Tor reports a successful connection through the VPN.
  3. Stop OpenVPN and confirm Tor loses connectivity (fail-closed).
  4. Start OpenVPN again, wait for tun0, and confirm Tor reconnects.

This is a live operator gate, not host-side proof of the guest tunnel.
'@ -ForegroundColor Yellow
    $answer = Read-Host "Type $challenge only after all four checks succeed"
    if ($answer -cne $challenge) {
        throw 'Gateway readiness was not confirmed. Workstation will not be started.'
    }

    return [DateTime]::UtcNow.ToString('o')
}

function Stop-RgVm {
    param(
        [Parameter(Mandatory)][string]$Vm,
        [int]$GraceSeconds = 60,
        [switch]$Force
    )

    $state = Get-RgVmState -Vm $Vm
    if ($state -eq 'saved') {
        Invoke-RgVBox -Arguments @('discardstate', $Vm) | Out-Null
        return
    }
    if ($state -in @('poweroff', 'aborted')) {
        return
    }

    Invoke-RgVBox -Arguments @('controlvm', $Vm, 'acpipowerbutton') -AllowFailure | Out-Null
    $state = Wait-RgVmStopped -Vm $Vm -TimeoutSeconds $GraceSeconds
    if ($state -notin @('poweroff', 'aborted', 'saved')) {
        if (-not $Force) {
            throw "VM '$Vm' did not shut down within $GraceSeconds seconds. Run Stop-RvbbitGhost.ps1 -Force to power it off."
        }
        Write-RgWarn "Forcing VM '$Vm' off after the graceful shutdown timeout."
        Invoke-RgVBox -Arguments @('controlvm', $Vm, 'poweroff') | Out-Null
        $state = Wait-RgVmStopped -Vm $Vm -TimeoutSeconds 30
        if ($state -notin @('poweroff', 'aborted', 'saved')) {
            throw "VM '$Vm' did not reach a stopped state after forced power-off."
        }
    }

    if ((Get-RgVmState -Vm $Vm) -eq 'saved') {
        Invoke-RgVBox -Arguments @('discardstate', $Vm) | Out-Null
    }
}

function Remove-RgSharedFolders {
    param([Parameter(Mandatory)][string]$Vm)

    $result = Invoke-RgVBox -Arguments @('showvminfo', $Vm, '--machinereadable') -RetryOnBusy
    $names = @()
    foreach ($line in ($result.Output -split "`r?`n")) {
        if ($line -match '^SharedFolderNameMachineMapping\d+="([^"]+)"$') {
            $names += $Matches[1]
        }
    }
    foreach ($name in $names) {
        Invoke-RgVBox -Arguments @('sharedfolder', 'remove', $Vm, '--name', $name) -RetryOnBusy | Out-Null
    }
}

function Set-RgVmIsolation {
    param([Parameter(Mandatory)][string]$Vm)

    $arguments = @(
        'modifyvm', $Vm,
        '--clipboard-mode', 'disabled',
        '--clipboard-file-transfers', 'disabled',
        '--drag-and-drop', 'disabled',
        '--audio-enabled', 'off',
        '--audio-in', 'off',
        '--audio-out', 'off',
        '--usb-ohci', 'off',
        '--usb-ehci', 'off',
        '--usb-xhci', 'off',
        '--vrde', 'off',
        '--recording', 'off'
    )
    Invoke-RgVBox -Arguments $arguments -RetryOnBusy | Out-Null
    Remove-RgSharedFolders -Vm $Vm
}

function Set-RgSessionNetwork {
    param(
        [Parameter(Mandatory)][string]$GatewayVm,
        [Parameter(Mandatory)][string]$WorkstationVm,
        [Parameter(Mandatory)][string]$InternalNetworkName
    )

    $gatewayArgs = @('modifyvm', $GatewayVm, '--nic1', 'nat', '--nic2', 'intnet', '--intnet2', $InternalNetworkName)
    $workstationArgs = @('modifyvm', $WorkstationVm, '--nic1', 'intnet', '--intnet1', $InternalNetworkName)
    foreach ($index in 3..8) {
        $gatewayArgs += @("--nic$index", 'none')
    }
    foreach ($index in 2..8) {
        $workstationArgs += @("--nic$index", 'none')
    }

    Invoke-RgVBox -Arguments $gatewayArgs -RetryOnBusy | Out-Null
    Invoke-RgVBox -Arguments $workstationArgs -RetryOnBusy | Out-Null
}

function Invoke-RgDownload {
    param(
        [Parameter(Mandatory)][uri]$Uri,
        [Parameter(Mandatory)][string]$Destination
    )

    if ($Uri.Scheme -ne 'https') {
        throw "Refusing a non-HTTPS download: $Uri"
    }

    New-RgDirectory -Path (Split-Path -Parent $Destination)
    $partial = "$Destination.partial"
    if (Test-Path -LiteralPath $partial) {
        Remove-Item -LiteralPath $partial -Force
    }

    Write-RgInfo "Downloading $Uri"
    $bits = Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue
    if ($null -ne $bits) {
        Start-BitsTransfer -Source $Uri.AbsoluteUri -Destination $partial -DisplayName 'Rvbbit Ghost verified download'
    }
    else {
        Invoke-WebRequest -Uri $Uri.AbsoluteUri -OutFile $partial -UseBasicParsing
    }

    Move-Item -LiteralPath $partial -Destination $Destination -Force
}

function Test-RgWhonixSignature {
    param(
        [Parameter(Mandatory)][string]$ImagePath,
        [Parameter(Mandatory)][string]$SignaturePath,
        [Parameter(Mandatory)][string]$KeyPath,
        [Parameter(Mandatory)][string]$ExpectedFingerprint
    )

    $gpg = Get-RgGpg
    $gpgHome = Join-Path $script:RuntimeRoot 'gnupg'
    New-RgDirectory -Path $gpgHome
    $expected = ($ExpectedFingerprint -replace '\s', '').ToUpperInvariant()

    $inspect = Invoke-RgExternal -FilePath $gpg -Arguments @(
        '--batch', '--homedir', $gpgHome, '--with-colons',
        '--import-options', 'show-only', '--import', $KeyPath
    )
    Assert-RgGpgKeyFingerprint -InspectOutput $inspect.Output -ExpectedFingerprint $expected

    Invoke-RgExternal -FilePath $gpg -Arguments @('--batch', '--homedir', $gpgHome, '--import', $KeyPath) | Out-Null
    $verify = Invoke-RgExternal -FilePath $gpg -Arguments @(
        '--batch', '--homedir', $gpgHome, '--status-fd', '1',
        '--verify', $SignaturePath, $ImagePath
    ) -AllowFailure

    Assert-RgGpgSignatureStatus -VerifyOutput $verify.Output -ExitCode $verify.ExitCode -ExpectedFingerprint $expected

    Write-RgInfo "Whonix image signature is valid for pinned key $expected."
}

function Assert-RgGpgKeyFingerprint {
    param(
        [Parameter(Mandatory)][string]$InspectOutput,
        [Parameter(Mandatory)][string]$ExpectedFingerprint
    )

    $expected = ($ExpectedFingerprint -replace '\s', '').ToUpperInvariant()
    $fingerprints = @()
    foreach ($line in ($InspectOutput -split "`r?`n")) {
        if ($line -match '^fpr:::::::::([0-9A-Fa-f]+):') {
            $fingerprints += $Matches[1].ToUpperInvariant()
        }
    }
    if ($expected -notin $fingerprints) {
        throw "The downloaded Whonix key does not contain the pinned fingerprint $expected."
    }
}

function Assert-RgGpgSignatureStatus {
    param(
        [Parameter(Mandatory)][string]$VerifyOutput,
        [Parameter(Mandatory)][int]$ExitCode,
        [Parameter(Mandatory)][string]$ExpectedFingerprint
    )

    $expected = ($ExpectedFingerprint -replace '\s', '').ToUpperInvariant()
    $validForPinnedKey = $false
    foreach ($line in ($VerifyOutput -split "`r?`n")) {
        if ($line -match '^\[GNUPG:\] VALIDSIG (.+)$') {
            $fields = $Matches[1] -split '\s+'
            if ($expected -in ($fields | ForEach-Object { $_.ToUpperInvariant() })) {
                $validForPinnedKey = $true
            }
        }
    }
    if ($ExitCode -ne 0 -or -not $validForPinnedKey) {
        throw "Whonix image signature verification failed. The image will not be imported.`n$VerifyOutput"
    }
}

function Test-RgSnapshotExists {
    param(
        [Parameter(Mandatory)][string]$Vm,
        [Parameter(Mandatory)][string]$Snapshot
    )
    $result = Invoke-RgVBox -Arguments @('snapshot', $Vm, 'showvminfo', $Snapshot) -AllowFailure -RetryOnBusy
    return $result.ExitCode -eq 0
}

function New-RgCleanSnapshot {
    param(
        [Parameter(Mandatory)][string]$GatewayVm,
        [Parameter(Mandatory)][string]$WorkstationVm
    )

    if ((Get-RgVmState -Vm $GatewayVm) -ne 'poweroff' -or (Get-RgVmState -Vm $WorkstationVm) -ne 'poweroff') {
        throw 'Both base VMs must be powered off before a clean snapshot is created.'
    }

    $name = 'rvbbit-clean-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
    $description = 'Rvbbit Ghost clean base. Maintenance only; never browse from the base VMs.'
    Invoke-RgVBox -Arguments @('snapshot', $GatewayVm, 'take', $name, '--description', $description) | Out-Null
    try {
        Invoke-RgVBox -Arguments @('snapshot', $WorkstationVm, 'take', $name, '--description', $description) | Out-Null
    }
    catch {
        Invoke-RgVBox -Arguments @('snapshot', $GatewayVm, 'delete', $name) -AllowFailure | Out-Null
        throw
    }
    return $name
}

function New-RgLinkedClone {
    param(
        [Parameter(Mandatory)][string]$BaseVm,
        [Parameter(Mandatory)][string]$Snapshot,
        [Parameter(Mandatory)][string]$CloneName,
        [Parameter(Mandatory)][string]$BaseFolder
    )

    if (-not (Test-RgSnapshotExists -Vm $BaseVm -Snapshot $Snapshot)) {
        throw "Snapshot '$Snapshot' was not found on base VM '$BaseVm'."
    }
    New-RgDirectory -Path $BaseFolder
    Invoke-RgVBox -Arguments @(
        'clonevm', $BaseVm, '--snapshot', $Snapshot, '--options', 'link',
        '--name', $CloneName, '--basefolder', $BaseFolder, '--register'
    ) | Out-Null

    $vm = Get-RgVmList | Where-Object { $_.Name -eq $CloneName } | Select-Object -First 1
    if ($null -eq $vm) {
        throw "Linked clone '$CloneName' was not registered."
    }
    return $vm
}

function Remove-RgSessionVm {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Uuid,
        [switch]$Force
    )

    if ($Name -notmatch '^Rvbbit-Ghost-(Gateway|Workstation)-Session-[0-9A-Za-z-]+$') {
        throw "Refusing to delete VM with an unexpected name: $Name"
    }
    if (-not (Test-RgVmExists -Name $Name -Uuid $Uuid)) {
        return
    }

    Stop-RgVm -Vm $Name -Force:$Force
    Invoke-RgVBox -Arguments @('unregistervm', $Name, '--delete') | Out-Null
}

function Clear-RgSession {
    param(
        [Parameter(Mandatory)]$State,
        [switch]$Force
    )

    if ($null -eq $State.session) {
        return
    }

    $session = $State.session
    if ($session.id -notmatch '^\d{8}T\d{6}Z-[0-9a-f]{8}$') {
        throw "Refusing to remove a session directory with an unexpected identifier: $($session.id)"
    }

    if ($null -ne $session.workstation -and (Test-RgVmExists -Name $session.workstation.name -Uuid $session.workstation.uuid)) {
        Remove-RgSessionVm -Name $session.workstation.name -Uuid $session.workstation.uuid -Force:$Force
    }
    if ($null -ne $session.workstation) {
        $State.session.workstation = $null
        Save-RgState -State $State
    }
    if ($null -ne $session.gateway -and (Test-RgVmExists -Name $session.gateway.name -Uuid $session.gateway.uuid)) {
        Remove-RgSessionVm -Name $session.gateway.name -Uuid $session.gateway.uuid -Force:$Force
    }
    if ($null -ne $session.gateway) {
        $State.session.gateway = $null
        Save-RgState -State $State
    }
    $sessionsRoot = [IO.Path]::GetFullPath((Join-Path $script:RuntimeRoot 'sessions'))
    $sessionPath = [IO.Path]::GetFullPath((Join-Path $sessionsRoot $session.id))
    if ($sessionPath.StartsWith($sessionsRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $sessionPath -PathType Container)) {
        Remove-Item -LiteralPath $sessionPath -Recurse -Force
    }

    $State.session = $null
    Save-RgState -State $State
}

function Clear-RgOrphanSessionVms {
    param([Parameter(Mandatory)]$State)

    $preservedUuids = @()
    if ($null -ne $State.session) {
        foreach ($entry in @($State.session.gateway, $State.session.workstation)) {
            if ($null -ne $entry) {
                $preservedUuids += $entry.uuid.ToLowerInvariant()
            }
        }
    }

    $orphans = @(Get-RgVmList | Where-Object {
        $_.Name -match '^Rvbbit-Ghost-(Gateway|Workstation)-Session-[0-9A-Za-z-]+$' -and
        $_.Uuid -notin $preservedUuids
    })
    foreach ($orphan in $orphans) {
        Write-RgWarn "Removing orphaned disposable VM '$($orphan.Name)' from an interrupted launch."
        Remove-RgSessionVm -Name $orphan.Name -Uuid $orphan.Uuid -Force
    }
}

function Start-RgBaseForMaintenance {
    param([Parameter(Mandatory)]$State)

    if ($null -ne $State.session) {
        throw 'A disposable session is registered. Stop it before base maintenance.'
    }
    foreach ($vm in @($State.base.gateway.name, $State.base.workstation.name)) {
        if ((Get-RgVmState -Vm $vm) -ne 'poweroff') {
            throw "Base VM '$vm' is not powered off."
        }
    }

    Invoke-RgVBox -Arguments @('startvm', $State.base.gateway.name, '--type', 'gui') | Out-Null
    Wait-RgVmRunning -Vm $State.base.gateway.name -TimeoutSeconds 120
    Invoke-RgVBox -Arguments @('startvm', $State.base.workstation.name, '--type', 'gui') | Out-Null
    Wait-RgVmRunning -Vm $State.base.workstation.name -TimeoutSeconds 120
}

function Assert-RgVmSetting {
    param(
        [Parameter(Mandatory)][hashtable]$Info,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string[]]$Allowed,
        [Parameter(Mandatory)][string]$Vm
    )

    if (-not $Info.ContainsKey($Key)) {
        throw "$Vm did not report required setting '$Key'; the audit is incomplete."
    }
    if ($Info[$Key] -notin $Allowed) {
        throw "$Vm has unsafe $Key=$($Info[$Key]); expected $($Allowed -join ' or ')."
    }
}

function Wait-RgBaseShutdown {
    param([Parameter(Mandatory)]$State)

    Write-RgInfo 'Waiting for both base VMs to be shut down from inside their guest operating systems.'
    while ($true) {
        $gatewayState = Get-RgVmState -Vm $State.base.gateway.name
        $workstationState = Get-RgVmState -Vm $State.base.workstation.name
        if ($gatewayState -eq 'poweroff' -and $workstationState -eq 'poweroff') {
            return
        }
        Start-Sleep -Seconds 5
    }
}

function Assert-RgBaseIntegrity {
    param([Parameter(Mandatory)]$State)

    if ($State.status -ne 'ready') {
        throw "Installation status is '$($State.status)'. Complete Initialize-RvbbitGhost.ps1 first."
    }
    if ($null -eq $State.vpn -or -not $State.vpn.required -or -not $State.vpn.providerConfigured) {
        throw 'The mandatory OpenVPN-before-Tor setup has not been attested. Run Initialize-RvbbitGhost.ps1.'
    }
    foreach ($entry in @($State.base.gateway, $State.base.workstation)) {
        if (-not (Test-RgVmExists -Name $entry.name -Uuid $entry.uuid)) {
            throw "Base VM '$($entry.name)' is missing or has an unexpected UUID."
        }
        if (-not (Test-RgSnapshotExists -Vm $entry.name -Snapshot $entry.snapshot)) {
            throw "Clean snapshot '$($entry.snapshot)' is missing from '$($entry.name)'."
        }
    }
}

Export-ModuleMember -Function @(
    'Write-RgInfo', 'Write-RgWarn', 'Get-RgRuntimeRoot', 'Get-RgStatePath', 'Get-RgVBoxHome',
    'Assert-RgWindows', 'New-RgDirectory', 'Get-RgState', 'Save-RgState',
    'Enter-RgOperationLock', 'Exit-RgOperationLock',
    'Get-RgVBoxManage', 'Get-RgGpg', 'Invoke-RgExternal', 'Invoke-RgVBox',
    'Install-RgWingetPackage', 'Get-RgVirtualBoxVersion', 'Get-RgVmList', 'Get-RgDefaultVmList',
    'Test-RgVmExists', 'Get-RgVmState', 'Wait-RgVmStopped', 'Wait-RgVmRunning', 'Stop-RgVm',
    'Set-RgVmIsolation', 'Set-RgSessionNetwork', 'Invoke-RgDownload',
    'Test-RgWhonixSignature', 'Test-RgSnapshotExists', 'New-RgCleanSnapshot',
    'New-RgLinkedClone', 'Remove-RgSessionVm', 'Clear-RgSession', 'Clear-RgOrphanSessionVms',
    'Start-RgBaseForMaintenance', 'Wait-RgBaseShutdown', 'Assert-RgBaseIntegrity',
    'Request-RgGatewayReadinessConfirmation', 'Assert-RgVmSetting'
)
