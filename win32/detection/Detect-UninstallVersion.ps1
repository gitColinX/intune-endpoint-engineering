<#
.SYNOPSIS
    Win32 app custom detection script: installed version at or above the packaged build.

.DESCRIPTION
    For apps that install into a version-numbered folder (for example
    C:\Program Files\Vendor\Client\4.12.0\), where a file or folder rule would
    break on every release, and for apps that update themselves, where an MSI
    product code rule turns healthy devices into false failures.

    Reads the Uninstall key in BOTH registry views explicitly through
    RegistryKey.OpenBaseKey, so the answer is the same whether Intune runs the
    script as a 32-bit or a 64-bit process.

    Intune's contract for detection scripts:
      detected      = exit 0 AND something written to STDOUT
      not detected  = anything else
    So this script writes nothing at all unless it detects the app.

    "At or above" matters: a device that later takes a newer build through the
    vendor's own updater still reports Installed, and Intune never tries to
    push the older package over it.

    Version strings: compare against what the registry actually holds, not the
    marketing version. One vendor I packaged registers a DisplayVersion that is
    not the release number on its download page (the first two parts come out
    as one number). Check a test device first:
      Get-ItemProperty HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*,
        HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\* |
        Where-Object DisplayName -like 'Contoso*' | Select-Object DisplayName, DisplayVersion, PSChildName

    Intune settings: "Run script as 32-bit process on 64-bit clients" = No,
    "Enforce script signature check" = No unless you sign.

.NOTES
    Pattern status: [built, ran on real tickets]. Used for a two-app document
    management client (agent services plus desktop client, linked by an Intune
    dependency); the pilot ring showed 7 of 7 reporting devices Installed, 0
    failed. Fresh rewrite, generalized from what I ran at work, unit-tested
    against synthetic entries.
#>
[CmdletBinding()]
param()

$Config = @{
    DisplayNameLike = 'Contoso Document Client*'
    MinimumVersion  = '412.0.7'
    # $true: only consider keys named like an MSI product code {GUID}. Useful
    # when the vendor also writes a non-MSI key with the same DisplayName.
    MsiKeysOnly     = $false
}

function ConvertTo-ComparableVersion {
    # Pure: '4.12.0', '4.12.0.7 (x64)', 'v4.12' -> [version] with four parts; $null if no number found.
    # Always pad to four parts. [version] treats a missing part as -1, so without
    # padding [version]'4.12.0' -ge [version]'4.12.0.0' is False, and a minimum
    # copied from a four-part MSI ProductVersion would never match a three-part
    # DisplayVersion: not detected forever, reinstalled every cycle, reported Failed.
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $m = [regex]::Match($Text, '\d+(\.\d+){0,3}')
    if (-not $m.Success) { return $null }
    $parts = @($m.Value.Split('.'))
    while ($parts.Count -lt 4) { $parts += '0' }
    try { return [version]($parts -join '.') } catch { return $null }
}

function Find-UninstallEntry {
    # Pure: pick the first entry that matches name and meets the minimum version.
    param(
        [AllowEmptyCollection()][object[]]$Entry = @(),
        [string]$DisplayNameLike,
        [string]$MinimumVersion,
        [bool]$MsiKeysOnly = $false
    )
    $min = ConvertTo-ComparableVersion -Text $MinimumVersion
    if ($null -eq $min) { throw "MinimumVersion '$MinimumVersion' is not a version" }
    foreach ($e in $Entry) {
        if (-not $e.DisplayName -or ($e.DisplayName -notlike $DisplayNameLike)) { continue }
        if ($MsiKeysOnly -and ($e.KeyName -notmatch '^\{[0-9A-Fa-f-]{36}\}$')) { continue }
        $v = ConvertTo-ComparableVersion -Text $e.DisplayVersion
        if ($null -ne $v -and $v -ge $min) { return $e }
    }
    return $null
}

function Get-UninstallEntryAllViews {
    $views = @([Microsoft.Win32.RegistryView]::Registry64, [Microsoft.Win32.RegistryView]::Registry32)
    foreach ($view in $views) {
        $base = $null
        try {
            $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $view)
            $root = $base.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')
            if (-not $root) { continue }
            foreach ($name in $root.GetSubKeyNames()) {
                $k = $root.OpenSubKey($name)
                if (-not $k) { continue }
                [pscustomobject]@{
                    KeyName        = $name
                    DisplayName    = [string]$k.GetValue('DisplayName')
                    DisplayVersion = [string]$k.GetValue('DisplayVersion')
                    View           = [string]$view
                }
                $k.Close()
            }
            $root.Close()
        }
        finally {
            if ($base) { $base.Close() }
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        $hit = Find-UninstallEntry -Entry @(Get-UninstallEntryAllViews) -DisplayNameLike $Config.DisplayNameLike -MinimumVersion $Config.MinimumVersion -MsiKeysOnly $Config.MsiKeysOnly
        if ($hit) {
            Write-Output ('Detected {0} {1} ({2})' -f $hit.DisplayName, $hit.DisplayVersion, $hit.View)
            exit 0
        }
        exit 1
    }
    catch {
        exit 1
    }
}
