"""Boot the release firmware on an ARM virt board and check its actual ramfb."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time


def qmp(command, arguments=None):
    request = {"execute": command}
    if arguments:
        request["arguments"] = arguments
    vm.stdin.write(json.dumps(request) + "\n")
    vm.stdin.flush()
    while line := vm.stdout.readline():
        response = json.loads(line)
        if "return" in response or "error" in response:
            return response
    raise RuntimeError(f"QEMU exited during {command}")


with tempfile.TemporaryDirectory() as tmp:
    screen = Path(tmp) / "frame.ppm"
    args = ["qemu-system-aarch64", "-nodefaults", "-machine", "virt,gic-version=3",
            "-cpu", "cortex-a76", "-m", "1024", "-device", "ramfb", "-display", "none",
            "-bios", sys.argv[1], "-qmp", "stdio", "-serial", "none"]
    with subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True) as vm:
        try:
            assert "QMP" in json.loads(vm.stdout.readline())
            assert "return" in qmp("qmp_capabilities")
            deadline = time.monotonic() + 60
            last = None
            while time.monotonic() < deadline:
                last = qmp("screendump", {"filename": str(screen)})
                if "return" in last:
                    with screen.open("rb") as stream:
                        magic, dimensions = stream.readline().strip(), stream.readline().split()
                    if magic == b"P6" and dimensions == [b"1600", b"1200"]:
                        print("ArmVirt GOP configured a 1600 x 1200 ramfb")
                        break
                time.sleep(0.3)
            else:
                raise RuntimeError(f"Expected a 1600 x 1200 framebuffer within 60 seconds ({last})")
        finally:
            vm.terminate()
