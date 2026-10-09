#!/usr/bin/env python3
"""Bucket an Intune app "Device install status" export into group-ready device lists.

Why: the Intune portal tells you an app has N failed devices. It does not tell
you which failures share a cause, which ones are not real, or which devices you
can put into a targeting group for a fix. This script answers that from the
export alone, offline, with the Python standard library.

Input: one or more exports of Apps > (app) > Device install status > Export,
as the CSV or the zip Intune hands you. Columns used:
    DeviceName, DeviceId, Platform, AppVersion, LastModifiedDateTime,
    AppInstallState / AppInstallState_loc, AppInstallStateDetails_loc, HexErrorCode
UserPrincipalName is read past and never written to the outputs.

Optional: --present-list, a list of device names that inventory (for example
Intune Discovered apps) says already HAVE the app. Failed devices on that list
go to their own bucket, because an app that updates itself can show "Failed"
while it is installed and healthy. In one case that was 667 of 707 failures.

Buckets for failed devices, first match wins:
    P_present_per_inventory   on --present-list: probably a detection problem, not an install problem
    C_stale_or_mixed          no status update within --stale-days (default 14) of the as-of date, or the device
                              has both Installed and Failed rows, or its name maps to more than one
                              device id (re-enrolled): record hygiene first, then decide
    A_installer_fatal         0x80070643 (MSI 1603, the generic "fatal error during installation")
    B_content_delivery        0x87D3xxxx (content download or content information failures)
    D_detection_mismatch      0x87D1041C (install finished, detection rule did not find it)
    E_retry_busy              0x80070652 (1618, another installation in progress)
    F_access_denied           0x80070005
    Z_other                   anything else

Outputs (in --out):
    summary.json, summary.md            counts only, no device names
    failed_devices.csv                  one row per failed device, with bucket and reasons
    bucket_<name>.txt / .csv            device names (and Intune device ids) per bucket

Device names are identifiers. Keep the outputs out of source control.

Pattern status: [built, ran on real tickets]. I bucketed an EDR sensor rollout
this way (75 failed installs on the app report; my bucket export had 78 device
rows: 68 installer errors, 7 content delivery, 3 stale) and put the first
bucket into a targeting group for read-only recon. This file is a fresh
rewrite, generalized from what I ran at work, tested only on synthetic exports.
One difference from what I did then: 0x80070652 (another installation in
progress) has its own retry bucket instead of sitting with content delivery.

Why --stale-days defaults to 14: a device that has not reported for two weeks
needs a record check before anyone debugs its installer, and a shorter line
pushes genuine failures from a rollout that ran over a couple of weeks into
the hygiene bucket.
"""

import argparse
import collections
import csv
import datetime as dt
import io
import json
import os
import re
import sys
import zipfile

STATE_CODES = {"S1": "Installed", "S2": "Failed", "S5": "Install Pending"}

BUCKET_ORDER = [
    "P_present_per_inventory",
    "C_stale_or_mixed",
    "A_installer_fatal",
    "B_content_delivery",
    "D_detection_mismatch",
    "E_retry_busy",
    "F_access_denied",
    "Z_other",
]

ERROR_RULES = [
    ("A_installer_fatal", re.compile(r"^0x80070643$", re.I)),
    ("B_content_delivery", re.compile(r"^0x87D3[0-9A-F]{4}$", re.I)),
    ("D_detection_mismatch", re.compile(r"^0x87D1041C$", re.I)),
    ("E_retry_busy", re.compile(r"^0x80070652$", re.I)),
    ("F_access_denied", re.compile(r"^0x80070005$", re.I)),
]

BUCKET_NOTES = {
    "P_present_per_inventory": "Inventory says the app is there. Check the detection rule before reinstalling anything.",
    "C_stale_or_mixed": "Record hygiene: stale check-in, conflicting rows, or a re-enrolled duplicate. Confirm the device is real and current first.",
    "A_installer_fatal": "MSI 1603. Generic. Needs a verbose MSI log or recon on the device; group these for a detection-only recon script.",
    "B_content_delivery": "Content download or content info failures. Often network or proxy; retry before deeper work.",
    "D_detection_mismatch": "Installer finished but the detection rule did not match. Fix the rule, not the device.",
    "E_retry_busy": "Another installation was running (1618). Usually clears on the next attempt.",
    "F_access_denied": "Access denied. Look at app control, EDR blocks, or file locks.",
    "Z_other": "Unclassified error codes.",
}


def parse_time(text):
    """Parse the export's LastModifiedDateTime. Returns a naive datetime or None."""
    if not text:
        return None
    t = text.strip().replace("T", " ").rstrip("Z")
    m = re.match(r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})(\.\d+)?", t)
    if m:
        return dt.datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S")
    for fmt in ("%m/%d/%Y %I:%M:%S %p", "%m/%d/%Y %H:%M:%S", "%m/%d/%Y", "%Y-%m-%d"):
        try:
            return dt.datetime.strptime(t, fmt)
        except ValueError:
            continue
    return None


