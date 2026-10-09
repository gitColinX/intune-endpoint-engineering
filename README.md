# Intune endpoint engineering

Intune Remediations and Win32 packaging patterns from real fleet work, written
with Claude. The fleet is my employer's: a hybrid Microsoft 365 tenant of about
1,100 Intune-managed endpoints, with about 850 to 860 managed Windows devices
in scope for this work between July and September 2026. I am the engineer on
the ground, so when an agent will not install, the problem is mine.

This repo is the generic version of what I built: the remediation patterns,
the packaging recipes, a small MSI toolkit, a triage tool for install-status
exports, and four case studies with the real (non-sensitive) numbers. It is a
fresh rewrite, generalized from what I ran at work. No employer code, names,
install tokens, tenant identifiers or device data are in it.

```
remediations/  recon first, then an idempotent self-heal, evidence into the IME Logs folder   [built, ran on real tickets]
msi/           ALLUSERS fix, MST that removes a custom action, read .intunewin metadata       [built, ran on real tickets]
win32/         version-aware detection, portable EXE wrapper, InstallShield response files    [built, ran on real tickets]
triage/        bucket an install-status export into group-ready device lists                  [built, ran on real tickets]
```

Status labels describe the pattern's original version at work. Every file here
is a fresh rewrite. The PowerShell files parse cleanly in Windows PowerShell
5.1 and PowerShell 7, the pure functions are unit-tested on synthetic
fixtures, and the read-only scripts and dry runs are smoke-tested on a
workstation. None of it has been run against a fleet in this exact form.

| | |
|---|---|
| **Case studies** | [`docs/case-studies/`](docs/case-studies/) |
| **Detection rule guide** | [`win32/DETECTION-RULES.md`](win32/DETECTION-RULES.md) |
| **32-bit versus 64-bit traps** | [`docs/64-bit-and-sysnative.md`](docs/64-bit-and-sysnative.md) |
| **Stack** | Intune Remediations and Win32 apps, Windows PowerShell 5.1 on devices, PowerShell 7 and Python 3 on the admin side, Claude |

## The problem

Intune is good at delivering an installer and bad at telling you why it
failed. The device install report says "Failed" with 0x80070643, which is
MSI error 1603, which means "something went wrong". Many devices were remote,
and I had no direct network path to end-user machines from my workstation, so
PsExec-style remoting was out. A remote support session needs a user at the
keyboard.

What I did have was Intune itself: Remediations run a script as SYSTEM on
every targeted device and bring back up to 2,048 characters of output per
device, and Collect diagnostics uploads the Intune Management Extension log
folder. Everything in `remediations/` is built on those two facts.

The agents that kept failing were the ones that matter most and that Intune
understands least: an RMM agent, an EDR sensor, a remote support client. They
update themselves, carry install tokens in odd places, and have custom actions
that fail without saying why.

## What is here

