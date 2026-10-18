#!/bin/bash
set -euo pipefail

task_root="$(cd "$(dirname "$0")/.." && pwd)"
mode="${1:-auto}"
case "$mode" in
    auto|--native|--universal) ;;
    -h|--help) printf 'Usage: %s [--native|--universal]\n' "$0"; exit 0 ;;
    *) printf 'Usage: %s [--native|--universal]\n' "$0" >&2; exit 2 ;;
esac
if [ "$#" -gt 1 ]; then
    printf '%s\n' 'Only one package mode is accepted.' >&2
    exit 2
fi

bundle="${NAHTV0MIXER_APP_OUTPUT:-$task_root/build/NahtV0Mixer.app}"
if [ ! -d "$bundle" ]; then
    printf '%s\n' 'Build the application with scripts/build-app.sh first.' >&2
    exit 2
fi
bundle="$(cd "$(dirname "$bundle")" && pwd -P)/$(basename "$bundle")"
source_info="$task_root/Resources/Info.plist"

validate_bundle() {
    local candidate="$1"
    local info="$candidate/Contents/Info.plist"
    local executable="$candidate/Contents/MacOS/NahtV0Mixer"
    local key expected actual arch minimums minimum
    plutil -lint "$info" >/dev/null
    for key in CFBundleIdentifier CFBundleExecutable CFBundleShortVersionString CFBundleVersion LSMinimumSystemVersion; do
        expected="$(/usr/libexec/PlistBuddy -c "Print $key" "$source_info")"
        actual="$(/usr/libexec/PlistBuddy -c "Print $key" "$info")"
        if [ "$actual" != "$expected" ]; then
            printf 'Bundle metadata does not match source: %s\n' "$key" >&2
            return 2
        fi
    done
    arch="$(lipo -archs "$executable")"
    case "$arch" in
        'arm64 x86_64'|'x86_64 arm64') ;;
        arm64|x86_64) ;;
        *) printf 'Unexpected architectures: %s\n' "$arch" >&2; return 2 ;;
    esac
    case "$mode" in
        --universal)
            if [ "$arch" != 'arm64 x86_64' ] && [ "$arch" != 'x86_64 arm64' ]; then
                printf '%s\n' 'A universal release requires arm64 and x86_64.' >&2
                return 2
            fi ;;
        --native)
            if [ "$arch" != "$(uname -m)" ]; then
                printf '%s\n' 'The bundle does not match the native architecture.' >&2
                return 2
            fi ;;
    esac
    minimums="$(xcrun vtool -show-build "$executable" | awk '$1 == "minos" {print $2}')"
    if [ -z "$minimums" ]; then
        printf '%s\n' 'Could not verify the Mach-O deployment target.' >&2
        return 2
    fi
    while IFS= read -r minimum; do
        if [ "$minimum" != '14.4' ] && [ "$minimum" != '14.4.0' ]; then
            printf 'Unexpected Mach-O minimum macOS: %s\n' "$minimum" >&2
            return 2
        fi
    done <<< "$minimums"
    if LC_ALL=C /usr/bin/grep -aEq '/Users/|/home/|/private/var/|/var/folders/' "$executable"; then
        printf '%s\n' 'The executable contains local build paths; rebuild before packaging.' >&2
        return 2
    fi
    codesign --verify --deep --strict --all-architectures "$candidate"
}

validate_bundle "$bundle"
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$source_info")"
if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf '%s\n' 'Release version must have the form major.minor.patch.' >&2
    exit 2
fi
architecture="$(lipo -archs "$bundle/Contents/MacOS/NahtV0Mixer")"
case "$architecture" in
    'arm64 x86_64'|'x86_64 arm64') architecture=universal ;;
esac
mkdir -p "$task_root/dist"
archive="NahtV0Mixer-${version}-macOS-${architecture}.zip"
stage="$(mktemp -d "$task_root/dist/.package.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
ditto -c -k --norsrc --noqtn --keepParent "$bundle" "$stage/$archive"
mkdir "$stage/check"
ditto -x -k "$stage/$archive" "$stage/check"
validate_bundle "$stage/check/$(basename "$bundle")"
(
    cd "$stage"
    shasum -a 256 "$archive" > "$archive.sha256"
    shasum -a 256 -c "$archive.sha256"
)
mv "$stage/$archive" "$task_root/dist/$archive"
mv "$stage/$archive.sha256" "$task_root/dist/$archive.sha256"
printf '%s\n' "$task_root/dist/$archive" "$task_root/dist/$archive.sha256"
