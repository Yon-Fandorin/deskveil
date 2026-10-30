#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
# Lock before any compiler/cache access, and keep the inherited descriptor through
# the complete build. Never remove this persistent lock while builds are running.
mkdir -p .build
exec python3 Tools/Distribution/release-guard.py run-locked .build/.softlock-build.lock /bin/zsh -s -- "$@" <<'LOCKED_BUILD'
set -euo pipefail
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-cache"
app_dir="${SOFTLOCK_APP_PATH:-$PWD/dist/DeskVeil.app}"
# Keep the final path component intact so a symlink destination is rejected.
app_dir="${app_dir:a}"
app_dir="${app_dir:h:A}/${app_dir:t}"
python3 Tools/Distribution/release-guard.py validate-app-path "$app_dir"
ensure_app_stopped() {
    swift -module-cache-path "$CLANG_MODULE_CACHE_PATH" - "$app_dir" <<'SWIFT'
import Darwin
import Foundation

let target = URL(fileURLWithPath: CommandLine.arguments[1])
    .appendingPathComponent("Contents/MacOS/SoftLock").resolvingSymlinksInPath().path
let required = proc_listallpids(nil, 0)
guard required > 0 else {
    fputs("Cannot check running processes; app was not replaced.\n", stderr); exit(1)
}
var pids = [pid_t](repeating: 0, count: Int(required) + 1024)
let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
guard count > 0, count < pids.count else {
    fputs("Cannot check running processes; app was not replaced.\n", stderr); exit(1)
}
for pid in pids.prefix(Int(count)) where pid > 0 {
    var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { continue }
    if URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath().path == target {
        fputs("SoftLock or its screen helper is running (PID \(pid)). Quit it before rebuilding this app, or set SOFTLOCK_APP_PATH to another location.\n", stderr)
        exit(1)
    }
}
SWIFT
}
ensure_app_stopped
bundle_id="${SOFTLOCK_BUNDLE_ID:-dev.local.softlock}"
signing_identity="${SOFTLOCK_SIGNING_IDENTITY:-$(zsh Tools/local-signing-identity.sh)}"
if [[ "$signing_identity" == "-" && "$bundle_id" == "dev.local.softlock" && "${SOFTLOCK_ALLOW_UNSTABLE_SIGNING:-0}" != "1" ]]; then
    print -u2 "Refusing an ad-hoc SoftLock update: it invalidates Accessibility and helper approval on every rebuild. Use the existing signing identity, or use a separate SOFTLOCK_BUNDLE_ID for a preview. Intentional ad-hoc builds require SOFTLOCK_ALLOW_UNSTABLE_SIGNING=1."
    exit 1
fi
swift build -c release --disable-sandbox
# App-only releases can retain the already-approved power helper. The complete
# staged release is still checked against the pinned helper hash before publication.
reuse_helper="${SOFTLOCK_POWER_HELPER_PATH:-}"
if [[ -z "$reuse_helper" ]]; then
    swiftc -O -target "$(/usr/bin/uname -m)-apple-macosx13.0" \
        -module-name SoftLockPower -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
        Sources/Localization.swift Sources/LidPower.swift Sources/LidService.swift Sources/KeepAwake.swift Sources/LidDuration.swift \
        Tools/PowerService/main.swift -o .build/release/SoftLockPower
else
    codesign --verify --strict "$reuse_helper"
fi
mkdir -p "${app_dir:h}"
staging_root="$(mktemp -d "${app_dir:h}/.softlock-build.XXXXXX")"
staged_app="$staging_root/staged.app"
previous_app="$staging_root/previous.app"
cleanup() {
    if [[ -e "$previous_app" || -L "$previous_app" ]]; then
        print -u2 "Original app preserved at $previous_app; staging directory retained."
        return 1
    fi
    rm -rf "$staging_root"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
mkdir -p "$staged_app/Contents/MacOS"
mkdir -p "$staged_app/Contents/Resources"
cp .build/release/SoftLock "$staged_app/Contents/MacOS/SoftLock"
cp Info.plist "$staged_app/Contents/Info.plist"
cp -R Sources/Resources/en.lproj Sources/Resources/ko.lproj "$staged_app/Contents/Resources/"
zsh Tools/Distribution/make-icon.sh "$staging_root/SoftLock.iconset" "$staged_app/Contents/Resources/SoftLock.icns"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_id" "$staged_app/Contents/Info.plist"
helper_app="$staged_app/Contents/Helpers/SoftLockPower.app"
mkdir -p "${helper_app:h}"
if [[ -n "$reuse_helper" ]]; then
    cp -R "$reuse_helper" "$helper_app"
else
    mkdir -p "$helper_app/Contents/MacOS"
    cp .build/release/SoftLockPower "$helper_app/Contents/MacOS/SoftLock"
    cp Tools/PowerService/Info.plist "$helper_app/Contents/Info.plist"
    mkdir -p "$helper_app/Contents/Resources"
    cp -R Sources/Resources/en.lproj Sources/Resources/ko.lproj "$helper_app/Contents/Resources/"
    codesign --force --sign "$signing_identity" --timestamp=none --identifier dev.local.softlock.power "$helper_app"
fi
codesign --force --sign "$signing_identity" --timestamp=none --identifier "$bundle_id" "$staged_app"
codesign --verify --strict --deep "$staged_app"
python3 Tools/Distribution/release-guard.py snapshot-app "$app_dir" > "$staging_root/destination.json"
if [[ "$bundle_id" == "dev.local.softlock" || "$app_dir" == "$PWD/dist/DeskVeil.app" ||
      "$app_dir" == "/Applications/SoftLock.app" || "$app_dir" == "$HOME/Applications/SoftLock.app" ||
      ( -e "$app_dir/Contents/Info.plist" && "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_dir/Contents/Info.plist")" == "dev.local.softlock" ) ]]; then
    python3 Tools/Distribution/release-guard.py check "$staged_app" --previous "$app_dir" >/dev/null
fi
ensure_app_stopped
python3 Tools/Distribution/release-guard.py publish-app "$staged_app" "$app_dir" \
    --expected-output "$staging_root/destination.json" --backup "$previous_app"
print "Built $app_dir"
LOCKED_BUILD
