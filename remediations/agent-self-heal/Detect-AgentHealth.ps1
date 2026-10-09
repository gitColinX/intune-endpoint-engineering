<#
.SYNOPSIS
    Intune Remediations detection script: is the agent installed and are all of its services Running?

.DESCRIPTION
    Read-only. Changes nothing on the device.

    Exit 0 and "HEALTHY: ..." when at least MinimumServiceCount services match
    ServiceNames and every one of them is Running.

    Exit 1 and "UNHEALTHY: ..." otherwise, with enough state in the output to
    triage from the portal without remoting in: which services exist and their
    status and start type, whether the install folder exists, and which
    Add/Remove Programs entries match the product name.

    Pair with Remediate-AgentSelfHeal.ps1. Keep the configuration blocks of the
    two scripts identical.

    Intune settings: run as SYSTEM, "Run script in 64-bit PowerShell" = Yes,
    signature check off unless you sign your scripts.

.NOTES
    Pattern status: [built, ran on real tickets]. The original worked a stranded
    group of devices for an RMM agent at my employer in July and August 2026.
    This file is a fresh rewrite, generalized from what I ran at work, tested
    only against synthetic input. Replace every Contoso placeholder before use.
#>
[CmdletBinding()]
param()

$Config = @{
    # Service names or wildcards. Every matching service must be Running.
    ServiceNames          = @('ContosoAgent*')
    # Regex. Services whose name matches are ignored (for example a remote
    # support service the vendor installs next to the agent but manages itself).
    ExcludeServicePattern = '^ContosoAgentRemoteSupport'
    # Fewer matching services than this counts as not installed.
    MinimumServiceCount   = 2
    # Regex matched against Add/Remove Programs DisplayName, for reporting.
    ProductNamePattern    = '^Contoso (RMM Agent|Agent Platform)\b'
    # Folder that exists when the agent is installed, for reporting.
    InstallFolder         = 'C:\Program Files (x86)\Contoso\Agent'
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

function Get-AgentService {
    param([hashtable]$Settings)
    $found = @(Get-Service -Name $Settings.ServiceNames -ErrorAction SilentlyContinue)
    if ($Settings.ExcludeServicePattern) {
        $found = @($found | Where-Object { $_.Name -notmatch $Settings.ExcludeServicePattern })
    }
    return $found
}

function Test-AgentHealthy {
    # Pure decision: takes objects with Name and Status, returns $true only when
    # enough services exist and none of them is anything other than Running.
    param(
        [AllowEmptyCollection()][object[]]$Service,
        [int]$MinimumServiceCount = 1
    )
    if ($null -eq $Service -or @($Service).Count -lt $MinimumServiceCount) { return $false }
    $notRunning = @($Service | Where-Object { [string]$_.Status -ne 'Running' })
    return ($notRunning.Count -eq 0)
}

function Get-MatchingUninstallEntry {
    param([string]$Pattern)
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($root in $roots) {
        foreach ($key in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            $p = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
            if ($p -and $p.DisplayName -and ($p.DisplayName -match $Pattern)) {
                [pscustomobject]@{
                    DisplayName    = [string]$p.DisplayName
                    DisplayVersion = [string]$p.DisplayVersion
                    KeyName        = $key.PSChildName
                }
            }
        }
    }
}

function Invoke-Main {
    try {
        $svc = Get-AgentService -Settings $Config
        $svcText = if ($svc.Count) { ($svc | ForEach-Object { '{0}={1}/{2}' -f $_.Name, $_.Status, $_.StartType }) -join ' ' } else { 'none' }
        if (Test-AgentHealthy -Service $svc -MinimumServiceCount $Config.MinimumServiceCount) {
            Write-Output ('HEALTHY: ' + $svcText)
            exit 0
        }
        $parts = New-Object System.Collections.Generic.List[string]
        $parts.Add('UNHEALTHY: services ' + $svcText + ' (need ' + $Config.MinimumServiceCount + ' Running)')
        $parts.Add('folder=' + (Test-Path -LiteralPath $Config.InstallFolder))
        $arp = @(Get-MatchingUninstallEntry -Pattern $Config.ProductNamePattern)
        if ($arp.Count) {
            $parts.Add('ARP: ' + (($arp | ForEach-Object { '{0} v{1} [{2}]' -f $_.DisplayName, $_.DisplayVersion, $_.KeyName }) -join '; '))
        }
        else {
            $parts.Add('ARP: none')
        }
        Write-Output (Format-RemediationOutput -Part $parts)
        exit 1
    }
    catch {
        Write-Output (Format-RemediationOutput -Part @('DETECTION ERROR', $_.Exception.Message))
        exit 1
    }
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
