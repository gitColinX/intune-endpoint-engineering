<#
.SYNOPSIS
    Intune Remediations detection-only monitor: WiFi connection failures and
    disconnects in the last 24 hours.

.DESCRIPTION
    Read-only. Reads the WLAN-AutoConfig operational log:
      8001  connected successfully        (counted for context, NEVER a failure)
      8002  failed to connect             (failure)
      8003  disconnected                  (failure, unless the reason matches IgnoreReasonPattern)

    Exit 1 only when FailCount (8002 plus non-ignored 8003) is above zero.
    Exit 0 otherwise, including devices with no WiFi activity at all.

    Output: FailCount, the split, the top reasons with counts, and the latest
    few failures with time, event id, SSID and reason.

    Privacy: SSIDs not listed in ReportSsids are printed as <other>. People's
    home networks do not belong in a fleet report.

    Things to know when you read the results:
      - The window is the 24 hours before each device's own last run, so two
        devices in the export are not measuring the same day.
      - Reason text is localized. IgnoreReasonPattern is matched against
        English text; adjust it for other display languages.
      - Some 8003 reasons are benign (the user disconnected, a policy turned off
        auto connect when a wired link came up). Look at your own data before
        widening the ignore pattern.

.NOTES
    Pattern status: [built, ran on real tickets]. My original version exited 1
    on ANY of 8001, 8002 or 8003, and 8001 is a successful connection. Its
    "devices with issues" count was really "devices that used WiFi" and
    overstated the problem by about half again. The per-device failure count in
    the output text was the real signal. This rewrite fixes that, filters the
    log by time instead of reading the newest 300 events, and masks SSIDs.
    Fresh rewrite, generalized from what I ran at work, tested against
    synthetic events only.
#>
[CmdletBinding()]
param()

$Config = @{
    HoursBack           = 24
    ReportSsids         = @('CONTOSO-CORP', 'CONTOSO-GUEST')
    IgnoreReasonPattern = '(?i)disconnected by the user'
    MaxEvents           = 5000
    RecentToShow        = 4
}

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

function ConvertFrom-WlanEventRecord {
    # Real EventLogRecord -> flat object the summary function understands.
    param($Record)
    $data = @{}
    try {
        $x = [xml]$Record.ToXml()
        foreach ($d in @($x.Event.EventData.Data)) {
            if ($d -and $d.Name) { $data[[string]$d.Name] = [string]$d.'#text' }
        }
    }
    catch { }
    $reason = ''
    if ($data.ContainsKey('Reason')) { $reason = $data['Reason'] }
    elseif ($data.ContainsKey('FailureReason')) { $reason = $data['FailureReason'] }
    return [pscustomobject]@{
        Id          = [int]$Record.Id
        TimeCreated = $Record.TimeCreated
        Ssid        = $(if ($data.ContainsKey('SSID')) { $data['SSID'] } else { '' })
        Reason      = $reason
    }
}

function Get-WlanFailureSummary {
    # Pure: takes objects with Id, TimeCreated, Ssid, Reason. No event log access.
    param(
        [AllowEmptyCollection()][object[]]$WlanEvent = @(),
        [string[]]$ReportSsids = @(),
        [string]$IgnoreReasonPattern = '',
        [int]$RecentToShow = 4
    )
    $connects = @($WlanEvent | Where-Object { $_.Id -eq 8001 })
    $connectFail = @($WlanEvent | Where-Object { $_.Id -eq 8002 })
    $allDisc = @($WlanEvent | Where-Object { $_.Id -eq 8003 })
    if ($IgnoreReasonPattern) {
        $ignored = @($allDisc | Where-Object { $_.Reason -match $IgnoreReasonPattern })
        $disc = @($allDisc | Where-Object { $_.Reason -notmatch $IgnoreReasonPattern })
    }
    else {
        $ignored = @()
        $disc = $allDisc
    }
    $failures = @($connectFail + $disc | Sort-Object TimeCreated -Descending)

    $top = @($failures | Group-Object { if ($_.Reason) { $_.Reason.Trim() } else { '(no reason)' } } |
        Sort-Object Count -Descending | Select-Object -First 3 | ForEach-Object { '{0} x{1}' -f $_.Name, $_.Count })
    $recent = @($failures | Select-Object -First $RecentToShow | ForEach-Object {
            $ssid = if ($ReportSsids -contains $_.Ssid) { $_.Ssid } elseif ($_.Ssid) { '<other>' } else { '-' }
            $r = [string]$_.Reason
            if ($r.Length -gt 70) { $r = $r.Substring(0, 70) }
            '{0} {1} {2} {3}' -f ([datetime]$_.TimeCreated).ToString('MM/dd HH:mm'), $_.Id, $ssid, $r
        })

    return [pscustomobject]@{
        FailCount       = $failures.Count
        ConnectFailures = $connectFail.Count
        Disconnects     = $disc.Count
        Ignored         = $ignored.Count
        Connects        = $connects.Count
        TopReasons      = $top
        Recent          = $recent
    }
}

function Invoke-Main {
    try {
        $filter = @{
            LogName   = 'Microsoft-Windows-WLAN-AutoConfig/Operational'
            Id        = 8001, 8002, 8003
            StartTime = (Get-Date).AddHours(-$Config.HoursBack)
        }
        $records = @(Get-WinEvent -FilterHashtable $filter -MaxEvents $Config.MaxEvents -ErrorAction SilentlyContinue)
        if ($records.Count -eq 0) {
            Write-Output ('OK: no WLAN events in the last {0}h' -f $Config.HoursBack)
            exit 0
        }
        $events = @($records | ForEach-Object { ConvertFrom-WlanEventRecord -Record $_ })
        $s = Get-WlanFailureSummary -WlanEvent $events -ReportSsids $Config.ReportSsids -IgnoreReasonPattern $Config.IgnoreReasonPattern -RecentToShow $Config.RecentToShow
        $head = 'FailCount={0} (connectFail={1} disconnect={2}; ignored={3} connects={4}; {5}h)' -f $s.FailCount, $s.ConnectFailures, $s.Disconnects, $s.Ignored, $s.Connects, $Config.HoursBack
        if ($s.FailCount -gt 0) {
            $parts = @($head, ('top: ' + ($s.TopReasons -join '; '))) + $s.Recent
            Write-Output (Format-RemediationOutput -Part $parts)
            exit 1
        }
        Write-Output ('OK: ' + $head)
        exit 0
    }
    catch {
        Write-Output (Format-RemediationOutput -Part @('MONITOR ERROR', $_.Exception.Message))
        exit 0
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-Main
}
