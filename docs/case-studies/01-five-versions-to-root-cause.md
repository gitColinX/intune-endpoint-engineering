# RMM agent install failures

July and August 2026. An RMM agent, run by our managed service provider and
delivered to the fleet as an Intune Win32 app, stopped installing on new
devices and kept failing on a group of existing ones. It took one repackage
and five script versions to find the cause, which was in my own scripts.

Patterns from this case: [`remediations/agent-self-heal`](../../remediations/agent-self-heal),
[`remediations/evidence-collector`](../../remediations/evidence-collector),
[`remediations/recon-template`](../../remediations/recon-template),
[`msi/`](../../msi) (`New-MsiTransformRemoveAction`, packed GUIDs).

## Part 1: new devices (fixed by the repackage)

In late June the vendor raised the minimum agent version its servers would
accept. Our Win32 app still shipped an older build, so from about the last week
of June new Autopilot devices failed to come up in the RMM.

On 2026-07-16 I repackaged the current vendor MSI as a new Win32 app, Required
to all devices, and on 07-17:

- changed detection from the MSI product code to "folder exists", matching the
  old app's rule, because product-code detection was reporting false failures
  on devices with older agent installs
- lowered the minimum OS so a handful of older devices still in the fleet
  were no longer excluded
- removed an Information URL that pointed at a live installer link and had
  produced an interactive install prompt
- validated on an out-of-box Autopilot test device: the agent installed
  silently during provisioning and the device appeared in the MSP's portal

I also pulled recent enrollments through Graph with a device-code sign-in,
requesting only `DeviceManagementManagedDevices.Read.All`. On the shared Graph
command-line client the token still carried every scope consented to that
app, which is one reason I later designed a dedicated read-only app
registration. Working through the list with Claude cut it from 30 devices to
the 9 that enrolled during the outage window. A detection-only gap check on
those 9 found the agent on all of them.

That repackage is what fixed the fleet and every new build after it.

## Part 2: existing devices that kept failing (the five versions)

A separate group of devices, about 10 at first and 17 at the most, kept
failing silent installs. Interactive elevated installs worked. Version one was
a platform script. Versions two to five were Intune remediations, and I kept
the exports for three, four and five.

| Version | Date | What it changed | What it showed (source) |
|---|---|---|---|
| v1 (platform script) | 07-18 | Download, size check to catch an HTML error page saved as `.msi`, `msiexec /qn` with a log | Ran once. No fleet export (transcript) |
| v2 | 07-20 | Explicit msiexec, removal of stale registration from the old build, TLS 1.2, transcript and verbose MSI log | A diagnostic run. The verbose log named the failing step: a vendor disk-space check custom action whose helper exited 2, giving Error 1722 and then a rollback with 1603 (verbose MSI log) |
| v3 | 07-22 | Basic UI level (`/qb!`) to get past a silent-only pre-check, pre-created the vendor log folder, ran the helper directly to capture its output | 6 of 10 devices still failing (Intune export) |
| v4 | 07-24 | An MST that deleted the disk-space check from `InstallExecuteSequence`, embedded in the script | 6 of 10 still failing (Intune export). The next custom action, a token check, failed instead (my notes, the raw log was not kept) |
| v5 | 07-27 | Kept the vendor's MSI file name byte for byte | Of 16 devices: 14 passed detection (one of them with the service stopped), 1 remediated, 1 failed (Intune export, latest state per device) |

Alongside those, I ran two detection-only packages on 18 devices. One ruled
out app control blocking the vendor's helper. The other copied vendor setup
logs and MsiInstaller events into the IME Logs folder. The worst machine got
its own set of scripts, in this order:

1. A read-only census of Add/Remove Programs entries, Windows Installer
   registrations, folders and services.
2. An evidence collector that staged a zip in the IME Logs folder for Collect
   diagnostics. The bundle showed that device's agent had been dead for most
   of a year.
3. A deep clean that computed the packed GUID to purge Windows Installer
   registration. I deployed it once and have no export for it.
4. A targeted fix that succeeded. The device then appeared in the MSP's
   portal.

On 07-31 I replaced all of these with one universal self-heal: touch nothing
if healthy, start stopped services, otherwise purge and reinstall with the
vendor's file name, and require every service Running. I assigned it to the
17 devices. Its export shows each device's latest result, last updated between
08-06 and 08-24: HEALTHY / NOTHING TOUCHED on all 17. That proves the no-op
guard and the end state. It cannot show whether the repair path ran on an
earlier cycle, because latest-state rows hide earlier runs.

## The root cause

The installer needed its original file name. Some vendors read a site token
from the installer file name, and every script before v5 saved the download
under a short name of my choosing. The vendor's custom actions failed quietly,
and the first fix, the MST that removed the disk-space check, only exposed the
next failing action (per my notes, as above). The cause was my own scripts
renaming the vendor's MSI.

v5's first comment line said not to rename the file. The generic self-heal in
this repo takes the file name as a setting for the same reason.

## The theory I got wrong

Because interactive elevated installs worked and silent ones did not, I
believed for several days that the problem was silent installs under SYSTEM.
I put that in an escalation to the vendor through our MSP, and it was wrong.
Now I mark hypotheses as hypotheses in escalations.

## Outcome

When I closed the incident, around 2026-08-10, the app showed 742 of 752
devices installed, with 8 known failures and 2 pending. That number is from my
notes at the time, not an export I kept. The old app object and a redundant
second remote-support app were deleted.

The repackaged Win32 app is what fixed the fleet. The script versions worked
the 10 to 17 devices that kept failing. The v5 export shows each device's
latest state, so I cannot say how many of the 14 that passed detection v5
itself fixed.

## What I changed afterwards

- I stopped renaming vendor installers. The self-heal in this repo takes the
  file name as a setting.
- I use a remediation to bring back a verbose MSI log through the IME Logs
  folder before I try a fix.
- The rewrite splits detection from remediation. My universal self-heal did
  its work inside the detection script, and detection runs on every cycle.
- I keep each version's Intune export. The exports for versions three to five
  are why I can say "6 of 10" here.
