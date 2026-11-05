param([ValidateRange(1,4)][int]$Slot = 1)

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
. (Join-Path $PSScriptRoot 'WtPets.Common.ps1')

$STATE_FILE     = [System.IO.Path]::Combine($env:TEMP, "claude-wt-pets-state-$Slot.json")
$PID_FILE       = [System.IO.Path]::Combine($env:TEMP, "claude-wt-pets-pet-$Slot.pid")
$TRANSITION_LOG = [System.IO.Path]::Combine($env:TEMP, 'claude-wt-pets-transition.log')
$OWNER_MAP_FILE = [System.IO.Path]::Combine($env:TEMP, 'claude-wt-pets-owner-map.json')
$script:petSize = Get-WtPetsPetSize
$GAP            = 10
$MAX_SLOTS      = 4
$SLEEP_AFTER_SECONDS = 300
$KEEP_TOPMOST_SECONDS = 3
$POLL_INTERVAL_MS = 1000
$OWNER_CHECK_SECONDS = 2
$SESSION_GONE_GRACE_SECONDS = 8
$DONE_STATE_GONE_GRACE_SECONDS = 3
$FAST_SHARED_SESSION_GONE_GRACE_SECONDS = 6
$TRANSITION_LOG_MAX_BYTES = 524288
$TRANSITION_LOG_KEEP_LINES = 1000
$STATE_NAMES    = @('idle', 'thinking', 'done', 'notification', 'sleeping', 'error', 'disconnected')
$VALID_STATES   = @{}
$STATE_NAMES | ForEach-Object { $VALID_STATES[$_] = $true }
$MEMORY_LIMIT_BYTES = 157286400

$script:jsonCache = @{}

function Read-JsonCached([string]$Path) {
    if (-not [System.IO.File]::Exists($Path)) { return $null }
    try {
        $ticks = ([System.IO.File]::GetLastWriteTimeUtc($Path)).Ticks
        $entry = $script:jsonCache[$Path]
        if ($entry -and $entry.Ticks -eq $ticks) { return $entry.Data }
        $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
        $data = $raw | ConvertFrom-Json
        $script:jsonCache[$Path] = @{ Ticks = $ticks; Data = $data }
        return $data
    } catch { return $null }
}

$createdNew = $false
$script:mutex = New-Object System.Threading.Mutex($true, "Local\claude-wt-pets-pet-$Slot", [ref]$createdNew)
if (-not $createdNew) {
    $script:mutex.Dispose()
    exit 0
}

