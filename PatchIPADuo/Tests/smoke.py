import pathlib
import plistlib
import struct
import subprocess
import tempfile
import zipfile

root = pathlib.Path(tempfile.mkdtemp())
src = root / "fixture.ipa"
prefix = "Payload/Test.app/"
info = dict(CFBundleIdentifier="org.example.fixture", CFBundleExecutable="Test",
            UIDeviceFamily=[2], CFBundlePackageType="APPL", MinimumOSVersion="15.0",
            UIApplicationSceneManifest={"UISceneConfigurations": {"UIWindowSceneSessionRoleApplication": [{"UISceneDelegateClassName":"Scene"}]}})
def make():
    with zipfile.ZipFile(src, "w", zipfile.ZIP_DEFLATED) as z:
        directory = zipfile.ZipInfo(prefix+"Resources")
        directory.external_attr = (0o40755 << 16) | 0x10
        z.writestr(directory, b"")
        z.writestr(prefix+"Resources/asset", b"resource")
        z.writestr(prefix+"Info.plist", plistlib.dumps(info))
        z.writestr(prefix+"Test", struct.pack("<14I",0xfeedfacf,0x100000c,0,2,1,24,0,0,0x32,24,2,15<<16,18<<16,0))

make()
for mode, version in [("full","27.1"),("reserved-side","27.0")]:
    output = subprocess.check_output([".build/release/Smoke",str(src),mode],text=True).strip()
    with zipfile.ZipFile(output) as z:
        assert z.read(prefix+"Resources/asset") == b"resource"
        p = plistlib.loads(z.read(prefix+"Info.plist"))
        assert p["DTSDKName"] == "iphoneos"+version and p["UIDeviceFamily"] == [1,2]
        assert struct.unpack_from("<I",z.read(prefix+"Test"),48)[0] == (27<<16 | int(version[-1])<<8)
del info["UIApplicationSceneManifest"]
make()
assert subprocess.run([".build/release/Smoke",str(src),"full"]).returncode != 0

make()
with zipfile.ZipFile(src, "a") as z:
    link = zipfile.ZipInfo(prefix+"link")
    link.external_attr = 0o120777 << 16
    z.writestr(link, b"Test")
failure = subprocess.run([".build/release/Smoke",str(src),"full"], capture_output=True, text=True)
assert failure.returncode != 0 and "Unsupported symbolic link: Payload/Test.app/link" in failure.stderr
