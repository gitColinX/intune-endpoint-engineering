<#
.SYNOPSIS
    Win32 app install wrapper for a legacy InstallShield setup.exe driven by a recorded response file.

.DESCRIPTION
    Old-style InstallShield setups (InstallScript, not an MSI underneath) have
    no /qn. They install silently only by replaying a response file (.iss)
    that you record once on a reference machine:

        setup.exe /r /f1"C:\Temp\setup.iss"

    and replay with:

        setup.exe /s /f1"<path>\setup.iss" /f2"<path>\setup.log"

    The catch: setup.exe's own exit code is not reliable. The result is in the
    /f2 log, under [ResponseResult], as ResultCode=<n>. 0 is success; negative
    values are documented InstallShield errors (for example -3 means the
    response file does not match the dialogs the setup showed, which usually
    means it was recorded for a different version or for an upgrade rather
    than a fresh install). This wrapper parses that log and turns it into a
    real exit code for Intune.

    Optional pieces:
      -UpgradeResponseFile  a second .iss recorded over an existing install; used
                            automatically when -ExistingInstallCheck exists
      -VerifyPath           a file that must exist afterwards (the main EXE)
      -GrantUsersModify     a folder where BUILTIN\Users gets Modify. Only for apps
                            that write into their own install folder, and then on
                            the data subfolder only. A program folder every user can
                            write to is an escalation path if anything elevated ever
                            runs from it.
      -LegacySms            adds /SMS. Classic InstallShield 5.x setup.exe hands off
                            to another process and returns before the install is
                            done; /SMS makes it wait. Without it the /f2 log may not
                            hold a ResultCode yet when the wrapper reads it.

    Timeout: if setup.exe is still running after -TimeoutMinutes, the wrapper
    stops it and its child processes and exits 1460 (ERROR_TIMEOUT), which
    Intune reports as a failure. It does not return 1618 (retry): a retry would
    start a second setup.exe while the first one could still be holding the
    install.

    DRY RUN unless -Apply is passed. Put -Apply in the Intune install command:
      %windir%\sysnative\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-WithResponseFile.ps1 -ResponseFile setup.iss -VerifyPath "C:\Program Files\Example\App\app.exe" -Apply

    Response files record what you typed into the setup dialogs, including the
    registration name and company. Keep recorded .iss files out of source
    control; the repo .gitignore excludes *.iss except the synthetic sample.

.NOTES
    Pattern status: [built, ran on real tickets]. Used for an engineering
    field-device configuration tool. Fresh rewrite, generalized from what I
    ran at work; ResultCode parsing is unit-tested against synthetic logs.
#>
[CmdletBinding()]
param(
    [string]$SetupFile = 'setup.exe',
    [string]$ResponseFile = 'setup.iss',
    [string]$UpgradeResponseFile = '',
    [string]$ExistingInstallCheck = '',
    [string]$VerifyPath = '',
    [string]$GrantUsersModify = '',
    [string]$LogFolder = (Join-Path $env:WINDIR 'Temp'),
    [string]$LogName = 'InstallShield_Silent',
    [int]$TimeoutMinutes = 60,
    [switch]$LegacySms,
    [switch]$Apply
)

function Get-IssResultCode {
    # Pure: returns the ResultCode under [ResponseResult] as an int, or $null.
    param([string[]]$LogLines)
    $inSection = $false
    foreach ($line in $LogLines) {
        $t = $line.Trim()
        if ($t -match '^\[(.+)\]$') { $inSection = ($Matches[1] -eq 'ResponseResult'); continue }
        if ($inSection -and $t -match '^ResultCode\s*=\s*(-?\d+)\s*$') { return [int]$Matches[1] }
    }
    return $null
}

function Get-IssResultText {
    # Pure: documented InstallShield silent-mode result codes.
    param([AllowNull()][object]$Code)
    if ($null -eq $Code) { return 'no ResultCode found (setup did not write the log, or crashed)' }
    $map = @{
        '0'   = 'Success'
        '-1'  = 'General error'
        '-2'  = 'Invalid mode'
        '-3'  = 'Required data not found in the response file (dialog sequence or version mismatch)'
        '-4'  = 'Not enough memory'
        '-5'  = 'File does not exist'
        '-6'  = 'Cannot write to the response file'
        '-7'  = 'Unable to write to the log file'
        '-8'  = 'Invalid path to the response file'
        '-9'  = 'Not a valid list type'
        '-10' = 'Data type is invalid'
        '-11' = 'Unknown error during setup'
        '-12' = 'Dialogs are out of order'
        '-51' = 'Cannot create the specified folder'
        '-52' = 'Cannot access the specified file or folder'
        '-53' = 'Invalid option selected'
    }
    $c = [string][int]$Code
    if ($map.ContainsKey($c)) { return $map[$c] }
    return 'Unknown result code'
}

