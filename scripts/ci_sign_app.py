#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Optionally development-sign the CI app using repository secrets."""
import base64
import datetime
import fnmatch
import hashlib
import os
from pathlib import Path
import plistlib
import re
import secrets
import shutil
import subprocess
import tempfile


def run(*args):
    # Capture security output: do not log certificate passwords or profile data.
    result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise RuntimeError(f"{args[0]} {args[1]} failed (exit {result.returncode})")
    return result.stdout


def main():
    os.chdir(Path(__file__).resolve().parent.parent)
    for name in ("IOS_CERTIFICATE_P12_BASE64", "IOS_PROFILE_BASE64"):
        if not os.environ.get(name):
            raise ValueError(f"Set the {name} repository secret before requesting signing")
    app = Path("build/ipa/Payload/WindowsiOS.app")
    bundle_id = plistlib.loads((app / "Info.plist").read_bytes())["CFBundleIdentifier"]
    with tempfile.TemporaryDirectory(prefix="winios-sign-") as temp:
        temp = Path(temp)
        cert = temp / "certificate.p12"
        profile = temp / "profile.mobileprovision"
        cert.write_bytes(base64.b64decode(os.environ["IOS_CERTIFICATE_P12_BASE64"]))
        profile.write_bytes(base64.b64decode(os.environ["IOS_PROFILE_BASE64"]))
        data = plistlib.loads(run("security", "cms", "-D", "-i", str(profile)))
        entitlements = data["Entitlements"]
        if data["ExpirationDate"] <= datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None):
            raise ValueError("Provisioning profile has expired")
        if not entitlements.get("get-task-allow") or not data.get("ProvisionedDevices"):
            raise ValueError("Use an Apple Development device profile permitting debugger attachment")
        permitted_id = entitlements["application-identifier"]
        prefix = permitted_id.split(".", 1)[0]
        app_id = f"{prefix}.{bundle_id}"
        if not fnmatch.fnmatchcase(app_id, permitted_id):
            raise ValueError("Bundle ID does not match the provisioning profile")
        entitlements["application-identifier"] = app_id
        if "keychain-access-groups" in entitlements:
            entitlements["keychain-access-groups"] = [
                value.replace("*", bundle_id)
                for value in entitlements["keychain-access-groups"]
            ]
        entitlement_file = temp / "entitlements.plist"
        entitlement_file.write_bytes(plistlib.dumps(entitlements))
        keychain = str(temp / "signing.keychain-db")
        password = secrets.token_urlsafe(32)
        run("security", "create-keychain", "-p", password, keychain)
        try:
            run("security", "set-keychain-settings", "-lut", "21600", keychain)
            run("security", "unlock-keychain", "-p", password, keychain)
            run("security", "import", str(cert), "-k", keychain,
                "-P", os.environ.get("IOS_CERTIFICATE_PASSWORD", ""),
                "-T", "/usr/bin/codesign", "-T", "/usr/bin/security")
            run("security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:",
                "-s", "-k", password, keychain)
            identities = run("security", "find-identity", "-v", "-p", "codesigning", keychain).decode()
            allowed = {hashlib.sha1(c).hexdigest().upper() for c in data["DeveloperCertificates"]}
            matching = allowed.intersection(re.findall(r"\b[0-9A-F]{40}\b", identities))
            if not matching:
                raise ValueError("Imported certificate does not match the development profile")
            shutil.copyfile(profile, app / "embedded.mobileprovision")
            run("codesign", "--force", "--sign", sorted(matching)[0], "--keychain", keychain,
                "--entitlements", str(entitlement_file), "--generate-entitlement-der", str(app))
            run("codesign", "--verify", "--deep", "--strict", str(app))
            output = Path("build/artifacts/WindowsiOS-iPhone-Duo-development.ipa").resolve()
            subprocess.run(["/usr/bin/zip", "-qry", str(output), "Payload"],
                           cwd="build/ipa", check=True)
            Path("build/artifacts/WindowsiOS-iPhone-Duo-unsigned.ipa").unlink()
            print("Development IPA signed. Only devices registered in the profile can install it.")
        finally:
            run("security", "delete-keychain", keychain)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, RuntimeError) as error:
        raise SystemExit(str(error)) from None
