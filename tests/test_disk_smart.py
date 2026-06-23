import importlib.util
from pathlib import Path
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = REPO_ROOT / "agent" / "collectors" / "disk_smart.py"
FIXTURE_DIR = Path(__file__).resolve().parent / "fixtures" / "smartctl"

spec = importlib.util.spec_from_file_location("disk_smart", MODULE_PATH)
disk_smart = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(disk_smart)


def fixture(name: str) -> str:
    return (FIXTURE_DIR / name).read_text(encoding="utf-8")


class DiskSmartParserTest(unittest.TestCase):
    def test_parse_ata_json(self) -> None:
        parsed = disk_smart.parse_json_smart(fixture("ata.json"))

        self.assertEqual(parsed["status"], "PASS")
        self.assertEqual(parsed["health"], "正常")
        self.assertEqual(parsed["temperature"], "36")
        self.assertEqual(parsed["power_on_hours"], "1234")
        self.assertEqual(parsed["reallocated_sectors"], "0")
        self.assertEqual(parsed["pending_sectors"], "0")
        self.assertEqual(parsed["uncorrectable_errors"], "0")
        self.assertEqual(parsed["crc_errors"], "2")

    def test_parse_nvme_json_warns_on_media_errors(self) -> None:
        parsed = disk_smart.parse_json_smart(fixture("nvme.json"))

        self.assertEqual(parsed["status"], "WARN")
        self.assertEqual(parsed["health"], "关注")
        self.assertEqual(parsed["temperature"], "44")
        self.assertEqual(parsed["media_errors"], "3")
        self.assertEqual(parsed["percentage_used"], "7")
        self.assertEqual(parsed["available_spare"], "95")
        self.assertEqual(parsed["power_on_hours"], "4096")

    def test_parse_raid_text(self) -> None:
        parsed = disk_smart.parse_text_smart(fixture("megaraid.txt"), source="raid_physical")

        self.assertEqual(parsed["source"], "raid_physical")
        self.assertEqual(parsed["status"], "WARN")
        self.assertEqual(parsed["health"], "关注")
        self.assertEqual(parsed["temperature"], "31")
        self.assertEqual(parsed["power_on_hours"], "1000")
        self.assertEqual(parsed["reallocated_sectors"], "4")

    def test_permission_denied_is_warn(self) -> None:
        parsed = disk_smart.parse_text_smart(fixture("permission_denied.txt"))

        self.assertEqual(parsed["status"], "WARN")
        self.assertEqual(parsed["health"], "关注")
        self.assertEqual(parsed["temperature"], "N/A")

    def test_io_error_is_warn(self) -> None:
        parsed = disk_smart.parse_text_smart(fixture("io_error.txt"))

        self.assertEqual(parsed["status"], "WARN")
        self.assertEqual(parsed["health"], "关注")
        self.assertEqual(parsed["temperature"], "N/A")

    def test_scan_raid_devices_deduplicates_supported_types(self) -> None:
        original = disk_smart.run_smartctl
        try:
            disk_smart.run_smartctl = lambda _args: "\n".join(
                [
                    "/dev/bus/0 -d megaraid,0 # /dev/bus/0 [megaraid_disk_00]",
                    "/dev/bus/0 -d megaraid,0 # duplicate",
                    "/dev/sda -d sat # direct disk",
                    "/dev/sg1 -d cciss,1 # cciss disk",
                ]
            )
            self.assertEqual(
                disk_smart.scan_raid_devices(),
                [("/dev/bus/0", "megaraid,0"), ("/dev/sg1", "cciss,1")],
            )
        finally:
            disk_smart.run_smartctl = original


if __name__ == "__main__":
    unittest.main()
