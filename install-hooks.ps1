param(
    [ValidateSet('user', 'project', 'both')]
    [string]$Scope = 'user',

    [switch]$Audit,

    # user/project 양쪽 settings에서 claude-wt-pets hook을 모두 제거한다. -Scope는 무시한다.
    # -Audit과 함께 쓰면 양쪽 모두 hook이 없는지 검사한다.
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

$HOOK_ENTRY = Join-Path $PSScriptRoot 'hook-entry.ps1'
$USER_SETTINGS = Join-Path $env:USERPROFILE '.claude\settings.json'
$PROJECT_SETTINGS = Join-Path $PSScriptRoot '.claude\settings.local.json'

$EVENTS = @(
    [pscustomobject]@{ Name = 'SessionStart';       Timeout = 5 },
    [pscustomobject]@{ Name = 'UserPromptSubmit';   Timeout = 3 },
    [pscustomobject]@{ Name = 'PreToolUse';         Timeout = 3 },
    [pscustomobject]@{ Name = 'PostToolUse';        Timeout = 3 },
    [pscustomobject]@{ Name = 'Stop';               Timeout = 3 },
    [pscustomobject]@{ Name = 'StopFailure';        Timeout = 3 },
    [pscustomobject]@{ Name = 'PostToolUseFailure'; Timeout = 3 },
    [pscustomobject]@{ Name = 'Notification';       Timeout = 8 }
)

function As-Array($value) {
    if ($null -eq $value) { return @() }
    if ($value -is [System.Array]) { return @($value) }
    return @($value)
}

function New-EmptySettings {
    return [pscustomobject]@{}
}

function Read-Settings($path) {
    if (-not (Test-Path -LiteralPath $path)) {
        return New-EmptySettings
    }

    $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return New-EmptySettings
    }

    # 파싱 실패 시 빈 설정으로 덮어쓰면 사용자의 기존 설정이 사라진다. 파일을 건드리지 않고 중단한다.
    try {
        $settings = $raw | ConvertFrom-Json
    } catch {
        throw "Cannot parse '$path' as JSON. Nothing was changed. Fix the file and run again. ($($_.Exception.Message))"
    }
    if ($settings -isnot [System.Management.Automation.PSCustomObject]) {
        throw "'$path' is not a JSON object. Nothing was changed. Fix the file and run again."
    }
    return $settings
}

function Backup-Settings($path) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }

    $backupDir = Join-Path (Split-Path -Parent $path) 'backups'
    New-Item -ItemType Directory -Force -Path $backupDir | Out-Null

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $name = [System.IO.Path]::GetFileNameWithoutExtension($path)
    $backup = Join-Path $backupDir "$name.claude-wt-pets-$stamp.json"
    Copy-Item -LiteralPath $path -Destination $backup -Force
    return $backup
}

function Ensure-Event($settings, [string]$eventName) {
    if (-not $settings.PSObject.Properties['hooks']) {
        $settings | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{})
    }
    if (-not $settings.hooks.PSObject.Properties[$eventName]) {
        $settings.hooks | Add-Member -NotePropertyName $eventName -NotePropertyValue @()
    }
}

function Ensure-HookCommand($settings, [string]$eventName, [string]$command, [int]$timeout) {
    Ensure-Event $settings $eventName

    $groups = @(As-Array $settings.hooks.PSObject.Properties[$eventName].Value)
    $normalizedCommand = $command.ToLowerInvariant()

    foreach ($group in $groups) {
        foreach ($hook in @(As-Array $group.hooks)) {
            if (([string]$hook.command).ToLowerInvariant() -eq $normalizedCommand) {
                return $false
            }
        }
    }

    $target = $null
    foreach ($group in $groups) {
        if ([string]$group.matcher -eq '*') {
            $target = $group
            break
        }
    }

    if ($null -eq $target) {
        $target = [pscustomobject]@{
            matcher = '*'
            hooks = @()
        }
        $groups = @($groups + @($target))
    }

    $hook = [pscustomobject]@{
        type = 'command'
        command = $command
        timeout = $timeout
    }

    $target.hooks = @(@(As-Array $target.hooks) + @($hook))
    $settings.hooks.PSObject.Properties[$eventName].Value = @($groups)
    return $true
}

function Test-WtPetsHookCommandPresent($settings, [string]$eventName, [string]$command) {
    Ensure-Event $settings $eventName

    $normalizedCommand = $command.ToLowerInvariant()
    $groups = @(As-Array $settings.hooks.PSObject.Properties[$eventName].Value)
    foreach ($group in $groups) {
        foreach ($hook in @(As-Array $group.hooks)) {
            if (([string]$hook.command).ToLowerInvariant() -eq $normalizedCommand) {
                return $true
            }
        }
    }

    return $false
}

function Remove-ClaudeWtPetsHooks($settings, [string]$eventName) {
    Ensure-Event $settings $eventName

    $groups = @(As-Array $settings.hooks.PSObject.Properties[$eventName].Value)
    $newGroups = @()

    foreach ($group in $groups) {
        $hooks = @()
        foreach ($hook in @(As-Array $group.hooks)) {
            $command = [string]$hook.command
            $normalized = $command.ToLowerInvariant()
            # 현재 설치 위치의 hook-entry.ps1과, 알려진 폴더 이름(claude-wt-pets, 옛 이름 clawd-notify)의
            # 이전 설치 흔적을 모두 이 도구의 hook으로 본다. clone 폴더 이름이 달라도 중복/잔존하지 않게 한다.
            $isClaudeWtPets =
                $normalized.Contains($HOOK_ENTRY.ToLowerInvariant()) -or
                $normalized.Contains('clawd-notify\notifier.js') -or
                $normalized.Contains('clawd-notify/notifier.js') -or
                $normalized.Contains('clawd-notify\hook-entry.ps1') -or
                $normalized.Contains('clawd-notify/hook-entry.ps1') -or
                $normalized.Contains('claude-wt-pets\hook-entry.ps1') -or
                $normalized.Contains('claude-wt-pets/hook-entry.ps1')

            if (-not $isClaudeWtPets) {
                $hooks += $hook
            }
        }

        if ($hooks.Count -gt 0) {
            $group.hooks = @($hooks)
            $newGroups += $group
        }
    }

    $settings.hooks.PSObject.Properties[$eventName].Value = @($newGroups)
}

