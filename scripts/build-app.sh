#!/bin/bash
set -euo pipefail

task_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$task_root"
build_args=(-c release)
case "${1:-}" in
    ""|--native) ;;
    --universal) build_args+=(--arch arm64 --arch x86_64) ;;
    -h|--help) printf 'Usage: %s [--native|--universal]\n' "$0"; exit 0 ;;
    *) printf 'Usage: %s [--native|--universal]\n' "$0" >&2; exit 2 ;;
esac
if [ "$#" -gt 1 ]; then
    printf '%s\n' 'Only one build mode is accepted.' >&2
    exit 2
fi

bundle="${NAHTV0MIXER_APP_OUTPUT:-$task_root/build/NahtV0Mixer.app}"
case "$bundle" in
    *.app) ;;
    *) printf '%s\n' 'NAHTV0MIXER_APP_OUTPUT must end in .app.' >&2; exit 2 ;;
esac
if [ -L "$bundle" ]; then
    printf '%s\n' 'Refusing to replace a symlinked app bundle.' >&2
    exit 2
fi
mkdir -p "$(dirname "$bundle")"
bundle="$(cd "$(dirname "$bundle")" && pwd -P)/$(basename "$bundle")"

ensure_not_running() {
    local process_paths
    process_paths="$(/bin/ps -ww -axo comm=)"
    if /usr/bin/grep -Fqx "$bundle/Contents/MacOS/NahtV0Mixer" <<< "$process_paths"; then
        printf '%s\n' 'The output app is running. Quit it or choose a different NAHTV0MIXER_APP_OUTPUT.' >&2
        exit 2
    fi
}
ensure_not_running
if [ -e "$bundle" ]; then
    old_identifier="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$bundle/Contents/Info.plist" 2>/dev/null || true)"
    if [ "$old_identifier" != 'com.levie.NahtV0Mixer' ]; then
        printf '%s\n' 'The output path contains another app or an unrecognized bundle; refusing to overwrite it.' >&2
        exit 2
    fi
fi

swift build "${build_args[@]}"
binary_dir="$(swift build "${build_args[@]}" --show-bin-path)"
staging_dir="$(mktemp -d "$(dirname "$bundle")/.nahtv0mixer-build.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT
staged_bundle="$staging_dir/$(basename "$bundle")"
mkdir -p "$staged_bundle/Contents/MacOS" "$staged_bundle/Contents/Resources"
cp "$binary_dir/NahtV0Mixer" "$staged_bundle/Contents/MacOS/NahtV0Mixer"
cp Resources/Info.plist "$staged_bundle/Contents/Info.plist"
cp LICENSE "$staged_bundle/Contents/Resources/LICENSE.txt"
cp CREDITS.md "$staged_bundle/Contents/Resources/CREDITS.md"
swift scripts/make-icon.swift "$staged_bundle/Contents/Resources/AppIcon.icns"

# SwiftPM resource bundles, when present, belong beside the executable's resources.
for resource_bundle in "$binary_dir"/NahtV0Mixer_*.bundle; do
    if [ -d "$resource_bundle" ]; then
        ditto "$resource_bundle" "$staged_bundle/Contents/Resources/$(basename "$resource_bundle")"
    fi
done

executable="$staged_bundle/Contents/MacOS/NahtV0Mixer"
if codesign -d "$executable" >/dev/null 2>&1; then
    codesign --remove-signature "$executable"
fi
xcrun strip -S "$executable"
if LC_ALL=C /usr/bin/grep -aEq '/Users/|/home/|/private/var/|/var/folders/' "$executable"; then
    printf '%s\n' 'The executable contains local build paths; refusing to package it.' >&2
    exit 2
fi
plutil -lint "$staged_bundle/Contents/Info.plist"
signing_identity="${NAHTV0MIXER_SIGN_IDENTITY:--}"
codesign --force --sign "$signing_identity" --identifier com.levie.NahtV0Mixer "$staged_bundle"
codesign --verify --deep --strict --all-architectures "$staged_bundle"

# Finish a successful staged build before replacing this project's old artifact.
ensure_not_running
if [ -e "$bundle" ]; then
    rm -rf "$bundle"
fi
mv "$staged_bundle" "$bundle"
touch "$bundle"
printf 'Built: %s\n' "$bundle"
if [ "$signing_identity" = '-' ]; then
    printf '%s\n' 'Signing: ad-hoc (not notarized).'
fi
