# 32-bit hosts, sysnative and Intune

Most of the "it works when I run it" bugs in my Intune scripts came from one
thing: the script ran in a 32-bit process on 64-bit Windows, and Windows
quietly redirected what it read and launched. Nothing errors. You just get the
wrong answer.

## Which Intune hosts are 32-bit

| Where the script runs | Bitness | Control |
|---|---|---|
| Win32 app install and uninstall commands | 32-bit (the Intune Management Extension host) | None. Use sysnative paths |
| Win32 app custom detection script | 64-bit unless "Run script as 32-bit process on 64-bit clients" is Yes | Leave it No |
| Remediations (detection and remediation) | 32-bit unless "Run script in 64-bit PowerShell" is Yes | Set it to Yes |
| Platform scripts | 32-bit unless "Run script in 64-bit PowerShell host" is Yes | Set it to Yes |

## What changes in a 32-bit process

| You write | You get in a 32-bit process |
|---|---|
| `HKLM:\SOFTWARE\Vendor` | `HKLM:\SOFTWARE\WOW6432Node\Vendor` |
| `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall` | the WOW6432Node Uninstall key, so 64-bit apps are invisible |
| `C:\Windows\System32\msiexec.exe` | `C:\Windows\SysWOW64\msiexec.exe` |
| `$env:ProgramFiles` / `%ProgramFiles%` | `C:\Program Files (x86)` |
| `C:\Windows\sysnative\...` | the real 64-bit System32 (this alias exists only for 32-bit processes) |

Two consequences that bit me:

- One of my early remediation scripts said "64-bit msiexec" in a comment and
  called `$env:SystemRoot\System32\msiexec.exe`. That is only the 64-bit
  binary if the PowerShell host is 64-bit. Which msiexec launches the install
  matters less than you would think; the registry and file paths the script
  itself reads matter more. A script that "checks both Uninstall keys" from a
  32-bit host reads the 32-bit one twice.
- A legacy-uninstall check written as `%ProgramFiles%\App\Uninstall.exe` in an
  install command only ever looked in `Program Files (x86)`.

## The patterns in this repo

1. **Relaunch in 64-bit.** Every device script that reads `HKLM:\SOFTWARE` or
   launches System32 tools carries the block from
   [`../remediations/lib/Ensure64Bit.ps1`](../remediations/lib/Ensure64Bit.ps1): if the OS is 64-bit and the
   process is not, start `%windir%\sysnative\WindowsPowerShell\v1.0\powershell.exe`
   on the same file with the same parameters and pass its exit code back. The
   WiFi monitor and the evidence detection script read only an event log and a
   ProgramData folder, which look the same from either host, so they skip it.
   The test suite runs the block from 32-bit Windows PowerShell and checks that
   the child is 64-bit and receives the same parameters.
2. **Read both registry views explicitly** where a script must not depend on
   its host, with `[Microsoft.Win32.RegistryKey]::OpenBaseKey(LocalMachine, Registry64)`
   and `Registry32` (see [`../win32/detection/Detect-UninstallVersion.ps1`](../win32/detection/Detect-UninstallVersion.ps1)).
3. **Install commands use sysnative** for `powershell.exe`, where it decides
   which registry view and Program Files your wrapper sees, and for
   `msiexec.exe` for consistency (msiexec is only a client: the Windows
   Installer service does the install, and custom action bitness comes from
   the package). Both fall back to System32 on a 32-bit OS, and
   `%ProgramW6432%` gives the 64-bit Program Files.

`sysnative` does not exist for a 64-bit process, so never hard-code it in a
script that might already be 64-bit; test for it first, as the guard does.
