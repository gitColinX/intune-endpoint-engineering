# EDR rollout triage: recon first, and no fix needed

August 2026. The fleet was moving from one EDR product to another. I
packaged the new sensor as an Intune Win32 app (vendor EXE, silent switches
plus the customer ID, file-exists detection) and assigned it. Most devices
took it. A block of them did not, and the Intune report said what it always
says: Failed, 0x80070643.

Patterns from this case: [`triage/`](../../triage),
[`remediations/edr-install-recon`](../../remediations/edr-install-recon),
[`remediations/recon-template`](../../remediations/recon-template).

## Bucket before you touch anything

On 2026-08-24 the app report showed 75 failed installs. I exported the app's
device install status and bucketed the failed devices by error, staleness and
conflicting records. My bucket export had 78 device rows:

| Bucket | Device rows | Meaning |
|---|---|---|
| Installer fatal error (0x80070643, MSI 1603) | 68 | The real problem, cause unknown |
| Content delivery (0x87D3xxxx) | 7 | Download or content info, usually transient |
| Stale or mixed record | 3 | Record hygiene, not an install problem |
| Total in the bucket export | 78 | |

The 68 went into a dedicated device group, created through Graph, so anything
I deployed next would reach only them.

## Recon, read-only, on the 68

I wrote a detection-only script for that group that changed nothing and
reported, per device: model, build, uptime, free disk, pending reboot flags;
the new sensor's service, version, folders and Add/Remove Programs entry; the
outgoing agent's service, driver service and exact build; Defender's state;
the MsiInstaller 1033 status code and the latest MSI error event; and the head,
last error lines and tail of the sensor's bootstrapper log.

The first draft did not record the outgoing agent's exact build. I sent it back
and the second version did. That turned out to be the field that mattered.

## What it showed

Per my notes from the end of August (the raw recon output was not kept), the
failing devices lined up with an older build of the outgoing EDR agent whose
driver blocked the new sensor's driver from registering. Devices on newer
builds of the outgoing agent installed the new sensor without trouble.

## What fixed it

Not me. The outgoing vendor's own agent upgrade wave moved most of the bucket
onto newer builds, and most of the 68 then installed on their own. A retry
remediation was considered and turned out not to be needed. My part was the
diagnosis: knowing why the devices failed, so that nobody wrote a script that
tore out one security agent to make room for another.

## What I took from it

- 1603 is a symptom. Bucket first, then ask the devices.
- Read-only recon can go to a broad group on day one. A fix cannot.
- Record the exact version of everything that might conflict. "Installed" is
  not enough when two security agents share a kernel.
- Sometimes the right remediation is none, and the report should say so.
