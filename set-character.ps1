param(
    [Alias('Default')]
    [string]$DefaultCharacter,

    [ValidateRange(1,4)]
    [int]$Slot = 0,

    [string]$Character,

    [switch]$ClearSlot,
    [switch]$List
)

. (Join-Path $PSScriptRoot 'WtPets.Common.ps1')

if ($List) {
    Get-WtPetsAvailableCharacters -SlotFirst | ForEach-Object { Write-Output $_ }
    exit 0
}

$config = Get-WtPetsConfig
$changed = $false

if ($DefaultCharacter) {
    Assert-WtPetsCharacter $DefaultCharacter
    $config.defaultCharacter = $DefaultCharacter
    $changed = $true
}

if ($Slot -gt 0 -and $ClearSlot) {
    $slotKey = [string]$Slot
    if ($config.slotCharacters.PSObject.Properties[$slotKey]) {
        $config.slotCharacters.PSObject.Properties.Remove($slotKey)
    }
    $changed = $true
} elseif ($Slot -gt 0) {
    Assert-WtPetsCharacter $Character
    $slotKey = [string]$Slot
    if ($config.slotCharacters.PSObject.Properties[$slotKey]) {
        $config.slotCharacters.PSObject.Properties[$slotKey].Value = $Character
    } else {
        $config.slotCharacters | Add-Member -MemberType NoteProperty -Name $slotKey -Value $Character
    }
    $changed = $true
}

if ($changed) {
    Save-WtPetsConfig $config
    $config = Get-WtPetsConfig

    if ($Slot -gt 0 -and $Character) {
        $statePath = Join-Path $env:TEMP "claude-wt-pets-state-$Slot.json"
        if (Test-Path $statePath) {
            $state = Get-Content $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
            $state.character = $Character
            $state | ConvertTo-Json -Depth 10 | Set-Content $statePath -Encoding UTF8 -NoNewline
        }
    }
}

Write-Output 'Available characters:'
Get-WtPetsAvailableCharacters -SlotFirst | ForEach-Object { Write-Output "  $_" }
Write-Output ''
Write-Output 'Current config:'
($config | ConvertTo-Json -Depth 20)