function Save-Settings($path, $settings) {
    $dir = Split-Path -Parent $path
    New-Item -ItemType Directory -Force -Path $dir | Out-Null

    $json = $settings | ConvertTo-Json -Depth 100
    $encoding = New-Object System.Text.UTF8Encoding -ArgumentList $false
    [System.IO.File]::WriteAllText($path, $json + [Environment]::NewLine, $encoding)
}

function Install-WtPetsHooks($path) {
    $settings = Read-Settings $path
    $backup = Backup-Settings $path
    $added = New-Object System.Collections.Generic.List[string]

    foreach ($event in $EVENTS) {
        Remove-ClaudeWtPetsHooks $settings $event.Name
        $command = 'powershell -NoProfile -ExecutionPolicy RemoteSigned -File "' + $HOOK_ENTRY + '" ' + $event.Name
        if (Ensure-HookCommand $settings $event.Name $command $event.Timeout) {
            $added.Add($event.Name)
        }
    }

    Save-Settings $path $settings

    return [pscustomobject]@{
        Path = $path
        Action = 'installed'
        Backup = $backup
        Added = $added -join ','
    }
}

function Disable-WtPetsHooks($path) {
    if (-not (Test-Path -LiteralPath $path)) {
        return [pscustomobject]@{
            Path = $path
            Action = 'skipped-missing'
            Backup = $null
            Added = ''
        }
    }

    $settings = Read-Settings $path
    $backup = Backup-Settings $path

    foreach ($event in $EVENTS) {
        Remove-ClaudeWtPetsHooks $settings $event.Name
    }

    Save-Settings $path $settings

    return [pscustomobject]@{
        Path = $path
        Action = 'disabled'
        Backup = $backup
        Added = ''
    }
}

function Audit-WtPetsHooks($path, [bool]$ShouldBeInstalled) {
    $settings = Read-Settings $path
    $missing = New-Object System.Collections.Generic.List[string]
    $unexpected = New-Object System.Collections.Generic.List[string]

    foreach ($event in $EVENTS) {
        $command = 'powershell -NoProfile -ExecutionPolicy RemoteSigned -File "' + $HOOK_ENTRY + '" ' + $event.Name
        $present = Test-WtPetsHookCommandPresent $settings $event.Name $command

        if ($ShouldBeInstalled) {
            if (-not $present) {
                $missing.Add($event.Name)
            }
        } elseif ($present) {
            $unexpected.Add($event.Name)
        }
    }

    $status = 'ok'
    if ($missing.Count -gt 0 -or $unexpected.Count -gt 0) {
        $status = 'mismatch'
    }

    return [pscustomobject]@{
        Path = $path
        Action = 'audit'
        Expected = if ($ShouldBeInstalled) { 'installed' } else { 'disabled' }
        Status = $status
        Missing = $missing -join ','
        Unexpected = $unexpected -join ','
    }
}

$actions = @()
if ($Uninstall) {
    if ($Audit) {
        $actions += Audit-WtPetsHooks $USER_SETTINGS $false
        $actions += Audit-WtPetsHooks $PROJECT_SETTINGS $false
    } else {
        # 한쪽만 제거되고 멈추지 않도록, 수정 전에 두 파일을 모두 먼저 읽어 본다.
        Read-Settings $USER_SETTINGS | Out-Null
        Read-Settings $PROJECT_SETTINGS | Out-Null
        $actions += Disable-WtPetsHooks $USER_SETTINGS
        $actions += Disable-WtPetsHooks $PROJECT_SETTINGS
    }
} elseif ($Audit) {
    if ($Scope -eq 'project') {
        $actions += Audit-WtPetsHooks $PROJECT_SETTINGS $true
        $actions += Audit-WtPetsHooks $USER_SETTINGS $false
    } elseif ($Scope -eq 'both') {
        $actions += Audit-WtPetsHooks $USER_SETTINGS $true
        $actions += Audit-WtPetsHooks $PROJECT_SETTINGS $true
    } else {
        $actions += Audit-WtPetsHooks $USER_SETTINGS $true
        $actions += Audit-WtPetsHooks $PROJECT_SETTINGS $false
    }
} else {
    # 한쪽만 바뀌고 멈추지 않도록, 수정 전에 두 파일을 모두 먼저 읽어 본다.
    Read-Settings $USER_SETTINGS | Out-Null
    Read-Settings $PROJECT_SETTINGS | Out-Null

    if ($Scope -eq 'project') {
        $actions += Install-WtPetsHooks $PROJECT_SETTINGS
        $actions += Disable-WtPetsHooks $USER_SETTINGS
    } elseif ($Scope -eq 'both') {
        $actions += Install-WtPetsHooks $USER_SETTINGS
        $actions += Install-WtPetsHooks $PROJECT_SETTINGS
    } else {
        $actions += Install-WtPetsHooks $USER_SETTINGS
        $actions += Disable-WtPetsHooks $PROJECT_SETTINGS
    }
}

$actions
