<#
.SYNOPSIS
    Intune Remediations detection-only template: read-only recon before any fix.

.DESCRIPTION
    Deploy this as a detection script with NO remediation script attached. It
    changes nothing. It answers "what is actually on these devices?" before
    anyone writes a fix, and the answer comes back per device in the
    "Pre-remediation detection output" column of the Intune report, which you
    can export.

    What it reports, each item short enough to survive the 2,048-character
    output limit:
      OS      build.UBR, model, uptime in days, free GB on the system drive
      REBOOT  pending reboot flags (CBS, WU, PFR)
      SVC     services matching ServiceNames, with status and start type
      ARP     Add/Remove Programs entries matching ProductNamePattern (both views)
      MSIDB   Windows Installer product registrations (packed GUID keys)
      DIR     which of the configured folders exist
      MSIEVT  latest MsiInstaller events for the product (1033 status code, 11708 and friends)
      LOG     newest log file in each configured log folder: name, age, last error-like lines

    Exit code: ReportExitCode (default 0). With no remediation attached, exit 1
    never triggers a change; some admins prefer 1 so every reporting device sits
    under the "With issues" filter. Pick one and keep it consistent.

    Intune settings: run as SYSTEM, "Run script in 64-bit PowerShell" = Yes.

.NOTES
    Pattern status: [built, ran on real tickets]. Versions of this ran during an
    RMM agent incident (census of leftovers, app-control evidence, a gap check
    on a handful of devices) and an EDR rollout (that run per my notes; no
    recon export kept). This is a fresh rewrite, generalized from what I ran
    at work, parse-checked and tested against synthetic input only.
#>
[CmdletBinding()]
param()

$Config = @{
    ServiceNames       = @('ContosoAgent*')
    ProductNamePattern = '^Contoso (RMM Agent|Agent Platform)\b'
    Folders            = @('C:\Program Files (x86)\Contoso\Agent', 'C:\ProgramData\Contoso')
    LogFolders         = @('C:\Program Files (x86)\Contoso\Agent\log')
    LogErrorPattern    = 'error|fail|denied|abort|exit code|return code'
    MsiEventDays       = 14
    ReportExitCode     = 0
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

function Get-PendingRebootFlag {
    $flags = @()
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $flags += 'CBS' }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $flags += 'WU' }
    $sm = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction SilentlyContinue
    if ($sm -and $sm.PendingFileRenameOperations) { $flags += 'PFR' }
    if ($flags.Count) { return ($flags -join '+') }
    return '-'
}

function Get-OsLine {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    $ubr = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue).UBR
    $up = if ($os) { [Math]::Round(((Get-Date) - $os.LastBootUpTime).TotalDays, 1) } else { '?' }
    $sysDrive = ($env:SystemDrive).TrimEnd(':')
    $free = (Get-PSDrive -Name $sysDrive -ErrorAction SilentlyContinue).Free
    $freeGb = if ($free) { [Math]::Round($free / 1GB, 1) } else { '?' }
    $model = if ($cs) { ([string]$cs.Model).Trim() } else { '?' }
    return ('OS build={0}.{1} model={2} upDays={3} freeGB={4}' -f $os.BuildNumber, $ubr, $model, $up, $freeGb)
}

function Get-UninstallLine {
    param([string]$Pattern)
    $hits = @()
    foreach ($root in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall') {
        $view = if ($root -like '*WOW6432Node*') { 'x86' } else { 'x64' }
        foreach ($key in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            $p = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
            if ($p -and $p.DisplayName -and $p.DisplayName -match $Pattern) {
                $hits += ('{0} v{1} {2} [{3}]' -f $p.DisplayName, $p.DisplayVersion, $view, $key.PSChildName)
            }
        }
    }
    if ($hits.Count) { return ('ARP ' + ($hits -join '; ')) }
    return 'ARP none'
}

function Get-MsiDbLine {
    param([string]$Pattern)
    $hits = @()
    foreach ($key in @(Get-ChildItem -LiteralPath 'HKLM:\SOFTWARE\Classes\Installer\Products' -ErrorAction SilentlyContinue)) {
        $n = (Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue).ProductName
        if ($n -and $n -match $Pattern) { $hits += ('{0} [{1}]' -f $n, $key.PSChildName) }
    }
    if ($hits.Count) { return ('MSIDB ' + ($hits -join '; ')) }
    return 'MSIDB none'
}

