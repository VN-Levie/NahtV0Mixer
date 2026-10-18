#!/bin/bash
set -euo pipefail

if [ "$#" -ne 0 ]; then
    printf 'Usage: %s\n' "$0" >&2
    exit 2
fi
task_root="$(cd "$(dirname "$0")/.." && pwd)"
bundle="${NAHTV0MIXER_APP_OUTPUT:-$task_root/build/NahtV0Mixer.app}"
destination='/Applications/NahtV0Mixer.app'
if [ ! -d "$bundle" ] || [ -L "$bundle" ] || [ -L "$destination" ]; then
    printf '%s\n' 'Build the application first; source and destination must not be symlinks.' >&2
    exit 2
fi
bundle="$(cd "$(dirname "$bundle")" && pwd -P)/$(basename "$bundle")"
if [ "$bundle" = "$destination" ]; then
    printf '%s\n' 'Source and destination are the same app.' >&2
    exit 2
fi
ensure_not_running() {
    local candidate process_paths
    process_paths="$(/bin/ps -ww -axo comm=)"
    for candidate in "$bundle" "$destination"; do
        if /usr/bin/grep -Fqx "$candidate/Contents/MacOS/NahtV0Mixer" <<< "$process_paths"; then
            printf '%s\n' 'Quit NahtV0Mixer from its menu bar before installing. No process has been stopped.' >&2
            exit 2
        fi
    done
}
ensure_not_running
identifier="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$bundle/Contents/Info.plist")"
if [ "$identifier" != 'com.levie.NahtV0Mixer' ]; then
    printf '%s\n' 'The source is not a NahtV0Mixer app bundle.' >&2
    exit 2
fi
if [ -e "$destination" ]; then
    old_identifier="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$destination/Contents/Info.plist" 2>/dev/null || true)"
    if [ "$old_identifier" != "$identifier" ]; then
        printf '%s\n' 'The destination contains another app; refusing to overwrite it.' >&2
        exit 2
    fi
fi
codesign --verify --deep --strict --all-architectures "$bundle"
stage="$(mktemp -d '/Applications/.nahtv0mixer-install.XXXXXX')"
trap 'rm -rf "$stage"' EXIT
ditto "$bundle" "$stage/NahtV0Mixer.app"
codesign --verify --deep --strict --all-architectures "$stage/NahtV0Mixer.app"
ensure_not_running
if [ -e "$destination" ]; then
    rm -rf "$destination"
fi
mv "$stage/NahtV0Mixer.app" "$destination"
touch "$destination"
codesign --verify --deep --strict --all-architectures "$destination"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$destination"
mdimport -i "$destination"
printf 'Installed: %s\n' "$destination"
