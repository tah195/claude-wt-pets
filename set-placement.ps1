param(
    [ValidateSet('bottom-right', 'bottom-left', 'top-right', 'top-left')]
    [string]$Anchor,

    [Nullable[int]]$OffsetX,
    [Nullable[int]]$OffsetY,
    [Nullable[int]]$SlotGap,

    [ValidateSet('left', 'right')]
    [string]$Direction,

    [switch]$Show
)

. (Join-Path $PSScriptRoot 'WtPets.Common.ps1')

$config = Get-WtPetsConfig
$changed = $false

if ($Anchor) {
    $config.placement.anchor = $Anchor
    $changed = $true
}
if ($PSBoundParameters.ContainsKey('OffsetX')) {
    $config.placement.offsetX = [int]$OffsetX
    $changed = $true
}
if ($PSBoundParameters.ContainsKey('OffsetY')) {
    $config.placement.offsetY = [int]$OffsetY
    $changed = $true
}
if ($PSBoundParameters.ContainsKey('SlotGap')) {
    $config.placement.slotGap = [int]$SlotGap
    $changed = $true
}
if ($Direction) {
    $config.placement.direction = $Direction
    $changed = $true
}

if ($changed) {
    Save-WtPetsConfig $config
    $config = Get-WtPetsConfig
}

Write-Output 'Current placement:'
(Get-WtPetsPlacementConfig | ConvertTo-Json -Depth 10)