| Folder | What it does | Status |
|---|---|---|
| [`remediations/recon-template`](remediations/recon-template) | Detection-only, read-only recon: OS build, reboot flags, services, Add/Remove Programs, Windows Installer registrations, MSI events, vendor log tail, inside the output limit | [built, ran on real tickets] |
| [`remediations/agent-self-heal`](remediations/agent-self-heal) | Detect and remediate pair. Healthy no-op, start stopped services, purge stale MSI registration (ARP; `Classes\Installer` Products, Features and UpgradeCodes by packed GUID; UserData), reinstall with the vendor file name preserved and kept out of the output, verify SHA256 or signer in a private work folder, require every service Running | [built, ran on real tickets] |
| [`remediations/evidence-collector`](remediations/evidence-collector) | Gathers event logs, vendor logs, registry and service state into a zip in the IME Logs folder so Collect diagnostics brings it back | [built, ran on real tickets] |
| [`remediations/wlan-monitor`](remediations/wlan-monitor) | Detection-only WiFi monitor that flags only failed connections and disconnects (8002, 8003), never successful connects (8001) | [built, ran on real tickets] |
| [`remediations/edr-install-recon`](remediations/edr-install-recon) | Read-only recon for a security agent stuck at 1603: outgoing agent build and driver, minifilters, MSI status code, bootstrapper log | [built, ran on real tickets] (run and finding per my notes; no recon export kept) |
| [`remediations/lib`](remediations/lib) | Packed GUID conversion; output budget for the 2,048-character limit; 64-bit host guard; private work folder checks | Packed GUID: [built, ran on real tickets]. The rest is new in this rewrite, from lessons in the originals (they hard-truncated output at 2,000 characters and had no 64-bit guard), and tested by the suite |
| [`msi/`](msi) | `Set-MsiProperty`, `New-MsiTransformRemoveAction`, `Test-MsiTransform`, `Get-MsiSequence`, `Get-IntuneWinMetadata` | [built, ran on real tickets] |
| [`win32/`](win32) | Detection template (DisplayVersion at or above), portable EXE wrapper with a synthetic Add/Remove Programs entry, InstallShield response-file wrapper, legacy-EXE-then-MSI recipe, detection rule decision guide | [built, ran on real tickets] |
| [`triage/`](triage) | Python, standard library only. Buckets an install-status export by error code, staleness and duplicates; optional inventory list to catch false failures | [built, ran on real tickets] |
| [`tests/`](tests) | Parser checks, hygiene checks, unit tests, a synthetic MSI built from scratch, smoke runs | repo tooling |

Every PowerShell script that changes anything is a dry run by default. Local
runs need `-Apply`. Intune cannot pass parameters to a remediation script, so
the uploaded copy needs `ApplyWhenNoParameter = $true` in its configuration
block, which makes going live a deliberate edit. The one `.cmd` file is a Win32
install command and runs for real.

A script that runs as SYSTEM should not trust its own download. A file
downloaded into a folder standard users can write to, such as
`C:\Windows\Temp`, can be swapped before msiexec runs it. The self-heal here
refuses to install without a SHA256, exact signer subject or signer
thumbprint check, and downloads into a work folder under Program Files that it
refuses if someone else created it or it is a junction. It sets the owner and
ACL to SYSTEM and Administrators and reads them back before anything is
downloaded.

## Apps I packaged

About ten Win32 apps between July and September 2026. All install as System,
and most write an install log. My convention now is to call msiexec through
`%windir%\sysnative` with `/L*v`, for a consistent command line.
Version-aware detection on the five where versions drift.

| App (generic) | Installer | Detection | Notes |
|---|---|---|---|
| RMM agent | Vendor MSI, original file name kept | Folder exists | Replaced a stale package that broke new Autopilot builds. See case study 1 |
| EDR sensor | Vendor EXE with a customer ID | File exists | Fleet migration. See case study 2 |
| Vulnerability scanner agent | MSI with server and agent-key properties | File exists | |
| Patch agent | MSI patched to `ALLUSERS=1` | MSI product code | Fixed a user-context install. See case study 4 |
| Document management agent services | Burn bundle | Script: DisplayVersion at or above | Dependency of the next app |
| Document management desktop client | InstallShield launcher around an MSI | Script: DisplayVersion at or above | Windows 11 requirement, 2 GB disk rule, in-place upgrade. Pilot: 7 of 7 reporting devices installed, 0 failed |
| Field-device configuration tool | Legacy InstallShield, recorded response file | File version at or above | `ResultCode` parsing |
| Spreadsheet simulation add-in | InstallShield around an MSI | File exists | |
| Compression utility | MSI, old EXE install removed first | File version at or above | |
| Portable engineering file viewer | Single EXE, no installer | File version at or above | Wrapper adds a Start Menu shortcut and an Add/Remove Programs entry |

Also: one screenshot tool I moved from a Win32 app to the Microsoft Store app
type so it updates itself, and a remote support client whose detection rule I
fixed (case study 3). I did not use supersedence; each replacement was an
in-place MSI upgrade, then I deleted the old app object.

Some vendor install command lines carry secrets (install tokens, customer IDs,
agent keys). None of them are in this repo, and a recorded InstallShield
response file holds whatever was typed into the registration dialog, so
`.gitignore` excludes real `.iss` files.

