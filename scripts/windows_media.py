# SPDX-License-Identifier: GPL-2.0-or-later
"""Read installation images from an ARM64 Windows ISO without modifying it."""
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET


def wimtool():
    tool = shutil.which("wimlib-imagex")
    if not tool:
        raise ValueError("Install wimlib first: brew install wimlib")
    return tool


def images(path):
    xml = subprocess.check_output([wimtool(), "info", str(path), "--xml"])
    result = []
    for image in ET.fromstring(xml).findall("IMAGE"):
        result.append({
            "index": int(image.attrib["INDEX"]),
            "name": image.findtext("NAME", ""),
            "arch": image.findtext("WINDOWS/ARCH", ""),
            "build": image.findtext("WINDOWS/VERSION/BUILD", "unknown"),
            "bytes": int(image.findtext("TOTALBYTES", "0")),
        })
    if not result:
        raise ValueError(f"No installation images found in {path}")
    return result


def select_image(catalog, index=None, name=None):
    selected = [item for item in catalog if (
        item["index"] == index if index is not None else item["name"].casefold() == name.casefold()
    )]
    if len(selected) != 1:
        choices = ", ".join(f'{item["index"]}: {item["name"]}' for item in catalog)
        raise ValueError(f"Cannot uniquely select {index or name}. Available images: {choices}")
    item = selected[0]
    if item["arch"] != "12":
        raise ValueError(f'{item["name"]} is not ARM64 (Windows architecture code {item["arch"]!r})')
    return item


def child(directory, name):
    matches = [p for p in directory.iterdir() if p.name.casefold() == name.casefold()]
    if len(matches) != 1:
        raise ValueError(f"Expected {name} in {directory}")
    return matches[0]


@dataclass
class ISOMedia:
    root: Path
    boot: Path
    install: Path
    boot_catalog: list
    install_catalog: list

    def copy_boot_files(self, destination):
        # Only boot files, never the ISO's large sources directory.
        for name in ("efi", "boot", "bootmgr.efi"):
            source = child(self.root, name)
            target = destination / name
            if source.is_dir():
                shutil.copytree(source, target, dirs_exist_ok=True)
            else:
                shutil.copy2(source, target)


@contextmanager
def open_iso(path, work):
    path = Path(path).expanduser().resolve(strict=True)
    if not path.is_file():
        raise ValueError(f"Not a file: {path}")
    work.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="windows-iso-", dir=work) as mount:
        root = Path(mount)
        subprocess.run(["hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", mount, str(path)], check=True)
        try:
            sources = child(root, "sources")
            boot = child(sources, "boot.wim")
            available = {p.name.casefold(): p for p in sources.iterdir()}
            install = available.get("install.wim") or available.get("install.esd")
            if install is None:
                raise ValueError("ISO needs sources/install.wim or install.esd; split SWM media is not supported")
            yield ISOMedia(root, boot, install, images(boot), images(install))
        finally:
            # Detach only this process's read-only mount; never force-detach user volumes.
            subprocess.run(["hdiutil", "detach", mount], check=True)
