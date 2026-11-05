$script:WtPetsRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($script:WtPetsRoot)) {
    $script:WtPetsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}
# config.json은 사용자 설정(git 제외), config.default.json은 저장소 기본값이다.
# 읽기: config.json이 있으면 그것을, 없으면 config.default.json을 읽는다. 저장은 항상 config.json에 한다.
$script:WtPetsConfigPath = Join-Path $script:WtPetsRoot 'config.json'
$script:WtPetsDefaultConfigPath = Join-Path $script:WtPetsRoot 'config.default.json'
$script:WtPetsCharactersDir = Join-Path $script:WtPetsRoot 'characters'
$script:WtPetsMaxSlots = 4

function New-WtPetsPlacementConfig {
    [pscustomobject]@{
        anchor = 'bottom-left'
        offsetX = 10
        offsetY = 10
        slotGap = 10
        direction = 'right'
    }
}

function Get-WtPetsCharacterDirectoryNames {
    $names = @(
        Get-ChildItem -LiteralPath $script:WtPetsCharactersDir -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { [string]$_.Name }
    )

    [Array]::Sort($names, [System.StringComparer]::Ordinal)
    return $names
}

function Get-WtPetsAvailableCharacters {
    param([switch]$SlotFirst)

    $ordered = New-Object System.Collections.Generic.List[string]
    $seen = @{}

    if ($SlotFirst) {
        $cfg = Get-WtPetsConfig
        for ($i = 1; $i -le $script:WtPetsMaxSlots; $i++) {
            $slotKey = [string]$i
            if ($cfg.slotCharacters -and $cfg.slotCharacters.PSObject.Properties[$slotKey]) {
                $name = [string]$cfg.slotCharacters.PSObject.Properties[$slotKey].Value
                if ((Test-WtPetsCharacterName $name) -and -not $seen.ContainsKey($name)) {
                    $ordered.Add($name)
                    $seen[$name] = $true
                }
            }
        }
    }

    Get-WtPetsCharacterDirectoryNames |
        ForEach-Object {
            if ((Test-WtPetsCharacterName $_) -and -not $seen.ContainsKey($_)) {
                $ordered.Add($_)
                $seen[$_] = $true
            }
        }

    return $ordered
}

