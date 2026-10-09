# Choosing a Win32 detection rule

The detection rule is the only thing Intune knows about whether your app is
installed. Get it wrong and the report lies in one of two directions: devices
that have the app show Failed and Intune keeps reinstalling, or devices that
lost the app show Installed and nobody notices. I cleaned up after the first
kind twice in one summer. This is the guide I use now.

## Quick decision

| The app... | Use | Avoid |
|---|---|---|
| is an MSI and never updates itself | MSI product code (optionally with version check) | |
| updates itself (agents, remote support clients, browsers) | File exists on a binary the uninstaller removes, or registry key exists on its service, or script with version at or above | MSI product code |
| installs into a version-numbered folder | Script: Uninstall `DisplayVersion` at or above the packaged build | File or folder rule on a fixed path |
| has a stable path and a versioned main EXE | File, version greater than or equal to | File exists alone, if you need upgrades to apply |
| is a portable EXE you wrapped | File, version greater than or equal to, on the copied EXE | |
| leaves folders behind on uninstall | A file the uninstaller deletes, or a service registry key | Folder exists |

## Why product codes break on self-updating agents

Every MSI has a ProductCode. Most vendors change it with every version (a
"major upgrade"). Intune's default rule for an MSI-based Win32 app is "this
ProductCode is installed". That is correct right up until the agent updates
itself, which many agents do on their own schedule. Then:

1. The agent updates to a newer build with a new ProductCode.
2. The detection rule no longer finds the packaged ProductCode, so Intune
   decides the app is missing.
3. Intune runs the packaged, older MSI as a Required install.
4. Installing an older MSI over a newer running client fails, usually 1603,
   reported as 0x80070643.
5. The device shows Failed while the agent is installed and healthy.

That is how a remote support client package showed 707 Failed devices out of
764, of which 667 were false (case study 3). Turning off auto-update to make
the report green is the wrong fix; auto-update is how security fixes reach the
agent. Change the rule, not the agent.

The uninstall command has the same problem. `msiexec /x {old ProductCode}`
does nothing on a device that has moved on. Look the code up at uninstall
time, by DisplayName, and run that:

```
%windir%\sysnative\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$k = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -EA SilentlyContinue | Where-Object { $_.DisplayName -like 'Contoso Agent*' -and $_.PSChildName -like '{*}' } | Select-Object -First 1; if (-not $k) { exit 0 }; $p = Start-Process msiexec.exe -ArgumentList ('/x ' + $k.PSChildName + ' /qn /norestart') -Wait -PassThru; exit $p.ExitCode"
```

## Folder exists is not free either

Program folders can outlive the agent, and a folder rule then calls the
device healthy. Prefer a file the uninstaller removes (the service
executable) or the service's registry key
(`HKLM\SYSTEM\CurrentControlSet\Services\<name>`, key exists). If the vendor
uses an instance-specific folder name, point at that exact name so a second
instance of the same product cannot satisfy the rule.

## Script detection rules

- Detected means **exit 0 and something on STDOUT**. Anything else is not
  detected. Write nothing when the app is missing.
- Set "Run script as 32-bit process on 64-bit clients" to **No**, or read both
  registry views explicitly as [`detection/Detect-UninstallVersion.ps1`](detection/Detect-UninstallVersion.ps1) does.
- Keep it fast and read-only. It runs on every evaluation.
- Compare against what the registry holds, not the marketing version. One
  vendor I packaged registers a DisplayVersion that is not the release number
  on its download page.
- Use "at or above". A device the vendor's updater moved ahead should stay
  Installed.
- Pad versions to four parts before comparing. PowerShell's `[version]` counts
  a missing part as -1, so `[version]'4.12.0' -ge [version]'4.12.0.0'` is
  False. Copy a four-part MSI ProductVersion into a rule that reads a
  three-part DisplayVersion and the app is never detected: Intune reinstalls it
  every cycle and reports Failed.

## Assignments affect the report too

- A System-context app assigned Required to both all devices and all users
  produces two report rows per device and a second status chart. Devices is
  enough.
- Removing a device from a Required group is part of uninstalling an app from
  it. Otherwise the next evaluation reinstalls it.

## Changing a rule on a live app

I change detection rules through Graph so I can keep the before and after JSON
for rollback, and I read the app back after each PATCH. One trap: if anyone
(including you) has the app open in the Intune portal from before the change
and clicks Save, the portal sends the whole app object it loaded and quietly
puts the old rule back. It happened to me three minutes after a fix. Close
portal blades before a Graph change, PATCH one field at a time, and check the
app again afterwards.