def read_rows(path):
    """Yield dict rows from a CSV file or from every CSV inside a zip."""
    if path.lower().endswith(".zip"):
        with zipfile.ZipFile(path) as z:
            for name in z.namelist():
                if not name.lower().endswith(".csv"):
                    continue
                text = z.read(name).decode("utf-8-sig", errors="replace")
                for row in csv.DictReader(io.StringIO(text)):
                    yield row
    else:
        with open(path, newline="", encoding="utf-8-sig", errors="replace") as f:
            for row in csv.DictReader(f):
                yield row


def normalize(row):
    """Reduce an export row to the fields this tool uses. Drops the UPN."""
    state = (row.get("AppInstallState_loc") or "").strip()
    if not state:
        code = (row.get("AppInstallState") or "").strip()
        state = STATE_CODES.get(code, code or "Unknown")
    err = (row.get("HexErrorCode") or "").strip()
    detail = (row.get("AppInstallStateDetails_loc") or "").strip()
    name = (row.get("DeviceName") or "").strip()
    device_id = (row.get("DeviceId") or "").strip()
    return {
        "name": name,
        "id": device_id,
        "key": (device_id or name).lower(),
        "platform": (row.get("Platform") or "").strip(),
        "version": (row.get("AppVersion") or "").strip(),
        "state": state,
        "error": err,
        "detail": detail,
        "time": parse_time(row.get("LastModifiedDateTime") or ""),
    }


def load_present_list(path):
    """Device names known to have the app: plain text (one per line) or CSV with a device name column."""
    names = set()
    with open(path, newline="", encoding="utf-8-sig", errors="replace") as f:
        text = f.read()
    first = text.splitlines()[0] if text.strip() else ""
    if "," in first:
        reader = csv.DictReader(io.StringIO(text))
        cols = [c for c in (reader.fieldnames or []) if c and c.replace(" ", "").lower() == "devicename"]
        if not cols:
            raise SystemExit("present list: CSV needs a DeviceName or 'Device name' column")
        for r in reader:
            v = (r.get(cols[0]) or "").strip()
            if v:
                names.add(v.lower())
    else:
        for line in text.splitlines():
            v = line.strip()
            if v and not v.startswith("#"):
                names.add(v.lower())
    return names


def classify_error(code):
    for bucket, rx in ERROR_RULES:
        if code and rx.match(code):
            return bucket
    return "Z_other"


def triage(rows, stale_days=14, as_of=None, present=None):
    """Pure core. rows: normalized dicts. Returns (devices, summary)."""
    present = present or set()
    by_device = collections.OrderedDict()
    for r in rows:
        if not r["key"]:
            continue
        by_device.setdefault(r["key"], []).append(r)

    times = [r["time"] for r in rows if r["time"]]
    if as_of is None:
        as_of = max(times) if times else dt.datetime(1970, 1, 1)

    ids_per_name = collections.defaultdict(set)
    for r in rows:
        if r["name"]:
            ids_per_name[r["name"].lower()].add(r["id"] or r["key"])
    duplicate_names = {n for n, ids in ids_per_name.items() if len(ids) > 1}

    devices = []
    effective_counts = collections.Counter()
    error_rows = collections.Counter()
    for key, drs in by_device.items():
        drs_sorted = sorted(drs, key=lambda x: x["time"] or dt.datetime(1970, 1, 1))
        latest = drs_sorted[-1]
        states = {d["state"] for d in drs}
        effective_counts[latest["state"]] += 1
        for d in drs:
            if d["error"]:
                error_rows[d["error"]] += 1
        if "Failed" not in states:
            continue
        failed_rows = [d for d in drs_sorted if d["state"] == "Failed"]
        last_failed = failed_rows[-1]
        errors = sorted({d["error"] or "(none)" for d in failed_rows})
        name = latest["name"] or next((d["name"] for d in drs if d["name"]), "")
        last_time = latest["time"]
        age = (as_of - last_time).days if last_time else None

        reasons = []
        if name.lower() in present:
            bucket = "P_present_per_inventory"
            reasons.append("present-per-inventory")
        else:
            if age is None or age > stale_days:
                reasons.append("stale" if age is not None else "no-timestamp")
            if "Installed" in states:
                reasons.append("mixed-states")
            if name.lower() in duplicate_names:
                reasons.append("duplicate-name")
            if reasons:
                bucket = "C_stale_or_mixed"
            else:
                bucket = classify_error(last_failed["error"])
                reasons.append("error " + (last_failed["error"] or "(none)"))
        devices.append({
            "DeviceName": name,
            "IntuneDeviceId": latest["id"],
            "Bucket": bucket,
            "Reasons": "; ".join(reasons),
            "Errors": "; ".join(errors),
            "LastStatusUpdate": last_time.strftime("%Y-%m-%d %H:%M") if last_time else "",
            "DaysSinceUpdate": "" if age is None else str(age),
            "Platform": latest["platform"],
            "AppVersion": latest["version"],
        })

    bucket_counts = collections.Counter(d["Bucket"] for d in devices)
    summary = {
        "as_of": as_of.strftime("%Y-%m-%d %H:%M"),
        "stale_days": stale_days,
        "rows": len(rows),
        "devices": len(by_device),
        "devices_by_latest_state": dict(sorted(effective_counts.items())),
        "failed_devices": len(devices),
        "buckets": {b: bucket_counts.get(b, 0) for b in BUCKET_ORDER if bucket_counts.get(b, 0)},
        "error_code_rows": dict(error_rows.most_common()),
        "duplicate_device_names": len(duplicate_names),
        "present_list_size": len(present),
    }
    devices.sort(key=lambda d: (BUCKET_ORDER.index(d["Bucket"]), d["DeviceName"].lower()))
    return devices, summary


