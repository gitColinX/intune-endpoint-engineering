# Intune Endpoint Engineering

These are the Intune Remediations and Win32 packaging scripts I built at work, where I support a hybrid Microsoft 365 tenant of about 1,100 Intune-managed endpoints. Between July and September 2026 I used them to find out why our RMM, EDR and remote support agents were showing as failed in Intune. I wrote the originals with Claude during those incidents. This copy is rewritten without company names, install tokens or device data.

## What's in here

- [remediations/](remediations/) - Intune Remediation scripts: read-only recon, an agent self-heal, an evidence collector and a WiFi failure monitor.
- [msi/](msi/) - a PowerShell module to patch an MSI property like `ALLUSERS`, build a transform, and read `.intunewin` metadata.
- [win32/](win32/) - packaging recipes: version-aware detection, a portable EXE wrapper, InstallShield response files.
- [triage/](triage/) - a Python script that sorts an Intune install-status export into device lists.
- [docs/case-studies/](docs/case-studies/) - four of these problems written up in full, with the numbers.

## What it did at work

- New Autopilot devices stopped showing up in our RMM after the vendor raised its minimum agent version. I repackaged the agent, which fixed the fleet. A group of existing devices kept failing, and it took me five script versions to find out why: my scripts were renaming the vendor's MSI, and the installer needed its original file name. My notes at close show 742 of 752 devices installed.
- Intune showed 707 of 764 devices failing a remote support client. A colleague suspected the agent had auto-updated past the product code the detection rule checked. I joined the report against Discovered apps: 667 were false and 40 were real. I changed the rule through Graph.
- An EDR rollout left 75 failed installs. From my notes, read-only recon pointed to an old build of the outgoing agent. That vendor's own upgrade wave cleared most of them, so I never needed a fix script.
- I packaged about ten Win32 apps. A document management client installed on 7 of 7 reporting pilot devices, five of them upgrades from older versions.

## Try it

From the repo root:

```powershell
pwsh -NoProfile -File .\tests\Run-Tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
python -I -B -m unittest discover -s triage\tests -v
```

The tests run offline on synthetic data. On 2026-10-09, 297 PowerShell checks passed in PowerShell 5.1 and 7, and 13 Python tests passed. Scripts that change anything only print what they would do until you add `-Apply`. I have not run this rewrite against a live tenant.

## More detail

- [Full write-up](docs/WRITEUP.md): every folder, the apps I packaged, problems I hit and how I worked with Claude
- [Detection rule guide](win32/DETECTION-RULES.md)
- [32-bit versus 64-bit traps](docs/64-bit-and-sysnative.md)

## About

Colin Lundholm, IT Support Engineer &middot; [GitHub profile](https://github.com/gitColinX) &middot; [LinkedIn](https://www.linkedin.com/in/cdlundholm)

MIT licensed.
