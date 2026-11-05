param(
    [string]$NodeExe = (Get-Command node -ErrorAction SilentlyContinue).Source
)

$ErrorActionPreference = 'Stop'
$script:passed = 0
$script:failed = 0

$NOTIFIER = Join-Path $PSScriptRoot '..\notifier.js'
$script:realTemp = $env:TEMP
$TEMP_ROOT = Join-Path $script:realTemp "claude-wt-pets-test-notifier-$([guid]::NewGuid().ToString('N').Substring(0,8))"

function New-TestEnv {
    if (Test-Path $TEMP_ROOT) { Remove-Item $TEMP_ROOT -Recurse -Force }
    New-Item -ItemType Directory -Path $TEMP_ROOT -Force | Out-Null
    $env:TEMP = $TEMP_ROOT
    $env:TMP = $TEMP_ROOT
    $env:CLAUDE_WT_PETS_OWNER_PROBE = ''
    $env:CLAUDE_WT_PETS_SESSION_PID = ''
    $env:CLAUDE_WT_PETS_SESSION_NAME = ''
    $env:CLAUDE_WT_PETS_SESSION_ID = ''
    $env:CLAUDE_WT_PETS_SESSION_PARENT_PID = ''
}

function Restore-TestEnv {
    $env:TEMP = $script:realTemp
    $env:TMP = $script:realTemp
}

function Invoke-Notifier([string]$HookName, [hashtable]$Event = @{}, [string]$SessionPid = '') {
    $env:CLAUDE_WT_PETS_SESSION_PID = $SessionPid
    $env:CLAUDE_WT_PETS_SESSION_ID = ''
    $json = $Event | ConvertTo-Json -Compress -Depth 5
    $output = $json | & $NodeExe $NOTIFIER $HookName 2>&1
}

function Get-Registry {
    $regFile = Join-Path $TEMP_ROOT 'claude-wt-pets-registry.json'
    if (Test-Path $regFile) {
        return (Get-Content $regFile -Raw -Encoding UTF8 | ConvertFrom-Json)
    }
    return $null
}

function Get-State([int]$Slot) {
    $sf = Join-Path $TEMP_ROOT "claude-wt-pets-state-$Slot.json"
    if (Test-Path $sf) {
        return (Get-Content $sf -Raw -Encoding UTF8 | ConvertFrom-Json)
    }
    return $null
}

function Get-OwnerMap {
    $mapFile = Join-Path $TEMP_ROOT 'claude-wt-pets-owner-map.json'
    if (Test-Path $mapFile) {
        return (Get-Content $mapFile -Raw -Encoding UTF8 | ConvertFrom-Json)
    }
    return $null
}

function Set-OwnerProbe([int]$MatchedHwnd, [int]$WindowPid, [string]$Title = 'Claude Code') {
    $env:CLAUDE_WT_PETS_OWNER_PROBE = (@{
        foreground_hwnd = 0
        foreground_pid = 0
        foreground_name = ''
        matched_hwnd = $MatchedHwnd
        tab_title = $Title
        visible_windows = @(
            @{
                hwnd = $MatchedHwnd
                pid = $WindowPid
                left = 0
                top = 0
                title = $Title
            }
        )
    } | ConvertTo-Json -Compress -Depth 5)
}

function Set-VisibleOwnerProbe([int]$Hwnd, [int]$WindowPid, [string]$Title) {
    $env:CLAUDE_WT_PETS_OWNER_PROBE = (@{
        foreground_hwnd = 0
        foreground_pid = 0
        foreground_name = ''
        matched_hwnd = 0
        tab_title = $Title
        visible_windows = @(
            @{
                hwnd = $Hwnd
                pid = $WindowPid
                left = 0
                top = 0
                title = $Title
            }
        )
    } | ConvertTo-Json -Compress -Depth 5)
}

