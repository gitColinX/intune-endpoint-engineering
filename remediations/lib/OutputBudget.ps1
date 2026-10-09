# Output budget helper for Intune Remediations.
#
# Intune shows at most 2,048 characters of a detection or remediation script's
# output in the portal and in exports. Anything past that is cut off, usually
# right where the interesting part was. This helper joins report fragments into
# one line and shares the budget fairly: short fragments stay whole, long ones
# are trimmed with a "..." marker, and if there are too many fragments the tail
# is replaced with "[+N more]".
#
# Intune scripts must be self-contained, so the device scripts in this repo carry
# an inline copy of the function between the region markers below.
# tests\Run-Tests.ps1 fails if any inline copy drifts from this file.

# region OutputBudget
function Format-RemediationOutput {
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyCollection()][string[]]$Part = @(),
        [ValidateRange(64, 100000)][int]$Budget = 2048,
        [string]$Separator = ' || '
    )
    $items = New-Object System.Collections.Generic.List[string]
    foreach ($p in $Part) {
        if ($null -eq $p) { continue }
        $t = (($p -replace '[\x00-\x1F\x7F]+', ' ') -replace '\s+', ' ').Trim()
        if ($t.Length -gt 0) { $items.Add($t) }
    }
    if ($items.Count -eq 0) { return '' }
    $joined = $items -join $Separator
    if ($joined.Length -le $Budget) { return $joined }

    $marker = '...'
    $minShare = 24
    $note = ''
    $maxParts = [int][Math]::Max(1, [Math]::Floor(($Budget + $Separator.Length) / ($minShare + $Separator.Length)))
    if ($items.Count -gt $maxParts) {
        $keep = [Math]::Max(1, $maxParts - 1)
        $note = '[+' + ($items.Count - $keep) + ' more]'
        $trimmed = New-Object System.Collections.Generic.List[string]
        for ($i = 0; $i -lt $keep; $i++) { $trimmed.Add($items[$i]) }
        $items = $trimmed
    }

    $sepCount = $items.Count - 1
    if ($note) { $sepCount++ }
    $available = $Budget - ($Separator.Length * $sepCount) - $note.Length
    $lengths = @($items | ForEach-Object { $_.Length })
    $alloc = New-Object 'int[]' $items.Count
    $open = New-Object System.Collections.Generic.List[int]
    for ($i = 0; $i -lt $items.Count; $i++) { $open.Add($i) }
    $remaining = $available
    while ($open.Count -gt 0) {
        $share = [int][Math]::Floor($remaining / $open.Count)
        $fits = @($open | Where-Object { $lengths[$_] -le $share })
        if ($fits.Count -eq 0) {
            foreach ($i in $open) { $alloc[$i] = $share }
            break
        }
        foreach ($i in $fits) {
            $alloc[$i] = $lengths[$i]
            $remaining -= $lengths[$i]
            [void]$open.Remove($i)
        }
    }

    $out = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $items.Count; $i++) {
        if ($alloc[$i] -ge $lengths[$i]) {
            $out.Add($items[$i])
        }
        else {
            $keepChars = [Math]::Max(0, $alloc[$i] - $marker.Length)
            $out.Add($items[$i].Substring(0, $keepChars) + $marker)
        }
    }
    if ($note) { $out.Add($note) }
    $result = $out -join $Separator
    if ($result.Length -gt $Budget) { $result = $result.Substring(0, $Budget) }
    return $result
}
# endregion OutputBudget
