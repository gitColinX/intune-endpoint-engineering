# Case studies

Four problems from one managed Windows fleet of about 850 devices, July to
September 2026. I left out vendors, people, devices and identifiers. Where a
number comes from my notes rather than an export I still have, the text says
so.

| # | Case | What it shows |
|---|---|---|
| 1 | [RMM agent install failures](01-five-versions-to-root-cause.md) | A repackage fixed new Autopilot builds. The devices that kept failing traced back to my scripts renaming the vendor's MSI. 742 of 752 installed when I closed the incident (per my notes) |
| 2 | [EDR rollout triage](02-edr-rollout-triage.md) | 75 failed installs. Read-only recon on the 68 installer errors pointed to an old build of the outgoing agent. No remediation script needed |
| 3 | [Remote support client false failures](03-auto-update-detection-false-failures.md) | 707 of 764 showed Failed, and 667 of them were false. A colleague's theory, checked with a join against Discovered apps and fixed through Graph |
| 4 | [Patch agent install context](04-msi-execution-context.md) | An `ALLUSERS=1` patch to a patch agent MSI. The first attempt still said User in the package metadata |
