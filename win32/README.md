# Win32 packaging recipes

Scripts and decisions for packaging awkward installers as Intune Win32 apps.
No vendor binaries are included. The decision guide for detection rules is in
[`DETECTION-RULES.md`](DETECTION-RULES.md).

## Conventions I use now

- **Install behavior: System.** Per-user installs of line-of-business tools
  cause more tickets than they save.
- **Call 64-bit binaries through sysnative.** The Intune Management Extension
  runs install and uninstall commands from a 32-bit process.
  `%windir%\sysnative\WindowsPowerShell\v1.0\powershell.exe` is the one that
  matters: a wrapper script in 32-bit PowerShell reads the wrong registry view
  and the wrong Program Files. I call `msiexec.exe` through sysnative too, to
  keep command lines consistent; msiexec is only a client, so its bitness does
  not change how an x64 MSI installs. See [`../docs/64-bit-and-sysnative.md`](../docs/64-bit-and-sysnative.md).
- **Always log.** `/L*v` for MSIs, `/log` for Burn bundles, `/f2` for
  InstallShield response-file installs, and a transcript for every wrapper
  script. The log path goes in the app notes so the next person knows where to
  look.
- **Default return codes** unless the vendor documents others. 3010 and 1641
  mean success with a reboot; 1618 means retry.
- **Requirement rules do the scoping.** A Windows 11 minimum OS rule makes
  Windows 10 devices report Not Applicable instead of failing.
- **No supersedence.** Every replacement I did was an MSI in-place upgrade
  (same upgrade code, newer version). I created the new app, moved the
  assignments, then deleted the old app object. Supersedence is the right tool
  when the old version must be uninstalled first; it was not needed here.
- **Pilot, then fleet.** A small device group gets the Required assignment
  first. For the two-app document management client below, the pilot ring was
  7 of 7 reporting devices installed, 0 failed, including in-place upgrades
  from five different older versions, before the fleet group got it.
- **Notes say who and why.** Packager, date, source, change record, what is
  unusual about the install. Secrets never go in notes.

## Recipes

| Recipe | Files | Use it when | Status |
|---|---|---|---|
| Version at or above | [`detection/Detect-UninstallVersion.ps1`](detection/Detect-UninstallVersion.ps1) | The app installs into a version-numbered folder, or updates itself | [built, ran on real tickets] |
| Portable EXE | [`portable-exe/`](portable-exe) | The vendor ships a single EXE and no installer | [built, ran on real tickets] |
| InstallShield response file | [`installshield/`](installshield) | Legacy `setup.exe` with no `/qn`; silent only by replaying a recorded `.iss` | [built, ran on real tickets] |
| Legacy EXE, then MSI | [`msi-replace-legacy/install.cmd`](msi-replace-legacy/install.cmd) | Some devices have the old EXE-installed version, the new one is an MSI | [built, ran on real tickets] |
| Patch the MSI | [`../msi`](../msi) | The MSI lacks a property you need at the package level (for example `ALLUSERS`) | [built, ran on real tickets] |

### Version at or above

Reads the Uninstall key in both registry views through `RegistryKey.OpenBaseKey`
so it behaves the same in a 32-bit or 64-bit host, and passes when
`DisplayVersion` is at or above the packaged build. It writes to STDOUT only
when it detects the app, because Intune's rule is "exit 0 and output means
installed".

I used it for a document management client shipped as two Win32 apps: an
agent services Burn bundle, and the desktop client (an InstallShield launcher
around an MSI) with an Intune dependency on the first. The client installs
into a folder named after its version, so a file rule would have broken on
every release, and its updater can move devices ahead of the package, so
"at or above" keeps Intune from fighting it. The vendor's registry
DisplayVersion is not the release number on its download page (the first two
parts come out as one number), so the threshold has to use what the registry
holds. The script pads both sides to four parts before comparing, because
`[version]` counts a missing part as -1 and would otherwise call 4.12.0 lower
than 4.12.0.0.

### Portable EXE

`Install-PortableApp.ps1` copies the EXE into Program Files, unblocks it,
creates an all-users Start Menu shortcut, writes an Add/Remove Programs entry
whose DisplayVersion comes from the EXE's own version resource, drops
`Uninstall-PortableApp.ps1` and a small manifest next to it, and reads every
value back. Uninstall works from Settings > Apps as well as from Intune.
Detection: file version at or above on the EXE.

### InstallShield response file

Record once on a reference machine with `setup.exe /r /f1"C:\Temp\setup.iss"`,
replay with `/s /f1 /f2`. The wrapper ignores setup.exe's exit code and reads
`ResultCode` under `[ResponseResult]` in the `/f2` log, which is where
InstallShield actually reports the result (`-3` usually means the response
file was recorded for a different version or for an upgrade). Optional: a
second response file for upgrades, a file that must exist afterwards, a Modify
grant for BUILTIN\Users on a folder, and `-LegacySms` for classic InstallShield
5.x setups that return before the install is done unless `/SMS` is passed. On a
timeout the wrapper stops setup.exe and its children and exits 1460, a
failure, rather than 1618, which would make Intune start a second setup.exe
next to the first.

If an app writes into its own install folder, grant Modify on the data
subfolder only; a program folder every user can write to is an escalation path.

Recorded `.iss` files hold whatever was typed into the dialogs, including the
registration name and company. Keep them out of source control. The sample
here is synthetic.

### Legacy EXE, then MSI

The compression utility's fleet had a mix of old EXE installs and nothing. The
install command removes the EXE install if present, then installs the MSI
through sysnative `msiexec` with a verbose log. My first version checked
`%ProgramFiles%`, which a 32-bit `cmd.exe` expands to `Program Files (x86)`;
the recipe uses `%ProgramW6432%` for the 64-bit folder.

Waiting for the old uninstaller is the subtle part. `Uninstall.exe /S` is the
NSIS idiom, and an NSIS uninstaller copies itself to `%TEMP%`, starts the copy
and exits at once, so neither a plain call nor `start /wait` waits for it. The
recipe passes `_?=<install folder>` so it runs in place and blocks, polls with
a timeout until the old main EXE is gone (for uninstallers that are not NSIS),
removes the leftover `Uninstall.exe` and folder, and exits 1618 (retry) if the
old install will not go away. That wait logic is new in this rewrite; I have
only run it against fake legacy folders, with msiexec and the uninstaller
replaced by echo lines.

## Apps I packaged

| App (generic) | Installer | Detection |
|---|---|---|
| RMM agent | Vendor MSI, original file name kept | Folder exists |
| EDR sensor | Vendor EXE with a customer ID | File exists |
| Vulnerability scanner agent | MSI with server and agent-key properties | File exists |
| Patch agent | MSI patched to `ALLUSERS=1` | MSI product code |
| Document management agent services | Burn bundle | Script, DisplayVersion at or above |
| Document management desktop client | InstallShield launcher around an MSI, dependency on the agent services | Script, DisplayVersion at or above |
| Field-device configuration tool | Legacy InstallShield with a response file | File version at or above |
| Spreadsheet simulation add-in | InstallShield around an MSI | File exists |
| Compression utility | MSI, legacy EXE removed first | File version at or above |
| Portable engineering file viewer | Single EXE | File version at or above |

One more, a screenshot tool, started as a Win32 app and moved to the
Microsoft Store app type so it keeps itself current.