function Set-ForegroundOwnerProbe([int]$Hwnd, [int]$WindowPid, [string]$Title) {
    $env:CLAUDE_WT_PETS_OWNER_PROBE = (@{
        foreground_hwnd = $Hwnd
        foreground_pid = $WindowPid
        foreground_name = 'WindowsTerminal'
        matched_hwnd = 0
        tab_title = $Title
        visible_windows = @(
            @{
                hwnd = $Hwnd
                pid = $WindowPid
                left = 0
                top = 0
                title = $Title
            }
        )
    } | ConvertTo-Json -Compress -Depth 5)
}

function Clear-OwnerFromRegistry([string]$SessionId) {
    $regFile = Join-Path $TEMP_ROOT 'claude-wt-pets-registry.json'
    $reg = Get-Content $regFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $entry = $reg.PSObject.Properties[$SessionId].Value
    if ($entry.PSObject.Properties['owner_hwnd']) { $entry.PSObject.Properties.Remove('owner_hwnd') }
    if ($entry.PSObject.Properties['owner_source']) { $entry.owner_source = '' }
    if ($entry.PSObject.Properties['window_title']) { $entry.PSObject.Properties.Remove('window_title') }
    $json = $reg | ConvertTo-Json -Compress -Depth 10
    Set-Content -LiteralPath $regFile -Encoding UTF8 -Value $json
}

function Assert-True([string]$Name, [bool]$Condition) {
    if ($Condition) {
        Write-Host "  PASS: $Name" -ForegroundColor Green
        $script:passed++
    } else {
        Write-Host "  FAIL: $Name" -ForegroundColor Red
        $script:failed++
    }
}

function Get-FakeDeadPid {
    for ($p = 59000; $p -lt 60000; $p++) {
        if (-not (Get-Process -Id $p -ErrorAction SilentlyContinue)) { return $p }
    }
    return 59999
}

function Test-StateHasOwner($State) {
    if (-not $State) { return $false }
    if (-not $State.PSObject.Properties['owner_hwnd']) { return $false }
    try { return ([Int64]$State.owner_hwnd -gt 0) } catch { return $false }
}

# --- Test 1: stale state rewrite ---
Write-Host "`nTest 1: stale state rewrite" -ForegroundColor Cyan
New-TestEnv

$oldSid = "old-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$newSid = "new-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$deadPid = [string](Get-FakeDeadPid)

Invoke-Notifier 'SessionStart' @{ session_id = $oldSid } -SessionPid $deadPid
$state1 = Get-State 1
Assert-True 'old session creates state' ($null -ne $state1)

Invoke-Notifier 'SessionStart' @{ session_id = $newSid } -SessionPid $deadPid
$reg = Get-Registry
$regHasNew = $false
if ($reg) { $regHasNew = [bool]$reg.PSObject.Properties[$newSid] }
Assert-True 'new session replaces stale' $regHasNew

$state1After = Get-State 1
if ($state1After) {
    Assert-True 'state session_id updated' ($state1After.session_id -eq $newSid)
}

# --- Test 2: same session skip ---
Write-Host "`nTest 2: same session skip" -ForegroundColor Cyan
New-TestEnv

$sid = "same-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$alivePid = [string]$PID

Invoke-Notifier 'SessionStart' @{ session_id = $sid } -SessionPid $alivePid
$state1 = Get-State 1
$ts1 = 0
if ($state1 -and $state1.PSObject.Properties['ts']) { $ts1 = [Int64]$state1.ts }

Start-Sleep -Milliseconds 200
Invoke-Notifier 'SessionStart' @{ session_id = $sid } -SessionPid $alivePid
$state1After = Get-State 1
$ts2 = 0
if ($state1After -and $state1After.PSObject.Properties['ts']) { $ts2 = [Int64]$state1After.ts }

Assert-True 'same session_id skips state rewrite' ($ts1 -eq $ts2)

# --- Test 3: fifth session ignored ---
Write-Host "`nTest 3: fifth session ignored" -ForegroundColor Cyan
New-TestEnv

