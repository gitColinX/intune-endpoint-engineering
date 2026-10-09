"""Tests for intune_install_triage.py against a synthetic export. Run from the repo root:

    python -I -B -m unittest discover -s triage/tests -v
"""
import csv
import datetime as dt
import json
import os
import shutil
import sys
import tempfile
import unittest
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

import intune_install_triage as t  # noqa: E402

FIXTURE = os.path.join(HERE, "fixtures", "device-install-status-synthetic.csv")


def load_fixture():
    return [t.normalize(r) for r in t.read_rows(FIXTURE)]


class TriageCore(unittest.TestCase):
    def setUp(self):
        self.devices, self.summary = t.triage(load_fixture(), stale_days=7)
        self.by_name = {}
        for d in self.devices:
            self.by_name.setdefault(d["DeviceName"], []).append(d)

    def bucket_of(self, name):
        rows = self.by_name[name]
        self.assertEqual(len(rows), 1, name)
        return rows[0]["Bucket"]

    def test_as_of_defaults_to_newest_timestamp(self):
        self.assertEqual(self.summary["as_of"], "2026-01-20 12:00")

    def test_counts(self):
        self.assertEqual(self.summary["rows"], 16)
        self.assertEqual(self.summary["devices"], 14)  # 13 names, one of them on two device ids
        self.assertEqual(self.summary["failed_devices"], 11)
        self.assertEqual(self.summary["buckets"], {
            "C_stale_or_mixed": 3,
            "A_installer_fatal": 2,
            "B_content_delivery": 2,
            "D_detection_mismatch": 1,
            "E_retry_busy": 1,
            "F_access_denied": 1,
            "Z_other": 1,
        })
        self.assertEqual(self.summary["duplicate_device_names"], 1)

    def test_error_buckets(self):
        self.assertEqual(self.bucket_of("TEST-PC-002"), "A_installer_fatal")
        self.assertEqual(self.bucket_of("TEST-PC-003"), "B_content_delivery")
        self.assertEqual(self.bucket_of("TEST-PC-004"), "F_access_denied")
        self.assertEqual(self.bucket_of("TEST-PC-005"), "E_retry_busy")
        self.assertEqual(self.bucket_of("TEST-PC-009"), "D_detection_mismatch")
        self.assertEqual(self.bucket_of("TEST-PC-012"), "Z_other")

    def test_state_code_fallback_without_localized_column(self):
        self.assertEqual(self.bucket_of("TEST-PC-013"), "B_content_delivery")

    def test_hygiene_bucket_reasons(self):
        self.assertIn("mixed-states", self.by_name["TEST-PC-006"][0]["Reasons"])
        self.assertIn("stale", self.by_name["TEST-PC-007"][0]["Reasons"])
        self.assertIn("duplicate-name", self.by_name["TEST-PC-008"][0]["Reasons"])
        for n in ("TEST-PC-006", "TEST-PC-007", "TEST-PC-008"):
            self.assertEqual(self.bucket_of(n), "C_stale_or_mixed")

    def test_installed_and_pending_are_not_failed(self):
        self.assertNotIn("TEST-PC-001", self.by_name)
        self.assertNotIn("TEST-PC-010", self.by_name)

    def test_present_list_moves_false_failures(self):
        devices, summary = t.triage(load_fixture(), stale_days=7, present={"test-pc-011"})
        self.assertEqual(summary["buckets"]["P_present_per_inventory"], 1)
        self.assertEqual(summary["buckets"]["A_installer_fatal"], 1)
        self.assertEqual([d["DeviceName"] for d in devices if d["Bucket"].startswith("P_")], ["TEST-PC-011"])

    def test_explicit_as_of_and_stale_days(self):
        devices, summary = t.triage(load_fixture(), stale_days=30, as_of=dt.datetime(2026, 1, 20))
        names = {d["DeviceName"] for d in devices if "stale" in d["Reasons"]}
        self.assertEqual(names, set())

    def test_default_stale_days_is_14(self):
        devices, summary = t.triage(load_fixture())
        self.assertEqual(summary["stale_days"], 14)
        stale = {d["DeviceName"] for d in devices if "stale" in d["Reasons"]}
        self.assertEqual(stale, {"TEST-PC-007"})  # 19 days old; everything else reported within 5

    def test_retry_busy_is_not_content_delivery(self):
        self.assertEqual(t.classify_error("0x80070652"), "E_retry_busy")
        self.assertEqual(t.classify_error("0x87D30065"), "B_content_delivery")

    def test_parse_time_formats(self):
        self.assertEqual(t.parse_time("2026-08-24 18:36:01.1234567"), dt.datetime(2026, 8, 24, 18, 36, 1))
        self.assertEqual(t.parse_time("2026-08-24T18:36:01Z"), dt.datetime(2026, 8, 24, 18, 36, 1))
        self.assertEqual(t.parse_time("8/24/2026 6:36:01 PM"), dt.datetime(2026, 8, 24, 18, 36, 1))
        self.assertIsNone(t.parse_time(""))


class TriageCli(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="triage-test-")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_zip_input_and_outputs(self):
        zpath = os.path.join(self.tmp, "export.zip")
        with zipfile.ZipFile(zpath, "w") as z:
            z.write(FIXTURE, "DeviceInstallStatusByApp_synthetic.csv")
        present = os.path.join(self.tmp, "present.csv")
        with open(present, "w", newline="", encoding="utf-8") as f:
            w = csv.writer(f)
            w.writerow(["Device name", "Version"])
            w.writerow(["TEST-PC-011", "9.9.9"])
        out = os.path.join(self.tmp, "out")
        rc = t.main(["--input", zpath, "--out", out, "--present-list", present])
        self.assertEqual(rc, 0)
        for f in ("summary.json", "summary.md", "failed_devices.csv", "bucket_A_installer_fatal.txt", "bucket_P_present_per_inventory.csv"):
            self.assertTrue(os.path.isfile(os.path.join(out, f)), f)
        with open(os.path.join(out, "bucket_A_installer_fatal.txt"), encoding="utf-8") as f:
            self.assertEqual(f.read().split(), ["TEST-PC-002"])

    def test_outputs_never_contain_upns_and_summaries_have_no_device_names(self):
        out = os.path.join(self.tmp, "out")
        t.main(["--input", FIXTURE, "--out", out])
        for name in os.listdir(out):
            with open(os.path.join(out, name), encoding="utf-8") as f:
                text = f.read()
            self.assertNotIn("@example.com", text, name)
            if name.startswith("summary"):
                self.assertNotIn("TEST-PC", text, name)
        with open(os.path.join(out, "summary.json"), encoding="utf-8") as f:
            self.assertEqual(json.load(f)["inputs"], ["device-install-status-synthetic.csv"])


if __name__ == "__main__":
    unittest.main()
