# Full write-up

At work I support a hybrid Microsoft 365 tenant of about 1,100 Intune-managed
endpoints, with about 850 managed Windows devices in scope between July and
September 2026. Agent install failures came to me.

Everything here is rewritten from scripts I ran at work, with company names,
install tokens and device data removed. It is tested offline and has not been
run against a live tenant.

Other docs:

- Case studies: [`case-studies/`](case-studies/)
- Detection rule guide: [`win32/DETECTION-RULES.md`](../win32/DETECTION-RULES.md)
- 32-bit versus 64-bit traps: [`64-bit-and-sysnative.md`](64-bit-and-sysnative.md)
- Stack: Intune Remediations and Win32 apps, Windows PowerShell 5.1 on
  devices, PowerShell 7 and Python 3 on the admin side, Claude

## Background

Intune's install report rarely says why an install failed. It shows
0x80070643, which is MSI error 1603, a generic failure. Many devices were
remote, and I had no direct network path to end-user machines from my
workstation, so PsExec-style remoting was out. A remote support session needs
a user at the keyboard.

I could still use Intune. Remediations run a script as SYSTEM on every
targeted device and bring back up to 2,048 characters of output per device,
and Collect diagnostics uploads the Intune Management Extension log folder.
The scripts in `remediations/` use both.

The agents that kept failing were an RMM agent, an EDR sensor and a remote
support client. They update themselves, some carry install tokens in the file
name or command line, and their custom actions often fail without a clear
error.

## What's in here

| Folder | What it does |
|---|---|
| [`remediations/recon-template`](../remediations/recon-template) | Detection-only, read-only recon: OS build, reboot flags, services, Add/Remove Programs, Windows Installer registrations, MSI events, vendor log tail, inside the output limit |
| [`remediations/agent-self-heal`](../remediations/agent-self-heal) | Detect and remediate pair. Healthy no-op, start stopped services, purge stale MSI registration (Add/Remove Programs, `Classes\Installer` Products, Features and UpgradeCodes by packed GUID, and UserData), reinstall with the vendor file name preserved and kept out of the output, verify SHA256 or signer in a private work folder, require every service Running |
| [`remediations/evidence-collector`](../remediations/evidence-collector) | Gathers event logs, vendor logs, registry and service state into a zip in the IME Logs folder so Collect diagnostics brings it back |
| [`remediations/wlan-monitor`](../remediations/wlan-monitor) | Detection-only WiFi monitor that flags only failed connections and disconnects (8002, 8003), never successful connects (8001) |
| [`remediations/edr-install-recon`](../remediations/edr-install-recon) | Read-only recon for a security agent stuck at 1603: outgoing agent build and driver, minifilters, MSI status code, bootstrapper log |
| [`remediations/lib`](../remediations/lib) | Packed GUID conversion, an output budget for the 2,048-character limit, a 64-bit host guard and private work folder checks |
| [`msi/`](../msi) | `Set-MsiProperty`, `New-MsiTransformRemoveAction`, `Test-MsiTransform`, `Get-MsiSequence`, `Get-IntuneWinMetadata` |
| [`win32/`](../win32) | Detection template (DisplayVersion at or above), portable EXE wrapper with a synthetic Add/Remove Programs entry, InstallShield response-file wrapper, legacy-EXE-then-MSI recipe, detection rule decision guide |
| [`triage/`](../triage) | Python, standard library only. Buckets an install-status export by error code, staleness and duplicates, with an optional inventory list to catch false failures |
| [`tests/`](../tests) | Parser checks, hygiene checks, unit tests, a synthetic MSI built from scratch, smoke runs |

All of these started as scripts I ran on real tickets. The exceptions are
`tests/` and the parts of `remediations/lib/` other than the packed GUID code,
which are new in this rewrite.

Every PowerShell script that changes anything is a dry run by default. Local
runs need `-Apply`. Intune cannot pass parameters to a remediation script, so
the uploaded copy needs `ApplyWhenNoParameter = $true` in its configuration
block, which makes going live a deliberate edit. The one `.cmd` file is a Win32
install command and runs for real.