trap {
    $trapError = ''
    try {
        if ($_.Exception -and $_.Exception.Message) {
            $trapError = [string]$_.Exception.Message
        }
    } catch {}
    $runtimeSkipReason = ''
    try {
        if (Get-Command Get-LiveSessionCloseStateSkipReason -ErrorAction SilentlyContinue) {
            $runtimeSkipReason = Get-LiveSessionCloseStateSkipReason
        } elseif ((Get-Command Test-SessionAliveForCleanup -ErrorAction SilentlyContinue) -and (Test-SessionAliveForCleanup)) {
            $runtimeSkipReason = 'live-session-trap'
        }
    } catch {}
    $shouldRemoveRuntimeFiles = [string]::IsNullOrWhiteSpace($runtimeSkipReason)
    try {
        if (Get-Command Write-TransitionLog -ErrorAction SilentlyContinue) {
            Write-TransitionLog 'pet-trap-cleanup' $script:lastState $script:lastTs "state_file_exists=$(Test-Path -LiteralPath $STATE_FILE);pid_file_exists=$(Test-Path -LiteralPath $PID_FILE);error=$trapError;skip_reason=$runtimeSkipReason"
        }
    } catch {}
    if ($shouldRemoveRuntimeFiles) {
        try { Remove-Item $STATE_FILE -ErrorAction SilentlyContinue } catch {}
        try {
            if (Get-Command Write-TransitionLog -ErrorAction SilentlyContinue) {
                Write-TransitionLog 'pet-trap-remove-state' $script:lastState $script:lastTs "state_file_exists=$(Test-Path -LiteralPath $STATE_FILE)"
            }
        } catch {}
        try { Remove-Item $PID_FILE -ErrorAction SilentlyContinue } catch {}
        try {
            if (Get-Command Write-TransitionLog -ErrorAction SilentlyContinue) {
                Write-TransitionLog 'pet-trap-remove-pid' $script:lastState $script:lastTs "pid_file_exists=$(Test-Path -LiteralPath $PID_FILE)"
            }
        } catch {}
    } else {
        try {
            if (Get-Command Write-TransitionLog -ErrorAction SilentlyContinue) {
                Write-TransitionLog 'pet-trap-keep-state' $script:lastState $script:lastTs "state_file_exists=$(Test-Path -LiteralPath $STATE_FILE);skip_reason=$runtimeSkipReason"
                Write-TransitionLog 'pet-trap-keep-pid' $script:lastState $script:lastTs "pid_file_exists=$(Test-Path -LiteralPath $PID_FILE);skip_reason=$runtimeSkipReason"
            }
        } catch {}
    }
    try { $script:mutex.ReleaseMutex() } catch {}
    try { $script:mutex.Dispose() } catch {}
    if (-not $shouldRemoveRuntimeFiles) {
        try {
            $restartCooldownFile = [System.IO.Path]::Combine($env:TEMP, "claude-wt-pets-pet-$Slot.restart-ts")
            $canRestart = $true
            try {
                if (Test-Path -LiteralPath $restartCooldownFile) {
                    $prevRestartTs = [long]((Get-Content -LiteralPath $restartCooldownFile -Raw -Encoding ASCII).Trim())
                    if (([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $prevRestartTs) -lt 10000) {
                        $canRestart = $false
                    }
                }
            } catch {}
            if ($canRestart) {
                [System.IO.File]::WriteAllText($restartCooldownFile, [string][DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
                $restartShell = New-Object -ComObject Shell.Application
                $restartShell.ShellExecute(
                    (Join-Path $PSHOME 'powershell.exe'),
                    ("-NoProfile -WindowStyle Hidden -STA -ExecutionPolicy RemoteSigned -File `"$PSScriptRoot\pet.ps1`" -Slot $Slot"),
                    '', 'open', 0
                )
                try {
                    if (Get-Command Write-TransitionLog -ErrorAction SilentlyContinue) {
                        Write-TransitionLog 'pet-trap-self-restart' $script:lastState $script:lastTs "slot=$Slot"
                    }
                } catch {}
            } else {
                try {
                    if (Get-Command Write-TransitionLog -ErrorAction SilentlyContinue) {
                        Write-TransitionLog 'pet-trap-restart-cooldown' $script:lastState $script:lastTs "slot=$Slot"
                    }
                } catch {}
            }
        } catch {}
    }
}

Set-Content -LiteralPath $PID_FILE -Value $PID -Encoding ASCII

$script:lastTs    = 0
$script:lastState = 'idle'
$script:ownerPid  = 0
$script:ownerHwnd = 0
$script:ownerSource = ''
$script:sessionPid = 0
$script:staleOwnerPid = 0
$script:staleOwnerHwnd = 0
$script:staleSessionPid = 0
$script:sessionGoneSince = 0
$script:sessionGoneStateTs = 0
$script:latestStateTs = 0
$script:character = ''
$script:isSleepingOverride = $false
$script:sleepBaseTs = 0
$script:lastIgnoredSleepTs = 0
$script:disconnectedReturnState = ''
$script:disconnectedReturnTs = 0
$script:tabTitle = ''
$script:windowTitle = ''
$script:ownerTitleConflictDetail = ''
$script:uiaTypesLoaded = $false
$script:lastSessionMarkerProbeHwnd = 0
$script:lastSessionMarkerProbeTitle = ''
$script:lastSessionMarkerProbeUntilMs = 0
$script:sessionId = ''
$script:sessionChanged = $false
$script:settingsOpen = $false
$script:isRestarting = $false
$script:closeReason = ''
$script:closeDetail = ''

function Rotate-TransitionLog {
    try {
        if (-not (Test-Path -LiteralPath $TRANSITION_LOG)) { return }
        if ((Get-Item -LiteralPath $TRANSITION_LOG).Length -le $TRANSITION_LOG_MAX_BYTES) { return }

        $lines = @(Get-Content -LiteralPath $TRANSITION_LOG -Tail $TRANSITION_LOG_KEEP_LINES -Encoding UTF8 -ErrorAction Stop)
        if ($lines.Count -gt 0) {
            Set-Content -LiteralPath $TRANSITION_LOG -Encoding UTF8 -Value $lines
        } else {
            Clear-Content -LiteralPath $TRANSITION_LOG -ErrorAction SilentlyContinue
        }
    } catch {}
}

function Write-TransitionLog($action, $state, $eventTs, [string]$detail = '') {
    try {
        Rotate-TransitionLog

        $payload = [ordered]@{
            ts = [DateTimeOffset]::Now.ToString('o')
            source = 'pet'
            slot = $Slot
            action = $action
            state = $state
            event_ts = $eventTs
            last_ts = $script:lastTs
            character = $script:character
            sleep_override = $script:isSleepingOverride
            sleep_base_ts = $script:sleepBaseTs
        }
        if (-not [string]::IsNullOrWhiteSpace($detail)) {
            $payload['detail'] = $detail
        }

        Add-Content -LiteralPath $TRANSITION_LOG -Encoding UTF8 -Value ($payload | ConvertTo-Json -Compress -Depth 5) -ErrorAction Stop
    } catch {}
}

function Restart-SleepTimer {
    if ($script:sleepTimer) {
        $script:sleepTimer.Stop()
        $script:sleepTimer.Start()
    }
}

function Ensure-PidFile {
    try {
        $currentPid = ''
        if (Test-Path -LiteralPath $PID_FILE) {
            $currentPid = (Get-Content -LiteralPath $PID_FILE -Raw -Encoding ASCII -ErrorAction SilentlyContinue).Trim()
        }

        if ($currentPid -ne [string]$PID) {
            Set-Content -LiteralPath $PID_FILE -Value $PID -Encoding ASCII
            Write-TransitionLog 'pid-file-restored' $script:lastState $script:lastTs
        }
    } catch {
        Write-TransitionLog 'pid-file-restore-error' $script:lastState $script:lastTs (Get-ErrorDetail $_)
    }
}

function Get-ErrorDetail {
    param($ErrorRecord)
    try {
        if ($ErrorRecord -and $ErrorRecord.Exception -and $ErrorRecord.Exception.Message) {
            return [string]$ErrorRecord.Exception.Message
        }
    } catch {}
    return ''
}

function Get-AnchorDetail {
    param([string]$Detail = '')

    $parts = @(
        "session_pid=$($script:sessionPid)",
        "owner_pid=$($script:ownerPid)",
        "owner_hwnd=$($script:ownerHwnd)",
        "owner_source=$($script:ownerSource)"
    )
    if (-not [string]::IsNullOrWhiteSpace($Detail)) {
        $parts += $Detail
    }
    return ($parts -join ';')
}

function Test-CleanupProcessAlive {
    param(
        [int]$ProcessId,
        [string]$ExpectedName = ''
    )

    if ($ProcessId -le 0) { return $false }
    try {
        $proc = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
        if (-not $proc) { return $false }
        if (-not [string]::IsNullOrWhiteSpace($ExpectedName) -and $proc.ProcessName -ne $ExpectedName) {
            return $false
        }
        return $true
    } catch {}

    return $false
}

function Test-CleanupOwnerHwndAlive {
    try {
        if ($script:ownerHwnd -le 0) { return $false }
        Ensure-WindowFocusType
        return [ClaudeWtPets.WindowFocus]::IsWindow([IntPtr]::new([Int64]$script:ownerHwnd))
    } catch {}

    return $false
}

function Set-PetCloseReason {
    param(
        [string]$Reason,
        [string]$Detail = ''
    )

    if ([string]::IsNullOrWhiteSpace($Reason)) { return }

    $script:closeReason = $Reason
    $script:closeDetail = $Detail

    $parts = @("close_reason=$Reason")
    if (-not [string]::IsNullOrWhiteSpace($Detail)) {
        $parts += $Detail
    }
    Write-TransitionLog 'pet-close-requested' $script:lastState $script:lastTs (Get-AnchorDetail ($parts -join ';'))
}

function Get-PetCleanupDetail {
    param([string]$Detail = '')

    $reason = $script:closeReason
    if ([string]::IsNullOrWhiteSpace($reason)) {
        $reason = 'unknown'
    }

    $stateSessionPid = 0
    try {
        $stateData = Read-JsonCached $STATE_FILE
        if ($stateData -and $stateData.PSObject.Properties['session_pid']) {
            try { $stateSessionPid = [int]$stateData.session_pid } catch {}
        }
    } catch {}

    $sessionPidAlive = Test-CleanupProcessAlive $script:sessionPid 'claude'
    $stateSessionPidAlive = Test-CleanupProcessAlive $stateSessionPid 'claude'
    $ownerPidAlive = Test-CleanupProcessAlive $script:ownerPid 'WindowsTerminal'
    $ownerHwndAlive = Test-CleanupOwnerHwndAlive

    $parts = @(
        "close_reason=$reason",
        "is_restarting=$($script:isRestarting)",
        "session_changed=$($script:sessionChanged)",
        "state_session_pid=$stateSessionPid",
        "session_pid_alive=$sessionPidAlive",
        "state_session_pid_alive=$stateSessionPidAlive",
        "owner_pid_alive=$ownerPidAlive",
        "owner_hwnd_alive=$ownerHwndAlive",
        "state_file_exists=$(Test-Path -LiteralPath $STATE_FILE)",
        "pid_file_exists=$(Test-Path -LiteralPath $PID_FILE)"
    )

    if (-not [string]::IsNullOrWhiteSpace($script:closeDetail)) {
        $parts += $script:closeDetail
    }
    if (-not [string]::IsNullOrWhiteSpace($Detail)) {
        $parts += $Detail
    }

    return Get-AnchorDetail ($parts -join ';')
}

function Remove-PetRuntimeFile {
    param(
        [string]$Kind,
        [string]$Path,
        [bool]$ShouldRemove,
        [string]$SkipReason = ''
    )

    $existsBefore = Test-Path -LiteralPath $Path
    if (-not $ShouldRemove) {
        Write-TransitionLog "pet-cleanup-keep-$Kind" $script:lastState $script:lastTs (Get-PetCleanupDetail "${Kind}_exists=$existsBefore;skip_reason=$SkipReason")
        return
    }

    if (-not $existsBefore) {
        Write-TransitionLog "pet-cleanup-missing-$Kind" $script:lastState $script:lastTs (Get-PetCleanupDetail "${Kind}_exists=false")
        return
    }

    try {
        Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
        $existsAfter = Test-Path -LiteralPath $Path
        Write-TransitionLog "pet-cleanup-remove-$Kind" $script:lastState $script:lastTs (Get-PetCleanupDetail "${Kind}_exists_before=$existsBefore;${Kind}_exists_after=$existsAfter")
    } catch {
        Write-TransitionLog "pet-cleanup-remove-$Kind-error" $script:lastState $script:lastTs (Get-PetCleanupDetail "${Kind}_exists_before=$existsBefore;error=$(Get-ErrorDetail $_)")
    }
}

function Test-SessionAliveForCleanup {
    if (Test-SessionProcessAlive $script:sessionPid) { return $true }

    try {
        $data = Read-JsonCached $STATE_FILE
        if (-not $data) { return $false }
        if ($data.session_pid -gt 0 -and (Test-SessionProcessAlive ([int]$data.session_pid))) {
            $script:sessionPid = [int]$data.session_pid
            return $true
        }
    } catch {}

    return $false
}

function Get-LiveSessionCloseStateSkipReason {
    $reason = $script:closeReason
    if ([string]::IsNullOrWhiteSpace($reason)) {
        $reason = 'unknown'
    }

    if (@('manual-menu-exit', 'unknown') -notcontains $reason) {
        return ''
    }
    if (-not (Test-SessionAliveForCleanup)) {
        return ''
    }

    if ($reason -eq 'manual-menu-exit') {
        return 'live-session-manual-menu-exit'
    }
    return 'live-session-unknown-close'
}

function Resolve-CharacterName($name) {
    Resolve-WtPetsCharacterName -Name $name -Fallback $script:character -Slot $Slot
}

function Get-CharacterFromCurrentState {
    try {
        $data = Read-JsonCached $STATE_FILE
        if (-not $data) { return '' }
        if ($data.character) {
            $candidate = Resolve-CharacterName ([string]$data.character)
            if (Test-WtPetsCharacterName $candidate) {
                return $candidate
            }
        }
    } catch {}

    return ''
}

function Ensure-FileOpsType {
    $typeName = 'ClaudeWtPets.FileOps'
    if (([System.Management.Automation.PSTypeName]$typeName).Type) { return }

    Add-Type @"
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace ClaudeWtPets {
    public static class FileOps {
        private const int MOVEFILE_REPLACE_EXISTING = 0x1;
        private const int MOVEFILE_WRITE_THROUGH = 0x8;

        [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
        private static extern bool MoveFileEx(string existingFileName, string newFileName, int flags);

        public static void ReplaceFile(string source, string destination) {
            if (!MoveFileEx(source, destination, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
        }
    }
}
"@
}

function Write-JsonFileAtomic([string]$Path, [string]$Json) {
    $suffix = "$PID.$([System.Guid]::NewGuid().ToString('N'))"
    $tmp = "$Path.$suffix.tmp"
    $encoding = New-Object System.Text.UTF8Encoding -ArgumentList $false

    try {
        Ensure-FileOpsType
        [System.IO.File]::WriteAllText($tmp, $Json, $encoding)
        [ClaudeWtPets.FileOps]::ReplaceFile($tmp, $Path)
    } finally {
        try { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } catch {}
    }
}

function Write-StateFileAtomic([string]$Json) {
    Write-JsonFileAtomic $STATE_FILE $Json
}

function Save-CurrentState($state, $character, [hashtable]$Extra = @{}) {
    try {
        $payload = [pscustomobject]@{
            state = $state
            message = ''
            ts = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            session_id = ''
            slot = $Slot
            character = $character
            owner_pid = $null
            owner_name = ''
        }

        $current = Read-JsonCached $STATE_FILE
        if ($current) {
            if ($current.PSObject.Properties['message']) { $payload.message = $current.message }
            if ($current.PSObject.Properties['session_id']) { $payload.session_id = $current.session_id }
            if ($current.PSObject.Properties['owner_pid']) { $payload.owner_pid = $current.owner_pid }
            if ($current.PSObject.Properties['owner_name']) { $payload.owner_name = $current.owner_name }
            if ($current.PSObject.Properties['owner_hwnd']) { $payload | Add-Member -NotePropertyName owner_hwnd -NotePropertyValue $current.owner_hwnd }
            if ($current.PSObject.Properties['owner_source']) { $payload | Add-Member -NotePropertyName owner_source -NotePropertyValue $current.owner_source }
            if ($current.PSObject.Properties['window_title']) {
                $candidateWindowTitle = [string]$current.window_title
                if (Test-OwnerWindowTitlePersistable $candidateWindowTitle) {
                    $payload | Add-Member -NotePropertyName window_title -NotePropertyValue $candidateWindowTitle
                }
            }
            if ($current.PSObject.Properties['session_pid']) { $payload | Add-Member -NotePropertyName session_pid -NotePropertyValue $current.session_pid }
            if ($current.PSObject.Properties['session_name']) { $payload | Add-Member -NotePropertyName session_name -NotePropertyValue $current.session_name }
            if ($current.PSObject.Properties['tab_title']) {
                $candidateTabTitle = [string]$current.tab_title
                if (Test-OwnerWindowTitlePersistable $candidateTabTitle) {
                    $payload | Add-Member -NotePropertyName tab_title -NotePropertyValue $candidateTabTitle
                }
            }
        }

        foreach ($key in $Extra.Keys) {
            Set-ObjectProperty $payload $key $Extra[$key]
        }

        $json = $payload | ConvertTo-Json -Depth 10 -Compress
        Write-StateFileAtomic $json
        return [Int64]$payload.ts
    } catch {}

    return $null
}

function Set-ObjectProperty($Object, [string]$Name, $Value) {
    if ($Object.PSObject.Properties[$Name]) {
        $Object.PSObject.Properties[$Name].Value = $Value
    } else {
        $Object | Add-Member -MemberType NoteProperty -Name $Name -Value $Value
    }
}

function Get-CurrentOwnerWindowTitle {
    try {
        if ($script:ownerHwnd -le 0) { return '' }
        Ensure-WindowFocusType
        return [ClaudeWtPets.WindowFocus]::GetWindowTitle([Int64]$script:ownerHwnd)
    } catch {}

    return ''
}

function Strip-TitleSpinner([string]$Title) {
    return ($Title -replace '^[⠀-⣿✳-✷○-●■-□•·⦿]+\s*', '')
}

function Test-WindowTitleCompatible([string]$CurrentTitle, [string]$StoredTitle) {
    $current = Strip-TitleSpinner(([string]$CurrentTitle).Trim())
    $stored = Strip-TitleSpinner(([string]$StoredTitle).Trim())
    if ([string]::IsNullOrWhiteSpace($current) -or [string]::IsNullOrWhiteSpace($stored)) { return $true }

    $left = $current.ToLowerInvariant()
    $right = $stored.ToLowerInvariant()
    return ($left -eq $right) -or $left.Contains($right) -or $right.Contains($left)
}

function Test-InternalProbeTitle([string]$Title) {
    $titleText = ([string]$Title).Trim()
    return -not [string]::IsNullOrWhiteSpace($titleText) -and $titleText.StartsWith('__claude_wt_pets_')
}

function Get-ExplicitSlotFromWindowTitle([string]$Title) {
    $titleText = Strip-TitleSpinner(([string]$Title).Trim())
    if ($titleText -match '^Claude #([1-4])(\b|$)') {
        try { return [Int32]$Matches[1] } catch {}
    }
    return 0
}

function Test-OtherSlotWindowTitle([string]$Title) {
    $titleSlot = Get-ExplicitSlotFromWindowTitle $Title
    return $titleSlot -gt 0 -and $titleSlot -ne $Slot
}

function Test-OwnerWindowTitlePersistable([string]$Title) {
    if ([string]::IsNullOrWhiteSpace([string]$Title)) { return $false }
    if (Test-InternalProbeTitle $Title) { return $false }
    if (Test-OtherSlotWindowTitle $Title) { return $false }
    return $true
}

function Set-OwnerTitleConflict([Int64]$Hwnd, [string]$CurrentTitle, [string]$Reason) {
    $detail = "reason=$Reason;hwnd=$Hwnd;title=$CurrentTitle;source=$($script:ownerSource)"
    $titleSlot = Get-ExplicitSlotFromWindowTitle $CurrentTitle
    if ($titleSlot -gt 0) { $detail += ";title_slot=$titleSlot" }
    $script:ownerTitleConflictDetail = "owner-title-conflict=$Reason;hwnd=$Hwnd;title=$CurrentTitle"
    if ($Hwnd -gt 0) { $script:staleOwnerHwnd = $Hwnd }
    $script:ownerHwnd = 0
    $script:ownerSource = 'shared-unresolved'
    Write-TransitionLog 'owner-window-title-conflict' $script:lastState $script:lastTs (Get-AnchorDetail $detail)
}

function Test-RecentSessionMarkerProbeTitle([Int64]$Hwnd, [string]$CurrentTitle) {
    if ($Hwnd -le 0 -or $Hwnd -ne $script:lastSessionMarkerProbeHwnd) { return $false }
    if (-not (Test-InternalProbeTitle $CurrentTitle)) { return $false }
    if ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() -gt $script:lastSessionMarkerProbeUntilMs) { return $false }
    return $true
}

function Get-SafeConsoleRestoreTitle([string]$RestoreTitle) {
    if (-not (Test-InternalProbeTitle $RestoreTitle)) { return $RestoreTitle }

    foreach ($candidate in @($script:tabTitle, $script:windowTitle, "Claude #$Slot", 'Claude Code')) {
        if (Test-OwnerWindowTitlePersistable $candidate) {
            return [string]$candidate
        }
    }

    return "Claude #$Slot"
}

function Test-OwnerMapWindowTitleCompatible($Record, [string]$CurrentTitle) {
    if ([string]::IsNullOrWhiteSpace($CurrentTitle)) { return $true }
    if (Test-InternalProbeTitle $CurrentTitle) { return $false }

    $storedTitles = @()
    if ($Record -and $Record.PSObject.Properties['window_title'] -and -not [string]::IsNullOrWhiteSpace([string]$Record.window_title)) {
        $storedTitles += [string]$Record.window_title
    }
    if ($Record -and $Record.PSObject.Properties['tab_title'] -and -not [string]::IsNullOrWhiteSpace([string]$Record.tab_title)) {
        $storedTitles += [string]$Record.tab_title
    }
    if ($storedTitles.Count -eq 0) { return $true }

    foreach ($stored in $storedTitles) {
        if (Test-WindowTitleCompatible $CurrentTitle $stored) { return $true }
    }

    return $false
}

function Test-CurrentOwnerWindowTitleOrMarkConflict([Int64]$Hwnd) {
    if ($Hwnd -le 0) { return $true }

    try {
        Ensure-WindowFocusType
        $currentTitle = [ClaudeWtPets.WindowFocus]::GetWindowTitle($Hwnd)
        if ([string]::IsNullOrWhiteSpace($currentTitle)) { return $true }

        if (Test-InternalProbeTitle $currentTitle) {
            if (Test-RecentSessionMarkerProbeTitle $Hwnd $currentTitle) {
                Write-TransitionLog 'owner-window-title-probe-marker-grace' $script:lastState $script:lastTs (Get-AnchorDetail "hwnd=$Hwnd;title=$currentTitle;source=$($script:ownerSource)")
                return $true
            }
            Set-OwnerTitleConflict $Hwnd $currentTitle 'probe-marker'
            return $false
        }

        $isMerged = Test-TerminalWindowsMerged
        if ((Test-OtherSlotWindowTitle $currentTitle) -and -not ((Test-SharedOwnerSource $script:ownerSource) -and $isMerged)) {
            Set-OwnerTitleConflict $Hwnd $currentTitle 'other-slot-title'
            return $false
        }

        if (Test-SharedOwnerSource $script:ownerSource) {
            if (Test-OwnerWindowTitlePersistable $currentTitle) {
                $script:windowTitle = $currentTitle
            }
            return $true
        }

        $record = [pscustomobject]@{}
        if (-not [string]::IsNullOrWhiteSpace($script:windowTitle)) {
            $record | Add-Member -NotePropertyName window_title -NotePropertyValue $script:windowTitle
        }
        if (-not [string]::IsNullOrWhiteSpace($script:tabTitle)) {
            $record | Add-Member -NotePropertyName tab_title -NotePropertyValue $script:tabTitle
        }
        if (Test-OwnerMapWindowTitleCompatible $record $currentTitle) { return $true }

        $previousTitle = $script:windowTitle
        $script:windowTitle = $currentTitle
        Write-TransitionLog 'owner-window-title-updated' $script:lastState $script:lastTs (Get-AnchorDetail "hwnd=$Hwnd;new_title=$currentTitle;previous_title=$previousTitle")
        Sync-OwnerMapFromCurrentOwner $script:ownerSource
        return $true
    } catch {}

    return $true
}

function Sync-OwnerMapFromCurrentOwner([string]$ownerSource, $StateData = $null) {
    try {
        if ($script:ownerHwnd -le 0) { return }
        if (-not (Test-OwnerSourcePersistable $ownerSource)) { return }

        if ($null -eq $StateData) {
            $StateData = Read-JsonCached $STATE_FILE
        }

        $sessionId = ''
        if ($StateData -and $StateData.PSObject.Properties['session_id']) {
            $sessionId = [string]$StateData.session_id
        }
        if ([string]::IsNullOrWhiteSpace($sessionId)) { return }

        $ownerMap = $null
        try {
            $ownerMap = Read-JsonCached $OWNER_MAP_FILE
        } catch {}
        if (-not $ownerMap) {
            if ([System.IO.File]::Exists($OWNER_MAP_FILE)) {
                Write-TransitionLog 'owner-map-sync-skip-parse-failed' $script:lastState $script:lastTs (Get-AnchorDetail "source=$ownerSource")
                return
            }
            $ownerMap = [pscustomobject]@{
                version = 1
                sessions = [pscustomobject]@{}
                slots = [pscustomobject]@{}
            }
        }

        if (-not $ownerMap.PSObject.Properties['version']) {
            Set-ObjectProperty $ownerMap 'version' 1
        }
        if (-not $ownerMap.PSObject.Properties['sessions'] -or $null -eq $ownerMap.sessions) {
            Set-ObjectProperty $ownerMap 'sessions' ([pscustomobject]@{})
        }
        if (-not $ownerMap.PSObject.Properties['slots'] -or $null -eq $ownerMap.slots) {
            Set-ObjectProperty $ownerMap 'slots' ([pscustomobject]@{})
        }

        $sessionPid = $null
        $sessionName = ''
        if ($StateData -and $StateData.PSObject.Properties['session_pid']) {
            try {
                $candidateSessionPid = [Int64]$StateData.session_pid
                if ($candidateSessionPid -gt 0) { $sessionPid = $candidateSessionPid }
            } catch {}
        }
        if ($StateData -and $StateData.PSObject.Properties['session_name']) {
            $sessionName = [string]$StateData.session_name
        }

        $tabTitle = $script:tabTitle
        if ($StateData -and $StateData.PSObject.Properties['tab_title'] -and -not [string]::IsNullOrWhiteSpace([string]$StateData.tab_title)) {
            $tabTitle = [string]$StateData.tab_title
        }

        $windowTitle = Get-CurrentOwnerWindowTitle
        if (-not [string]::IsNullOrWhiteSpace($windowTitle) -and -not (Test-OwnerWindowTitlePersistable $windowTitle)) {
            Write-TransitionLog 'owner-map-sync-skip-unpersistable-title' $script:lastState $script:lastTs (Get-AnchorDetail "source=$ownerSource;title=$windowTitle")
            $windowTitle = ''
        }
        if ([string]::IsNullOrWhiteSpace($windowTitle) -and $StateData -and $StateData.PSObject.Properties['window_title']) {
            $candidateStateTitle = [string]$StateData.window_title
            if (Test-OwnerWindowTitlePersistable $candidateStateTitle) {
                $windowTitle = $candidateStateTitle
            }
        }
        if ([string]::IsNullOrWhiteSpace($windowTitle) -and (Test-OwnerWindowTitlePersistable $script:windowTitle)) {
            $windowTitle = $script:windowTitle
        }
        if (-not [string]::IsNullOrWhiteSpace($windowTitle)) {
            $script:windowTitle = $windowTitle
        }

        $ownerPid = $null
        if ($script:ownerPid -gt 0) { $ownerPid = [Int64]$script:ownerPid }

        $record = [pscustomobject]@{
            session_id = $sessionId
            slot = $Slot
            character = $script:character
            pet_name = $script:character
            owner_pid = $ownerPid
            owner_name = 'WindowsTerminal'
            owner_hwnd = [Int64]$script:ownerHwnd
            owner_source = $ownerSource
            window_title = $windowTitle
            tab_title = $tabTitle
            session_pid = $sessionPid
            session_name = $sessionName
            ts = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        }

        Set-ObjectProperty $ownerMap.sessions $sessionId $record
        Set-ObjectProperty $ownerMap.slots ([string]$Slot) $record
        Set-ObjectProperty $ownerMap 'updated_at' ([DateTimeOffset]::UtcNow.ToString('o'))

        $json = $ownerMap | ConvertTo-Json -Depth 10 -Compress
        Write-JsonFileAtomic $OWNER_MAP_FILE $json
        Write-TransitionLog 'owner-map-updated' $script:lastState $script:lastTs (Get-AnchorDetail "source=$ownerSource")
    } catch {
        Write-TransitionLog 'owner-map-update-error' $script:lastState $script:lastTs (Get-ErrorDetail $_)
    }
}

function Save-RecoveredOwnerState([string]$ownerSource) {
    try {
        $extra = @{
            owner_pid = $script:ownerPid
            owner_name = 'WindowsTerminal'
            owner_hwnd = $script:ownerHwnd
            owner_source = $ownerSource
        }
        $windowTitle = Get-CurrentOwnerWindowTitle
        if (-not [string]::IsNullOrWhiteSpace($windowTitle) -and -not (Test-OwnerWindowTitlePersistable $windowTitle)) {
            Write-TransitionLog 'owner-state-save-skip-unpersistable-title' $script:lastState $script:lastTs (Get-AnchorDetail "source=$ownerSource;title=$windowTitle")
            $windowTitle = ''
        }
        if ([string]::IsNullOrWhiteSpace($windowTitle) -and (Test-OwnerWindowTitlePersistable $script:windowTitle)) {
            $windowTitle = $script:windowTitle
        }
        if (-not [string]::IsNullOrWhiteSpace($windowTitle)) {
            $script:windowTitle = $windowTitle
            $extra['window_title'] = $windowTitle
        }
        if (-not [string]::IsNullOrWhiteSpace($script:tabTitle)) {
            $extra['tab_title'] = $script:tabTitle
        }

        $current = Read-JsonCached $STATE_FILE
        if ($current) {
            foreach ($name in @('previous_state', 'previous_ts')) {
                if ($current.PSObject.Properties[$name]) {
                    $extra[$name] = $current.$name
                }
            }
        }

        $savedTs = Save-CurrentState $script:lastState $script:character $extra
        if ($null -ne $savedTs) {
            $script:lastTs = [Int64]$savedTs
        }
        $script:ownerSource = $ownerSource
        Sync-OwnerMapFromCurrentOwner $ownerSource $current
    } catch {
        Write-TransitionLog 'owner-state-save-error' $script:lastState $script:lastTs (Get-ErrorDetail $_)
    }
}

function Get-InitialPosition($slot, $placement = $null) {
    if ($null -eq $placement) {
        $placement = Get-WtPetsPlacementConfig -DefaultSlotGap $GAP
    }
    $size = $script:petSize
    $workArea = [System.Windows.SystemParameters]::WorkArea
    $step = $size + $placement.slotGap

    if ($placement.anchor.EndsWith('right')) {
        $left = $workArea.Right - $placement.offsetX - $size
    } else {
        $left = $workArea.Left + $placement.offsetX
    }

    if ($placement.direction -eq 'left') {
        $left = $left - (($MAX_SLOTS - $slot) * $step)
    } else {
        $left = $left + (($slot - 1) * $step)
    }

    if ($placement.anchor.StartsWith('bottom')) {
        $top = $workArea.Bottom - $placement.offsetY - $size
    } else {
        $top = $workArea.Top + $placement.offsetY
    }

    return [pscustomobject]@{
        Left = $left
        Top = $top
    }
}

function Get-LayoutSignature($size, $placement) {
    return '{0}|{1}|{2}|{3}|{4}|{5}' -f $size, $placement.anchor, $placement.direction, $placement.offsetX, $placement.offsetY, $placement.slotGap
}

# config.json(없으면 config.default.json)의 크기/배치 값이 바뀌면 재시작 없이 크기와 기본 위치를 다시 적용한다.
# 파싱 실패(다른 process가 쓰는 중) 시에는 기본값으로 떨어지지 않고 다음 tick에 재시도한다.
# 캐릭터 변경처럼 크기/배치와 무관한 config 저장은 signature가 같으므로 무시한다.
function Sync-LayoutFromConfig([switch]$Force) {
    try {
        $cfg = Read-JsonCached (Get-WtPetsConfigReadPath)
        if ($null -eq $cfg) { return }

        $newSize = ConvertTo-WtPetsPetSize $cfg
        $newPlacement = ConvertTo-WtPetsPlacement $cfg -DefaultSlotGap $GAP
        $signature = Get-LayoutSignature $newSize $newPlacement
        if (-not $Force -and $signature -eq $script:layoutSignature) { return }

        $previousSignature = $script:layoutSignature
        $script:layoutSignature = $signature
        $script:petSize = $newSize
        $window.Width = $newSize
        $window.Height = $newSize
        $image.Width = $newSize
        $image.Height = $newSize
        $position = Get-InitialPosition $Slot $newPlacement
        $window.Left = $position.Left
        $window.Top = $position.Top
        Write-TransitionLog 'layout-applied' $script:lastState $script:lastTs "previous=$previousSignature;new=$signature"
    } catch {
        Write-TransitionLog 'layout-sync-error' $script:lastState $script:lastTs (Get-ErrorDetail $_)
    }
}

function Refresh-OwnerFromState {
    try {
        $data = Read-JsonCached $STATE_FILE
        if (-not $data) { return }
        $stateTs = 0
        if ($data.PSObject.Properties['ts']) {
            try { $stateTs = [Int64]$data.ts } catch {}
        }
        if ($stateTs -gt 0) {
            $script:latestStateTs = $stateTs
        }
        $isFreshState = $stateTs -gt $script:lastTs

        if ($data.owner_pid) {
            $candidateOwnerPid = [Int32]$data.owner_pid
            if ($candidateOwnerPid -gt 0 -and ($candidateOwnerPid -ne $script:staleOwnerPid -or $isFreshState)) {
                $script:ownerPid = $candidateOwnerPid
                $script:staleOwnerPid = 0
            }
        }
        if ($data.owner_hwnd) {
            $candidateOwnerHwnd = [Int64]$data.owner_hwnd
            if ($candidateOwnerHwnd -gt 0 -and ($candidateOwnerHwnd -ne $script:staleOwnerHwnd -or $isFreshState)) {
                $script:ownerHwnd = $candidateOwnerHwnd
                $script:staleOwnerHwnd = 0
            }
        }
        if ($data.PSObject.Properties['owner_source']) {
            $script:ownerSource = [string]$data.owner_source
        }
        if ($data.PSObject.Properties['tab_title'] -and $data.tab_title) {
            $script:tabTitle = [string]$data.tab_title
        }
        if ($data.PSObject.Properties['window_title'] -and $data.window_title) {
            $candidateWindowTitle = [string]$data.window_title
            if (Test-OwnerWindowTitlePersistable $candidateWindowTitle) {
                $script:windowTitle = $candidateWindowTitle
            }
        }
        if ($data.PSObject.Properties['session_id'] -and -not [string]::IsNullOrWhiteSpace([string]$data.session_id)) {
            $script:sessionId = [string]$data.session_id
        }
        if ($data.session_pid) {
            $candidateSessionPid = [Int32]$data.session_pid
            if ($candidateSessionPid -gt 0 -and ($candidateSessionPid -ne $script:staleSessionPid -or $isFreshState)) {
                $sessionPidChanged = $candidateSessionPid -ne $script:sessionPid
                $script:sessionPid = $candidateSessionPid
                $script:staleSessionPid = 0
                if (
                    $sessionPidChanged -or
                    (Test-SessionProcessAlive $candidateSessionPid) -or
                    ($isFreshState -and $script:sessionGoneStateTs -gt 0 -and $stateTs -ne $script:sessionGoneStateTs)
                ) {
                    $script:sessionGoneSince = 0
                    $script:sessionGoneStateTs = 0
                }
            }
        }
    } catch {
        Write-TransitionLog 'refresh-owner-error' $script:lastState $script:lastTs (Get-ErrorDetail $_)
    }
}

function Get-UsedOwnerHwndsFromStates {
    $used = @{}

    for ($candidateSlot = 1; $candidateSlot -le $MAX_SLOTS; $candidateSlot++) {
        if ($candidateSlot -eq $Slot) { continue }

        $candidateState = [System.IO.Path]::Combine($env:TEMP, "claude-wt-pets-state-$candidateSlot.json")
        try {
            $data = Read-JsonCached $candidateState
            if (-not $data) { continue }
            $ownerHwnd = 0
            try { $ownerHwnd = [Int64]$data.owner_hwnd } catch {}
            if ($ownerHwnd -gt 0) {
                $used[[string]$ownerHwnd] = $true
            }
        } catch {}
    }

    return $used
}

function Test-HwndClaimedByUntrustedSource([Int64]$hwnd) {
    $found = $false
    for ($s = 1; $s -le $MAX_SLOTS; $s++) {
        if ($s -eq $Slot) { continue }
        $path = [System.IO.Path]::Combine($env:TEMP, "claude-wt-pets-state-$s.json")
        try {
            $data = Read-JsonCached $path
            if (-not $data) { continue }
            $h = 0
            try { $h = [Int64]$data.owner_hwnd } catch {}
            if ($h -eq $hwnd) {
                $src = ''
                if ($data.PSObject.Properties['owner_source']) { $src = [string]$data.owner_source }
                if (-not (Test-UntrustedOwnerSource $src)) { return $false }
                $found = $true
            }
        } catch {}
    }
    return $found
}

function Test-OwnerWindowAlive {
    try {
        if ($script:ownerHwnd -gt 0) {
            Ensure-WindowFocusType
            $hwnd = [IntPtr]::new([Int64]$script:ownerHwnd)
            if ([ClaudeWtPets.WindowFocus]::IsWindow($hwnd)) { return $true }
        }
    } catch {}

    return $false
}

function Test-UntrustedOwnerSource([string]$Source) {
    return @('foreground', 'foreground-shared', 'foreground-window', 'foreground-window-shared', 'process-recovery', 'process-recovery-shared', 'session-marker-shared', 'tab-strip-shared', 'last-known-good-shared', 'screen-order', 'screen-order-focus', 'screen-order-fallback', 'shared-unresolved', 'unresolved') -contains $Source
}

function Test-OwnerSourcePersistable([string]$Source) {
    return @('session-marker', 'session-marker-shared', 'tab-strip', 'tab-strip-shared', 'title-match', 'tab-title', 'last-known-good', 'last-known-good-shared') -contains $Source
}

function Test-OwnerSourceRequiresFocusRecheck([string]$Source) {
    return @('foreground', 'foreground-shared', 'foreground-window', 'foreground-window-shared', 'session-marker-shared', 'tab-strip-shared', 'process-recovery-shared', 'last-known-good-shared', 'screen-order', 'screen-order-focus', 'screen-order-fallback', 'shared-unresolved', 'unresolved') -contains $Source
}

function Test-SharedOwnerSource([string]$Source) {
    return @('foreground-shared', 'session-marker-shared', 'tab-strip-shared', 'process-recovery-shared', 'last-known-good-shared') -contains $Source
}

function Get-ActiveSlotCount {
    $activeSlots = 0
    for ($s = 1; $s -le $MAX_SLOTS; $s++) {
        $path = [System.IO.Path]::Combine($env:TEMP, "claude-wt-pets-state-$s.json")
        if (-not (Test-Path -LiteralPath $path)) { continue }
        try {
            $data = Read-JsonCached $path
            if ($data -and $data.PSObject.Properties['session_pid']) {
                $pid = 0
                try { $pid = [Int32]$data.session_pid } catch {}
                if ($pid -gt 0) {
                    $proc = $null
                    try { $proc = [System.Diagnostics.Process]::GetProcessById($pid) } catch {}
                    if (-not $proc) { continue }
                }
            }
        } catch {}
        $activeSlots++
    }
    return $activeSlots
}

function Get-TerminalMergeInfo {
    try {
        Ensure-WindowFocusType
        $visibleWindows = @([ClaudeWtPets.WindowFocus]::FindVisibleTerminalWindows())
        $activeSlots = Get-ActiveSlotCount
        return [pscustomobject]@{
            VisibleCount = $visibleWindows.Count
            ActiveSlots = $activeSlots
            IsMerged = ($visibleWindows.Count -gt 0 -and $activeSlots -gt 0 -and $visibleWindows.Count -lt $activeSlots)
        }
    } catch {
        return [pscustomobject]@{
            VisibleCount = 0
            ActiveSlots = 0
            IsMerged = $false
        }
    }
}

function Test-CurrentOwnerSharedByOtherSlot {
    if ($script:ownerHwnd -le 0) { return $false }

    for ($s = 1; $s -le $MAX_SLOTS; $s++) {
        if ($s -eq $Slot) { continue }
        $path = [System.IO.Path]::Combine($env:TEMP, "claude-wt-pets-state-$s.json")
        try {
            $data = Read-JsonCached $path
            if (-not $data) { continue }

            $otherHwnd = 0
            try { $otherHwnd = [Int64]$data.owner_hwnd } catch {}
            if ($otherHwnd -ne $script:ownerHwnd) { continue }

            $otherPid = 0
            try { $otherPid = [Int32]$data.session_pid } catch {}
            if ($otherPid -gt 0 -and -not (Test-SessionProcessAlive $otherPid)) { continue }

            return $true
        } catch {}
    }

    return $false
}

function Test-TerminalWindowsMerged {
    $mergeInfo = Get-TerminalMergeInfo
    return [bool]$mergeInfo.IsMerged
}

function Test-SharedOwnerStillPlausible {
    if (-not (Test-SharedOwnerSource $script:ownerSource)) { return $true }

    $isAlive = $false
    try {
        Ensure-WindowFocusType
        $hwnd = [IntPtr]::new([Int64]$script:ownerHwnd)
        $isAlive = [ClaudeWtPets.WindowFocus]::IsWindow($hwnd)
    } catch {}
    if (-not $isAlive) { return $false }

    if (Test-CurrentOwnerSharedByOtherSlot) { return $true }

    $mergeInfo = Get-TerminalMergeInfo
    return [bool]$mergeInfo.IsMerged
}

function Get-OtherSlotTabTitles {
    $titles = @{}
    for ($s = 1; $s -le $MAX_SLOTS; $s++) {
        if ($s -eq $Slot) { continue }
        $sf = [System.IO.Path]::Combine($env:TEMP, "claude-wt-pets-state-$s.json")
        try {
            $d = Read-JsonCached $sf
            if ($d -and $d.tab_title) { $titles[[string]$s] = [string]$d.tab_title }
        } catch {}
    }
    return $titles
}

function Find-UnusedWindowByTitle {
    param([string]$MatchTitle, $VisibleWindows, $UsedHwnds, $ExcludeTitles)

    $candidates = @()
    foreach ($w in $VisibleWindows) {
        $wHwnd = [Int64]$w.Hwnd
        if ($wHwnd -le 0 -or $UsedHwnds.ContainsKey([string]$wHwnd)) { continue }

        $windowTitle = [ClaudeWtPets.WindowFocus]::GetWindowTitle($wHwnd)
        if ([string]::IsNullOrWhiteSpace($windowTitle)) { continue }

        $isMatch = ($windowTitle -eq $MatchTitle) -or
                   ($windowTitle.Contains($MatchTitle)) -or
                   ($MatchTitle.Contains($windowTitle))
        if (-not $isMatch) { continue }

        $claimedByOther = $false
        if ($ExcludeTitles) {
            foreach ($entry in $ExcludeTitles.GetEnumerator()) {
                $et = $entry.Value
                if ($et -eq $MatchTitle) { continue }
                if (($windowTitle -eq $et) -or $windowTitle.Contains($et) -or $et.Contains($windowTitle)) {
                    $claimedByOther = $true
                    break
                }
            }
        }
        if ($claimedByOther) { continue }

        $candidates += $w
    }
    return $candidates
}

function Test-SessionPidClaimedByOtherSlot {
    if ($script:sessionPid -le 0) { return $false }
    for ($s = 1; $s -le $MAX_SLOTS; $s++) {
        if ($s -eq $Slot) { continue }
        $sf = [System.IO.Path]::Combine($env:TEMP, "claude-wt-pets-state-$s.json")
        try {
            $d = Read-JsonCached $sf
            if ($d -and -not [string]::IsNullOrWhiteSpace([string]$d.session_id) -and [Int32]$d.session_pid -eq $script:sessionPid) {
                return $true
            }
        } catch {}
    }
    return $false
}

function Resolve-OwnerHwndFromSessionMarker {
    param([switch]$LogMiss)

    try {
        if ([string]::IsNullOrWhiteSpace($script:sessionId)) {
            if ($LogMiss) {
                Write-TransitionLog 'owner-window-session-marker-skip-no-session-id' $script:lastState $script:lastTs (Get-AnchorDetail)
            }
            return $false
        }
        if (Test-SessionPidClaimedByOtherSlot) {
            if ($LogMiss) {
                Write-TransitionLog 'owner-window-session-marker-skip-pid-claimed' $script:lastState $script:lastTs (Get-AnchorDetail "session_pid=$($script:sessionPid)")
            }
            return $false
        }

        $parentPid = 0
        if ($script:sessionPid -gt 0) {
            try {
                Ensure-ProcessParentType
                $parentPid = [ClaudeWtPets.ProcessParent]::GetParentProcessId($script:sessionPid)
            } catch {}
        }
        if ($parentPid -le 0) { return $false }

        Ensure-WindowFocusType
        $visibleWindows = @([ClaudeWtPets.WindowFocus]::FindVisibleTerminalWindows())
        if ($visibleWindows.Count -eq 0) { return $false }

        $marker = "__claude_wt_pets_" + [Guid]::NewGuid().ToString('N').Substring(0, 8)
        $restoreTitle = ''
        $matched = $false
        $matchedSource = 'session-marker'
        $lastAttempt = -1
        $lastVisibleCount = $visibleWindows.Count
        $lastActiveSlots = Get-ActiveSlotCount
        $lastUsedCount = 0
        $lastMerged = ($lastVisibleCount -gt 0 -and $lastActiveSlots -gt 0 -and $lastVisibleCount -lt $lastActiveSlots)
        $lastUsedMatch = 0

        try {
            [void][ClaudeWtPets.WindowFocus]::FreeConsole()
            if (-not [ClaudeWtPets.WindowFocus]::AttachConsole([uint32]$parentPid)) {
                if ($LogMiss) {
                    Write-TransitionLog 'owner-window-session-marker-attach-failed' $script:lastState $script:lastTs (Get-AnchorDetail "parent_pid=$parentPid")
                }
                return $false
            }
            $restoreTitle = [ClaudeWtPets.WindowFocus]::ReadConsoleTitle()
            [void][ClaudeWtPets.WindowFocus]::SetConsoleTitle($marker)

            $retryDelays = @(20, 40, 80, 120, 180, 250, 350, 500)
            for ($attempt = 0; $attempt -lt $retryDelays.Count -and -not $matched; $attempt++) {
                $lastAttempt = $attempt + 1
                [System.Threading.Thread]::Sleep($retryDelays[$attempt])

                $scanWindows = @([ClaudeWtPets.WindowFocus]::FindVisibleTerminalWindows())
                $usedHwnds = Get-UsedOwnerHwndsFromStates
                $lastVisibleCount = $scanWindows.Count
                $lastActiveSlots = Get-ActiveSlotCount
                $lastUsedCount = $usedHwnds.Count
                $lastMerged = ($lastVisibleCount -gt 0 -and $lastActiveSlots -gt 0 -and $lastVisibleCount -lt $lastActiveSlots)
                if ($scanWindows.Count -eq 0) { continue }
                foreach ($w in $scanWindows) {
                    $wHwnd = [Int64]$w.Hwnd
                    if ($wHwnd -le 0) { continue }
                    $title = [ClaudeWtPets.WindowFocus]::GetWindowTitle($wHwnd)
                    if ($title -and $title.Contains($marker)) {
                        $isUsed = $usedHwnds.ContainsKey([string]$wHwnd)
                        $allowSharedMatch = $isUsed -and $lastMerged
                        if ($isUsed -and -not $allowSharedMatch) {
                            $claimerUntrusted = Test-HwndClaimedByUntrustedSource $wHwnd
                            if (-not $claimerUntrusted) {
                                $lastUsedMatch = $wHwnd
                                continue
                            }
                        }

                        $script:ownerPid = [Int32]$w.ProcessId
                        $script:ownerHwnd = $wHwnd
                        $script:lastSessionMarkerProbeHwnd = $wHwnd
                        $script:lastSessionMarkerProbeTitle = $marker
                        $script:lastSessionMarkerProbeUntilMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + 5000
                        $script:staleOwnerHwnd = 0
                        $script:staleOwnerPid = 0
                        $matchedSource = if ($isUsed) { 'session-marker-shared' } else { 'session-marker' }
                        $matched = $true
                        break
                    }
                }
            }
        } finally {
            try {
                if (-not [string]::IsNullOrWhiteSpace($restoreTitle)) {
                    $safeRestoreTitle = Get-SafeConsoleRestoreTitle $restoreTitle
                    [void][ClaudeWtPets.WindowFocus]::SetConsoleTitle($safeRestoreTitle)
                    if ($safeRestoreTitle -ne $restoreTitle) {
                        Write-TransitionLog 'owner-window-session-marker-restore-sanitized' $script:lastState $script:lastTs (Get-AnchorDetail "previous_restore=$restoreTitle;safe_restore=$safeRestoreTitle")
                    }
                }
            } catch {}
            try { [void][ClaudeWtPets.WindowFocus]::FreeConsole() } catch {}
        }

        if ($matched) {
            Save-RecoveredOwnerState $matchedSource
            Write-TransitionLog 'owner-window-recovered-from-session-marker' $script:lastState $script:lastTs (Get-AnchorDetail "parent_pid=$parentPid;source=$matchedSource;attempt=$lastAttempt;visible=$lastVisibleCount;active_slots=$lastActiveSlots;used=$lastUsedCount;merged=$lastMerged")
            Clear-DisconnectedState 'owner-window-recovered-from-session-marker'
            return $true
        }

        if ($LogMiss) {
            $detail = "parent_pid=$parentPid;attempts=$lastAttempt;visible=$lastVisibleCount;active_slots=$lastActiveSlots;used=$lastUsedCount;merged=$lastMerged"
            if ($lastUsedMatch -gt 0) { $detail += ";used_match=$lastUsedMatch" }
            Write-TransitionLog 'owner-window-session-marker-no-match' $script:lastState $script:lastTs (Get-AnchorDetail $detail)
        }
    } catch {
        if ($LogMiss) {
            Write-TransitionLog 'owner-window-session-marker-error' $script:lastState $script:lastTs (Get-ErrorDetail $_)
        }
    }

    return $false
}

function Get-OwnerMapRecordForCurrentSlot {
    try {
        $ownerMap = Read-JsonCached $OWNER_MAP_FILE
        if (-not $ownerMap) { return $null }

        if (
            -not [string]::IsNullOrWhiteSpace($script:sessionId) -and
            $ownerMap.PSObject.Properties['sessions'] -and
            $ownerMap.sessions -and
            $ownerMap.sessions.PSObject.Properties[$script:sessionId]
        ) {
            return $ownerMap.sessions.PSObject.Properties[$script:sessionId].Value
        }

        $slotKey = [string]$Slot
        if (
            $ownerMap.PSObject.Properties['slots'] -and
            $ownerMap.slots -and
            $ownerMap.slots.PSObject.Properties[$slotKey]
        ) {
            $record = $ownerMap.slots.PSObject.Properties[$slotKey].Value
            $recordSessionId = ''
            if ($record.PSObject.Properties['session_id']) {
                $recordSessionId = [string]$record.session_id
            }
            $recordSessionPid = 0
            if ($record.PSObject.Properties['session_pid']) {
                try { $recordSessionPid = [Int32]$record.session_pid } catch {}
            }

            if (
                [string]::IsNullOrWhiteSpace($script:sessionId) -or
                $recordSessionId -eq $script:sessionId -or
                ($script:sessionPid -gt 0 -and $recordSessionPid -eq $script:sessionPid)
            ) {
                return $record
            }
        }
    } catch {
        Write-TransitionLog 'owner-map-read-error' $script:lastState $script:lastTs (Get-ErrorDetail $_)
    }

    return $null
}

function Resolve-OwnerHwndFromOwnerMap {
    param([switch]$LogMiss)

    try {
        $record = Get-OwnerMapRecordForCurrentSlot
        if (-not $record) {
            if ($LogMiss) {
                Write-TransitionLog 'owner-window-owner-map-miss' $script:lastState $script:lastTs (Get-AnchorDetail 'reason=no-record')
            }
            return $false
        }

        $recordSource = ''
        if ($record.PSObject.Properties['owner_source']) {
            $recordSource = [string]$record.owner_source
        }
        if (-not (Test-OwnerSourcePersistable $recordSource)) {
            if ($LogMiss) {
                Write-TransitionLog 'owner-window-owner-map-miss' $script:lastState $script:lastTs (Get-AnchorDetail "reason=unusable-source;source=$recordSource")
            }
            return $false
        }

        $isMerged = Test-TerminalWindowsMerged
        $isSharedRecord = Test-SharedOwnerSource $recordSource
        if ($isSharedRecord -and -not $isMerged) {
            if ($LogMiss) {
                Write-TransitionLog 'owner-window-owner-map-miss' $script:lastState $script:lastTs (Get-AnchorDetail "reason=shared-source-not-merged;source=$recordSource")
            }
            return $false
        }

        $mappedHwnd = 0
        try { $mappedHwnd = [Int64]$record.owner_hwnd } catch {}
        if ($mappedHwnd -le 0) {
            if ($LogMiss) {
                Write-TransitionLog 'owner-window-owner-map-miss' $script:lastState $script:lastTs (Get-AnchorDetail 'reason=missing-hwnd')
            }
            return $false
        }

        $usedHwnds = Get-UsedOwnerHwndsFromStates
        $isClaimed = $usedHwnds.ContainsKey([string]$mappedHwnd)
        if ($isClaimed -and -not $isMerged) {
            if ($LogMiss) {
                Write-TransitionLog 'owner-window-owner-map-miss' $script:lastState $script:lastTs (Get-AnchorDetail "reason=claimed;hwnd=$mappedHwnd")
            }
            return $false
        }

        Ensure-WindowFocusType
        $visibleWindows = @([ClaudeWtPets.WindowFocus]::FindVisibleTerminalWindows())
        foreach ($w in $visibleWindows) {
            $wHwnd = [Int64]$w.Hwnd
            if ($wHwnd -ne $mappedHwnd) { continue }

            $currentTitle = [ClaudeWtPets.WindowFocus]::GetWindowTitle($wHwnd)
            if (Test-InternalProbeTitle $currentTitle) {
                if ($LogMiss) {
                    Write-TransitionLog 'owner-window-owner-map-miss' $script:lastState $script:lastTs (Get-AnchorDetail "reason=probe-marker-title;hwnd=$mappedHwnd;title=$currentTitle")
                }
                return $false
            }
            if ((Test-OtherSlotWindowTitle $currentTitle) -and -not ($isSharedRecord -and $isMerged)) {
                if ($LogMiss) {
                    Write-TransitionLog 'owner-window-owner-map-miss' $script:lastState $script:lastTs (Get-AnchorDetail "reason=other-slot-title;hwnd=$mappedHwnd;title=$currentTitle")
                }
                return $false
            }
            if (-not (Test-OwnerMapWindowTitleCompatible $record $currentTitle)) {
                if ($LogMiss) {
                    Write-TransitionLog 'owner-window-owner-map-miss' $script:lastState $script:lastTs (Get-AnchorDetail "reason=title-conflict;hwnd=$mappedHwnd;new_title=$currentTitle;previous_title=$($record.window_title)")
                }
                return $false
            }

            $script:ownerPid = [Int32]$w.ProcessId
            $script:ownerHwnd = $mappedHwnd
            if (-not [string]::IsNullOrWhiteSpace($currentTitle)) {
                $script:windowTitle = $currentTitle
                if (-not (Test-SharedOwnerSource $recordSource)) {
                    $script:tabTitle = $currentTitle
                }
            }
            $script:staleOwnerHwnd = 0
            $script:staleOwnerPid = 0
            $ownerSource = if ($isClaimed) { 'last-known-good-shared' } else { 'last-known-good' }
            Save-RecoveredOwnerState $ownerSource
            Write-TransitionLog 'owner-window-recovered-from-owner-map' $script:lastState $script:lastTs (Get-AnchorDetail "hwnd=$mappedHwnd;source=$recordSource;visible=$($visibleWindows.Count);window_title=$currentTitle")
            Clear-DisconnectedState 'owner-window-recovered-from-owner-map'
            return $true
        }

        if ($LogMiss) {
            Write-TransitionLog 'owner-window-owner-map-miss' $script:lastState $script:lastTs (Get-AnchorDetail "reason=not-visible;hwnd=$mappedHwnd;visible=$($visibleWindows.Count)")
        }
    } catch {
        if ($LogMiss) {
            Write-TransitionLog 'owner-window-owner-map-error' $script:lastState $script:lastTs (Get-ErrorDetail $_)
        }
    }

    return $false
}

function Get-TerminalTabTitles([Int64]$Hwnd) {
    # UIA 읽기 전용 열거. window title(활성 탭)과 달리 비활성 탭 제목까지 보인다.
    $names = @()
    try {
        if (-not $script:uiaTypesLoaded) {
            Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes -ErrorAction Stop
            $script:uiaTypesLoaded = $true
        }
        $element = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$Hwnd)
        if (-not $element) { return $names }
        $condition = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::TabItem)
        $tabs = $element.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition)
        foreach ($tab in $tabs) {
            $name = ''
            try { $name = [string]$tab.Current.Name } catch {}
            if (-not [string]::IsNullOrWhiteSpace($name)) { $names += $name }
        }
    } catch {}
    return $names
}

function Resolve-OwnerHwndFromTabStrip {
    param([switch]$LogMiss)

    try {
        if (Test-SessionPidClaimedByOtherSlot) {
            if ($LogMiss) {
                Write-TransitionLog 'owner-window-tab-strip-skip-pid-claimed' $script:lastState $script:lastTs (Get-AnchorDetail "session_pid=$($script:sessionPid)")
            }
            return $false
        }
        Ensure-WindowFocusType
        $visibleWindows = @([ClaudeWtPets.WindowFocus]::FindVisibleTerminalWindows())
        if ($visibleWindows.Count -eq 0) { return $false }

        $storedTabTitle = ''
        if (-not [string]::IsNullOrWhiteSpace($script:tabTitle) -and -not (Test-InternalProbeTitle $script:tabTitle) -and -not (Test-OtherSlotWindowTitle $script:tabTitle)) {
            $storedTabTitle = [string]$script:tabTitle
        }

        $usedHwnds = Get-UsedOwnerHwndsFromStates
        $budget = [System.Diagnostics.Stopwatch]::StartNew()
        $candidates = @()
        $sharedEvidence = @{}
        foreach ($w in $visibleWindows) {
            if ($budget.ElapsedMilliseconds -gt 1500) {
                if ($LogMiss) {
                    Write-TransitionLog 'owner-window-tab-strip-budget-exceeded' $script:lastState $script:lastTs (Get-AnchorDetail "elapsed_ms=$($budget.ElapsedMilliseconds);visible=$($visibleWindows.Count)")
                }
                return $false
            }
            $wHwnd = 0
            try { $wHwnd = [Int64]$w.Hwnd } catch {}
            if ($wHwnd -le 0) { continue }
            $tabNames = @(Get-TerminalTabTitles $wHwnd)
            if ($tabNames.Count -eq 0) { continue }
            $mine = $false
            $otherSlot = $false
            foreach ($name in $tabNames) {
                if (Test-InternalProbeTitle $name) { continue }
                if ([string]::IsNullOrWhiteSpace((Strip-TitleSpinner (([string]$name).Trim())))) { continue }
                if (Test-OtherSlotWindowTitle $name) { $otherSlot = $true; continue }
                if ((Get-ExplicitSlotFromWindowTitle $name) -eq $Slot) { $mine = $true; continue }
                if (-not [string]::IsNullOrWhiteSpace($storedTabTitle) -and (Test-WindowTitleCompatible $name $storedTabTitle)) { $mine = $true }
            }
            if ($mine) {
                $candidates += $w
                $sharedEvidence[[string]$wHwnd] = $otherSlot
            }
        }

        if ($candidates.Count -ne 1) {
            if ($LogMiss) {
                Write-TransitionLog 'owner-window-tab-strip-no-unique-match' $script:lastState $script:lastTs (Get-AnchorDetail "slot=$Slot;tab_title=$storedTabTitle;candidates=$($candidates.Count);visible=$($visibleWindows.Count)")
            }
            return $false
        }

        $match = $candidates[0]
        $matchHwnd = [Int64]$match.Hwnd
        $ownerSource = 'tab-strip'
        if ($usedHwnds.ContainsKey([string]$matchHwnd)) {
            $sharedOk = $sharedEvidence[[string]$matchHwnd] -or (Test-TerminalWindowsMerged)
            if (-not $sharedOk) {
                if ($LogMiss) {
                    Write-TransitionLog 'owner-window-tab-strip-candidate-used' $script:lastState $script:lastTs (Get-AnchorDetail "slot=$Slot;hwnd=$matchHwnd;visible=$($visibleWindows.Count)")
                }
                return $false
            }
            $ownerSource = 'tab-strip-shared'
        }

        $script:ownerPid = [Int32]$match.ProcessId
        $script:ownerHwnd = $matchHwnd
        $script:staleOwnerHwnd = 0
        $script:staleOwnerPid = 0
        Save-RecoveredOwnerState $ownerSource
        Write-TransitionLog 'owner-window-recovered-from-tab-strip' $script:lastState $script:lastTs (Get-AnchorDetail "slot=$Slot;hwnd=$matchHwnd;source=$ownerSource;visible=$($visibleWindows.Count);elapsed_ms=$($budget.ElapsedMilliseconds)")
        Clear-DisconnectedState 'owner-window-recovered-from-tab-strip'
        return $true
    } catch {
        if ($LogMiss) {
            Write-TransitionLog 'owner-window-tab-strip-error' $script:lastState $script:lastTs (Get-ErrorDetail $_)
        }
    }

    return $false
}

function Resolve-OwnerHwndFromTabTitle {
    param([switch]$LogMiss)

    try {
        if ([string]::IsNullOrWhiteSpace($script:sessionId)) {
            if ($LogMiss) {
                Write-TransitionLog 'owner-window-tab-title-skip-no-session-id' $script:lastState $script:lastTs (Get-AnchorDetail)
            }
            return $false
        }
        if (Test-SessionPidClaimedByOtherSlot) {
            if ($LogMiss) {
                Write-TransitionLog 'owner-window-tab-title-skip-pid-claimed' $script:lastState $script:lastTs (Get-AnchorDetail "session_pid=$($script:sessionPid)")
            }
            return $false
        }
        Ensure-WindowFocusType
        $visibleWindows = @([ClaudeWtPets.WindowFocus]::FindVisibleTerminalWindows())
        if ($visibleWindows.Count -eq 0) { return $false }

        $usedHwnds = Get-UsedOwnerHwndsFromStates
        $slotMarker = "Claude #$Slot"
        $otherMarkers = @{}
        for ($s = 1; $s -le $MAX_SLOTS; $s++) {
            if ($s -ne $Slot) { $otherMarkers[[string]$s] = "Claude #$s" }
        }

        $candidates = @(Find-UnusedWindowByTitle -MatchTitle $slotMarker -VisibleWindows $visibleWindows -UsedHwnds $usedHwnds -ExcludeTitles $otherMarkers)

        if ($candidates.Count -ne 1 -and -not [string]::IsNullOrWhiteSpace($script:tabTitle)) {
            $otherTitles = Get-OtherSlotTabTitles
            $candidates = @(Find-UnusedWindowByTitle -MatchTitle $script:tabTitle -VisibleWindows $visibleWindows -UsedHwnds $usedHwnds -ExcludeTitles $otherTitles)
        }

        if ($candidates.Count -ne 1) {
            if ($LogMiss) {
                Write-TransitionLog 'owner-window-tab-title-no-unique-match' $script:lastState $script:lastTs (Get-AnchorDetail "slot=$Slot;marker=$slotMarker;tab_title=$($script:tabTitle);candidates=$($candidates.Count);visible=$($visibleWindows.Count)")
            }
            return $false
        }

        $match = $candidates[0]
        $script:ownerPid = [Int32]$match.ProcessId
        $script:ownerHwnd = [Int64]$match.Hwnd
        $script:staleOwnerHwnd = 0
        $script:staleOwnerPid = 0
        Save-RecoveredOwnerState 'tab-title'
        Write-TransitionLog 'owner-window-recovered-from-tab-title' $script:lastState $script:lastTs (Get-AnchorDetail "slot=$Slot;hwnd=$($match.Hwnd);marker=$slotMarker;tab_title=$($script:tabTitle);visible=$($visibleWindows.Count)")
        Clear-DisconnectedState 'owner-window-recovered-from-tab-title'
        return $true
    } catch {
        if ($LogMiss) {
            Write-TransitionLog 'owner-window-tab-title-error' $script:lastState $script:lastTs (Get-ErrorDetail $_)
        }
    }

    return $false
}

function Resolve-SharedOwnerHwnd {
    $previousHwnd = [Int64]$script:ownerHwnd
    $previousSource = [string]$script:ownerSource
    $previousPid = [Int32]$script:ownerPid
    try {
        if ($script:ownerHwnd -le 0) { return $false }
        if (@('session-marker', 'title-match') -contains $script:ownerSource) { return $false }

        $usedHwnds = Get-UsedOwnerHwndsFromStates
        if (-not $usedHwnds.ContainsKey([string]$script:ownerHwnd)) { return $false }

        Ensure-WindowFocusType
        $visibleWindows = @([ClaudeWtPets.WindowFocus]::FindVisibleTerminalWindows())
        $hasUnclaimed = $false
        foreach ($w in $visibleWindows) {
            $wHwnd = [Int64]$w.Hwnd
            if ($wHwnd -gt 0 -and $wHwnd -ne $script:ownerHwnd -and -not $usedHwnds.ContainsKey([string]$wHwnd)) {
                $hasUnclaimed = $true
                break
            }
        }
        if (-not $hasUnclaimed) { return $false }

        $activeSlots = 1
        for ($s = 1; $s -le $MAX_SLOTS; $s++) {
            if ($s -eq $Slot) { continue }
            if (Test-Path -LiteralPath ([System.IO.Path]::Combine($env:TEMP, "claude-wt-pets-state-$s.json"))) {
                $activeSlots++
            }
        }

        if ($visibleWindows.Count -lt $activeSlots) {
            $ownerMapFile = [System.IO.Path]::Combine($env:TEMP, 'claude-wt-pets-owner-map.json')
            $ownerMap = Read-JsonCached $ownerMapFile
            if (-not $ownerMap) { return $false }
            $slotKey = [string]$Slot
            $myMapHwnd = 0
            if ($ownerMap.slots -and $ownerMap.slots.PSObject.Properties[$slotKey]) {
                try { $myMapHwnd = [Int64]$ownerMap.slots.$slotKey.owner_hwnd } catch {}
            }

            if ($myMapHwnd -gt 0 -and $myMapHwnd -eq $script:ownerHwnd) { return $false }

            if (Test-SharedOwnerSource $script:ownerSource) {
                $hwnd = [IntPtr]::new([Int64]$script:ownerHwnd)
                if ([ClaudeWtPets.WindowFocus]::IsWindow($hwnd)) {
                    Write-TransitionLog 'shared-owner-merged-stale-map-stay' $script:lastState $script:lastTs (Get-AnchorDetail "map_hwnd=$myMapHwnd;source=$($script:ownerSource);visible=$($visibleWindows.Count);active=$activeSlots")
                    Sync-OwnerMapFromCurrentOwner $script:ownerSource
                    return $false
                }
            }
        }

        $script:staleOwnerHwnd = $script:ownerHwnd
        $script:ownerHwnd = 0
        $script:ownerSource = 'shared-unresolved'

        if (Resolve-OwnerHwndFromTabStrip) {
            Write-TransitionLog 'shared-owner-resolved-tab-strip' $script:lastState $script:lastTs (Get-AnchorDetail "previous=$previousHwnd;new=$($script:ownerHwnd)")
            return $true
        }
        if (Resolve-OwnerHwndFromSessionMarker) {
            Write-TransitionLog 'shared-owner-resolved-session-marker' $script:lastState $script:lastTs (Get-AnchorDetail "previous=$previousHwnd;new=$($script:ownerHwnd)")
            return $true
        }
        if (Resolve-OwnerHwndFromOwnerMap) {
            Write-TransitionLog 'shared-owner-resolved-owner-map' $script:lastState $script:lastTs (Get-AnchorDetail "previous=$previousHwnd;new=$($script:ownerHwnd)")
            return $true
        }
        if (Resolve-OwnerHwndFromTabTitle) {
            Write-TransitionLog 'shared-owner-resolved-tab-title' $script:lastState $script:lastTs (Get-AnchorDetail "previous=$previousHwnd;new=$($script:ownerHwnd)")
            return $true
        }

        $script:ownerHwnd = 0
        $script:ownerSource = 'shared-unresolved'
        $script:ownerPid = $previousPid
        $script:staleOwnerHwnd = $previousHwnd
        Write-TransitionLog 'shared-owner-unresolved-disconnected' $script:lastState $script:lastTs (Get-AnchorDetail "previous=$previousHwnd;previous_source=$previousSource;visible_windows=$($visibleWindows.Count);trusted_only=true")
        Show-OwnerLinkMissing 'shared-owner-unresolved;trusted_only=true'
        return $false
    } catch {
        if ($previousHwnd -gt 0) {
            $script:ownerHwnd = 0
            $script:ownerSource = 'shared-unresolved'
            $script:ownerPid = $previousPid
            $script:staleOwnerHwnd = $previousHwnd
        }
        Write-TransitionLog 'shared-owner-resolve-error' $script:lastState $script:lastTs (Get-ErrorDetail $_)
        Show-OwnerLinkMissing 'shared-owner-resolve-error'
        return $false
    }
}

function Get-DisconnectedReturn {
    $state = $script:disconnectedReturnState
    $ts = [Int64]$script:disconnectedReturnTs

    if (
        -not [string]::IsNullOrWhiteSpace($state) -and
        $state -ne 'disconnected' -and
        $VALID_STATES.ContainsKey($state)
    ) {
        return [pscustomobject]@{ State = $state; Ts = $ts }
    }

    try {
        $current = Read-JsonCached $STATE_FILE
        if ($current) {
            $previousState = ''
            $previousTs = 0
            if ($current.PSObject.Properties['previous_state']) { $previousState = [string]$current.previous_state }
            if ($current.PSObject.Properties['previous_ts']) {
                try { $previousTs = [Int64]$current.previous_ts } catch {}
            }
            if (
                -not [string]::IsNullOrWhiteSpace($previousState) -and
                $previousState -ne 'disconnected' -and
                $VALID_STATES.ContainsKey($previousState)
            ) {
                return [pscustomobject]@{ State = $previousState; Ts = $previousTs }
            }
        }
    } catch {}

    return [pscustomobject]@{ State = 'idle'; Ts = 0 }
}

function Clear-DisconnectedState([string]$reason) {
    if ($script:lastState -ne 'disconnected') { return }

    try {
        Write-TransitionLog 'disconnected-owner-restored-keep-state' 'disconnected' $script:lastTs $reason
    } catch {
        Write-TransitionLog 'disconnected-restore-error' $script:lastState $script:lastTs (Get-ErrorDetail $_)
    }
}

function Show-OwnerLinkMissing([string]$detail) {
    try {
        $returnState = $script:lastState
        $returnTs = [Int64]$script:lastTs
        if ($returnState -eq 'disconnected') {
            $return = Get-DisconnectedReturn
            $returnState = [string]$return.State
            $returnTs = [Int64]$return.Ts
        }
        if (
            [string]::IsNullOrWhiteSpace($returnState) -or
            $returnState -eq 'disconnected' -or
            -not $VALID_STATES.ContainsKey($returnState)
        ) {
            $returnState = 'idle'
            $returnTs = 0
        }

        $script:disconnectedReturnState = $returnState
        $script:disconnectedReturnTs = $returnTs
        $script:isSleepingOverride = $false
        $script:sleepBaseTs = 0
        $script:lastIgnoredSleepTs = 0
        $script:lastState = 'disconnected'
        $image.Source = Load-Image 'disconnected' $script:character
        $savedTs = Save-CurrentState 'disconnected' $script:character @{
            previous_state = $returnState
            previous_ts = $returnTs
            owner_hwnd = 0
            owner_source = if ([string]::IsNullOrWhiteSpace($script:ownerSource)) { 'unresolved' } else { $script:ownerSource }
        }
        if ($null -ne $savedTs) {
            $script:lastTs = [Int64]$savedTs
        }
        Write-TransitionLog 'owner-link-missing-visible' 'disconnected' $script:lastTs ($detail + ";previous_state=$returnState")
        Restart-SleepTimer
    } catch {
        Write-TransitionLog 'owner-link-missing-visible-error' $script:lastState $script:lastTs (Get-ErrorDetail $_)
    }
}

function Test-OwnerProcessAlive {
    try {
        if ($script:ownerPid -gt 0) {
            $owner = Get-Process -Id $script:ownerPid -ErrorAction SilentlyContinue
            if ($owner) { return $true }
        }
    } catch {}

    return $false
}

function Test-SessionProcessAlive([int]$ProcessId) {
    try {
        if ($ProcessId -gt 0) {
            $session = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
            if ($session -and $session.ProcessName -eq 'claude') { return $true }
        }
    } catch {}

    return $false
}

function Test-SessionProcessAliveFromStateFile {
    try {
        $data = Read-JsonCached $STATE_FILE
        if (-not $data) { return $false }
        if ($data.session_pid -gt 0) {
            $recovered = Get-Process -Id ([int]$data.session_pid) -ErrorAction SilentlyContinue
            if ($recovered -and $recovered.ProcessName -eq 'claude') {
                $script:sessionPid = [int]$data.session_pid
                return $true
            }
        }
    } catch {}
    return $false
}

function Test-MissingSessionGraceActive([string]$WaitAction, [string]$ExpiredAction, [string]$Detail = '') {
    $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $currentStateTs = [Int64]0
    if ($script:latestStateTs -gt 0) {
        $currentStateTs = [Int64]$script:latestStateTs
    } elseif ($script:lastTs -gt 0) {
        $currentStateTs = [Int64]$script:lastTs
    }

    if ($script:sessionGoneSince -le 0) {
        $script:sessionGoneSince = $nowMs
        $script:sessionGoneStateTs = $currentStateTs
        Write-TransitionLog $WaitAction $script:lastState $script:lastTs (Get-AnchorDetail ("missing=session;state_ts=$currentStateTs;$Detail"))
        return $true
    }

    if ($script:sessionGoneStateTs -gt 0 -and $currentStateTs -gt 0 -and $currentStateTs -ne $script:sessionGoneStateTs) {
        Write-TransitionLog 'session-process-gone-state-advanced-reset' $script:lastState $script:lastTs (Get-AnchorDetail ("previous_state_ts=$($script:sessionGoneStateTs);current_state_ts=$currentStateTs;$Detail"))
        $script:sessionGoneSince = 0
        $script:sessionGoneStateTs = 0
        return $true
    }

    $graceLimit = $SESSION_GONE_GRACE_SECONDS
    $restingStateFast = $false
    $fastSharedGrace = $false
    if ($script:lastState -eq 'done' -or $script:lastState -eq 'idle' -or $script:lastState -eq 'sleeping') {
        $graceLimit = $DONE_STATE_GONE_GRACE_SECONDS
        $restingStateFast = $true
    }
    if (
        (Test-SharedOwnerSource $script:ownerSource) -and
        $script:sessionGoneStateTs -gt 0 -and
        $currentStateTs -eq $script:sessionGoneStateTs
    ) {
        $graceLimit = $FAST_SHARED_SESSION_GONE_GRACE_SECONDS
        $fastSharedGrace = $true
    }

    if (($nowMs - $script:sessionGoneSince) -lt ($graceLimit * 1000)) {
        return $true
    }

    Write-TransitionLog $ExpiredAction $script:lastState $script:lastTs (Get-AnchorDetail ("missing=session;grace_seconds=$graceLimit;resting_fast=$restingStateFast;fast_shared_grace=$fastSharedGrace;state_ts=$currentStateTs;$Detail"))
    return $false
}

function Test-OwnerAlive {
    if (Test-OwnerWindowAlive) { return $true }
    if (Test-OwnerProcessAlive) { return $true }
    return $false
}

function Ensure-ProcessParentType {
    $typeName = 'ClaudeWtPets.ProcessParent'
    if (([System.Management.Automation.PSTypeName]$typeName).Type) { return }

    Add-Type @"
using System;
using System.Runtime.InteropServices;

namespace ClaudeWtPets {
    public static class ProcessParent {
        private const uint TH32CS_SNAPPROCESS = 0x00000002;

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
        private struct PROCESSENTRY32 {
            public uint dwSize;
            public uint cntUsage;
            public uint th32ProcessID;
            public IntPtr th32DefaultHeapID;
            public uint th32ModuleID;
            public uint cntThreads;
            public uint th32ParentProcessID;
            public int pcPriClassBase;
            public uint dwFlags;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
            public string szExeFile;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr CreateToolhelp32Snapshot(uint dwFlags, uint th32ProcessID);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool Process32First(IntPtr hSnapshot, ref PROCESSENTRY32 lppe);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool Process32Next(IntPtr hSnapshot, ref PROCESSENTRY32 lppe);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr hObject);

        public static int GetParentProcessId(int processId) {
            IntPtr snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
            if (snapshot == IntPtr.Zero || snapshot == new IntPtr(-1)) return 0;

            try {
                PROCESSENTRY32 entry = new PROCESSENTRY32();
                entry.dwSize = (uint)Marshal.SizeOf(typeof(PROCESSENTRY32));
                if (!Process32First(snapshot, ref entry)) return 0;

                do {
                    if (entry.th32ProcessID == (uint)processId) {
                        return (int)entry.th32ParentProcessID;
                    }
                } while (Process32Next(snapshot, ref entry));
            } finally {
                CloseHandle(snapshot);
            }

            return 0;
        }
    }
}
"@
}

function Ensure-WindowFocusType {
    $typeName = 'ClaudeWtPets.WindowFocus'
    if (([System.Management.Automation.PSTypeName]$typeName).Type) { return }

    Add-Type @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace ClaudeWtPets {
    public class TerminalWindowInfo {
        public long Hwnd { get; set; }
        public int ProcessId { get; set; }
        public int Left { get; set; }
        public int Top { get; set; }
        public int Right { get; set; }
        public int Bottom { get; set; }
        public int Width { get { return Right - Left; } }
        public int Height { get { return Bottom - Top; } }
    }

    public static class WindowFocus {
        public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

        [StructLayout(LayoutKind.Sequential)]
        public struct RECT {
            public int Left;
            public int Top;
            public int Right;
            public int Bottom;
        }

        [DllImport("user32.dll")]
        public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

        [DllImport("user32.dll")]
        public static extern bool IsWindowVisible(IntPtr hWnd);

        [DllImport("user32.dll")]
        public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

        [DllImport("user32.dll")]
        public static extern int GetClassName(IntPtr hWnd, StringBuilder className, int maxCount);

        [DllImport("user32.dll")]
        public static extern bool IsWindow(IntPtr hWnd);

        [DllImport("user32.dll")]
        public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);

        [DllImport("user32.dll")]
        public static extern bool SetForegroundWindow(IntPtr hWnd);

        [DllImport("user32.dll")]
        public static extern bool IsIconic(IntPtr hWnd);

        [DllImport("user32.dll")]
        public static extern IntPtr GetForegroundWindow();

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool FreeConsole();

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool AttachConsole(uint dwProcessId);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern bool SetConsoleTitle(string lpConsoleTitle);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern uint GetConsoleTitle(StringBuilder lpConsoleTitle, uint nSize);

        public static string ReadConsoleTitle() {
            var sb = new StringBuilder(1024);
            uint len = GetConsoleTitle(sb, (uint)sb.Capacity);
            return len > 0 ? sb.ToString() : "";
        }

        [DllImport("user32.dll")]
        public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int maxCount);

        [DllImport("user32.dll")]
        public static extern int GetWindowTextLength(IntPtr hWnd);

        public static string GetWindowTitle(long hwndValue) {
            var hwnd = new IntPtr(hwndValue);
            int length = GetWindowTextLength(hwnd);
            if (length <= 0) return "";
            var sb = new StringBuilder(length + 1);
            GetWindowText(hwnd, sb, sb.Capacity);
            return sb.ToString();
        }

        public static long[] FindVisibleTerminalWindowsForPid(int pid) {
            var windows = new List<long>();
            EnumWindows((hWnd, lParam) => {
                uint windowPid;
                GetWindowThreadProcessId(hWnd, out windowPid);
                if (windowPid == pid && IsWindow(hWnd) && IsWindowVisible(hWnd)) {
                    var className = new StringBuilder(256);
                    GetClassName(hWnd, className, className.Capacity);
                    if (className.ToString() == "CASCADIA_HOSTING_WINDOW_CLASS") {
                        windows.Add(hWnd.ToInt64());
                    }
                }
                return true;
            }, IntPtr.Zero);
            return windows.ToArray();
        }

        public static TerminalWindowInfo[] FindVisibleTerminalWindows() {
            var windows = new List<TerminalWindowInfo>();
            EnumWindows((hWnd, lParam) => {
                if (!IsWindow(hWnd) || !IsWindowVisible(hWnd)) return true;

                var className = new StringBuilder(256);
                GetClassName(hWnd, className, className.Capacity);
                if (className.ToString() != "CASCADIA_HOSTING_WINDOW_CLASS") return true;

                uint windowPid;
                GetWindowThreadProcessId(hWnd, out windowPid);

                RECT rect;
                if (!GetWindowRect(hWnd, out rect)) return true;

                windows.Add(new TerminalWindowInfo {
                    Hwnd = hWnd.ToInt64(),
                    ProcessId = (int)windowPid,
                    Left = rect.Left,
                    Top = rect.Top,
                    Right = rect.Right,
                    Bottom = rect.Bottom
                });
                return true;
            }, IntPtr.Zero);
            return windows.ToArray();
        }
    }
}
"@
}

function Ensure-OverlayWindowType {
    $typeName = 'ClaudeWtPets.OverlayWindow'
    if (([System.Management.Automation.PSTypeName]$typeName).Type) { return }

    Add-Type @"
using System;
using System.Runtime.InteropServices;

namespace ClaudeWtPets {
    public static class OverlayWindow {
        private const int GWL_EXSTYLE = -20;
        private const long WS_EX_TOOLWINDOW = 0x00000080L;
        private const long WS_EX_APPWINDOW = 0x00040000L;

        [DllImport("user32.dll", EntryPoint="GetWindowLong")]
        private static extern int GetWindowLong32(IntPtr hWnd, int nIndex);

        [DllImport("user32.dll", EntryPoint="SetWindowLong")]
        private static extern int SetWindowLong32(IntPtr hWnd, int nIndex, int dwNewLong);

        [DllImport("user32.dll", EntryPoint="GetWindowLongPtr")]
        private static extern IntPtr GetWindowLongPtr64(IntPtr hWnd, int nIndex);

        [DllImport("user32.dll", EntryPoint="SetWindowLongPtr")]
        private static extern IntPtr SetWindowLongPtr64(IntPtr hWnd, int nIndex, IntPtr dwNewLong);

        private static IntPtr GetWindowLongPtr(IntPtr hWnd, int nIndex) {
            if (IntPtr.Size == 8) {
                return GetWindowLongPtr64(hWnd, nIndex);
            }
            return new IntPtr(GetWindowLong32(hWnd, nIndex));
        }

        private static IntPtr SetWindowLongPtr(IntPtr hWnd, int nIndex, IntPtr dwNewLong) {
            if (IntPtr.Size == 8) {
                return SetWindowLongPtr64(hWnd, nIndex, dwNewLong);
            }
            return new IntPtr(SetWindowLong32(hWnd, nIndex, dwNewLong.ToInt32()));
        }

        public static void HideFromAltTab(IntPtr hWnd) {
            long style = GetWindowLongPtr(hWnd, GWL_EXSTYLE).ToInt64();
            style = (style | WS_EX_TOOLWINDOW) & ~WS_EX_APPWINDOW;
            SetWindowLongPtr(hWnd, GWL_EXSTYLE, new IntPtr(style));
        }
    }
}
"@
}

function Hide-WindowFromAltTab {
    try {
        Ensure-OverlayWindowType
        $helper = New-Object System.Windows.Interop.WindowInteropHelper -ArgumentList $window
        $hwnd = $helper.Handle
        if ($hwnd -eq [IntPtr]::Zero) { return }

        [ClaudeWtPets.OverlayWindow]::HideFromAltTab($hwnd)
        Write-TransitionLog 'hide-from-alt-tab' $script:lastState $script:lastTs
    } catch {
        Write-TransitionLog 'hide-from-alt-tab-error' $script:lastState $script:lastTs (Get-ErrorDetail $_)
    }
}

function Resolve-OwnerHwndInVerifiedOrder {
    param(
        [switch]$LogMiss,
        [switch]$TrustedOnly
    )

    $script:ownerTitleConflictDetail = ''

    if ($script:ownerHwnd -le 0) {
        if ($LogMiss) { [void](Resolve-OwnerHwndFromTabStrip -LogMiss) }
        else { [void](Resolve-OwnerHwndFromTabStrip) }
    }
    if ($script:ownerHwnd -le 0) {
        if ($LogMiss) { [void](Resolve-OwnerHwndFromSessionMarker -LogMiss) }
        else { [void](Resolve-OwnerHwndFromSessionMarker) }
    }
    if ($script:ownerHwnd -le 0) {
        if ($LogMiss) { [void](Resolve-OwnerHwndFromOwnerMap -LogMiss) }
        else { [void](Resolve-OwnerHwndFromOwnerMap) }
    }
    if ($script:ownerHwnd -le 0 -and -not [string]::IsNullOrWhiteSpace($script:ownerTitleConflictDetail)) {
        return $false
    }
    if ($script:ownerHwnd -le 0) {
        if ($LogMiss) { [void](Resolve-OwnerHwndFromTabTitle -LogMiss) }
        else { [void](Resolve-OwnerHwndFromTabTitle) }
    }

    if ($script:ownerHwnd -le 0 -and $LogMiss) {
        Write-TransitionLog 'owner-window-trusted-only-unresolved' $script:lastState $script:lastTs (Get-AnchorDetail)
    }

    return $script:ownerHwnd -gt 0
}

function Focus-OwnerWindow {
    $previousStale = $script:staleOwnerHwnd
    $script:staleOwnerHwnd = 0
    $script:staleOwnerPid = 0
    Refresh-OwnerFromState
    if ($script:ownerHwnd -gt 0 -and -not (Test-SharedOwnerStillPlausible)) {
        $script:staleOwnerHwnd = [Int64]$script:ownerHwnd
        $script:ownerHwnd = 0
        $script:ownerSource = 'shared-unresolved'
        Write-TransitionLog 'focus-owner-shared-source-stale' $script:lastState $script:lastTs (Get-AnchorDetail "previous=$($script:staleOwnerHwnd)")
    } elseif (
        $script:ownerHwnd -gt 0 -and
        -not (Test-SharedOwnerSource $script:ownerSource) -and
        (Test-OwnerSourceRequiresFocusRecheck $script:ownerSource)
    ) {
        $script:staleOwnerHwnd = [Int64]$script:ownerHwnd
        $script:ownerHwnd = 0
        Write-TransitionLog 'focus-owner-recheck-required' $script:lastState $script:lastTs (Get-AnchorDetail "previous=$($script:staleOwnerHwnd);source=$($script:ownerSource)")
    }
    if ($script:ownerHwnd -gt 0) {
        [void](Resolve-SharedOwnerHwnd)
    }
    if ($script:ownerHwnd -le 0) {
        [void](Resolve-OwnerHwndInVerifiedOrder -LogMiss -TrustedOnly)
    }
    if ($script:ownerHwnd -le 0) {
        Write-TransitionLog 'focus-owner-missing-hwnd' $script:lastState $script:lastTs (Get-AnchorDetail "previous_stale=$previousStale")
        $missingDetail = 'missing=owner_hwnd'
        if (-not [string]::IsNullOrWhiteSpace($script:ownerTitleConflictDetail)) {
            $missingDetail = $script:ownerTitleConflictDetail
        }
        Show-OwnerLinkMissing $missingDetail
        return
    }

    $topmostChanged = $false
    try {
        Ensure-WindowFocusType
        $hwnd = [IntPtr]::new([Int64]$script:ownerHwnd)
        if (-not [ClaudeWtPets.WindowFocus]::IsWindow($hwnd)) {
            $script:staleOwnerHwnd = [Int64]$script:ownerHwnd
            $script:ownerHwnd = 0
            $resolved = Resolve-OwnerHwndInVerifiedOrder -LogMiss -TrustedOnly
            if ($resolved) {
                $hwnd = [IntPtr]::new([Int64]$script:ownerHwnd)
            } else {
                Write-TransitionLog 'focus-owner-invalid-hwnd' $script:lastState $script:lastTs (Get-AnchorDetail)
                Show-OwnerLinkMissing 'invalid=owner_hwnd'
                return
            }
        }

        if (-not [ClaudeWtPets.WindowFocus]::IsWindow($hwnd)) {
            Write-TransitionLog 'focus-owner-invalid-hwnd' $script:lastState $script:lastTs (Get-AnchorDetail)
            Show-OwnerLinkMissing 'invalid=owner_hwnd'
            return
        }
        if (-not (Test-CurrentOwnerWindowTitleOrMarkConflict ([Int64]$script:ownerHwnd))) {
            Show-OwnerLinkMissing $script:ownerTitleConflictDetail
            return
        }

        $window.Topmost = $false
        $topmostChanged = $true
        if ([ClaudeWtPets.WindowFocus]::IsIconic($hwnd)) {
            [void][ClaudeWtPets.WindowFocus]::ShowWindowAsync($hwnd, 9)
        }
        [void][ClaudeWtPets.WindowFocus]::SetForegroundWindow($hwnd)
        Write-TransitionLog 'focus-owner-window' $script:lastState $script:lastTs (Get-AnchorDetail)
        Clear-DisconnectedState 'focus-owner-window'
    } catch {
        Write-TransitionLog 'focus-owner-error' $script:lastState $script:lastTs (Get-ErrorDetail $_)
    } finally {
        if ($topmostChanged) {
            try { $window.Topmost = $true } catch {}
        }
    }
}

function Get-ImagePath($state, $character) {
    $resolvedCharacter = Resolve-CharacterName $character
    if (-not [string]::IsNullOrWhiteSpace($resolvedCharacter)) {
        $charDir = Join-Path $script:WtPetsCharactersDir $resolvedCharacter
        $statePath = Join-Path $charDir "$state.png"
        if (Test-Path -LiteralPath $statePath) {
            return [System.IO.Path]::GetFullPath($statePath)
        }

        $idlePath = Join-Path $charDir 'idle.png'
        if (Test-Path -LiteralPath $idlePath) {
            return [System.IO.Path]::GetFullPath($idlePath)
        }
    }

    return $null
}

function Load-Image($state, $character) {
    $path = Get-ImagePath $state $character
    if ([string]::IsNullOrWhiteSpace($path)) { return $null }
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $src = New-Object System.Windows.Media.Imaging.BitmapImage
        $src.BeginInit()
        $src.UriSource   = [Uri]::new($path, [UriKind]::Absolute)
        $src.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $src.EndInit()
        $src.Freeze()
        return $src
    } catch { return $null }
}

function Show-SettingsWindow {
    try {
        $cfg = Get-WtPetsConfig
        $currentSize = 80
        try { $currentSize = [int]$cfg.petSize } catch {}
        if ($currentSize -lt 40) { $currentSize = 40 }
        if ($currentSize -gt 200) { $currentSize = 200 }

        $placement = Get-WtPetsPlacementConfig -DefaultSlotGap $GAP

        $settingsWindow = New-Object System.Windows.Window
        $settingsWindow.Title = 'claude-wt-pets 설정'
        $settingsWindow.Width = 340
        $settingsWindow.SizeToContent = 'Height'
        $settingsWindow.WindowStartupLocation = 'CenterScreen'
        $settingsWindow.ResizeMode = 'NoResize'
        $settingsWindow.Topmost = $true

        $stack = New-Object System.Windows.Controls.StackPanel
        $stack.Margin = [System.Windows.Thickness]::new(16)

        $labelStyle = { param($text)
            $lbl = New-Object System.Windows.Controls.TextBlock
            $lbl.Text = $text
            $lbl.FontWeight = [System.Windows.FontWeights]::Bold
            $lbl.Margin = [System.Windows.Thickness]::new(0, 10, 0, 4)
            return $lbl
        }

        # --- 크기 ---
        $stack.Children.Add((& $labelStyle '펫 크기 (전체 슬롯 공통)')) | Out-Null

        $sizePanel = New-Object System.Windows.Controls.DockPanel
        $sizePanel.Margin = [System.Windows.Thickness]::new(0, 0, 0, 4)

        $sizeLabel = New-Object System.Windows.Controls.TextBlock
        $sizeLabel.Text = [string]$currentSize
        $sizeLabel.Width = 30
        $sizeLabel.TextAlignment = 'Center'
        $sizeLabel.VerticalAlignment = 'Center'
        [System.Windows.Controls.DockPanel]::SetDock($sizeLabel, 'Right')

        $sizeSlider = New-Object System.Windows.Controls.Slider
        $sizeSlider.Minimum = 40
        $sizeSlider.Maximum = 200
        $sizeSlider.Value = $currentSize
        $sizeSlider.TickFrequency = 10
        $sizeSlider.IsSnapToTickEnabled = $true
        $sizeSlider.add_ValueChanged({
            param($s, $e)
            $sizeLabel.Text = [string][int]$sizeSlider.Value
        })

        $sizePanel.Children.Add($sizeLabel) | Out-Null
        $sizePanel.Children.Add($sizeSlider) | Out-Null
        $stack.Children.Add($sizePanel) | Out-Null

        # --- 위치 ---
        $stack.Children.Add((& $labelStyle '위치 기준점')) | Out-Null

        $anchorCombo = New-Object System.Windows.Controls.ComboBox
        $anchorCombo.Margin = [System.Windows.Thickness]::new(0, 0, 0, 4)
        $anchorOptions = @('bottom-left', 'bottom-right', 'top-left', 'top-right')
        foreach ($opt in $anchorOptions) {
            $anchorCombo.Items.Add($opt) | Out-Null
        }
        $anchorCombo.SelectedItem = $placement.anchor
        $stack.Children.Add($anchorCombo) | Out-Null

        $stack.Children.Add((& $labelStyle '배치 방향')) | Out-Null

        $dirCombo = New-Object System.Windows.Controls.ComboBox
        $dirCombo.Margin = [System.Windows.Thickness]::new(0, 0, 0, 4)
        foreach ($opt in @('right', 'left')) {
            $dirCombo.Items.Add($opt) | Out-Null
        }
        $dirCombo.SelectedItem = $placement.direction
        $stack.Children.Add($dirCombo) | Out-Null

        $makeNumberRow = { param($label, $value)
            $row = New-Object System.Windows.Controls.DockPanel
            $row.Margin = [System.Windows.Thickness]::new(0, 0, 0, 4)
            $lbl = New-Object System.Windows.Controls.TextBlock
            $lbl.Text = $label
            $lbl.Width = 100
            $lbl.VerticalAlignment = 'Center'
            [System.Windows.Controls.DockPanel]::SetDock($lbl, 'Left')
            $tb = New-Object System.Windows.Controls.TextBox
            $tb.Text = [string][int]$value
            $tb.Width = 60
            [System.Windows.Controls.DockPanel]::SetDock($tb, 'Right')
            $row.Children.Add($lbl) | Out-Null
            $row.Children.Add($tb) | Out-Null
            return @{ Panel = $row; TextBox = $tb }
        }

        $stack.Children.Add((& $labelStyle '여백 / 간격')) | Out-Null

        $oxRow = & $makeNumberRow '가로 여백 (px)' $placement.offsetX
        $stack.Children.Add($oxRow.Panel) | Out-Null

        $oyRow = & $makeNumberRow '세로 여백 (px)' $placement.offsetY
        $stack.Children.Add($oyRow.Panel) | Out-Null

        $sgRow = & $makeNumberRow '슬롯 간격 (px)' $placement.slotGap
        $stack.Children.Add($sgRow.Panel) | Out-Null

        # --- 버튼 ---
        $btnPanel = New-Object System.Windows.Controls.StackPanel
        $btnPanel.Orientation = 'Horizontal'
        $btnPanel.HorizontalAlignment = 'Right'
        $btnPanel.Margin = [System.Windows.Thickness]::new(0, 16, 0, 0)

        $saveApplyFn = {
            $newSize = [int]$sizeSlider.Value
            $newAnchor = [string]$anchorCombo.SelectedItem
            $newDir = [string]$dirCombo.SelectedItem
            $newOx = 10; try { $newOx = [int]$oxRow.TextBox.Text } catch {}
            $newOy = 10; try { $newOy = [int]$oyRow.TextBox.Text } catch {}
            $newSg = 10; try { $newSg = [int]$sgRow.TextBox.Text } catch {}

            $saveCfg = Get-WtPetsConfig
            if ($saveCfg.PSObject.Properties['petSize']) {
                $saveCfg.petSize = $newSize
            } else {
                $saveCfg | Add-Member -NotePropertyName petSize -NotePropertyValue $newSize
            }
            $saveCfg.placement.anchor = $newAnchor
            $saveCfg.placement.direction = $newDir
            $saveCfg.placement.offsetX = $newOx
            $saveCfg.placement.offsetY = $newOy
            $saveCfg.placement.slotGap = $newSg

            Save-WtPetsConfig $saveCfg
            Write-TransitionLog 'settings-saved' $script:lastState $script:lastTs "size=$newSize;anchor=$newAnchor;direction=$newDir"

            $settingsWindow.Close()

            # 이 pet은 즉시 반영하고, 다른 slot pet은 각자 layoutTimer가 config 변경을 감지해 반영한다.
            Sync-LayoutFromConfig
        }

        $btnSave = New-Object System.Windows.Controls.Button
        $btnSave.Content = '저장 (전체 펫 즉시 적용)'
        $btnSave.Padding = [System.Windows.Thickness]::new(12, 6, 12, 6)
        $btnSave.add_Click({ & $saveApplyFn })
        $btnPanel.Children.Add($btnSave) | Out-Null

        $stack.Children.Add($btnPanel) | Out-Null

        $settingsWindow.Content = $stack
        $script:settingsOpen = $true
        try {
            $settingsWindow.ShowDialog() | Out-Null
        } finally {
            $script:settingsOpen = $false
        }
    } catch {
        Write-TransitionLog 'settings-window-error' $script:lastState $script:lastTs (Get-ErrorDetail $_)
    }
}

function Reset-ToIdle {
    $image.Source = Load-Image 'idle' $script:character
    $script:lastState = 'idle'
    $savedTs = Save-CurrentState 'idle' $script:character
    if ($null -ne $savedTs) {
        $script:lastTs = [Int64]$savedTs
    }
    $script:isSleepingOverride = $false
    $script:sleepBaseTs = 0
    $script:lastIgnoredSleepTs = 0
    $script:disconnectedReturnState = ''
    $script:disconnectedReturnTs = 0
    Write-TransitionLog 'manual-reset' 'idle' $script:lastTs
    Restart-SleepTimer
}

$script:character = Get-CharacterFromCurrentState
if ([string]::IsNullOrWhiteSpace($script:character)) {
    $script:character = Get-WtPetsCharacterForSlot -Slot $Slot
}
Write-TransitionLog 'pet-start' 'idle' 0

$window = New-Object System.Windows.Window
$window.WindowStyle        = 'None'
$window.AllowsTransparency = $true
$window.Background         = [System.Windows.Media.Brushes]::Transparent
$window.Topmost            = $true
$window.ShowInTaskbar      = $false
$window.Width              = $script:petSize
$window.Height             = $script:petSize
$initialPlacement          = Get-WtPetsPlacementConfig -DefaultSlotGap $GAP
$script:layoutSignature    = Get-LayoutSignature $script:petSize $initialPlacement
$initialPosition           = Get-InitialPosition $Slot $initialPlacement
$window.Left               = $initialPosition.Left
$window.Top                = $initialPosition.Top
$window.ResizeMode         = 'NoResize'
$window.add_SourceInitialized({ Hide-WindowFromAltTab })

$image         = New-Object System.Windows.Controls.Image
$image.Width   = $script:petSize
$image.Height  = $script:petSize
$image.Stretch = [System.Windows.Media.Stretch]::Uniform
$image.Source  = Load-Image 'idle' $script:character

$window.add_MouseLeftButtonDown({
    param($sender, $eventArgs)
    if (([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control) -ne 0) {
        Focus-OwnerWindow
        $eventArgs.Handled = $true
        return
    }
    $window.DragMove()
})
$window.add_MouseDoubleClick({
    param($sender, $eventArgs)
    if ($eventArgs.ChangedButton -eq [System.Windows.Input.MouseButton]::Left) {
        Reset-ToIdle
        $eventArgs.Handled = $true
    }
})
$window.add_MouseRightButtonDown({
    $menu = New-Object System.Windows.Controls.ContextMenu

    $idleItem = New-Object System.Windows.Controls.MenuItem
    $idleItem.Header = '기본 상태로 돌리기'
    $idleItem.add_Click({ Reset-ToIdle })
    $menu.Items.Add($idleItem) | Out-Null

    $focusItem = New-Object System.Windows.Controls.MenuItem
    $focusItem.Header = '터미널 창 앞으로 가져오기 (탭 선택 안 됨)'
    $focusItem.ToolTip = 'Windows Terminal의 top-level 창만 앞으로 가져오며 내부 탭은 선택하지 않습니다.'
    $focusItem.add_Click({ Focus-OwnerWindow })
    $menu.Items.Add($focusItem) | Out-Null

    $separator = New-Object System.Windows.Controls.Separator
    $menu.Items.Add($separator) | Out-Null

    $characterMenu = New-Object System.Windows.Controls.MenuItem
    $characterMenu.Header = '캐릭터'
    foreach ($characterName in Get-WtPetsAvailableCharacters -SlotFirst) {
        $characterItem = New-Object System.Windows.Controls.MenuItem
        $characterItem.Header = $characterName
        $characterItem.Tag = $characterName
        $characterItem.IsCheckable = $true
        $characterItem.IsChecked = $characterName -eq $script:character
        $characterItem.add_Click({
            param($sender, $eventArgs)
            $selectedCharacter = [string]$sender.Tag
            if (-not (Test-WtPetsCharacterName $selectedCharacter)) { return }

            $script:character = $selectedCharacter
            $image.Source = Load-Image $script:lastState $script:character
            $savedTs = Save-CurrentState $script:lastState $script:character
            if ($null -ne $savedTs) {
                $script:lastTs = [Int64]$savedTs
            }

            $cfg = Get-WtPetsConfig
            $sk = [string]$Slot
            if ($cfg.slotCharacters.PSObject.Properties[$sk]) {
                $cfg.slotCharacters.PSObject.Properties[$sk].Value = $selectedCharacter
            } else {
                $cfg.slotCharacters | Add-Member -MemberType NoteProperty -Name $sk -Value $selectedCharacter
            }
            Save-WtPetsConfig $cfg

            Write-TransitionLog 'character-change' $script:lastState $script:lastTs "character=$($script:character)"
            Restart-SleepTimer
        })
        $characterMenu.Items.Add($characterItem) | Out-Null
    }
    $menu.Items.Add($characterMenu) | Out-Null

    $settingsItem = New-Object System.Windows.Controls.MenuItem
    $settingsItem.Header = '설정'
    $settingsItem.add_Click({ Show-SettingsWindow })
    $menu.Items.Add($settingsItem) | Out-Null

    $separator2 = New-Object System.Windows.Controls.Separator
    $menu.Items.Add($separator2) | Out-Null

    $item = New-Object System.Windows.Controls.MenuItem
    $item.Header = '종료'
    $item.add_Click({
        Set-PetCloseReason 'manual-menu-exit'
        $window.Close()
    })
    $menu.Items.Add($item) | Out-Null
    $menu.IsOpen = $true
})

$window.Content = $image

$window.add_Loaded({
    Refresh-OwnerFromState
    if ($script:ownerHwnd -gt 0 -and (Test-OwnerSourcePersistable $script:ownerSource)) {
        Sync-OwnerMapFromCurrentOwner $script:ownerSource
    }

    $script:sleepTimer          = New-Object System.Windows.Threading.DispatcherTimer
    $script:sleepTimer.Interval = [TimeSpan]::FromSeconds($SLEEP_AFTER_SECONDS)
    $script:sleepTimer.add_Tick({
        $script:sleepTimer.Stop()
        if ($script:lastState -ne 'idle') {
            Write-TransitionLog 'sleep-skip-active-state' $script:lastState $script:lastTs
            $script:sleepTimer.Start()
            return
        }
        $image.Source = Load-Image 'sleeping' $script:character
        $script:lastState = 'sleeping'
        $script:isSleepingOverride = $true
        $script:sleepBaseTs = $script:lastTs
        $script:lastIgnoredSleepTs = 0
        Write-TransitionLog 'sleep-timer' 'sleeping' $script:sleepBaseTs
    })
    $script:sleepTimer.Start()

    $script:pollTimer          = New-Object System.Windows.Threading.DispatcherTimer
    $script:pollTimer.Interval = [TimeSpan]::FromMilliseconds($POLL_INTERVAL_MS)
    $script:pollTimer.add_Tick({
        try {
            $data = Read-JsonCached $STATE_FILE
            if (-not $data) { return }
            $incomingTs = [Int64]$data.ts
            if ($data.PSObject.Properties['session_id'] -and -not [string]::IsNullOrWhiteSpace([string]$data.session_id)) {
                $incomingSessionId = [string]$data.session_id
                if (-not [string]::IsNullOrWhiteSpace($script:sessionId) -and $incomingSessionId -ne $script:sessionId) {
                    Write-TransitionLog 'session-id-changed-close' $script:lastState $script:lastTs "previous=$($script:sessionId);new=$incomingSessionId"
                    $script:sessionChanged = $true
                    Set-PetCloseReason 'session-id-changed' "previous=$($script:sessionId);new=$incomingSessionId"
                    $window.Close()
                    return
                }
            }
            Refresh-OwnerFromState
            $incomingCharacter = $script:character
            if ($data.character) {
                $incomingCharacter = Resolve-CharacterName ([string]$data.character)
            }
            $characterChanged = $incomingCharacter -ne $script:character
            $st = $data.state
            if (-not $VALID_STATES.ContainsKey($st)) {
                $script:lastTs = $incomingTs
                return
            }
            if ($incomingTs -lt $script:lastTs) { return }
            if ($st -eq 'disconnected') {
                try {
                    if ($data.PSObject.Properties['previous_state']) {
                        $previousState = [string]$data.previous_state
                        if (
                            -not [string]::IsNullOrWhiteSpace($previousState) -and
                            $previousState -ne 'disconnected' -and
                            $VALID_STATES.ContainsKey($previousState)
                        ) {
                            $script:disconnectedReturnState = $previousState
                        }
                    }
                    if ($data.PSObject.Properties['previous_ts']) {
                        try { $script:disconnectedReturnTs = [Int64]$data.previous_ts } catch {}
                    }
                } catch {}
            } else {
                $script:disconnectedReturnState = ''
                $script:disconnectedReturnTs = 0
            }
            if ($script:isSleepingOverride -and $incomingTs -le $script:sleepBaseTs) {
                if ($characterChanged) {
                    $script:character = $incomingCharacter
                    $image.Source = Load-Image 'sleeping' $script:character
                    Write-TransitionLog 'sleep-character-change' 'sleeping' $incomingTs
                }
                if ($script:lastIgnoredSleepTs -ne $incomingTs) {
                    $script:lastIgnoredSleepTs = $incomingTs
                    Write-TransitionLog 'ignore-stale-state-while-sleeping' $st $incomingTs
                }
                return
            }
            if ($script:isSleepingOverride) {
                $script:isSleepingOverride = $false
                $script:sleepBaseTs = 0
                $script:lastIgnoredSleepTs = 0
                Write-TransitionLog 'wake-new-state' $st $incomingTs
            }
            if ($incomingTs -eq $script:lastTs -and $st -eq $script:lastState -and -not $characterChanged) { return }
            $script:character = $incomingCharacter
            $script:lastTs = $incomingTs
            if ($st -ne $script:lastState -or $characterChanged) {
                $script:lastState = $st
                $image.Source = Load-Image $st $script:character
                Write-TransitionLog 'poll-state-change' $st $incomingTs
            }
            Restart-SleepTimer
        } catch {
            Write-TransitionLog 'poll-timer-error' $script:lastState $script:lastTs (Get-ErrorDetail $_)
        }
    })
    $script:pollTimer.Start()

    $script:topmostTimer          = New-Object System.Windows.Threading.DispatcherTimer
    $script:topmostTimer.Interval = [TimeSpan]::FromSeconds($KEEP_TOPMOST_SECONDS)
    $script:topmostTimer.add_Tick({
        try {
            Ensure-PidFile
            if (-not $window.Topmost) {
                $window.Topmost = $true
            } else {
                $window.Topmost = $false
                $window.Topmost = $true
            }
            $memBytes = [GC]::GetTotalMemory($false)
            if ($memBytes -gt $MEMORY_LIMIT_BYTES) {
                Write-TransitionLog 'memory-watchdog-restart' $script:lastState $script:lastTs "mem_mb=$([Math]::Round($memBytes / 1048576, 1))"
                $script:isRestarting = $true
                $petScript = Join-Path $PSScriptRoot 'pet.ps1'
                $powerShellExe = Join-Path $PSHOME 'powershell.exe'
                $launchArgs = @('-NoProfile', '-WindowStyle', 'Hidden', '-STA', '-ExecutionPolicy', 'RemoteSigned', '-File', "`"$petScript`"", '-Slot', [string]$Slot)
                try {
                    $restartShell = New-Object -ComObject Shell.Application
                    $restartShell.ShellExecute($powerShellExe, ($launchArgs -join ' '), '', 'open', 0)
                } catch {}
                Set-PetCloseReason 'memory-watchdog-restart' "mem_mb=$([Math]::Round($memBytes / 1048576, 1))"
                $window.Close()
                return
            }
        } catch {
            Write-TransitionLog 'topmost-timer-error' $script:lastState $script:lastTs (Get-ErrorDetail $_)
        }
    })
    $script:topmostTimer.Start()

    $script:layoutTimer          = New-Object System.Windows.Threading.DispatcherTimer
    $script:layoutTimer.Interval = [TimeSpan]::FromMilliseconds($POLL_INTERVAL_MS)
    $script:layoutTimer.add_Tick({ Sync-LayoutFromConfig })
    $script:layoutTimer.Start()

    $script:ownerTimer          = New-Object System.Windows.Threading.DispatcherTimer
    $script:ownerTimer.Interval = [TimeSpan]::FromSeconds($OWNER_CHECK_SECONDS)
    $script:ownerTimer.add_Tick({
        try {
        if ($script:settingsOpen) { return }

        if ($script:ownerPid -le 0) {
            Refresh-OwnerFromState
        }
        if ($script:ownerHwnd -le 0) {
            Refresh-OwnerFromState
        }
        if ($script:sessionPid -le 0) {
            Refresh-OwnerFromState
        }
        if ($script:sessionPid -le 0) {
            if (Test-SessionProcessAliveFromStateFile) {
                Write-TransitionLog 'session-pid-recovered-from-state' $script:lastState $script:lastTs (Get-AnchorDetail "recovered_pid=$($script:sessionPid)")
                return
            }
            if (Test-MissingSessionGraceActive 'no-session-pid-wait' 'no-session-pid-close-grace-expired') {
                return
            }
            Write-TransitionLog 'no-session-pid-close' $script:lastState $script:lastTs (Get-AnchorDetail 'missing=session_pid')
            Set-PetCloseReason 'no-session-pid-close' 'missing=session_pid'
            $window.Close()
            return
        }
        if ($script:sessionPid -gt 0) {
            try {
                $session = Get-Process -Id $script:sessionPid -ErrorAction SilentlyContinue
                if ($session -and $session.ProcessName -ne 'claude') {
                    Write-TransitionLog 'session-pid-reused' $script:lastState $script:lastTs (Get-AnchorDetail "expected=claude;actual=$($session.ProcessName)")
                    $session = $null
                }
                if (-not $session) {
                    if (Test-OwnerWindowAlive) {
                        if (Test-MissingSessionGraceActive 'session-process-gone-wait-owner-window' 'session-process-gone-close-grace-expired') {
                            return
                        }
                        Set-PetCloseReason 'session-process-gone-close-grace-expired' 'missing=session;owner_hwnd_alive=true'
                        $window.Close()
                        return
                    }
                    Write-TransitionLog 'session-process-gone-close' $script:lastState $script:lastTs (Get-AnchorDetail 'missing=session;owner_hwnd_alive=false')
                    Set-PetCloseReason 'session-process-gone-close' 'missing=session;owner_hwnd_alive=false'
                    $window.Close()
                    return
                }
                $script:sessionGoneSince = 0
                $script:sessionGoneStateTs = 0
            } catch {
                if (Test-OwnerWindowAlive) {
                    if (Test-MissingSessionGraceActive 'session-process-check-error-wait-owner-window' 'session-process-check-error-close-grace-expired' ("error=" + (Get-ErrorDetail $_))) {
                        return
                    }
                    Set-PetCloseReason 'session-process-check-error-close-grace-expired' ("owner_hwnd_alive=true;error=" + (Get-ErrorDetail $_))
                    $window.Close()
                    return
                }
                Write-TransitionLog 'session-process-check-error-close' $script:lastState $script:lastTs (Get-AnchorDetail ("missing=session;owner_hwnd_alive=false;error=" + (Get-ErrorDetail $_)))
                Set-PetCloseReason 'session-process-check-error-close' ("missing=session;owner_hwnd_alive=false;error=" + (Get-ErrorDetail $_))
                $window.Close()
                return
            }
        }
        if ($script:ownerHwnd -gt 0) {
            try {
                Ensure-WindowFocusType
                $hwnd = [IntPtr]::new([Int64]$script:ownerHwnd)
                if (-not [ClaudeWtPets.WindowFocus]::IsWindow($hwnd)) {
                    $script:staleOwnerHwnd = [Int64]$script:ownerHwnd
                    $script:ownerHwnd = 0
                    if ($script:sessionPid -gt 0 -or (Test-OwnerProcessAlive)) {
                        Write-TransitionLog 'owner-window-gone-wait-anchor' $script:lastState $script:lastTs (Get-AnchorDetail 'missing=owner_hwnd')
                        return
                    }
                    Write-TransitionLog 'owner-window-gone-close' $script:lastState $script:lastTs (Get-AnchorDetail 'missing=owner_hwnd;session_pid=0;owner_pid_alive=false')
                    Set-PetCloseReason 'owner-window-gone-close' 'missing=owner_hwnd;session_pid=0;owner_pid_alive=false'
                    $window.Close()
                    return
                }
            } catch {
                Write-TransitionLog 'owner-window-check-error' $script:lastState $script:lastTs (Get-ErrorDetail $_)
            }
        }
        if ($script:ownerPid -gt 0) {
            try {
                $owner = Get-Process -Id $script:ownerPid -ErrorAction SilentlyContinue
                if ($owner -and $owner.ProcessName -ne 'WindowsTerminal') {
                    Write-TransitionLog 'owner-pid-reused' $script:lastState $script:lastTs (Get-AnchorDetail "expected=WindowsTerminal;actual=$($owner.ProcessName)")
                    $owner = $null
                }
                if (-not $owner) {
                    if ($script:sessionPid -gt 0 -or (Test-OwnerWindowAlive)) {
                        $script:staleOwnerPid = [Int32]$script:ownerPid
                        $script:ownerPid = 0
                        Write-TransitionLog 'owner-process-gone-wait-anchor' $script:lastState $script:lastTs (Get-AnchorDetail 'missing=owner_pid')
                        return
                    }
                    Write-TransitionLog 'owner-process-gone-close' $script:lastState $script:lastTs (Get-AnchorDetail 'missing=owner_pid;session_pid=0;owner_hwnd_alive=false')
                    Set-PetCloseReason 'owner-process-gone-close' 'missing=owner_pid;session_pid=0;owner_hwnd_alive=false'
                    $window.Close()
                    return
                }
            } catch {
                if ($script:sessionPid -gt 0 -or (Test-OwnerWindowAlive)) {
                    $script:staleOwnerPid = [Int32]$script:ownerPid
                    $script:ownerPid = 0
                    Write-TransitionLog 'owner-process-check-error-wait-anchor' $script:lastState $script:lastTs (Get-AnchorDetail ("missing=owner_pid;error=" + (Get-ErrorDetail $_)))
                    return
                }
                Write-TransitionLog 'owner-process-check-error-close' $script:lastState $script:lastTs (Get-AnchorDetail ("missing=owner_pid;session_pid=0;owner_hwnd_alive=false;error=" + (Get-ErrorDetail $_)))
                Set-PetCloseReason 'owner-process-check-error-close' ("missing=owner_pid;session_pid=0;owner_hwnd_alive=false;error=" + (Get-ErrorDetail $_))
                $window.Close()
                return
            }
        } else {
            Refresh-OwnerFromState
        }
        } catch {
            Write-TransitionLog 'owner-timer-error' $script:lastState $script:lastTs (Get-ErrorDetail $_)
        }
    })
    $script:ownerTimer.Start()
})

$window.add_Closed({
    Write-TransitionLog 'pet-closed' $script:lastState $script:lastTs (Get-PetCleanupDetail)
    if ($script:pollTimer)  { $script:pollTimer.Stop() }
    if ($script:sleepTimer) { $script:sleepTimer.Stop() }
    if ($script:topmostTimer) { $script:topmostTimer.Stop() }
    if ($script:ownerTimer) { $script:ownerTimer.Stop() }
    if ($script:layoutTimer) { $script:layoutTimer.Stop() }
    Write-TransitionLog 'pet-cleanup-start' $script:lastState $script:lastTs (Get-PetCleanupDetail)

    $liveSessionStateSkipReason = Get-LiveSessionCloseStateSkipReason
    $removeState = -not $script:isRestarting -and -not $script:sessionChanged -and [string]::IsNullOrWhiteSpace($liveSessionStateSkipReason)
    $stateSkipReason = ''
    if (-not $removeState) {
        if ($script:isRestarting) { $stateSkipReason = 'restart' }
        elseif ($script:sessionChanged) { $stateSkipReason = 'session-changed' }
        else { $stateSkipReason = $liveSessionStateSkipReason }
    }
    Remove-PetRuntimeFile 'state' $STATE_FILE $removeState $stateSkipReason

    $removePid = -not $script:sessionChanged
    $pidSkipReason = ''
    if (-not $removePid) { $pidSkipReason = 'session-changed' }
    Remove-PetRuntimeFile 'pid' $PID_FILE $removePid $pidSkipReason

    Write-TransitionLog 'pet-cleanup-finished' $script:lastState $script:lastTs (Get-PetCleanupDetail)
    try { $script:mutex.ReleaseMutex() } catch {}
    try { $script:mutex.Dispose() } catch {}
})

$app = New-Object System.Windows.Application
$app.add_DispatcherUnhandledException({
    param($sender, $e)
    try {
        Write-TransitionLog 'dispatcher-unhandled-exception' $script:lastState $script:lastTs ("error=" + [string]$e.Exception.Message)
    } catch {}
    $e.Handled = $true
})
$app.Run($window) | Out-Null
