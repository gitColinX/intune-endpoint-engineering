# Case studies

Four real problems from one managed Windows fleet of about 850 to 860 devices,
July to September 2026. Vendors, people, devices and identifiers are left out
on purpose; the numbers are real. Where a number comes from my notes rather
than an export I still have, the text says so.

| # | Case | What it shows |
|---|---|---|
| 1 | [Five versions to root cause](01-five-versions-to-root-cause.md) | Repackage fixed new Autopilot builds; five script versions and a self-heal worked the stranded devices; the bug was our own scripts renaming the vendor's MSI. 742 of 752 installed when I closed the incident (per my notes) |
| 2 | [EDR rollout triage](02-edr-rollout-triage.md) | 75 failed installs on the app report; 78 device rows in my bucket export, bucketed 68 / 7 / 3; read-only recon on the 68 pointed at the outgoing agent's old build blocking the new driver; no remediation script needed |
| 3 | [Auto-update false failures](03-auto-update-detection-false-failures.md) | 707 of 764 Failed, 667 of them false. A colleague's theory, proved with a join against Discovered apps, fixed through Graph, undone once by a portal save |
| 4 | [MSI execution context](04-msi-execution-context.md) | `ALLUSERS=1` patch; the first attempt still said User; verify the metadata, not the edit |
