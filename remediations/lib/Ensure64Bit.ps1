# 64-bit host guard for Intune scripts.
#
# Intune Remediations run in 32-bit Windows PowerShell unless "Run script in
# 64-bit PowerShell" is set to Yes, and the Win32 app installer host is 32-bit.
# In a 32-bit host on 64-bit Windows:
#   - HKLM:\SOFTWARE\... silently reads HKLM:\SOFTWARE\WOW6432Node\...
#   - $env:WINDIR\System32 silently becomes SysWOW64
#   - $env:ProgramFiles points at "Program Files (x86)"
# A script that "checks the 64-bit Uninstall key" can be checking the 32-bit one
# twice and never know it.
#
# This block relaunches the script under the 64-bit Windows PowerShell through
# the sysnative alias (only visible to 32-bit processes), forwards the bound
# parameters, and passes the child's exit code back to Intune. Paste it right
# after the param() block and the configuration, before any real work.
#
# tests\Run-Tests.ps1 checks that every inline copy matches this file.

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