The self-heal checks its download before it runs anything as SYSTEM, because
a file saved to a folder users can write to, such as `C:\Windows\Temp`, can be
swapped before msiexec runs it. It refuses to install without a SHA256, exact
signer subject or signer thumbprint check. It downloads into a work folder
under Program Files and refuses that folder if someone else created it or it
is a junction. It sets the owner and ACL to SYSTEM and Administrators and reads
them back before anything is downloaded.

## Apps I packaged

I packaged about ten Win32 apps between July and September 2026. All install
as System, and most write an install log. I now call msiexec through
`%windir%\sysnative` with `/L*v` so the command line is the same every time.
Five of them use version-aware detection because their versions drift.

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

I also moved one screenshot tool from a Win32 app to the Microsoft Store app
type so it updates itself, and fixed the detection rule for a remote support
client (case study 3). I did not use supersedence. Each replacement was an
in-place MSI upgrade, and then I deleted the old app object.

Some vendor install command lines carry secrets (install tokens, customer IDs,
agent keys). None of them are in this repo. A recorded InstallShield response
file holds whatever was typed into the registration dialog, so `.gitignore`
excludes real `.iss` files.

## Problems I hit

- I renamed the vendor's MSI in four script versions before finding out the
  installer needed its original file name. Some vendors read a site token from
  it. Every script before version five saved the download under a short name I
  chose, and the install started, then failed in a custom action. The
  self-heal now takes the file name as a setting, and the comments say, in
  capitals, not to change it. It also keeps the name out of everything it
  reports. A verbose MSI log records the package path, so the log stays in a
  private folder and only a redacted copy goes where Collect diagnostics picks
  it up.
- I built an MST that deleted the vendor's disk-space check from
  `InstallExecuteSequence`. Per my notes (the raw log was not kept), a token
  check further down then failed instead. The real cause was upstream of both.
- I escalated the wrong theory first. Interactive elevated installs worked and
  silent SYSTEM installs did not, so I told the vendor, through our MSP, that
  silent SYSTEM installs were the problem. They were not. Now I mark
  hypotheses as hypotheses in escalations.
- A remote support client showed 707 of 764 devices Failed. A colleague
  suggested the agents had auto-updated past the package's product code. I
  joined each device against Discovered apps: 667 of those were false and 40
  were real.
- I fixed that detection rule through Graph, and the Intune portal put it
  back. Three minutes later my own portal Save, from a blade opened before the
  change, re-sent the whole cached app object with the old rule. I re-applied
  the change one field per PATCH and read each one back.
- My first `ALLUSERS=1` patch of the patch agent MSI looked fine, but the
  re-wrapped package still recorded `MsiExecutionContext` User, and I never
  pinned down why. Only reading `Detection.xml` caught it. I redid the edit,
  gated the re-wrap on a read-back, and that package said System.
- Version one of my WiFi monitor counted successful connections as problems.
  It exited 1 on any of WLAN events 8001, 8002 or 8003, and 8001 is a
  successful connect, so its "with issues" count overstated the problem by
  about half again. The per-device failure count in the output was the real
  signal. The rewrite flags only failures and masks SSIDs it does not know.
- My final RMM self-heal did all of its work inside the detection script. It
  reported HEALTHY / NOTHING TOUCHED on all 17 devices it was assigned to,
  which proves the no-op guard, not the repair path. Detection runs on every
  schedule cycle, so anything destructive there can run more often than
  intended. The rewrite splits detect from remediate.
- One of my early scripts said "64-bit msiexec" in a comment and called
  `System32\msiexec.exe`, which is only 64-bit when the host is. The registry
  and Program Files paths mattered more, because they redirect too. My
  originals had no 64-bit guard. Every device script here that reads
  `HKLM:\SOFTWARE` or launches System32 tools relaunches itself in 64-bit if
  it has to. Details in [`64-bit-and-sysnative.md`](64-bit-and-sysnative.md).
- Using `-ErrorAction SilentlyContinue` everywhere hid failures. The rewrite
  reads back every registry delete, service delete and folder delete and says
  "verified gone" or "STILL PRESENT".
- Remediation output is capped at 2,048 characters. My originals
  hard-truncated at 2,000 and could cut off the line I needed.
  `Format-RemediationOutput` now shares the budget across fragments.
- In the EDR rollout, read-only recon was enough. Recon on the failed bucket
  pointed at an old build of the outgoing agent (from my notes, no recon
  export kept). That vendor's own upgrade wave cleared most of it, and I never
  needed a remediation script.

