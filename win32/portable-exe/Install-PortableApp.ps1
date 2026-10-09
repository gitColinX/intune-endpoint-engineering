<#
.SYNOPSIS
    Win32 app install wrapper that turns a portable, installer-less EXE into a managed app.

.DESCRIPTION
    Some tools ship as a single EXE with no installer. Intune can still deliver
    them as a Win32 app, but users then have no Start Menu entry, nothing shows
    in Settings > Apps, and there is no clean way to remove it. This wrapper:

      1. copies the EXE (and Uninstall-PortableApp.ps1) into Program Files
      2. removes the downloaded-from-internet mark (Unblock-File)
      3. creates an all-users Start Menu shortcut (unless -NoShortcut)
      4. writes a synthetic Add/Remove Programs entry: DisplayName, DisplayVersion
         read from the EXE's own version resource, Publisher, InstallLocation,
         DisplayIcon, UninstallString, QuietUninstallString, NoModify, NoRepair,
         EstimatedSize, InstallDate
      5. writes portable-app.json next to the EXE so the uninstaller knows what to remove
      6. reads every value back and exits 1 if anything does not match

    DRY RUN unless -Apply is passed. Put -Apply in the Intune install command.

    Intune install command (32-bit host, so go through sysnative):
      %windir%\sysnative\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-PortableApp.ps1 -AppName "Example Viewer" -Publisher "Example Publisher" -ExeName "ExampleViewer.exe" -Apply
    Intune uninstall command:
      %windir%\sysnative\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Uninstall-PortableApp.ps1 -TargetFolder "C:\Program Files\Example Publisher\Example Viewer" -Apply
    Detection rule: File, C:\Program Files\Example Publisher\Example Viewer\ExampleViewer.exe,
      Version greater than or equal to the packaged build.

.NOTES
    Pattern status: [built, ran on real tickets]. Used for a portable
    engineering file viewer that was packaged and assigned for a software
    request; I do not have install counts for it on file. Fresh rewrite,
    generalized from what I ran at work. Parse-checked; the pure helpers are unit-tested. Not run as SYSTEM
    in this form.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$AppName,
    [Parameter(Mandatory = $true)][string]$Publisher,
    [Parameter(Mandatory = $true)][string]$ExeName,
    [string]$TargetFolder = '',
    [string]$RegistryKeyName = '',
    [switch]$NoShortcut,
    [switch]$Apply
)

function Get-ProgramFiles64 {
    if ($env:ProgramW6432) { return $env:ProgramW6432 }
    return $env:ProgramFiles
}

function Get-DefaultKeyName {
    # Pure: 'Example Viewer' -> 'ExampleViewer_Portable'
    param([string]$Name)
    return (($Name -replace '[^A-Za-z0-9]', '') + '_Portable')
}

