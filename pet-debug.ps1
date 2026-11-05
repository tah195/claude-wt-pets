param([ValidateRange(1,4)][int]$Slot = 1)

$ErrorActionPreference = 'Stop'

$logFile = [System.IO.Path]::Combine($env:TEMP, "claude-wt-pets-pet-debug-$Slot.log")
$launcher = Join-Path $PSScriptRoot 'launch-pet.ps1'
$stateFile = [System.IO.Path]::Combine($env:TEMP, "claude-wt-pets-state-$Slot.json")
$pidFile = [System.IO.Path]::Combine($env:TEMP, "claude-wt-pets-pet-$Slot.pid")

function Write-DebugLog {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format o), $Message
    Add-Content -LiteralPath $logFile -Encoding UTF8 -Value $line
}

Set-Content -LiteralPath $logFile -Encoding UTF8 -Value ("[{0}] pet debug start slot={1}" -f (Get-Date -Format o), $Slot)

if (-not (Test-Path -LiteralPath $launcher)) {
    Write-DebugLog "missing launcher: $launcher"
    exit 1
}

Write-DebugLog "state file: $stateFile"
Write-DebugLog "pid file: $pidFile"

& powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File $launcher -Slot $Slot

Start-Sleep -Milliseconds 500

if (Test-Path -LiteralPath $pidFile) {
    Write-DebugLog "pet pid: $(Get-Content -LiteralPath $pidFile -Raw -Encoding ASCII)"
} else {
    Write-DebugLog 'pet pid file was not created'
}

if (Test-Path -LiteralPath $stateFile) {
    Write-DebugLog "state exists"
} else {
    Write-DebugLog 'state file does not exist yet'
}

Get-Content -LiteralPath $logFile -Encoding UTF8