$alivePid = [string]$PID
$sids = @()
for ($i = 1; $i -le 5; $i++) {
    $sids += "s$i-$([guid]::NewGuid().ToString('N').Substring(0,8))"
}

for ($i = 0; $i -lt 4; $i++) {
    Invoke-Notifier 'SessionStart' @{ session_id = $sids[$i] } -SessionPid $alivePid
}

Invoke-Notifier 'SessionStart' @{ session_id = $sids[4] } -SessionPid $alivePid

$reg = Get-Registry
$fifthInReg = $false
if ($reg) { $fifthInReg = [bool]$reg.PSObject.Properties[$sids[4]] }
Assert-True 'fifth session not in registry' (-not $fifthInReg)

# --- Test 4: slot override priority ---
Write-Host "`nTest 4: slot override priority" -ForegroundColor Cyan
New-TestEnv

$sid = "prio-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$deadPid4 = [string](Get-FakeDeadPid)
Invoke-Notifier 'SessionStart' @{ session_id = $sid } -SessionPid $deadPid4

$reg = Get-Registry
$entry = $null
if ($reg -and $reg.PSObject.Properties[$sid]) { $entry = $reg.$sid }
Assert-True 'session gets slot 1' ($null -ne $entry -and [int]$entry.slot -eq 1)
Assert-True 'character is assigned' ($null -ne $entry -and -not [string]::IsNullOrWhiteSpace([string]$entry.character))

# --- Test 5: shared owner source stays volatile ---
Write-Host "`nTest 5: shared owner source stays volatile" -ForegroundColor Cyan
New-TestEnv

$alivePid = [string]$PID
$ownerPid = 4242
$sharedHwnd = 123456
$sid1 = "shared-a-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$sid2 = "shared-b-$([guid]::NewGuid().ToString('N').Substring(0,8))"

Set-OwnerProbe -MatchedHwnd $sharedHwnd -WindowPid $ownerPid
Invoke-Notifier 'SessionStart' @{ session_id = $sid1 } -SessionPid $alivePid
$state1 = Get-State 1
Assert-True 'first matched owner is direct' ($null -ne $state1 -and $state1.owner_source -eq 'title-match')

$ownerMap1 = Get-OwnerMap
$sid1InOwnerMap = $false
if ($ownerMap1 -and $ownerMap1.sessions) {
    $sid1InOwnerMap = [bool]$ownerMap1.sessions.PSObject.Properties[$sid1]
}
Assert-True 'direct owner is saved to owner map' $sid1InOwnerMap
Assert-True 'owner map records pet and window names' (
    $sid1InOwnerMap -and
    -not [string]::IsNullOrWhiteSpace([string]$ownerMap1.sessions.PSObject.Properties[$sid1].Value.pet_name) -and
    [string]$ownerMap1.sessions.PSObject.Properties[$sid1].Value.window_title -eq 'Claude Code'
)

Set-OwnerProbe -MatchedHwnd $sharedHwnd -WindowPid $ownerPid
Invoke-Notifier 'SessionStart' @{ session_id = $sid2 } -SessionPid $alivePid
$state2 = Get-State 2
Assert-True 'used matched owner becomes shared' ($null -ne $state2 -and $state2.owner_source -eq 'session-marker-shared')

$ownerMap2 = Get-OwnerMap
$sid2InOwnerMap = $false
if ($ownerMap2 -and $ownerMap2.sessions) {
    $sid2InOwnerMap = [bool]$ownerMap2.sessions.PSObject.Properties[$sid2]
}
Assert-True 'shared owner is not saved to owner map' (-not $sid2InOwnerMap)

# --- Test 6: owner map title change on same hwnd updates stored title ---
Write-Host "`nTest 6: owner map title change on same hwnd updates stored title" -ForegroundColor Cyan
New-TestEnv

$alivePid = [string]$PID
$ownerPid = 4343
$ownerHwnd = 223344
$sid = "title-guard-$([guid]::NewGuid().ToString('N').Substring(0,8))"

