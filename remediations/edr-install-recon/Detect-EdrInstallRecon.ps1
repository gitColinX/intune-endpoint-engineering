<#
.SYNOPSIS
    Intune Remediations detection-only recon for a security agent that will not install.

.DESCRIPTION
    Read-only. No remediation script attached. Built for the moment when an
    EDR sensor rollout through Intune leaves a block of devices at "Failed"
    with the same generic installer error (0x80070643, MSI 1603) and the
    install-status report cannot tell you why.

    Per device, in one line that fits the 2,048-character limit:
      Model, Build.UBR, UptimeDays, FreeGB, Reboot (CBS / WU / PFR)
      New sensor: service state, binary version, which folders exist, ARP version
      Each outgoing agent: service state, driver service state, binary version
      Other security services (Defender by default)
      Loaded file-system minifilters that are not on the ignore list (fltmc)
      MsiStatus: the status code from the latest MsiInstaller 1033 event for the product
      MsiErrEvt: the latest MsiInstaller failure event for the product, from
                 MsiErrorEventIds (default 11708 install failed, 11711,
                 11722 for an Error 1722 custom action failure, 11725 removal
                 failed). 11724 is a successful removal and is left out. Add
                 other ids only after you have seen them on a failing device.
      Bootstrapper log in C:\Windows\Temp: count, newest name, first line,
      last error-like lines, final line

    The point is to compare failing devices against healthy ones on the things
    that differ: an older build of the outgoing agent, a driver still loaded, a
    pending reboot, a full disk.

    Intune settings: run as SYSTEM, "Run script in 64-bit PowerShell" = Yes.
    Assign it to a group holding only the failed bucket.

.NOTES
    Pattern status: [built, ran on real tickets] (run and finding per my notes;
    no recon export kept). In an EDR migration at my employer the failed bucket
    lined up with an older build of the outgoing agent blocking the new
    sensor's driver. The file-backed part is the revision: the first draft did
    not record the outgoing agent's exact build and the second did. Fresh
    rewrite, generalized from what I ran at work, tested against synthetic
    input only.
#>
[CmdletBinding()]
param()

$Config = @{
    NewServiceName         = 'ContosoSensorService'
    NewAgentExe            = 'C:\Program Files\Contoso\Sensor\ContosoSensorService.exe'
    NewAgentFolders        = @(
        @{ Label = 'PF'; Path = 'C:\Program Files\Contoso\Sensor' },
        @{ Label = 'DRV'; Path = 'C:\Windows\System32\drivers\ContosoSensor' },
        @{ Label = 'PD'; Path = 'C:\ProgramData\Contoso\Sensor' }
    )
    NewProductPattern      = 'Contoso.*Sensor'
    BootstrapperLogPattern = 'ContosoSensor|SensorSetup'
    OutgoingAgents         = @(
        @{ Label = 'Old'; Service = 'FabrikamAgent'; DriverService = 'FabrikamMonitor' }
    )
    OtherServices          = @('WinDefend')
    CheckMinifilters       = $true
    IgnoreMinifilters      = @('bindflt', 'CldFlt', 'FileCrypt', 'FileInfo', 'luafv', 'npsvctrig', 'storqosflt', 'wcifs', 'Wof', 'WdFilter', 'UCPD', 'applockerfltr', 'bfs')
    LogErrorPattern        = 'error|fail|abort|denied|block|rollback|unable|cannot|tamper'
    MsiErrorEventIds       = @(11708, 11711, 11722, 11725)
    ReportExitCode         = 0
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

function Get-ServiceState {
    param([string]$Name)
    $s = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($s) { return [string]$s.Status }
    return 'None'
}

function Get-ServiceBinaryVersion {
    param([string]$Name)
    $svc = Get-CimInstance Win32_Service -Filter ("Name='{0}'" -f ($Name -replace "'", "''")) -ErrorAction SilentlyContinue
    if (-not $svc -or -not $svc.PathName) { return '-' }
    $path = Get-BinaryPathFromCommandLine -CommandLine $svc.PathName
    if ($path -and (Test-Path -LiteralPath $path)) { return [string](Get-Item -LiteralPath $path).VersionInfo.ProductVersion }
    return '-'
}

function Get-BinaryPathFromCommandLine {
    # Pure: '"C:\x y\a.exe" -k foo' -> 'C:\x y\a.exe'; 'C:\a.exe -k' -> 'C:\a.exe'
    param([string]$CommandLine)
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return '' }
    $c = $CommandLine.Trim()
    if ($c.StartsWith('"')) {
        $end = $c.IndexOf('"', 1)
        if ($end -gt 1) { return $c.Substring(1, $end - 1) }
        return $c.Trim('"')
    }
    $m = [regex]::Match($c, '^(.+?\.(exe|sys|dll))(\s|$)', 'IgnoreCase')
    if ($m.Success) { return $m.Groups[1].Value }
    return ($c -split '\s+')[0]
}

