# Remediations

Intune Remediations are a detection script and an optional remediation script
that run as SYSTEM on a schedule. Detection exits 0 (fine) or 1 (needs
attention); if a remediation script is attached, exit 1 triggers it, and the
detection runs again afterwards. Each script's output, up to 2,048 characters,
comes back per device and can be exported.

That makes Remediations three tools in one, and this folder uses all three:

| Use | How | Scripts here |
|---|---|---|
| Fleet query | Detection only, no remediation attached, output is the answer | `recon-template`, `edr-install-recon`, `wlan-monitor` |
| Fix | Detection decides, remediation repairs, detection confirms | `agent-self-heal` |
| Evidence retrieval | Remediation writes a zip into the IME Logs folder, Collect diagnostics uploads it | `evidence-collector` |

## Settings I use for every package

- Run this script using the logged-on credentials: **No** (SYSTEM).
- Enforce script signature check: **No**, unless you sign your scripts.
- Run script in 64-bit PowerShell: **Yes**. The default is No, and in a
  32-bit host `HKLM:\SOFTWARE` quietly means `WOW6432Node`. Every script here
  that reads `HKLM:\SOFTWARE` or launches System32 tools also carries a guard
  that relaunches itself in 64-bit, because a setting is one click away from
  being wrong. The WiFi monitor and the evidence detection script read only an
  event log and a ProgramData folder, so they do not need it. See
  [`../docs/64-bit-and-sysnative.md`](../docs/64-bit-and-sysnative.md).
- Schedule: hourly while investigating, daily once stable, Once for anything
  heavy.
- Scope: a device group made for the job. The fleet only for monitors.

## The patterns

### Recon first ([`recon-template/Detect-ReconTemplate.ps1`](recon-template/Detect-ReconTemplate.ps1))

Before writing a fix, deploy a detection-only script that answers "what is
actually on these devices?" and export the results. It changes nothing, so it
can go to a wide group on day one. Mine report the OS build and UBR, uptime,
free disk, pending reboot flags, the agent's services, matching Add/Remove
Programs entries in both registry views, Windows Installer product
registrations, the latest MsiInstaller events (with the 1033 status code), and
the last error-like lines from the newest vendor log.

Versions of this ran during the RMM agent incident (a census of leftovers on a
broken device, a check that app control was not blocking the vendor's helper
on 18 devices, a gap check on the devices enrolled during an outage window)
and during the EDR rollout (that run per my notes; no recon export kept).

### Idempotent self-heal ([`agent-self-heal/`](agent-self-heal))

`Detect-AgentHealth.ps1` is read-only: every expected service exists and is
Running, or exit 1 with the state.

`Remediate-AgentSelfHeal.ps1` escalates and stops at the first stage that
works:

```
Stage 0  healthy                -> touch nothing, "NOTHING TOUCHED", exit 0
Stage 1  services stopped       -> start them, wait, re-check
         service Disabled       -> report and stop; someone did that on purpose
Stage 2  rebuild                -> msiexec /x by product code
                                -> purge what msiexec left behind, each key exported to .reg first:
                                     Uninstall\<key>                         (both registry views)
                                     Classes\Installer\Products\<packed GUID>
                                     Classes\Installer\Features\<packed GUID>
                                     Classes\Installer\UpgradeCodes\<code>, the product's value only
                                     Installer\UserData\<SID>\Products\<packed GUID>
                                -> delete leftover services and folders (Program Files / ProgramData only)
                                -> create or check the private work folder under Program Files
                                     (refused if someone else created it or it is a junction;
                                      owner and ACL set to SYSTEM and Administrators, then read back)
                                -> download there under the vendor's exact file name
                                -> verify SHA256, exact signer subject or signer thumbprint; refuse if none is configured
                                -> install with a verbose log in the work folder; stage a redacted copy in IME Logs
                                -> require every service Running, else exit 1 with the MSI log's telling lines
```

Every deletion is read back ("verified gone" or "STILL PRESENT"). Dry run by
default: `-Apply` locally, `ApplyWhenNoParameter = $true` in the copy you
upload. Component registrations (`UserData\<SID>\Components`) are left alone on
purpose: they are keyed by component and shared across products, and a
leftover value there at worst leaves a file behind at a later uninstall.

The vendor file name is a setting for a reason. Some vendors read a site token
from the installer file name. My scripts renamed the download to something
tidy, and a custom action failed. That took five versions to find (case
study 1). If your vendor does the same, the configured script holds a secret:
keep it out of source control. The repo `.gitignore` excludes `*.local.ps1`
so you can keep a configured copy next to the template. The script also keeps
the name out of what it writes: the portal
output never prints the file name or URL, and because a verbose MSI log records
the package path, the log and the transcript stay in the private work folder.
Only a copy with the file name, its base name and the URL replaced by
`<vendor-installer>` goes to IME Logs. If the vendor's custom actions log the
bare token too, add a regex for it to `RedactPatterns`.

What the original proved in production: its export holds each device's latest
result, last updated between 08-06 and 08-24, and that was HEALTHY / NOTHING
TOUCHED on all 17. That proves the no-op guard and the end state; it cannot
show whether the repair path ran on an earlier cycle. The repair steps
themselves were proved by earlier versions: one device remediated by version
five and one by a targeted single-device fix.