function Get-ArpValue {
    # Pure: the Add/Remove Programs values this wrapper writes.
    param([string]$AppName, [string]$Publisher, [string]$Version, [string]$Target, [string]$ExePath, [long]$SizeKb, [string]$Date)
    $ps = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $uninstall = '"{0}" -NoProfile -ExecutionPolicy Bypass -File "{1}\Uninstall-PortableApp.ps1" -Apply' -f $ps, $Target
    return [ordered]@{
        DisplayName          = $AppName
        DisplayVersion       = $Version
        Publisher            = $Publisher
        InstallLocation      = $Target
        DisplayIcon          = $ExePath
        UninstallString      = $uninstall
        QuietUninstallString = $uninstall
        NoModify             = 1
        NoRepair             = 1
        EstimatedSize        = [int]$SizeKb
        InstallDate          = $Date
    }
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

if (-not $TargetFolder) { $TargetFolder = Join-Path (Join-Path (Get-ProgramFiles64) $Publisher) $AppName }
if (-not $RegistryKeyName) { $RegistryKeyName = Get-DefaultKeyName -Name $AppName }
$source = Join-Path $PSScriptRoot $ExeName
$exe = Join-Path $TargetFolder $ExeName
$shortcut = Join-Path $env:ProgramData ('Microsoft\Windows\Start Menu\Programs\' + $AppName + '.lnk')
$regKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\' + $RegistryKeyName
$log = Join-Path $env:WINDIR ('Temp\' + $RegistryKeyName + '_Install.log')

if (-not (Test-Path -LiteralPath $source)) { Write-Output "Source EXE not found: $source"; exit 1 }

if (-not $Apply) {
    Write-Output 'DRY-RUN (pass -Apply to install). Would:'
    Write-Output "  copy $source -> $exe"
    Write-Output "  copy Uninstall-PortableApp.ps1 -> $TargetFolder"
    if (-not $NoShortcut) { Write-Output "  create shortcut $shortcut" }
    Write-Output "  write $regKey (DisplayVersion from the EXE version resource)"
    exit 0
}

Start-Transcript -Path $log -Append | Out-Null
$code = 1
try {
    $ErrorActionPreference = 'Stop'
    New-Item -ItemType Directory -Path $TargetFolder -Force | Out-Null
    Copy-Item -LiteralPath $source -Destination $exe -Force
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Uninstall-PortableApp.ps1') -Destination $TargetFolder -Force
    Unblock-File -LiteralPath $exe
    $version = [string](Get-Item -LiteralPath $exe).VersionInfo.ProductVersion
    if ([string]::IsNullOrWhiteSpace($version)) { $version = [string](Get-Item -LiteralPath $exe).VersionInfo.FileVersion }
    if ([string]::IsNullOrWhiteSpace($version)) { $version = '0.0' }

    if (-not $NoShortcut) {
        $ws = New-Object -ComObject WScript.Shell
        $lnk = $ws.CreateShortcut($shortcut)
        $lnk.TargetPath = $exe
        $lnk.WorkingDirectory = $TargetFolder
        $lnk.IconLocation = "$exe,0"
        $lnk.Save()
    }

    $sizeKb = [long][Math]::Ceiling(((Get-ChildItem -LiteralPath $TargetFolder -File | Measure-Object -Property Length -Sum).Sum) / 1KB)
    $values = Get-ArpValue -AppName $AppName -Publisher $Publisher -Version $version -Target $TargetFolder -ExePath $exe -SizeKb $sizeKb -Date (Get-Date -Format yyyyMMdd)
    New-Item -Path $regKey -Force | Out-Null
    foreach ($k in $values.Keys) {
        $type = if ($values[$k] -is [int]) { 'DWord' } else { 'String' }
        New-ItemProperty -Path $regKey -Name $k -Value $values[$k] -PropertyType $type -Force | Out-Null
    }

    $manifest = [ordered]@{ AppName = $AppName; Publisher = $Publisher; ExeName = $ExeName; TargetFolder = $TargetFolder; RegistryKeyName = $RegistryKeyName; Shortcut = $(if ($NoShortcut) { '' } else { $shortcut }) }
    $manifest | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $TargetFolder 'portable-app.json') -Encoding UTF8

    # Read back everything that was written.
    $problems = @()
    $readBack = Get-ItemProperty -LiteralPath $regKey
    foreach ($k in $values.Keys) {
        if ([string]$readBack.$k -ne [string]$values[$k]) { $problems += "registry $k" }
    }
    if ([string](Get-Item -LiteralPath $exe).VersionInfo.ProductVersion -ne $version -and $version -ne '0.0') { $problems += 'exe version' }
    if (-not $NoShortcut -and -not (Test-Path -LiteralPath $shortcut)) { $problems += 'shortcut' }
    if ($problems.Count) {
        Write-Output ('Install wrote but did not verify: ' + ($problems -join ', '))
    }
    else {
        Write-Output "Installed $AppName $version to $TargetFolder, Add/Remove Programs entry verified."
        $code = 0
    }
}
catch {
    Write-Output ('Install failed: ' + $_.Exception.Message)
    $code = 1
}
finally {
    Stop-Transcript | Out-Null
}
exit $code