function Get-MinifilterName {
    # Pure: parse "fltmc filters" text into filter names (with altitude).
    param([string[]]$FltmcOutput, [string[]]$Ignore = @())
    $names = @()
    foreach ($line in $FltmcOutput) {
        if ($line -match '^\s*([A-Za-z0-9_\-\.]+)\s+(\d+)\s+(\d+(\.\d+)?)\s*') {
            if ($Matches[1] -eq 'Filter') { continue }
            if ($Ignore -contains $Matches[1]) { continue }
            $names += ('{0}@{1}' -f $Matches[1], $Matches[3])
        }
    }
    return $names
}

function Select-MsiErrorEvent {
    # Pure: the newest event whose id is in Id and whose message matches the product pattern.
    param([AllowEmptyCollection()][object[]]$EventRecord = @(), [int[]]$Id = @(), [string]$ProductPattern)
    return ($EventRecord | Where-Object { $Id -contains [int]$_.Id -and [string]$_.Message -match $ProductPattern } |
        Sort-Object TimeCreated -Descending | Select-Object -First 1)
}

function Get-PendingRebootFlag {
    $flags = @()
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $flags += 'CBS' }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $flags += 'WU' }
    $sm = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction SilentlyContinue
    if ($sm -and $sm.PendingFileRenameOperations) { $flags += 'PFR' }
    if ($flags.Count) { return ($flags -join '+') }
    return '-'
}

function Get-ShortLine {
    param([string]$Text, [int]$Max = 130)
    $t = ([string]$Text -replace '\s+', ' ').Trim()
    if ($t.Length -gt $Max) { $t = $t.Substring(0, $Max) }
    return $t
}