## What broke, and what I learned

- **Renaming the vendor's MSI cost me four script versions.** Some vendors
  read a site token from the installer file name. Every script before version
  five saved the download under a short name I chose. The install started,
  then failed in a custom action. The self-heal now takes the file name as a
  setting and the comments say, in capitals, not to change it. It also keeps
  the name out of everything it reports: a verbose MSI log records the package
  path, so the log stays in a private folder and only a redacted copy goes
  where Collect diagnostics picks it up.
- **Removing a failing custom action exposed the next one.** I built an MST
  that deleted the vendor's disk-space check from `InstallExecuteSequence`.
  The disk check went away and, per my notes (the raw log was not kept), a
  token check further down failed instead. The real cause was upstream of
  both. An MST is a diagnostic tool before it is a fix.
- **I escalated the wrong theory first.** Interactive elevated installs
  worked and silent SYSTEM installs did not, so I told the vendor, through our
  MSP, that silent SYSTEM installs were the problem. They were not. Now I mark
  hypotheses as hypotheses in escalations.
- **Self-updating agents make product-code detection lie.** A remote support
  client showed 707 of 764 devices Failed. A colleague suggested the agents
  had auto-updated past the package's product code; a per-device join against
  Discovered apps proved 667 of those were false and 40 were real.
- **The Intune portal can silently undo a Graph change.** I fixed that
  detection rule through Graph. Three minutes later my own portal Save, from a
  blade opened before the change, re-sent the whole cached app object and put
  the old rule back. I re-applied it one field per PATCH and read each one back.
- **Verify the metadata, not the edit.** My first `ALLUSERS=1` patch of the
  patch agent MSI looked fine, but the re-wrapped package still recorded
  `MsiExecutionContext` User, and I never pinned down why. Only reading
  `Detection.xml` caught it. I redid the edit, gated the re-wrap on a
  read-back, and that package said System.
- **My WiFi monitor counted successful connections as problems.** Version one
  exited 1 on any of WLAN events 8001, 8002 or 8003, and 8001 is a successful
  connect, so its "with issues" count overstated the problem by about half
  again. The per-device failure count in the output was the real signal. The
  rewrite flags only failures and masks SSIDs it does not know.
- **Repair logic does not belong in the detection slot.** My final RMM
  self-heal did all of its work inside the detection script. It reported
  HEALTHY / NOTHING TOUCHED on all 17 devices it was assigned to, which proves
  the no-op guard, not the repair path. But detection runs on every schedule
  cycle, so anything destructive there can run more often than intended. The
  rewrite splits detect from remediate.
- **32-bit hosts quietly change what your script reads.** One of my early
  scripts said "64-bit msiexec" in a comment and called `System32\msiexec.exe`,
  which is only 64-bit when the host is. That mattered less than the registry
  and Program Files paths, which redirect too. Every device script here that
  reads `HKLM:\SOFTWARE` or launches System32 tools relaunches itself in
  64-bit if it has to. Details in [`docs/64-bit-and-sysnative.md`](docs/64-bit-and-sysnative.md).
- **`-ErrorAction SilentlyContinue` everywhere hid failures.** The rewrite
  reads back every registry delete, service delete and folder delete and says
  "verified gone" or "STILL PRESENT".
- **The 2,048-character limit truncates exactly the line you need.** Hence
  `Format-RemediationOutput`, which shares the budget fairly across fragments.
- **Recon first sometimes means no fix at all.** In the EDR rollout, read-only
  recon on the failed bucket pointed at an old build of the outgoing agent
  (from my notes; no recon export kept). That vendor's own upgrade wave
  cleared most of it. I never needed a remediation script.

## What it produced

