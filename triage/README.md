# Install-status triage

`intune_install_triage.py` turns an Intune app's device install status export
into buckets of devices that share a cause, and writes each bucket as a plain
list you can load into a group. Python 3.8 or later, standard library only, no
network, no Graph.

Status: [built, ran on real tickets]. I bucketed an EDR sensor rollout this
way. The app report showed 75 failed installs; my bucket export had 78 device
rows: 68 installer errors, 7 content delivery, 3 stale. The 68 went into a
device group for read-only recon (case study 2). This file is a fresh rewrite,
generalized from what I ran at work; its unit tests run on a synthetic
export. One difference from what I did then:
`0x80070652` (another installation in progress) has its own retry bucket
instead of sitting with content delivery.

`--stale-days` defaults to 14. A device that has not reported for two weeks
needs a record check before anyone debugs its installer, and a shorter line
pushes genuine failures from a rollout that ran over a couple of weeks into the
hygiene bucket. Lower it for a fast rollout, raise it for a slow one.

## Run it

Export from Intune: Apps > Windows > (app) > Device install status > Export.
You get a zip with one CSV; either works as input.

```powershell
python -I .\triage\intune_install_triage.py --input .\DeviceInstallStatusByApp_xxxx.zip --out .\triage-out
python -I .\triage\intune_install_triage.py --input .\export.csv --out .\triage-out --stale-days 7 --as-of 2026-08-24
python -I .\triage\intune_install_triage.py --input .\export.csv --out .\triage-out --present-list .\discovered-app-devices.csv
```

## Buckets

A device counts as failed if any of its rows is Failed. First match wins:

| Bucket | Rule | What to do |
|---|---|---|
| `P_present_per_inventory` | Device is on `--present-list` | Inventory says the app is there. Fix the detection rule, not the device |
| `C_stale_or_mixed` | No status update within `--stale-days` (default 14), or both Installed and Failed rows, or the name maps to more than one device id | Record hygiene first: is the device real and current? |
| `A_installer_fatal` | `0x80070643` (MSI 1603) | Generic. Recon or a verbose MSI log. Group these |
| `B_content_delivery` | `0x87D3xxxx` | Download or content info. Often network or proxy. Retry first |
| `D_detection_mismatch` | `0x87D1041C` | The installer finished and the rule did not match. Fix the rule |
| `E_retry_busy` | `0x80070652` (1618) | Another install was running. Usually clears |
| `F_access_denied` | `0x80070005` | App control, EDR, file locks |
| `Z_other` | Anything else | Look at them by hand |

Rows per device: the export has one row per device and user combination, so a
shared device can have several. The tool collapses them by Intune device id
and uses the newest row for the device's current state.

## The present list, and why 1603 is not always real

An app that updates itself can show Failed with 0x80070643 on a device where it
is installed and healthy, because Intune keeps trying to install the older
package over it. In one case that was 667 of 707 failures. Before you treat
the 1603 bucket as real, export the devices that inventory says have the app
(Intune Discovered apps, or your RMM) and pass them as `--present-list`, as
plain text with one device name per line, or as a CSV with a `DeviceName` or
`Device name` column.

## Outputs

| File | Contents |
|---|---|
| `summary.json`, `summary.md` | Counts only: rows, devices by latest state, buckets, error codes |
| `failed_devices.csv` | One row per failed device: name, Intune device id, bucket, reasons, errors, last update, days since update, platform, app version |
| `bucket_<name>.txt` | Device names, one per line |
| `bucket_<name>.csv` | `DeviceName`, `IntuneDeviceId` |

User principal names are read past and never written. Device names are still
identifiers: keep the output folder out of source control (`.gitignore`
excludes `triage-out/` and `out/`).

## From a bucket to a group

Entra security groups take Entra device object ids, not Intune device ids. With
the Graph PowerShell SDK, per device: read the Intune managed device for its
`azureADDeviceId`, look up `/devices?$filter=deviceId eq '<that id>'` for the
Entra object id, then `New-MgGroupMemberByRef`. Or use the Entra bulk import
for group members with the resolved object ids. Either way, count the members
afterwards and compare with the bucket.