Set-OwnerProbe -MatchedHwnd $ownerHwnd -WindowPid $ownerPid -Title 'Claude #3'
Invoke-Notifier 'SessionStart' @{ session_id = $sid } -SessionPid $alivePid
Clear-OwnerFromRegistry $sid

Set-VisibleOwnerProbe -Hwnd $ownerHwnd -WindowPid $ownerPid -Title 'Claude #2'
Invoke-Notifier 'UserPromptSubmit' @{ session_id = $sid } -SessionPid $alivePid
$guardedState = Get-State 1

Assert-True 'title change on same hwnd updates stored title and restores owner' (
    $null -ne $guardedState -and
    $guardedState.owner_hwnd -eq $ownerHwnd -and
    [string]$guardedState.window_title -eq 'Claude #2'
)

# --- Test 7: untrusted probe does not assign owner ---
Write-Host "`nTest 7: untrusted probe does not assign owner" -ForegroundColor Cyan
New-TestEnv

$alivePid = [string]$PID
$ownerPid = 4444
$foregroundHwnd = 334455
$sid = "foreground-block-$([guid]::NewGuid().ToString('N').Substring(0,8))"

Set-ForegroundOwnerProbe -Hwnd $foregroundHwnd -WindowPid $ownerPid -Title 'Foreground Claude'
Invoke-Notifier 'SessionStart' @{ session_id = $sid } -SessionPid $alivePid
$foregroundState = Get-State 1
Assert-True 'foreground probe is not used as owner' (-not (Test-StateHasOwner $foregroundState))

New-TestEnv
$unusedHwnd = 445566
$sid = "unused-block-$([guid]::NewGuid().ToString('N').Substring(0,8))"

Set-VisibleOwnerProbe -Hwnd $unusedHwnd -WindowPid $ownerPid -Title 'Only Visible Claude'
Invoke-Notifier 'SessionStart' @{ session_id = $sid } -SessionPid $alivePid
$unusedState = Get-State 1
Assert-True 'single unused visible window is not used as owner' (-not (Test-StateHasOwner $unusedState))

# --- Test 8: live session missing runtime files is kept ---
Write-Host "`nTest 8: live session missing runtime files is kept" -ForegroundColor Cyan
New-TestEnv

$alivePid = [string]$PID
$sid1 = "live-runtime-a-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$sid2 = "live-runtime-b-$([guid]::NewGuid().ToString('N').Substring(0,8))"

Invoke-Notifier 'SessionStart' @{ session_id = $sid1 } -SessionPid $alivePid
Remove-Item -LiteralPath (Join-Path $TEMP_ROOT 'claude-wt-pets-state-1.json') -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $TEMP_ROOT 'claude-wt-pets-pet-1.pid') -Force -ErrorAction SilentlyContinue

Invoke-Notifier 'SessionStart' @{ session_id = $sid2 } -SessionPid $alivePid
$reg = Get-Registry
$sid1Kept = $false
$sid2Added = $false
if ($reg) {
    $sid1Kept = [bool]$reg.PSObject.Properties[$sid1]
    $sid2Added = [bool]$reg.PSObject.Properties[$sid2]
}
Assert-True 'live session remains in registry even when runtime files are missing' $sid1Kept
Assert-True 'new session uses another slot instead of deleting live session' $sid2Added

# --- Cleanup ---
Restore-TestEnv
try { Remove-Item $TEMP_ROOT -Recurse -Force -ErrorAction SilentlyContinue } catch {}

# --- Summary ---
Write-Host "`n--- Results ---" -ForegroundColor White
Write-Host "Passed: $script:passed" -ForegroundColor Green
if ($script:failed -gt 0) {
    Write-Host "Failed: $script:failed" -ForegroundColor Red
    exit 1
} else {
    Write-Host "All tests passed." -ForegroundColor Green
    exit 0
}