| Job | When | Result |
|---|---|---|
| **RMM agent, new builds** | 2026-07-16 to 07-17 | Repackaged the current agent as a new Win32 app after the vendor raised its minimum version. Detection moved from MSI product code to folder exists. An out-of-box Autopilot test device installed it silently and showed up in the MSP's portal. |
| **RMM agent, stranded devices** | 2026-07-17 to 08-24 | Five script versions, then a single self-heal; the Intune exports I kept cover versions three to five and the self-heal. Versions three and four left 6 of 10 devices failing. Version five, with the file name preserved: of 16 devices, 14 passed detection (one with the service stopped), 1 remediated, 1 failed. The final self-heal's latest result was HEALTHY / NOTHING TOUCHED on 17 of 17. When I closed the incident the app showed 742 of 752 installed, with 8 known failures and 2 pending, per my notes. The repackage fixed the fleet; the remediations worked the 10 to 17 stranded devices. |
| **EDR rollout triage** | 2026-08-24 to 08-31 | 75 failed installs on the app report; my bucket export had 78 device rows: 68 installer errors, 7 content delivery, 3 stale. Read-only recon on the 68 pointed at an old build of the outgoing agent blocking the new sensor's driver (from my notes; the raw recon output was not kept). The outgoing vendor's upgrade wave, not my action, cleared most of them. |
| **Self-updating agent false failures** | 2026-09-11 | 707 of 764 devices showed Failed; 667 were false and 40 were real. Detection changed to file exists through Graph, reverted by a portal save, re-applied with read-back. I did not re-measure the failure count afterwards. |
| **Patch agent install context** | 2026-08-07 | `ALLUSERS=1` added to a copy of the MSI; the package metadata went from User to System on the second attempt. |
| **Document management client** | 2026-09-09 to 09-11 | Two apps linked by a dependency, script detection at or above the packaged version. Pilot: 7 of 7 reporting devices installed, 0 failed: five upgraded in place from five different older versions, one clean install, one already current. The fleet wave followed; I do not have its numbers on file. |
| **WiFi monitor** | 2026-07-22 to 08-25 | Ran fleet-wide as a detection-only remediation and fed a wireless investigation. Its first version taught me the 8001 lesson above. |

## Using it

1. Read the script header, then fill in the `$Config` block. Every value in
   this repo is a placeholder (Contoso, Fabrikam, example.com).
2. Run it locally without `-Apply`. Read the WOULD lines.
3. For Intune, upload a copy with `ApplyWhenNoParameter = $true`, run as
   SYSTEM, "Run script in 64-bit PowerShell" set to Yes. Assign to a small
   group first.
4. Never commit a configured copy. `.gitignore` excludes `*.local.ps1` for
   exactly that.

Tests:

```powershell
pwsh -NoProfile -File .\tests\Run-Tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
python -I -B -m unittest discover -s triage\tests -v
```

## How this was built

The original scripts were co-written with Claude while the incidents were
live. I set the scope and the rules (recon before repair, dry run before
apply, no change counted as done until a read-back said so, every tenant
object name approved before it was created), deployed everything through
Intune, read the logs, and decided what shipped. I approved production writes
before they ran. In later sessions, routine reads often ran under Claude
Code's auto mode, whose classifier approves them; the contract (my standing
instructions to the agent) still required my approval for production writes.
Claude drafted most of the code. I sent drafts back when they missed
something; the first EDR recon script did not record the outgoing agent's
exact build, and per my notes that turned out to be the field that lined up
with the failures.

This is a fresh rewrite, generalized from what I ran at work, written with
Claude Code. I directed the work and checked the results against my own
records. The code here is tested offline against synthetic fixtures (297
PowerShell checks passing in both Windows PowerShell 5.1 and PowerShell 7,
and 13 Python tests passing, on 2026-10-09) and has not been run against a
live tenant in this form. The test suite parses every PowerShell file, runs
the pure functions against synthetic fixtures, builds a synthetic MSI from
scratch to exercise the MSI module, and smoke-runs the read-only scripts and
dry runs. The triage tool's Python tests run on a synthetic export.
PSScriptAnalyzer has not been run on this code.

## About

Colin Lundholm, IT Support Engineer, working across systems administration,
endpoint, identity and cloud &middot; [GitHub profile](https://github.com/gitColinX)
&middot; [LinkedIn](https://www.linkedin.com/in/cdlundholm)

Corrections welcome by issue or pull request. MIT licensed.
