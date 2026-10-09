<#
.SYNOPSIS
    Removes an app installed by Install-PortableApp.ps1, then verifies it is gone.

.DESCRIPTION
    Reads portable-app.json from TargetFolder (or from this script's own folder
    when run from the Add/Remove Programs entry), stops processes running from
    the folder, removes the shortcut, the Add/Remove Programs key and the
    folder, removes the publisher folder if it is now empty, and reads back.

    Refuses to delete anything that is not at least two levels below Program Files.

    DRY RUN unless -Apply is passed.

.NOTES
    Pattern status: [built, ran on real tickets]. Fresh rewrite, generalized
    from what I ran at work.
#>
[CmdletBinding()]
param(
    [string]$TargetFolder = '',
    [switch]$Apply
)

function Test-SafeRemovalPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if (-not [System.IO.Path]::IsPathRooted($Path)) { return $false }
    if ($Path -match '\.\.') { return $false }
    $full = $Path.TrimEnd('\')
    $roots = @('C:\Program Files', 'C:\Program Files (x86)', 'C:\ProgramData')
    foreach ($r in $roots) {
        if ($full.StartsWith($r + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            $rest = $full.Substring($r.Length + 1)
            if (@($rest.Split('\') | Where-Object { $_ }).Count -ge 2) { return $true }
        }
    }
    return $false
}

if ($MyInvocation.InvocationName -eq '.') { return }

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

if (-not $TargetFolder) { $TargetFolder = $PSScriptRoot }
$manifestPath = Join-Path $TargetFolder 'portable-app.json'
if (-not (Test-Path -LiteralPath $manifestPath)) {
    Write-Output "Nothing to do: no portable-app.json in $TargetFolder"
    exit 0
}
$m = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$target = [string]$m.TargetFolder
$regKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\' + $m.RegistryKeyName

if (-not (Test-SafeRemovalPath -Path $target)) {
    Write-Output "Refusing: $target is not at least two levels below Program Files or ProgramData"
    exit 1
}

if (-not $Apply) {
    Write-Output 'DRY-RUN (pass -Apply to uninstall). Would remove:'
    Write-Output "  processes running from $target"
    if ($m.Shortcut) { Write-Output "  $($m.Shortcut)" }
    Write-Output "  $regKey"
    Write-Output "  $target"
    exit 0
}

$log = Join-Path $env:WINDIR ('Temp\' + $m.RegistryKeyName + '_Uninstall.log')
Start-Transcript -Path $log -Append | Out-Null
Set-Location -LiteralPath $env:WINDIR
Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($target + '\', [System.StringComparison]::OrdinalIgnoreCase) } |
    Stop-Process -Force -ErrorAction SilentlyContinue
if ($m.Shortcut) { Remove-Item -LiteralPath $m.Shortcut -Force -ErrorAction SilentlyContinue }
Remove-Item -LiteralPath $regKey -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
$parent = Split-Path $target -Parent
if ((Test-Path -LiteralPath $parent) -and -not (Get-ChildItem -LiteralPath $parent -Force -ErrorAction SilentlyContinue) -and (Test-SafeRemovalPath -Path (Join-Path $parent 'x'))) {
    Remove-Item -LiteralPath $parent -Force -ErrorAction SilentlyContinue
}

$left = @()
if (Test-Path -LiteralPath $regKey) { $left += 'registry key' }
if (Test-Path -LiteralPath $target) { $left += 'folder' }
if ($m.Shortcut -and (Test-Path -LiteralPath $m.Shortcut)) { $left += 'shortcut' }
Stop-Transcript | Out-Null
if ($left.Count) {
    Write-Output ('Uninstall incomplete, still present: ' + ($left -join ', '))
    exit 1
}
Write-Output "Uninstalled $($m.AppName); registry key, folder and shortcut verified gone."
exit 0
