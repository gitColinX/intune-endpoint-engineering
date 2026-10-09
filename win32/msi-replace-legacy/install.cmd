@echo off
rem Win32 app install command: remove a legacy EXE-based install, then install the MSI.
rem
rem Pattern status: [built, ran on real tickets] for a compression utility whose fleet
rem had a mix of old EXE installs and nothing at all. Fresh rewrite, generalized from
rem what I ran at work. The in-place uninstall wait below is new in this rewrite; it has
rem only been run against fake legacy folders, with msiexec and the uninstaller replaced
rem by echo lines.
rem
rem Why each line looks the way it does:
rem  - The Intune Management Extension runs this in a 32-bit cmd.exe on 64-bit Windows.
rem    In that host %ProgramFiles% expands to "Program Files (x86)", so a check written
rem    as %ProgramFiles%\App only ever finds 32-bit installs. %ProgramW6432% is the
rem    64-bit Program Files and is only defined on 64-bit Windows, hence the fallback.
rem    My first version used %ProgramFiles% and missed 64-bit legacy installs.
rem  - Waiting for the old uninstaller. "Uninstall.exe /S" is the NSIS idiom, and an
rem    NSIS uninstaller copies itself to %TEMP%, starts the copy and exits at once, so
rem    neither a plain call nor "start /wait" waits for the real work. _?=<folder>
rem    makes it run in place and block until it is done (NSIS wants _?= last and
rem    unquoted, even with spaces). Because some uninstallers are not NSIS, the script
rem    also polls until the old main EXE is gone, with a timeout. Running in place
rem    leaves Uninstall.exe and the folder behind, so those are removed afterwards.
rem    If the old install will not go away, exit 1618 so Intune retries later instead
rem    of racing msiexec against a half-removed app.
rem  - msiexec through %windir%\sysnative: msiexec.exe is only a client (the Windows
rem    Installer service does the install, and custom action bitness comes from the
rem    package), so this is for a consistent command line, not a fix. What actually
rem    broke in 32-bit hosts was paths and registry reads, as above.
rem  - The exit code of msiexec is what Intune sees: 0, 3010 and 1641 are success codes
rem    in the default return code table.
rem
rem Detection rule to pair with it: File, version greater than or equal to the packaged
rem build, on the main EXE in its 64-bit folder.

setlocal
set "MSI=%~dp0ExampleApp-x64.msi"
set "LOG=%windir%\Temp\ExampleApp_Install.log"
set "LEGACYEXE=ExampleApp.exe"
set "PF64=%ProgramFiles%"
if defined ProgramW6432 set "PF64=%ProgramW6432%"
set "PF86=%ProgramFiles(x86)%"

call :removelegacy "%PF64%\ExampleApp" || exit /b 1618
if defined PF86 call :removelegacy "%PF86%\ExampleApp" || exit /b 1618

set "MSIEXEC=%windir%\System32\msiexec.exe"
if exist "%windir%\sysnative\msiexec.exe" set "MSIEXEC=%windir%\sysnative\msiexec.exe"
"%MSIEXEC%" /i "%MSI%" /qn /norestart /L*v "%LOG%"
exit /b %errorlevel%

:removelegacy
rem %~1 is a legacy install folder. Returns 0 when nothing is left to remove.
if not exist "%~1\Uninstall.exe" exit /b 0
"%~1\Uninstall.exe" /S _?=%~1
set /a WAITED=0
:waitgone
if not exist "%~1\%LEGACYEXE%" goto legacygone
if %WAITED% GEQ 120 exit /b 1
ping -n 3 127.0.0.1 >nul
set /a WAITED+=2
goto waitgone
:legacygone
del /f /q "%~1\Uninstall.exe" >nul 2>&1
rd "%~1" >nul 2>&1
exit /b 0