function Get-MsiEventLine {
    param([string]$Pattern, [int]$Days)
    $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'MsiInstaller'; StartTime = (Get-Date).AddDays(-$Days) } -ErrorAction SilentlyContinue |
        Where-Object { $_.Message -match $Pattern } | Select-Object -First 4)
    if (-not $ev.Count) { return 'MSIEVT none' }
    $lines = foreach ($e in $ev) {
        $status = if ($e.Id -eq 1033 -and $e.Message -match 'status:\s*(\d+)') { ' status=' + $Matches[1] } else { '' }
        '{0} id{1}{2}' -f $e.TimeCreated.ToString('MM/dd HH:mm'), $e.Id, $status
    }
    return ('MSIEVT ' + ($lines -join '; '))
}

function Get-LogLine {
    param([string]$Folder, [string]$ErrorPattern)
    $log = Get-ChildItem -LiteralPath $Folder -Filter '*.log' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $log) { return ('LOG ' + (Split-Path $Folder -Leaf) + ': none') }
    $age = [Math]::Round(((Get-Date) - $log.LastWriteTime).TotalHours, 1)
    $errs = @(Select-String -LiteralPath $log.FullName -Pattern $ErrorPattern -ErrorAction SilentlyContinue | Select-Object -Last 2 | ForEach-Object { $_.Line.Trim() })
    $tail = if ($errs.Count) { $errs -join ' / ' } else { 'no error-like lines' }
    return ('LOG {0} ({1}h old): {2}' -f $log.Name, $age, $tail)
}

function Invoke-Main {
    $parts = New-Object System.Collections.Generic.List[string]
    try {
        $parts.Add((Get-OsLine))
        $parts.Add('REBOOT ' + (Get-PendingRebootFlag))
        $svc = @(Get-Service -Name $Config.ServiceNames -ErrorAction SilentlyContinue)
        $parts.Add('SVC ' + $(if ($svc.Count) { ($svc | ForEach-Object { '{0}={1}/{2}' -f $_.Name, $_.Status, $_.StartType }) -join ' ' } else { 'none' }))
        $parts.Add((Get-UninstallLine -Pattern $Config.ProductNamePattern))
        $parts.Add((Get-MsiDbLine -Pattern $Config.ProductNamePattern))
        $parts.Add('DIR ' + (($Config.Folders | ForEach-Object { '{0}={1}' -f (Split-Path $_ -Leaf), (Test-Path -LiteralPath $_) }) -join ' '))
        $parts.Add((Get-MsiEventLine -Pattern $Config.ProductNamePattern.TrimStart('^') -Days $Config.MsiEventDays))
        foreach ($f in $Config.LogFolders) { $parts.Add((Get-LogLine -Folder $f -ErrorPattern $Config.LogErrorPattern)) }
    }
    catch {
        $parts.Add('RECON ERROR: ' + $_.Exception.Message)
    }
    Write-Output (Format-RemediationOutput -Part $parts)
    exit $Config.ReportExitCode
}

if ($MyInvocation.InvocationName -ne '.') {
    # region Ensure64Bit
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        $ps64 = Join-Path $env:WINDIR 'sysnative\WindowsPowerShell\v1.0\powershell.exe'
        if (Test-Path -LiteralPath $ps64) {
            $relaunch = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
            foreach ($entry in $PSBoundParameters.GetEnumerator()) {
                if ($entry.Value -is [System.Management.Automation.SwitchParameter]) {
                    if ($entry.Value.IsPresent) { $relaunch += ('-' + $entry.Key) }
                }
                else {
                    $relaunch += ('-' + $entry.Key)
                    $relaunch += [string]$entry.Value
                }
            }
            & $ps64 @relaunch
            exit $LASTEXITCODE
        }
        Write-Output 'ERROR: running in a 32-bit host and the sysnative path is missing. Set "Run script in 64-bit PowerShell" to Yes.'
        exit 1
    }
    # endregion Ensure64Bit
    Invoke-Main
}
