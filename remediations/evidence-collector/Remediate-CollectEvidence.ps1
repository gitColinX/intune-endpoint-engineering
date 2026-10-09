<#
.SYNOPSIS
    Intune Remediations remediation script: collect an evidence bundle and stage
    it where Intune "Collect diagnostics" picks it up.

.DESCRIPTION
    The problem this solves: a device is failing, you have no remote session
    (no line of sight for PsExec, no user available for a remote support
    session), and the logs you need sit on the device. Intune's Collect
    diagnostics action uploads the Intune Management Extension Logs folder
    (C:\ProgramData\Microsoft\IntuneManagementExtension\Logs). So: run as
    SYSTEM, gather what you need, zip it, and drop the zip into that folder.
    Then trigger Collect diagnostics on the device and download the result from
    the portal.

    Collected (all configurable):
      - event logs for the last DaysBack days (wevtutil epl with a time query)
      - vendor and setup log folders, filtered by pattern, files over MaxFileMB skipped
      - registry exports (Uninstall keys in both views by default)
      - services matching ServiceNamePattern: state, start mode, account, binary path
      - systeminfo, ipconfig /all, WinHTTP proxy
      - optional HEAD requests to URLs you list (empty by default)
    Not collected: anything under C:\Users. Add it only if you need it and your
    privacy rules allow it.

    A second copy of the zip stays in WorkFolder. The work folder sits under
    Program Files and goes through New-PrivateFolder (refused if someone else
    created it or it is a junction, owner and ACL read back), because the
    script stages files there and then deletes the staging folder recursively
    as SYSTEM. Robocopy runs with /XJ so a junction planted in a vendor log
    folder is not followed. Old bundles beyond KeepBundles are pruned from both
    places.

    DRY RUN BY DEFAULT: without -Apply (local) or ApplyWhenNoParameter = $true
    (uploaded copy) it lists what it would collect and how big it is, and writes
    nothing.

    Keep bundles small. MaxBundleMB is a setting, not a Microsoft limit: the
    default of 50 is a size I chose to keep uploads small. Set it for your
    devices and network, and check Microsoft's current Collect diagnostics
    documentation before you raise it. When a bundle comes out over
    MaxBundleMB, the script deletes it and leaves a small _TOOBIG.txt note in
    IME Logs instead. The detection script treats that note like a
    recent bundle, so a recurring schedule backs off instead of building
    another oversized zip every cycle.

.NOTES
    Pattern status: [built, ran on real tickets]. The original found that one
    device's agent had been dead for most of a year, without anyone touching
    the device. Fresh rewrite, generalized from what I ran at work,
    parse-checked and tested against synthetic input only.
#>
[CmdletBinding()]
param(
    [switch]$Apply
)

