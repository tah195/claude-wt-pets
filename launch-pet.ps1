param([int]$Slot = 0)

$petScript = Join-Path $PSScriptRoot "pet.ps1"
$registry  = Join-Path $env:TEMP "claude-wt-pets-registry.json"
$MAX_SLOTS = 4

function Get-LatestSlot {
    if (-not (Test-Path -LiteralPath $registry)) { return $null }

    try {
        $reg = Get-Content -LiteralPath $registry -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
    } catch {
        return $null
    }

    $latest = $null
    $reg.PSObject.Properties | ForEach-Object {
        if (-not $latest -or $_.Value.ts -gt $latest.Value.ts) {
            $latest = $_
        }
    }

    if (-not $latest) { return $null }
    return [int]$latest.Value.slot
}

if ($Slot -lt 1 -or $Slot -gt $MAX_SLOTS) {
    $Slot = Get-LatestSlot
}

if ($Slot -lt 1 -or $Slot -gt $MAX_SLOTS) { exit 0 }
if (-not (Test-Path -LiteralPath $petScript)) { exit 0 }

$powerShellExe = Join-Path $PSHOME 'powershell.exe'

$launchArgs = @(
    '-NoProfile',
    '-WindowStyle', 'Hidden',
    '-STA',
    '-ExecutionPolicy', 'RemoteSigned',
    '-File', "`"$petScript`"",
    '-Slot', [string]$Slot
)

try {
    $envVars = [Environment]::GetEnvironmentVariables('Process')
    if ($envVars.Contains('Path') -and $envVars.Contains('PATH')) {
        [Environment]::SetEnvironmentVariable('PATH', $null, 'Process')
    }
} catch {}

try {
    try {
        $log = [System.IO.Path]::Combine($env:TEMP, 'claude-wt-pets-transition.log')
        $payload = [ordered]@{
            ts = [DateTimeOffset]::Now.ToString('o')
            source = 'launch-pet'
            slot = $Slot
            action = 'launch-pet-start'
        }
        Add-Content -LiteralPath $log -Encoding UTF8 -Value ($payload | ConvertTo-Json -Compress -Depth 5) -ErrorAction Stop
    } catch {}

    $shell = New-Object -ComObject Shell.Application
    $shell.ShellExecute($powerShellExe, ($launchArgs -join ' '), '', 'open', 0)

    try {
        $log = [System.IO.Path]::Combine($env:TEMP, 'claude-wt-pets-transition.log')
        $payload = [ordered]@{
            ts = [DateTimeOffset]::Now.ToString('o')
            source = 'launch-pet'
            slot = $Slot
            action = 'launch-pet-started'
        }
        Add-Content -LiteralPath $log -Encoding UTF8 -Value ($payload | ConvertTo-Json -Compress -Depth 5) -ErrorAction Stop
    } catch {}
} catch {
    try {
        $log = [System.IO.Path]::Combine($env:TEMP, 'claude-wt-pets-transition.log')
        $payload = [ordered]@{
            ts = [DateTimeOffset]::Now.ToString('o')
            source = 'launch-pet'
            slot = $Slot
            action = 'launch-pet-error'
            detail = [string]$_.Exception.Message
        }
        Add-Content -LiteralPath $log -Encoding UTF8 -Value ($payload | ConvertTo-Json -Compress -Depth 5) -ErrorAction Stop
    } catch {}
}