def write_outputs(out_dir, devices, summary, inputs):
    os.makedirs(out_dir, exist_ok=True)
    summary = dict(summary)
    summary["inputs"] = [os.path.basename(p) for p in inputs]
    with open(os.path.join(out_dir, "summary.json"), "w", encoding="utf-8") as f:
        json.dump(summary, f, indent=2)

    fields = ["DeviceName", "IntuneDeviceId", "Bucket", "Reasons", "Errors", "LastStatusUpdate", "DaysSinceUpdate", "Platform", "AppVersion"]
    with open(os.path.join(out_dir, "failed_devices.csv"), "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=fields)
        w.writeheader()
        w.writerows(devices)

    for bucket in BUCKET_ORDER:
        members = [d for d in devices if d["Bucket"] == bucket]
        if not members:
            continue
        names = sorted({d["DeviceName"] for d in members if d["DeviceName"]}, key=str.lower)
        with open(os.path.join(out_dir, "bucket_%s.txt" % bucket), "w", encoding="utf-8") as f:
            f.write("\n".join(names) + "\n")
        with open(os.path.join(out_dir, "bucket_%s.csv" % bucket), "w", newline="", encoding="utf-8") as f:
            w = csv.writer(f)
            w.writerow(["DeviceName", "IntuneDeviceId"])
            for d in members:
                w.writerow([d["DeviceName"], d["IntuneDeviceId"]])

    lines = [
        "# Install status triage",
        "",
        "As of %s, stale after %d days. Inputs: %s." % (summary["as_of"], summary["stale_days"], ", ".join(summary["inputs"])),
        "",
        "| Measure | Count |",
        "|---|---|",
        "| Rows in export | %d |" % summary["rows"],
        "| Unique devices | %d |" % summary["devices"],
    ]
    for state, n in summary["devices_by_latest_state"].items():
        lines.append("| Devices, latest state %s | %d |" % (state, n))
    lines.append("| Devices with any Failed row | %d |" % summary["failed_devices"])
    lines += ["", "| Bucket | Devices | What to do |", "|---|---|---|"]
    for b, n in summary["buckets"].items():
        lines.append("| %s | %d | %s |" % (b, n, BUCKET_NOTES[b]))
    lines += ["", "Error codes (rows): " + ", ".join("%s x%d" % (k or "(none)", v) for k, v in summary["error_code_rows"].items()), ""]
    with open(os.path.join(out_dir, "summary.md"), "w", encoding="utf-8") as f:
        f.write("\n".join(lines))


def main(argv=None):
    ap = argparse.ArgumentParser(description="Bucket an Intune app install-status export into group-ready device lists.")
    ap.add_argument("--input", nargs="+", required=True, help="export CSV or zip (one or more)")
    ap.add_argument("--out", required=True, help="output folder (created if missing)")
    ap.add_argument("--stale-days", type=int, default=14, help="no status update for more than this many days counts as stale (default 14)")
    ap.add_argument("--as-of", help="reference date YYYY-MM-DD (default: newest timestamp in the export)")
    ap.add_argument("--present-list", help="device names that inventory says already have the app (txt or CSV)")
    args = ap.parse_args(argv)

    rows = []
    for p in args.input:
        if not os.path.isfile(p):
            ap.error("input not found: %s" % p)
        rows.extend(normalize(r) for r in read_rows(p))
    if not rows:
        ap.error("no rows read from input")
    as_of = dt.datetime.strptime(args.as_of, "%Y-%m-%d") if args.as_of else None
    present = load_present_list(args.present_list) if args.present_list else set()
    devices, summary = triage(rows, stale_days=args.stale_days, as_of=as_of, present=present)
    write_outputs(args.out, devices, summary, args.input)

    print("rows=%d devices=%d failed=%d" % (summary["rows"], summary["devices"], summary["failed_devices"]))
    for b, n in summary["buckets"].items():
        print("  %-26s %d" % (b, n))
    print("Wrote %s. The bucket files contain device names: keep them out of source control." % args.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