$Config = @{
    ImeLogs              = 'C:\ProgramData\Microsoft\IntuneManagementExtension\Logs'
    BundlePrefix         = 'Evidence_ContosoAgent_'
    # Under Program Files: standard users cannot pre-create it there.
    WorkFolder           = 'C:\Program Files\EvidenceCollector'
    DaysBack             = 14
    EventChannels        = @(
        'Application',
        'System',
        'Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Admin',
        'Microsoft-Windows-AppLocker/MSI and Script',
        'Microsoft-Windows-AppLocker/EXE and DLL',
        'Microsoft-Windows-CodeIntegrity/Operational'
    )
    FileSources          = @(
        @{ Name = 'Agent'; Path = 'C:\Program Files (x86)\Contoso\Agent'; Include = @('*.log', '*.txt', '*.json', '*.config') },
        @{ Name = 'AgentSetup'; Path = 'C:\Program Files (x86)\Contoso\AgentSetupLogs'; Include = @('*.log', '*.txt') },
        @{ Name = 'IME'; Path = 'C:\ProgramData\Microsoft\IntuneManagementExtension\Logs'; Include = @('*.log') }
    )
    RegistryExports      = @(
        'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    ServiceNamePattern   = '^ContosoAgent'
    ConnectivityUrls     = @()
    MaxFileMB            = 25
    # A size you choose, not a Microsoft limit. See the description above.
    MaxBundleMB          = 50
    KeepBundles          = 2
    ApplyWhenNoParameter = $false
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

function ConvertTo-SafeFileName {
    # Pure: event channel or registry path to a file name.
    param([string]$Name)
    $s = ($Name -replace '[\\/:*?"<>| ]+', '_').Trim('_')
    if ($s.Length -gt 100) { $s = $s.Substring(0, 100) }
    return $s
}

function Get-EventTimeQuery {
    # Pure: XPath for wevtutil limiting events to the last N days.
    param([int]$Days)
    $ms = [int64]$Days * 24 * 60 * 60 * 1000
    return "*[System[TimeCreated[timediff(@SystemTime) <= $ms]]]"
}

function Measure-Source {
    param([hashtable]$Source, [int]$MaxFileMB)
    if (-not (Test-Path -LiteralPath $Source.Path)) { return ('{0}: missing' -f $Source.Name) }
    # Filter by name here: -Include with -LiteralPath is unreliable in Windows PowerShell 5.1.
    $files = @(Get-ChildItem -LiteralPath $Source.Path -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
            $n = $_.Name
            @($Source.Include | Where-Object { $n -like $_ }).Count -gt 0
        })
    $small = @($files | Where-Object { $_.Length -le ($MaxFileMB * 1MB) })
    $mb = [Math]::Round((($small | Measure-Object -Property Length -Sum).Sum) / 1MB, 1)
    return ('{0}: {1} files, {2} MB ({3} skipped as too large)' -f $Source.Name, $small.Count, $mb, ($files.Count - $small.Count))
}

# region PrivateFolder
function Test-TrustedFolderState {
    # Pure: '' when the state is safe for SYSTEM to run files from, else the reason.
    # Rule objects need Sid and Type (Allow or Deny).
    param(
        [string]$OwnerSid,
        [AllowEmptyCollection()][object[]]$Rule = @(),
        [bool]$Protected,
        [bool]$IsReparsePoint
    )
    $trusted = @('S-1-5-18', 'S-1-5-32-544')
    if ($IsReparsePoint) { return 'it is a reparse point (junction or symbolic link)' }
    if ($trusted -notcontains $OwnerSid) { return "owner $OwnerSid is not SYSTEM or Administrators" }
    if (-not $Protected) { return 'it still inherits permissions from its parent' }
    foreach ($r in $Rule) {
        if ([string]$r.Type -eq 'Allow' -and $trusted -notcontains [string]$r.Sid) { return "its ACL allows $($r.Sid)" }
    }
    return ''
}

function Get-FolderState {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force
    $acl = Get-Acl -LiteralPath $Path
    $sidType = [System.Security.Principal.SecurityIdentifier]
    $rules = @($acl.GetAccessRules($true, $true, $sidType) | ForEach-Object {
            [pscustomobject]@{ Sid = $_.IdentityReference.Value; Type = [string]$_.AccessControlType }
        })
    return [pscustomobject]@{
        OwnerSid       = $acl.GetOwner($sidType).Value
        Rule           = $rules
        Protected      = [bool]$acl.AreAccessRulesProtected
        IsReparsePoint = [bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
    }
}

function New-PrivateFolder {
    param([Parameter(Mandatory = $true)][string]$Path)
    $parent = Split-Path -Parent $Path
    while ($parent) {
        if (Test-Path -LiteralPath $parent) {
            if ((Get-Item -LiteralPath $parent -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                throw "Refusing $Path : parent $parent is a junction or symbolic link"
            }
        }
        $next = Split-Path -Parent $parent
        if (-not $next -or $next -eq $parent) { break }
        $parent = $next
    }
    if (Test-Path -LiteralPath $Path) {
        $s = Get-FolderState -Path $Path
        if ($s.IsReparsePoint) { throw "Refusing $Path : it is a junction or symbolic link" }
        if (@('S-1-5-18', 'S-1-5-32-544') -notcontains $s.OwnerSid) {
            throw "Refusing $Path : it already exists and is owned by $($s.OwnerSid), not SYSTEM or Administrators. Check who created it before removing it."
        }
    }
    else {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
    & icacls.exe $Path /setowner '*S-1-5-32-544' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls /setowner failed on $Path (exit $LASTEXITCODE)" }
    & icacls.exe $Path /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls failed on $Path (exit $LASTEXITCODE)" }
    $s = Get-FolderState -Path $Path
    $why = Test-TrustedFolderState -OwnerSid $s.OwnerSid -Rule $s.Rule -Protected $s.Protected -IsReparsePoint $s.IsReparsePoint
    if ($why) { throw "Work folder $Path did not verify: $why" }
}
# endregion PrivateFolder

function Remove-OldBundle {
    param([string]$Folder, [string]$Prefix, [int]$Keep, [string]$Suffix = '*.zip')
    $old = @(Get-ChildItem -LiteralPath $Folder -Filter ($Prefix + $Suffix) -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -Skip $Keep)
    foreach ($f in $old) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue }
    return $old.Count
}

function Invoke-Collect {
    param([bool]$DoApply)
    $report = New-Object System.Collections.Generic.List[string]
    $code = 1
    try {
        if (-not $DoApply) {
            $report.Add('MODE: DRY-RUN (no changes)')
            $report.Add('WOULD export events (' + $Config.DaysBack + 'd): ' + ($Config.EventChannels -join ', '))
            foreach ($s in $Config.FileSources) { $report.Add('WOULD copy ' + (Measure-Source -Source $s -MaxFileMB $Config.MaxFileMB)) }
            $report.Add('WOULD export registry: ' + ($Config.RegistryExports -join ', '))
            if ($Config.ConnectivityUrls.Count) { $report.Add('WOULD HEAD: ' + ($Config.ConnectivityUrls -join ', ')) }
            $report.Add('WOULD zip to ' + $Config.WorkFolder + ' and copy to ' + $Config.ImeLogs)
            return @{ Code = 0; Report = $report }
        }

        $report.Add('MODE: APPLY')
        New-PrivateFolder -Path $Config.WorkFolder
        $stamp = Get-Date -Format 'yyyyMMdd_HHmm'
        # A fresh, unpredictable staging folder. No -Force: if it already exists, stop.
        $stage = Join-Path $Config.WorkFolder ('stage_' + $stamp + '_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $stage | Out-Null

        $q = Get-EventTimeQuery -Days $Config.DaysBack
        $evOk = 0
        foreach ($ch in $Config.EventChannels) {
            $dest = Join-Path $stage ((ConvertTo-SafeFileName -Name $ch) + '.evtx')
            & wevtutil.exe epl $ch $dest "/q:$q" /ow:true 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { $evOk++ }
        }
        $report.Add("EVENTS: $evOk of $($Config.EventChannels.Count) channels")

        $maxBytes = [int64]$Config.MaxFileMB * 1MB
        foreach ($s in $Config.FileSources) {
            if (-not (Test-Path -LiteralPath $s.Path)) { $report.Add("FILES $($s.Name): missing"); continue }
            $dest = Join-Path $stage ('files_' + (ConvertTo-SafeFileName -Name $s.Name))
            $rcArgs = @($s.Path, $dest) + @($s.Include) + @('/S', '/XJ', "/MAX:$maxBytes", '/R:0', '/W:0', '/NFL', '/NDL', '/NJH', '/NJS', '/NP')
            & robocopy.exe @rcArgs | Out-Null
            $rc = $LASTEXITCODE
            $n = @(Get-ChildItem -LiteralPath $dest -Recurse -File -ErrorAction SilentlyContinue).Count
            $report.Add(('FILES {0}: {1} copied (robocopy {2})' -f $s.Name, $n, $rc))
        }

        foreach ($k in $Config.RegistryExports) {
            $dest = Join-Path $stage ('reg_' + (ConvertTo-SafeFileName -Name $k) + '.reg')
            & reg.exe export $k $dest /y 2>&1 | Out-Null
        }

        Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $Config.ServiceNamePattern } |
            Select-Object Name, State, StartMode, StartName, PathName | Format-List | Out-File -FilePath (Join-Path $stage 'services.txt') -Encoding utf8
        & systeminfo.exe 2>&1 | Out-File -FilePath (Join-Path $stage 'systeminfo.txt') -Encoding utf8
        & ipconfig.exe /all 2>&1 | Out-File -FilePath (Join-Path $stage 'ipconfig.txt') -Encoding utf8
        & netsh.exe winhttp show proxy 2>&1 | Out-File -FilePath (Join-Path $stage 'winhttp_proxy.txt') -Encoding utf8

        if ($Config.ConnectivityUrls.Count) {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            foreach ($u in $Config.ConnectivityUrls) {
                try {
                    $r = Invoke-WebRequest -Uri $u -Method Head -UseBasicParsing -TimeoutSec 10
                    Add-Content -LiteralPath (Join-Path $stage 'connectivity.txt') -Value "$u -> HTTP $($r.StatusCode)"
                }
                catch {
                    Add-Content -LiteralPath (Join-Path $stage 'connectivity.txt') -Value "$u -> FAIL $($_.Exception.Message)"
                }
            }
        }

        $zipName = $Config.BundlePrefix + $stamp + '.zip'
        $zip = Join-Path $Config.WorkFolder $zipName
        Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -Force
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
        $zipMb = [Math]::Round((Get-Item -LiteralPath $zip).Length / 1MB, 1)
        if ($zipMb -gt $Config.MaxBundleMB) {
            # Do not keep it: on an hourly schedule, oversized zips would pile up and
            # fill the disk of the device you are trying to diagnose. Leave a small
            # note instead; the detection script backs off while the note is recent.
            Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
            $note = Join-Path $Config.ImeLogs ($Config.BundlePrefix + $stamp + '_TOOBIG.txt')
            Set-Content -LiteralPath $note -Encoding ascii -Value @(
                "Evidence bundle $zipName came out at $zipMb MB, over MaxBundleMB $($Config.MaxBundleMB).",
                'Deleted. Narrow FileSources or DaysBack, or raise MaxBundleMB.'
            )
            [void](Remove-OldBundle -Folder $Config.ImeLogs -Prefix $Config.BundlePrefix -Keep $Config.KeepBundles -Suffix '*_TOOBIG.txt')
            $report.Add("TOO BIG: $zipName was $zipMb MB (limit $($Config.MaxBundleMB)); deleted, note left in IME Logs, detection backs off")
            return @{ Code = 1; Report = $report }
        }
        Copy-Item -LiteralPath $zip -Destination (Join-Path $Config.ImeLogs $zipName) -Force
        $staged = Get-Item -LiteralPath (Join-Path $Config.ImeLogs $zipName) -ErrorAction SilentlyContinue
        $pruned = (Remove-OldBundle -Folder $Config.ImeLogs -Prefix $Config.BundlePrefix -Keep $Config.KeepBundles) +
                  (Remove-OldBundle -Folder $Config.WorkFolder -Prefix $Config.BundlePrefix -Keep $Config.KeepBundles)
        if ($staged -and $staged.Length -eq (Get-Item -LiteralPath $zip).Length) {
            $report.Add("STAGED: $zipName ($zipMb MB) in IME Logs, verified; pruned $pruned old bundle(s). Now run Collect diagnostics on this device.")
            $code = 0
        }
        else {
            $report.Add("STAGE FAILED: copy of $zipName to IME Logs did not verify")
            $code = 1
        }
    }
    catch {
        $report.Add('ERROR: ' + $_.Exception.Message)
        $code = 1
    }
    return @{ Code = $code; Report = $report }
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
    $result = @(Invoke-Collect -DoApply ($Apply.IsPresent -or [bool]$Config.ApplyWhenNoParameter))[-1]
    Write-Output (Format-RemediationOutput -Part $result.Report)
    exit $result.Code
}
