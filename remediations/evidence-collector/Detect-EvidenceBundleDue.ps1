<#
.SYNOPSIS
    Intune Remediations detection script: is an evidence bundle due on this device?

.DESCRIPTION
    Read-only. Exit 1 (bundle due, run the collector) when the IME Logs folder
    holds no bundle with this prefix newer than MaxAgeHours. Exit 0 otherwise.
    That keeps a recurring schedule from building a fresh zip every hour.

    A recent _TOOBIG.txt note from the collector counts too: it means the last
    bundle came out over the size limit and was deleted, so the schedule backs
    off instead of building another oversized zip every cycle. The output says
    so, so it is visible in the report.

    Pair with Remediate-CollectEvidence.ps1 and keep BundlePrefix identical.
    Assign to a small device group (the devices you are investigating), not to
    the fleet.

    No 64-bit guard: it reads only a folder under ProgramData, which is the
    same from a 32-bit or a 64-bit host.

.NOTES
    Pattern status: [built, ran on real tickets]. Fresh rewrite, generalized
    from what I ran at work.
#>
[CmdletBinding()]
param()

$Config = @{
    ImeLogs      = 'C:\ProgramData\Microsoft\IntuneManagementExtension\Logs'
    BundlePrefix = 'Evidence_ContosoAgent_'
    MaxAgeHours  = 20
}

function Get-RecentBundle {
    # Newest first: bundles (.zip) and too-big notes (_TOOBIG.txt) newer than Hours.
    param([string]$Folder, [string]$Prefix, [int]$Hours)
    $cutoff = (Get-Date).AddHours(-$Hours)
    $zips = @(Get-ChildItem -LiteralPath $Folder -Filter ($Prefix + '*.zip') -File -ErrorAction SilentlyContinue)
    $notes = @(Get-ChildItem -LiteralPath $Folder -Filter ($Prefix + '*_TOOBIG.txt') -File -ErrorAction SilentlyContinue)
    return @(@($zips) + @($notes) | Where-Object { $_.LastWriteTime -gt $cutoff } | Sort-Object LastWriteTime -Descending)
}

if ($MyInvocation.InvocationName -ne '.') {
    $recent = Get-RecentBundle -Folder $Config.ImeLogs -Prefix $Config.BundlePrefix -Hours $Config.MaxAgeHours
    if ($recent.Count) {
        $f = $recent[0]
        if ($f.Name -like '*_TOOBIG.txt') {
            Write-Output ('BUNDLE TOO BIG at {0}: see {1} in IME Logs; narrow the collector before the next run' -f $f.LastWriteTime.ToString('MM/dd HH:mm'), $f.Name)
        }
        else {
            Write-Output ('BUNDLE PRESENT: {0} ({1} MB, {2})' -f $f.Name, [Math]::Round($f.Length / 1MB, 1), $f.LastWriteTime.ToString('MM/dd HH:mm'))
        }
        exit 0
    }
    Write-Output ('BUNDLE DUE: none newer than {0}h in IME Logs' -f $Config.MaxAgeHours)
    exit 1
}
