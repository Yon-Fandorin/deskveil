#!/usr/bin/env python3
"""Check native signature continuity and impersonation rejection, without root/power changes."""
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / "dist/DeskVeil.app").resolve()


def run(*arguments):
    return subprocess.check_output([str(value) for value in arguments], text=True)


def plan(bundle):
    return json.loads(run(bundle / "Contents/MacOS/SoftLock", "--lid-install-plan"))


def sign(path, identity, identifier="dev.local.softlock"):
    run("/usr/bin/codesign", "--force", "--sign", identity, "--timestamp=none", "--identifier", identifier, path)


original = plan(BUNDLE)
resources = plistlib.loads((BUNDLE / "Contents/_CodeSignature/CodeResources").read_bytes())
nested = resources["files2"]["Helpers/SoftLockPower.app"]
assert nested["cdhash"].hex() == original["helperHash"], "Helper must be sealed as nested code"
match = re.search(r'certificate leaf = H"([a-f0-9]{40})"', original["clientRequirement"])
if not match:
    raise SystemExit("This test requires a certificate-signed build, not an explicit ad-hoc build.")
signer = match[1]
with tempfile.TemporaryDirectory(prefix="softlock-identity-", dir="/private/tmp") as directory:
    temporary = Path(directory)
    updated = temporary / "Updated.app"
    shutil.copytree(BUNDLE, updated)
    info_path = updated / "Contents/Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    info["CFBundleVersion"] = "9999"
    info["CFBundleShortVersionString"] = "99.0"
    info_path.write_bytes(plistlib.dumps(info))
    sign(updated, signer)
    update = plan(updated)
    assert update["clientHash"] != original["clientHash"], "Fixture did not change the app's CDHash"
    assert update["clientRequirement"] == original["clientRequirement"]
    assert update["helperHash"] == original["helperHash"]
    print("PASS app version/CDHash changes preserve helper approval identity")
    sign(updated / "Contents/Helpers/SoftLockPower.app", "-", "dev.local.softlock.power")
    tampered = subprocess.run([str(updated / "Contents/MacOS/SoftLock"), "--lid-install-plan"],
                              capture_output=True, text=True)
    assert tampered.returncode != 0, "Replaced helper escaped the app's nested signature verification"
    print("PASS replacing the bundled helper invalidates the signed installation envelope")

    # Compile the production verifier, and execute real signed peers. No mock of
    # SecCode, certificate extraction, UID checking or requirement evaluation.
    source = temporary / "main.swift"
    source.write_text('''import Darwin
import Foundation
let own = CommandLine.arguments[0]
let expected = CommandLine.arguments[1]
let result: [String: Any] = [
    "hash": try lidSignature(own),
    "requirement": try lidClientRequirement(own),
    "allowed": lidPeerIsAllowed(getpid(), uid: getuid(), configuration:
        ["uid": getuid(), "clientRequirement": expected]),
    "wrongUID": lidPeerIsAllowed(getpid(), uid: getuid(), configuration:
        ["uid": getuid() + 1, "clientRequirement": expected])]
print(String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self))
''')
    probe = temporary / "peer"
    run("/usr/bin/swiftc", "-O", "-module-cache-path", ROOT / ".build/clang-cache",
        ROOT / "Sources/Localization.swift", ROOT / "Sources/LidPower.swift", source, "-o", probe)
    for identity, identifier, allowed in [
        (signer, "dev.local.softlock", True),
        ("-", "dev.local.softlock", False),
        (signer, "dev.local.softlock.impostor", False),
    ]:
        sign(probe, identity, identifier)
        result = json.loads(run(probe, original["clientRequirement"]))
        assert result["allowed"] is allowed, (identity, identifier, result)
        assert result["wrongUID"] is False
    print("PASS native peers: same signer/identifier accepted; unsigned namesake, other identifier and UID rejected")