function Get-SetupArgument {
    # Pure: the setup.exe argument line.
    param([string]$ResponseFile, [string]$LogFile, [bool]$LegacySms = $false)
    $a = '/s /f1"{0}" /f2"{1}"' -f $ResponseFile, $LogFile
    if ($LegacySms) { $a += ' /SMS' }
    return $a
}

function Stop-ProcessTree {
    # Stops a process and everything it started, children first.
    param([int]$Id)
    foreach ($child in @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$Id" -ErrorAction SilentlyContinue)) {
        Stop-ProcessTree -Id ([int]$child.ProcessId)
    }
    Stop-Process -Id $Id -Force -ErrorAction SilentlyContinue
}

function Resolve-PackagePath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    return (Join-Path $PSScriptRoot $Path)
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

$setup = Resolve-PackagePath -Path $SetupFile
$iss = Resolve-PackagePath -Path $ResponseFile
$upgradeIss = Resolve-PackagePath -Path $UpgradeResponseFile
if ($ExistingInstallCheck -and $upgradeIss -and (Test-Path -LiteralPath $ExistingInstallCheck) -and (Test-Path -LiteralPath $upgradeIss)) {
    $iss = $upgradeIss
}
$issLog = Join-Path $LogFolder ($LogName + '_iss.log')
$transcript = Join-Path $LogFolder ($LogName + '_wrapper.log')

foreach ($f in @($setup, $iss)) {
    if (-not (Test-Path -LiteralPath $f)) { Write-Output "Missing package file: $f"; exit 1 }
}

if (-not $Apply) {
    Write-Output 'DRY-RUN (pass -Apply to install). Would run:'
    Write-Output ('  "{0}" {1}' -f $setup, (Get-SetupArgument -ResponseFile $iss -LogFile $issLog -LegacySms $LegacySms.IsPresent))
    if ($VerifyPath) { Write-Output "  then require $VerifyPath" }
    if ($GrantUsersModify) { Write-Output "  then grant BUILTIN\Users Modify on $GrantUsersModify" }
    exit 0
}

Start-Transcript -Path $transcript -Append | Out-Null
$code = 1
try {
    Remove-Item -LiteralPath $issLog -Force -ErrorAction SilentlyContinue
    $argLine = Get-SetupArgument -ResponseFile $iss -LogFile $issLog -LegacySms $LegacySms.IsPresent
    Write-Output "Running $setup $argLine"
    $p = Start-Process -FilePath $setup -ArgumentList $argLine -PassThru -WindowStyle Hidden
    if (-not $p.WaitForExit($TimeoutMinutes * 60 * 1000)) {
        Write-Output "setup.exe still running after $TimeoutMinutes minutes; stopping it and its child processes"
        Stop-ProcessTree -Id $p.Id
        $code = 1460
    }
    else {
        Write-Output "setup.exe exit code: $($p.ExitCode) (informational; ResultCode decides)"
        $lines = @()
        if (Test-Path -LiteralPath $issLog) { $lines = @(Get-Content -LiteralPath $issLog) }
        $rc = Get-IssResultCode -LogLines $lines
        Write-Output ('ISS ResultCode: {0} ({1})' -f $rc, (Get-IssResultText -Code $rc))
        if ($rc -eq 0) {
            if ($VerifyPath -and -not (Test-Path -LiteralPath $VerifyPath)) {
                Write-Output "ResultCode 0 but $VerifyPath is missing"
                $code = 1
            }
            else {
                $code = 0
                if ($GrantUsersModify) {
                    & icacls.exe $GrantUsersModify /grant '*S-1-5-32-545:(OI)(CI)M' | Out-Null
                    $modify = [System.Security.AccessControl.FileSystemRights]::Modify
                    $acl = @((Get-Acl -LiteralPath $GrantUsersModify).Access | Where-Object {
                            $_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value -eq 'S-1-5-32-545' -and
                            ($_.FileSystemRights -band $modify) -eq $modify
                        })
                    if ($acl.Count) { Write-Output 'ACL grant verified: BUILTIN\Users Modify' }
                    else { Write-Output 'ACL grant did not verify'; $code = 1 }
                }
            }
        }
        else {
            $code = 1603
        }
    }
}
catch {
    Write-Output ('Wrapper error: ' + $_.Exception.Message)
    $code = 1
}
finally {
    Stop-Transcript | Out-Null
}
exit $code
