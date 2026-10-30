#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
# Share the builders' persistent lock before venv installation or compiler/cache
# access. Keep its inherited descriptor until packaging is completely finished.
mkdir -p .build
exec python3 Tools/Distribution/release-guard.py run-locked .build/.softlock-build.lock /bin/zsh -s -- "$@" <<'LOCKED_PACKAGE'
set -euo pipefail
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-cache"
app_dir="${SOFTLOCK_APP_PATH:-$PWD/dist/DeskVeil.app}"
app_dir="${app_dir:A}"
[[ -d "$app_dir" ]] || { print -u2 "Build DeskVeil.app first with zsh build.sh"; exit 1; }
python3 Tools/Distribution/release-guard.py check "$app_dir" >/dev/null
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_dir/Contents/Info.plist")"
architecture="$(lipo -archs "$app_dir/Contents/MacOS/SoftLock")"
[[ "$architecture" == "arm64" || "$architecture" == "x86_64" ]] || {
    print -u2 "Unsupported packaging architecture: $architecture"; exit 1
}
output="${SOFTLOCK_DMG_PATH:-$PWD/dist/DeskVeil-$version-macOS-$architecture.dmg}"
# Resolve parent aliases while retaining a final symlink for the guard to reject.
output="${output:a}"
output="${output:h:A}/${output:t}"
[[ "$output" != "$app_dir" && "$output" != "$app_dir/"* ]] || {
    print -u2 "The disk image output must be outside the source app."; exit 1
}
[[ -f "$app_dir/Contents/Resources/SoftLock.icns" ]] || { print -u2 "Rebuild the app to include its Finder icon."; exit 1; }
mkdir -p "${output:h}" .build
staging="$(mktemp -d "${output:h}/.softlock-dmg.XXXXXX")"
verification_mount="$staging/verify"
mounted=0
cleanup() {
    if (( mounted )); then
        if ! hdiutil detach "$verification_mount" >/dev/null; then
            print -u2 "Verification image is still mounted; kept $staging"
            return 1
        fi
    fi
    rm -rf "$staging"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
python3 Tools/Distribution/release-guard.py check-output "$output" > "$staging/output-before.json"
# Freeze one verified release instead of reading a mutable build output while
# generating the image. The mounted payload must match this complete manifest.
python3 Tools/Distribution/release-guard.py check "$app_dir" > "$staging/release.json"
mkdir -p "$staging/source"
packaged_app="$staging/source/${app_dir:t}"
ditto "$app_dir" "$packaged_app"
python3 Tools/Distribution/release-guard.py check "$packaged_app" --expected-manifest "$staging/release.json" >/dev/null
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$packaged_app/Contents/Info.plist")" == "$version" &&
   "$(lipo -archs "$packaged_app/Contents/MacOS/SoftLock")" == "$architecture" ]] || {
    print -u2 "Source version or architecture changed during packaging; retry with a stable build."; exit 1
}
if [[ ! -x .build/dmg-tools/bin/dmgbuild ]]; then
    python3 -m venv .build/dmg-tools
    .build/dmg-tools/bin/python -m pip install --disable-pip-version-check 'dmgbuild==1.6.7'
fi
swift Tools/Distribution/artwork.swift background "$staging/background.png" "$version" "$architecture"
.build/dmg-tools/bin/dmgbuild -s Tools/Distribution/dmg-settings.py \
    -D "app=$packaged_app" -D "background=$staging/background.png" \
    "DeskVeil 설치" "$staging/SoftLock.dmg"
hdiutil verify "$staging/SoftLock.dmg"
mkdir -p "$verification_mount"
hdiutil attach -readonly -nobrowse -mountpoint "$verification_mount" "$staging/SoftLock.dmg" >/dev/null
mounted=1
python3 Tools/Distribution/release-guard.py check "$verification_mount/${app_dir:t}" --expected-manifest "$staging/release.json" >/dev/null
[[ "$(readlink "$verification_mount/응용 프로그램")" == "/Applications" ]] || {
    print -u2 "Invalid Applications shortcut in disk image"; exit 1
}
hdiutil detach "$verification_mount" >/dev/null
mounted=0
python3 Tools/Distribution/release-guard.py publish "$staging/SoftLock.dmg" "$output" --expected-output "$staging/output-before.json"
print "Packaged $output"
LOCKED_PACKAGE
