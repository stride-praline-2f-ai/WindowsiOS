#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Retry a timed-out ISO installation on a new disk, retaining the previous files.

Reuses the completed installer image read-only. The Windows apply step restarts;
this does not resume a partially applied DISM image. No deadline by default.
"""
import argparse
from pathlib import Path
import os
import shutil
import subprocess
import sys

import provision_windows_arm64 as provision


DISK_BYTES = 32 * 1024**3


def preflight(source, output, template):
    if output.exists():
        raise ValueError(f"Refusing to reuse {output}. Choose a new --output directory.")
    if not output.parent.is_dir():
        raise ValueError(f"Output parent does not exist: {output.parent}")
    for path in (source / "installer_iso.img", source / "code.fd", template, provision.WINVM):
        if not path.is_file() or not path.stat().st_size:
            raise ValueError(f"Required file missing or empty: {path}")
    running = subprocess.run(["pgrep", "-u", str(os.getuid()), "-x", "winvm"], capture_output=True, text=True)
    if running.returncode == 0:
        raise ValueError("A winvm process is still running. Wait for it to stop before retrying; do not delete any files.")
    if running.returncode != 1:
        raise ValueError("Could not check for a running winvm process")
    required = DISK_BYTES + 1024**3
    free = shutil.disk_usage(output.parent).free
    if free < required:
        raise ValueError(f"Preserving the old disk and creating a new one requires about 33 GiB free; available: {free / 1024**3:.1f} GiB. No files changed.")


def retry(source, output, template, timeout=0):
    preflight(source, output, template)
    print(f"Previous VM files preserved in: {source}", flush=True)
    print(f"New Windows disk and logs: {output}", flush=True)
    print("Reusing installer_iso.img read-only. Windows installation restarts from the beginning.", flush=True)
    print("Phase time limit: " + (f"{timeout} minutes" if timeout else "none"), flush=True)
    output.mkdir()  # Refuse a collision, including one occurring after preflight.
    shutil.copyfile(source / "code.fd", output / "code.fd")
    shutil.copyfile(template, output / "vars.fd")
    with (output / "windows11.img").open("xb") as disk:
        disk.truncate(DISK_BYTES)
    provision.WORK = output
    provision.WIN_IMG = output / "windows11.img"
    provision.CODE_FD = output / "code.fd"
    provision.VARS_FD = output / "vars.fd"
    provision.PHASE_TIMEOUT = timeout
    provision.run_winvm_phase("phase1_dism", ["--disk1", str(source / "installer_iso.img")],
                              output / "prov_phase1.png", max_minutes=40)
    shutil.copyfile(provision.VARS_FD, output / "vars_post_dism.fd")
    provision.run_winvm_phase("phase2_oobe", [], output / "prov_phase2.png", max_minutes=60)
    shutil.copyfile(provision.VARS_FD, output / "vars_clean.fd")
    print("SUCCESS: Windows ARM64 provisioned and cleanly shut down!", flush=True)
    print(f"Pack the new disk from {output / 'windows11.img'}, not the old partial disk.", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-work", type=Path, default=provision.ROOT / "work")
    parser.add_argument("--output", type=Path, default=provision.ROOT / "work" / "retry")
    parser.add_argument("--vars-template", type=Path, default=Path("/opt/homebrew/share/qemu/edk2-arm-vars.fd"))
    parser.add_argument("--phase-timeout-minutes", type=int, default=0, help="0 means no deadline (default)")
    parser.add_argument("--check-only", action="store_true", help="Validate retry inputs and free space without changing files")
    args = parser.parse_args()
    if args.phase_timeout_minutes < 0:
        parser.error("--phase-timeout-minutes must be zero or positive")
    source = args.source_work.expanduser().resolve()
    output = args.output.expanduser().resolve()
    template = args.vars_template.expanduser().resolve()
    if args.check_only:
        preflight(source, output, template)
        print(f"Retry prerequisites passed. Files are unchanged. Output would be {output}")
    else:
        retry(source, output, template, args.phase_timeout_minutes)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, RuntimeError, TimeoutError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