### Evidence into the IME Logs folder ([`evidence-collector/`](evidence-collector))

When you cannot reach a device and need its logs, have it send them. The
remediation gathers event logs (last 14 days, filtered by time with
`wevtutil epl`), vendor and setup logs, Uninstall registry exports, service
details, `systeminfo`, `ipconfig /all` and the WinHTTP proxy, zips them, and
copies the zip into `C:\ProgramData\Microsoft\IntuneManagementExtension\Logs`.
Then run Collect diagnostics on the device from the portal and download the
result. The detection script makes it run at most once per 20 hours.
`MaxBundleMB` is a setting, not a Microsoft limit: the default of 50 is a
size I chose to keep uploads small, so set it for your devices and network
and check Microsoft's current Collect diagnostics documentation. A bundle
that comes out over `MaxBundleMB` is deleted and replaced by a small
`_TOOBIG.txt` note, and detection backs off while the note is recent, so an
hourly schedule cannot fill the disk of the device you are diagnosing.

The original found that one device's agent had been dead for most of a year.
Nobody touched the device.

Keep bundles small and do not collect user profile folders unless you have to
and your privacy rules allow it.

### WiFi failures, not WiFi usage ([`wlan-monitor/Detect-WlanFailures.ps1`](wlan-monitor/Detect-WlanFailures.ps1))

Reads the WLAN-AutoConfig log for the last 24 hours. 8002 (failed to connect)
and 8003 (disconnected) count as failures, except disconnect reasons you list
as benign. 8001 (connected) never does. Output: the failure count, the split,
the top reasons and the most recent failures, with SSIDs that are not on your
list shown as `<other>`.

My first version exited 1 on any 8001, 8002 or 8003. Since 8001 is a
successful connection, the "with issues" count was really a count of devices
that used WiFi that day, about half again larger than the number that had a
failure. The per-device failure count in the output text was right all along;
the exit code was wrong. It also read only the newest 300 events before
filtering by time, and printed every SSID it saw.

Remember that each device's 24 hours ends at its own last run, so the export
is not one shared day.

### EDR install recon ([`edr-install-recon/Detect-EdrInstallRecon.ps1`](edr-install-recon/Detect-EdrInstallRecon.ps1))

For a security agent rollout stuck at 0x80070643. One line per device: model,
build, uptime, free disk, reboot flags, the new sensor's service, version,
folders and Add/Remove Programs version, each outgoing agent's service, driver
service and binary version, Defender, loaded minifilters that are not on an
ignore list, the MsiInstaller 1033 status code, the latest MSI failure event
(11708, 11711, 11722, 11725 by default; not 11724, which is a successful
removal), and the bootstrapper log's first line, last error lines and final
line. Deploy it to a group holding only the failed bucket (see
[`../triage`](../triage)).

Status: [built, ran on real tickets] (run and finding per my notes; no recon
export kept). The file-backed part is the revision: the first draft did not
record the outgoing agent's exact build, and the second did. Case study 2 is
the story.

## Shared pieces ([`lib/`](lib))

Intune scripts must be self-contained, so each device script carries inline
copies of these, between `# region` markers. `tests/Run-Tests.ps1` fails if an
inline copy drifts from the file in `lib`.

- `PackedGuid.ps1`: `ConvertTo-PackedGuid` and `ConvertFrom-PackedGuid`.
  Windows Installer stores product codes under `Classes\Installer\Products`
  and `UserData` in a packed form (first three groups reversed, the rest
  pair-swapped). You need it to find the keys that keep a broken product
  "installed" after `msiexec /x` fails. [built, ran on real tickets]: the
  single-device fix in case study 1 used it.
- `OutputBudget.ps1`: `Format-RemediationOutput` joins fragments into one line
  that fits the 2,048-character limit. Short fragments stay whole, long ones
  are trimmed with `...`, and too many fragments end with `[+N more]`. New in
  this rewrite and unit-tested; the originals cut output with a hard
  `Substring(0, 2000)`.
- `Ensure64Bit.ps1`: the relaunch guard. New in this rewrite; the originals
  had none. The test suite runs it from 32-bit Windows PowerShell and checks
  that the child is 64-bit and gets the same parameters.
- `PrivateFolder.ps1`: `New-PrivateFolder` for a work folder SYSTEM will run
  or delete files from. It refuses a folder that is a junction, has a junction
  above it, or was created by someone other than SYSTEM or Administrators,
  then sets owner and ACL and reads them back. New in this rewrite; the pure
  decision function is unit-tested, and the refusal paths are tested on
  temporary folders.

## How the rewrite differs from what I ran

| Original | Rewrite |
|---|---|
| Repair work inside the detection script | Separate detect and remediate scripts |
| Broad regex registry deletes, `SilentlyContinue` | Anchored include pattern plus exclude pattern, `.reg` backup, read-back of every delete |
| `System32\msiexec.exe` assumed to be 64-bit | 64-bit relaunch guard in every device script that reads `HKLM:\SOFTWARE` or launches System32 tools |
| Output truncated with a hard `Substring(0, 2000)` | Fair-share output budget |
| WiFi monitor flagged successful connects | Flags only 8002 and non-benign 8003 |
| Company names and URLs in the code | Placeholders and a configuration block |