function Test-WtPetsCharacterName {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    if ($Name -eq '.' -or $Name -eq '..') { return $false }
    if ($Name.StartsWith('.')) { return $false }
    if ($Name.Contains('\') -or $Name.Contains('/') -or $Name.Contains('..')) { return $false }
    if ($Name -notmatch '^[\p{L}\p{N}_.-]+$') { return $false }
    $item = Get-Item -LiteralPath (Join-Path $script:WtPetsCharactersDir $Name) -ErrorAction SilentlyContinue
    return ($null -ne $item -and $item.PSIsContainer)
}

function Assert-WtPetsCharacter {
    param([string]$Name)

    if (-not (Test-WtPetsCharacterName $Name)) {
        $available = (Get-WtPetsAvailableCharacters -SlotFirst) -join ', '
        if ([string]::IsNullOrWhiteSpace($Name)) {
            throw "Character name is empty. Available: $available"
        }
        throw "Unknown character '$Name'. Available: $available"
    }
}

function New-WtPetsConfig {
    $allChars = @(Get-WtPetsAvailableCharacters)
    $default = ''
    if ($allChars.Count -gt 0) {
        $default = $allChars[0]
    }

    [pscustomobject]@{
        defaultCharacter = $default
        slotCharacters = [pscustomobject]@{}
        placement = New-WtPetsPlacementConfig
    }
}

function Ensure-WtPetsConfigShape {
    param($Config)

    if (-not $Config.PSObject.Properties['defaultCharacter']) {
        $Config | Add-Member -NotePropertyName defaultCharacter -NotePropertyValue ''
    }
    if (-not $Config.PSObject.Properties['slotCharacters']) {
        $Config | Add-Member -NotePropertyName slotCharacters -NotePropertyValue ([pscustomobject]@{})
    }
    if (-not $Config.PSObject.Properties['placement']) {
        $Config | Add-Member -NotePropertyName placement -NotePropertyValue (New-WtPetsPlacementConfig)
    }
    if (-not $Config.PSObject.Properties['petSize']) {
        $Config | Add-Member -NotePropertyName petSize -NotePropertyValue 80
    }

    $defaults = New-WtPetsPlacementConfig
    foreach ($property in @('anchor', 'offsetX', 'offsetY', 'slotGap', 'direction')) {
        if (-not $Config.placement.PSObject.Properties[$property]) {
            $Config.placement | Add-Member -NotePropertyName $property -NotePropertyValue $defaults.$property
        }
    }

    return $Config
}

function ConvertTo-WtPetsPetSize {
    param($Config)

    $size = 80
    if ($null -ne $Config -and $Config.PSObject.Properties['petSize']) {
        try { $size = [int]$Config.petSize } catch {}
    }
    if ($size -lt 40) { $size = 40 }
    if ($size -gt 200) { $size = 200 }
    return $size
}

function Get-WtPetsPetSize {
    return ConvertTo-WtPetsPetSize (Get-WtPetsConfig)
}

function Get-WtPetsConfigReadPath {
    if ([System.IO.File]::Exists($script:WtPetsConfigPath)) {
        return $script:WtPetsConfigPath
    }
    return $script:WtPetsDefaultConfigPath
}

function Get-WtPetsConfig {
    try {
        $cfg = Get-Content -LiteralPath (Get-WtPetsConfigReadPath) -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
    } catch {
        $cfg = New-WtPetsConfig
    }

    return Ensure-WtPetsConfigShape $cfg
}

function Save-WtPetsConfig {
    param($Config)

    $Config = Ensure-WtPetsConfigShape $Config
    $json = $Config | ConvertTo-Json -Depth 20
    $encoding = New-Object System.Text.UTF8Encoding -ArgumentList $false
    [System.IO.File]::WriteAllText($script:WtPetsConfigPath, $json + [Environment]::NewLine, $encoding)
}

function Get-WtPetsCharacterForSlot {
    param(
        [ValidateRange(1,4)]
        [int]$Slot,
        [string]$EnvironmentCharacter = $env:CLAUDE_WT_PETS_CHARACTER
    )

    $cfg = Get-WtPetsConfig
    $slotKey = [string]$Slot
    if (Test-WtPetsCharacterName $EnvironmentCharacter) {
        return $EnvironmentCharacter
    }
    if ($cfg.slotCharacters -and $cfg.slotCharacters.PSObject.Properties[$slotKey]) {
        $slotCharacter = [string]$cfg.slotCharacters.PSObject.Properties[$slotKey].Value
        if (Test-WtPetsCharacterName $slotCharacter) {
            return $slotCharacter
        }
    }
    if (Test-WtPetsCharacterName $cfg.defaultCharacter) {
        return [string]$cfg.defaultCharacter
    }

    $first = @(Get-WtPetsAvailableCharacters | Select-Object -First 1)
    if ($first.Count -gt 0) { return [string]$first[0] }
    return ''
}

function Resolve-WtPetsCharacterName {
    param(
        [string]$Name,
        [string]$Fallback,
        [ValidateRange(1,4)]
        [int]$Slot
    )

    if (Test-WtPetsCharacterName $Name) { return $Name }
    if (Test-WtPetsCharacterName $Fallback) { return $Fallback }
    return Get-WtPetsCharacterForSlot -Slot $Slot
}

function Set-WtPetsSlotCharacter {
    param(
        [ValidateRange(1,4)]
        [int]$Slot,
        [string]$Character
    )

    Assert-WtPetsCharacter $Character

    $cfg = Get-WtPetsConfig
    $slotKey = [string]$Slot
    if ($cfg.slotCharacters.PSObject.Properties[$slotKey]) {
        $cfg.slotCharacters.PSObject.Properties[$slotKey].Value = $Character
    } else {
        $cfg.slotCharacters | Add-Member -MemberType NoteProperty -Name $slotKey -Value $Character
    }

    Save-WtPetsConfig $cfg
}

function Get-WtPetsNumber {
    param($Value, [double]$Fallback)

    if ($null -eq $Value) { return $Fallback }
    try {
        return [double]$Value
    } catch {
        return $Fallback
    }
}

function Get-WtPetsPlacementConfig {
    param([double]$DefaultSlotGap = 10)

    return ConvertTo-WtPetsPlacement (Get-WtPetsConfig) -DefaultSlotGap $DefaultSlotGap
}

function ConvertTo-WtPetsPlacement {
    param($Config, [double]$DefaultSlotGap = 10)

    $placement = $null
    if ($null -ne $Config -and $Config.PSObject.Properties['placement']) {
        $placement = $Config.placement
    }
    if ($null -eq $placement) {
        $placement = New-WtPetsPlacementConfig
    }

    $anchor = ([string]$placement.anchor).ToLowerInvariant()
    $direction = ([string]$placement.direction).ToLowerInvariant()
    $offsetX = Get-WtPetsNumber $placement.offsetX 10
    $offsetY = Get-WtPetsNumber $placement.offsetY 10
    $slotGap = Get-WtPetsNumber $placement.slotGap $DefaultSlotGap

    if (@('top-left', 'top-right', 'bottom-left', 'bottom-right') -notcontains $anchor) {
        $anchor = 'bottom-left'
    }
    if (@('left', 'right') -notcontains $direction) {
        $direction = 'right'
    }

    return [pscustomobject]@{
        anchor = $anchor
        direction = $direction
        offsetX = $offsetX
        offsetY = $offsetY
        slotGap = $slotGap
    }
}
