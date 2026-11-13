# SPDX-License-Identifier: GPL-2.0-or-later
import contextlib
import io
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import provision_windows_arm64 as provision
import retry_windows_provision as recovery


class PhaseDeadlineTests(unittest.TestCase):
    def run_phase(self, temp, process, timeout, times):
        with patch.object(provision, "WORK", Path(temp)), patch.object(
            provision, "PHASE_TIMEOUT", timeout
        ), patch.object(provision.subprocess, "Popen", return_value=process), patch.object(
            provision.subprocess, "check_output", return_value="16G disk"
        ), patch.object(provision.time, "monotonic", side_effect=times), patch.object(
            provision.time, "sleep"
        ), contextlib.redirect_stdout(io.StringIO()):
            provision.run_winvm_phase("test", [], Path(temp) / "screen.png", max_minutes=40)

    def test_zero_deadline_survives_more_than_three_hours(self):
        process = Mock(returncode=0)
        process.poll.side_effect = [None, None, 0, 0]
        with tempfile.TemporaryDirectory() as temp:
            self.run_phase(temp, process, 0, [0, 20000, 20001, 20002])
        process.terminate.assert_not_called()

    def test_explicit_deadline_waits_for_child_to_stop(self):
        process = Mock()
        process.poll.return_value = None
        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaises(TimeoutError):
                self.run_phase(temp, process, 1, [0, 61])
        process.terminate.assert_called_once()
        process.wait.assert_called_once_with(timeout=15)


class RecoveryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.source = Path(self.temp.name)
        self.output = self.source / "retry"
        self.template = self.source / "template.fd"
        self.runner = self.source / "winvm"
        for name, contents in (("installer_iso.img", b"installer"), ("code.fd", b"firmware"),
                               ("windows11.img", b"partial 82 percent"), ("vars.fd", b"old vars"),
                               ("template.fd", b"fresh vars"), ("winvm", b"runner")):
            (self.source / name).write_bytes(contents)

    def preflight(self, running=1, free=100 * 1024**3):
        with patch.object(provision, "WINVM", self.runner), patch.object(
            recovery.subprocess, "run", return_value=subprocess.CompletedProcess([], running)
        ), patch.object(recovery.shutil, "disk_usage", return_value=SimpleNamespace(free=free)):
            recovery.preflight(self.source, self.output, self.template)

    def test_refuses_active_vm_and_low_space_without_creating_files(self):
        with self.assertRaisesRegex(ValueError, "still running"):
            self.preflight(running=0)
        with self.assertRaisesRegex(ValueError, "33 GiB"):
            self.preflight(free=1024)
        self.assertFalse(self.output.exists())

    def test_existing_output_is_never_reused(self):
        self.output.mkdir()
        (self.output / "windows11.img").write_bytes(b"another VM")
        with self.assertRaisesRegex(ValueError, "Refusing to reuse"):
            self.preflight()
        self.assertEqual((self.output / "windows11.img").read_bytes(), b"another VM")

    def test_retry_preserves_original_disk_and_uses_unlimited_new_disk(self):
        originals = {p.name: p.read_bytes() for p in self.source.iterdir()}
        fields = {name: getattr(provision, name) for name in ("WORK", "WIN_IMG", "CODE_FD", "VARS_FD", "PHASE_TIMEOUT")}
        observed = []

        def phase(name, extra, screenshot, max_minutes):
            observed.append((name, extra, provision.WIN_IMG, provision.PHASE_TIMEOUT))

        try:
            with patch.object(recovery, "preflight"), patch.object(
                provision, "run_winvm_phase", side_effect=phase
            ), contextlib.redirect_stdout(io.StringIO()):
                recovery.retry(self.source, self.output, self.template)
        finally:
            for name, value in fields.items():
                setattr(provision, name, value)
        self.assertEqual(len(observed), 2)
        self.assertEqual(observed[0][1], ["--disk1", str(self.source / "installer_iso.img")])
        self.assertTrue(all(item[2] == self.output / "windows11.img" and item[3] == 0 for item in observed))
        self.assertEqual((self.output / "windows11.img").stat().st_size, recovery.DISK_BYTES)
        self.assertEqual((self.output / "vars.fd").read_bytes(), b"fresh vars")
        for name, contents in originals.items():
            self.assertEqual((self.source / name).read_bytes(), contents)


if __name__ == "__main__":
    unittest.main()