function Invoke-Main {
    $r = New-Object System.Collections.Generic.List[string]
    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
        $ubr = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue).UBR
        $r.Add('Model=' + $(if ($cs) { ([string]$cs.Model).Trim() } else { '?' }))
        $r.Add('Build=' + $os.BuildNumber + '.' + $ubr)
        if ($os) { $r.Add('UptimeDays=' + [Math]::Round(((Get-Date) - $os.LastBootUpTime).TotalDays, 1)) }
        $free = (Get-PSDrive -Name ($env:SystemDrive.TrimEnd(':')) -ErrorAction SilentlyContinue).Free
        if ($free) { $r.Add('FreeGB=' + [Math]::Round($free / 1GB, 1)) }
        $r.Add('Reboot=' + (Get-PendingRebootFlag))

        $r.Add('NewSvc=' + (Get-ServiceState -Name $Config.NewServiceName))
        $r.Add('NewVer=' + $(if (Test-Path -LiteralPath $Config.NewAgentExe) { (Get-Item -LiteralPath $Config.NewAgentExe).VersionInfo.ProductVersion } else { '-' }))
        $present = @($Config.NewAgentFolders | Where-Object { Test-Path -LiteralPath $_.Path } | ForEach-Object { $_.Label })
        $r.Add('NewDirs=' + $(if ($present.Count) { $present -join '+' } else { '-' }))
        $arp = Get-ChildItem -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' -ErrorAction SilentlyContinue |
            Get-ItemProperty -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match $Config.NewProductPattern } | Select-Object -First 1
        $r.Add('NewARP=' + $(if ($arp) { $arp.DisplayVersion } else { '-' }))

        foreach ($o in $Config.OutgoingAgents) {
            $r.Add(('{0}Svc={1} {0}Drv={2} {0}Ver={3}' -f $o.Label, (Get-ServiceState -Name $o.Service), (Get-ServiceState -Name $o.DriverService), (Get-ServiceBinaryVersion -Name $o.Service)))
        }
        foreach ($s in $Config.OtherServices) { $r.Add(('{0}={1}' -f $s, (Get-ServiceState -Name $s))) }

        if ($Config.CheckMinifilters) {
            $flt = @(& fltmc.exe filters 2>$null)
            if ($LASTEXITCODE -eq 0 -and $flt.Count) {
                $names = @(Get-MinifilterName -FltmcOutput $flt -Ignore $Config.IgnoreMinifilters)
                $r.Add('Minifilters=' + $(if ($names.Count) { $names -join ',' } else { 'none beyond ignore list' }))
            }
            else {
                $r.Add('Minifilters=unavailable')
            }
        }

        $evt = Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'MsiInstaller'; Id = 1033 } -MaxEvents 300 -ErrorAction SilentlyContinue |
            Where-Object { $_.Message -match $Config.NewProductPattern } | Select-Object -First 1
        if ($evt) {
            $code = if ($evt.Message -match 'status:\s*(\d+)') { $Matches[1] } else { 'unparsed' }
            $r.Add('MsiStatus=' + $code + '@' + $evt.TimeCreated.ToString('MM/dd-HH:mm'))
        }
        else { $r.Add('MsiStatus=-') }
        $msiEvents = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'MsiInstaller'; Id = $Config.MsiErrorEventIds } -MaxEvents 400 -ErrorAction SilentlyContinue)
        $evt2 = Select-MsiErrorEvent -EventRecord $msiEvents -Id $Config.MsiErrorEventIds -ProductPattern $Config.NewProductPattern
        $r.Add('MsiErrEvt=' + $(if ($evt2) { '{0}@{1}' -f $evt2.Id, $evt2.TimeCreated.ToString('MM/dd') } else { '-' }))

        $logs = @(Get-ChildItem -LiteralPath (Join-Path $env:WINDIR 'Temp') -Filter '*.log' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match $Config.BootstrapperLogPattern } | Sort-Object LastWriteTime -Descending)
        $r.Add('SetupLogs=' + $logs.Count)
        if ($logs.Count) {
            $log = $logs[0]
            $r.Add('SetupLog=' + $log.Name)
            $r.Add('Head=' + (Get-ShortLine -Text (Get-Content -LiteralPath $log.FullName -TotalCount 1 -ErrorAction SilentlyContinue) -Max 120))
            $errs = @(Select-String -LiteralPath $log.FullName -Pattern $Config.LogErrorPattern -ErrorAction SilentlyContinue | Select-Object -Last 3)
            foreach ($e in $errs) { $r.Add(('Err=L{0}: {1}' -f $e.LineNumber, (Get-ShortLine -Text $e.Line))) }
            if (-not $errs.Count) { $r.Add('Err=none-matched') }
            $r.Add('End=' + (Get-ShortLine -Text (Get-Content -LiteralPath $log.FullName -Tail 1 -ErrorAction SilentlyContinue)))
        }
    }
    catch {
        $r.Add('RECON ERROR: ' + $_.Exception.Message)
    }
    Write-Output (Format-RemediationOutput -Part $r -Separator ' | ')
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
