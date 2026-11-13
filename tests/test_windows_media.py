# SPDX-License-Identifier: GPL-2.0-or-later
"""Run with python3 -m unittest discover -s tests -p test_windows_media.py."""
import contextlib
import io
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import windows_media as media
import provision_windows_arm64 as provision


def image(index, name, arch="12", build="26300"):
    return {"index": index, "name": name, "arch": arch, "build": build, "bytes": 10000000}


class WindowsMediaTests(unittest.TestCase):
    def test_selects_pro_by_name_not_fixed_index(self):
        catalog = [image(1, "Windows 11 Home"), image(4, "Windows 11 Pro")]
        self.assertEqual(media.select_image(catalog, name="Windows 11 Pro")["index"], 4)
        self.assertEqual(media.select_image(catalog, index=1)["name"], "Windows 11 Home")

    def test_rejects_wrong_architecture_and_ambiguous_selection(self):
        with self.assertRaisesRegex(ValueError, "not ARM64"):
            media.select_image([image(1, "Windows 11 Pro", arch="9")], index=1)
        with self.assertRaisesRegex(ValueError, "Cannot uniquely select"):
            media.select_image([image(1, "Windows 11 Pro"), image(2, "Windows 11 Pro")], name="Windows 11 Pro")

    def test_reads_actual_build_from_utf16_wim_metadata(self):
        xml = ('<?xml version="1.0" encoding="UTF-16"?><WIM><IMAGE INDEX="4">'
               '<NAME>Windows 11 Pro</NAME><TOTALBYTES>12345</TOTALBYTES><WINDOWS>'
               '<ARCH>12</ARCH><VERSION><BUILD>26300</BUILD></VERSION></WINDOWS></IMAGE></WIM>')
        with patch.object(media, "wimtool", return_value="wimlib-imagex"), patch.object(
            media.subprocess, "check_output", return_value=xml.encode("utf-16")
        ):
            catalog = media.images(Path("install.wim"))
        self.assertEqual(catalog[0]["build"], "26300")
        self.assertEqual(catalog[0]["bytes"], 12345)

    def test_copies_boot_files_without_install_payload(self):
        with tempfile.TemporaryDirectory() as temp:
            root, dest = Path(temp) / "iso", Path(temp) / "target"
            root.mkdir(); dest.mkdir()
            (root / "EFI").mkdir(); (root / "Boot").mkdir()
            (root / "BOOTMGR.EFI").write_bytes(b"boot")
            (root / "sources").mkdir()
            iso = media.ISOMedia(root, root / "sources/boot.wim", root / "sources/install.wim", [], [])
            iso.copy_boot_files(dest)
            self.assertEqual({p.name for p in dest.iterdir()}, {"efi", "boot", "bootmgr.efi"})

    def test_iso_mount_is_read_only_and_detaches_on_metadata_error(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / "windows.iso"
            source.touch()
            calls = []

            def fake_run(args, **kwargs):
                calls.append(args)
                if args[1] == "attach":
                    mounted = Path(args[args.index("-mountpoint") + 1])
                    (mounted / "sources").mkdir()
                    (mounted / "sources/boot.wim").touch()
                    (mounted / "sources/install.esd").touch()
                return subprocess.CompletedProcess(args, 0)

            with patch.object(media.subprocess, "run", side_effect=fake_run), patch.object(
                media, "images", side_effect=ValueError("bad metadata")
            ):
                with self.assertRaisesRegex(ValueError, "bad metadata"):
                    with media.open_iso(source, root / "work"):
                        self.fail("Invalid ISO metadata was accepted")
            self.assertIn("-readonly", calls[0])
            self.assertEqual(calls[-1][:2], ["hdiutil", "detach"])
            self.assertEqual(calls[-1][2], calls[0][calls[0].index("-mountpoint") + 1])

    def test_inspect_never_provisions_or_writes_vm_disks(self):
        iso = media.ISOMedia(Path("/iso"), Path("boot.wim"), Path("install.wim"),
                             [image(1, "Windows PE")], [image(4, "Windows 11 Pro")])
        with patch.object(sys, "argv", ["provision", "--iso", "windows.iso", "--inspect"]), patch.object(
            provision, "open_iso", return_value=contextlib.nullcontext(iso)
        ), patch.object(provision, "provision") as boot, contextlib.redirect_stdout(io.StringIO()):
            provision.main()
            boot.assert_not_called()

    def test_existing_vm_is_refused_before_mounting_or_provisioning(self):
        with tempfile.TemporaryDirectory() as temp:
            disk = Path(temp) / "windows11.img"
            disk.write_bytes(b"existing VM")
            with patch.object(provision, "WIN_IMG", disk), patch.object(
                sys, "argv", ["provision", "--iso", "windows.iso"]
            ), patch.object(provision, "open_iso") as mount, patch.object(
                provision, "provision"
            ) as boot, contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit):
                    provision.main()
                mount.assert_not_called()
                boot.assert_not_called()
            self.assertEqual(disk.read_bytes(), b"existing VM")


if __name__ == "__main__":
    unittest.main()