## Results

| Job | When | Result |
|---|---|---|
| RMM agent, new builds | 2026-07-16 to 07-17 | Repackaged the current agent as a new Win32 app after the vendor raised its minimum version. Detection moved from MSI product code to folder exists. An out-of-box Autopilot test device installed it silently and showed up in the MSP's portal. |
| RMM agent, existing devices | 2026-07-17 to 08-24 | Five script versions, then a single self-heal. The Intune exports I kept cover versions three to five and the self-heal. Versions three and four left 6 of 10 devices failing. Version five, with the file name preserved: of 16 devices, 14 passed detection (one with the service stopped), 1 remediated, 1 failed. The final self-heal's latest result was HEALTHY / NOTHING TOUCHED on 17 of 17. When I closed the incident the app showed 742 of 752 installed, with 8 known failures and 2 pending, per my notes. The repackage fixed the fleet. The remediations worked the 10 to 17 devices that kept failing. |
| EDR rollout triage | 2026-08-24 to 08-31 | 75 failed installs on the app report. My bucket export had 78 device rows: 68 installer errors, 7 content delivery, 3 stale. Read-only recon on the 68 pointed at an old build of the outgoing agent blocking the new sensor's driver (from my notes, the raw recon output was not kept). The outgoing vendor's upgrade wave, not my action, cleared most of them. |
| Self-updating agent false failures | 2026-09-11 | 707 of 764 devices showed Failed. 667 were false and 40 were real. I changed detection to file exists through Graph. A portal save reverted it, and I re-applied it with a read-back. I did not re-measure the failure count afterwards. |
| Patch agent install context | 2026-08-07 | I added `ALLUSERS=1` to a copy of the MSI. The package metadata went from User to System on the second attempt. |
| Document management client | 2026-09-09 to 09-11 | Two apps linked by a dependency, script detection at or above the packaged version. Pilot: 7 of 7 reporting devices installed, 0 failed: five upgraded in place from five different older versions, one clean install, one already current. The fleet wave followed. I do not have its numbers on file. |
| WiFi monitor | 2026-07-22 to 08-25 | Ran fleet-wide as a detection-only remediation and fed a wireless investigation. Its first version is where I found the 8001 problem above. |

## Usage

1. Read the script header, then fill in the `$Config` block. Every value in
   this repo is a placeholder (Contoso, Fabrikam, example.com).
2. Run it locally without `-Apply`. Read the WOULD lines.
3. For Intune, upload a copy with `ApplyWhenNoParameter = $true`, run as
   SYSTEM, "Run script in 64-bit PowerShell" set to Yes. Assign to a small
   group first.
4. Never commit a configured copy. `.gitignore` excludes `*.local.ps1` for
   exactly that.

Tests, from the repo root:

```powershell
pwsh -NoProfile -File .\tests\Run-Tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
python -I -B -m unittest discover -s triage\tests -v
```

## How I built it

I wrote the original scripts with Claude during the incidents. I set the scope
and the rules (recon before repair, dry run before apply, no change counted as
done until a read-back said so, every tenant object name approved before it
was created), deployed everything through Intune, read the logs, and decided
what shipped. Every production write waited for my approval. In later
sessions, routine reads often ran without asking me each time. Claude drafted
most of the code, and I sent drafts back when they missed something. The
first EDR recon script did not record the outgoing agent's exact build, and
per my notes that turned out to be the field that lined up with the failures.

I made this rewrite with Claude Code and checked the results against my own
records. The test suite parses every PowerShell file, runs the pure functions
against synthetic fixtures, builds a synthetic MSI from scratch to exercise
the MSI module, and smoke-runs the read-only scripts and dry runs. On
2026-10-09, 297 PowerShell checks passed in both Windows PowerShell 5.1 and
PowerShell 7, and the triage tool's 13 Python tests passed on a synthetic
export. I have not run PSScriptAnalyzer on this code.

## About

Colin Lundholm, IT Support Engineer &middot; [GitHub profile](https://github.com/gitColinX)
&middot; [LinkedIn](https://www.linkedin.com/in/cdlundholm)

Corrections welcome by issue or pull request. MIT licensed.
