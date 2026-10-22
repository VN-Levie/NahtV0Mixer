#!/bin/bash
set -euo pipefail

task_root="$(cd "$(dirname "$0")/.." && pwd)"
mode=auto
widget=0
usage() {
    printf 'Usage: %s [--native|--universal] [--widget]\n' "$0"
}
fail() {
    printf '%s\n' "$1" >&2
    exit 2
}
while [ "$#" -gt 0 ]; do
    case "$1" in
        --native|--universal)
            [ "$mode" = auto ] || fail 'Only one package architecture is accepted.'
            mode="$1" ;;
        --widget)
            [ "$widget" -eq 0 ] || fail 'Only one --widget flag is accepted.'
            widget=1 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
    shift
done

default_bundle="$task_root/build/NahtV0Mixer.app"
if [ "$widget" -eq 1 ]; then
    default_bundle="$task_root/build/widget/NahtV0Mixer.app"
fi
bundle="${NAHTV0MIXER_APP_OUTPUT:-$default_bundle}"
if [ ! -d "$bundle" ]; then
    fail 'Build the application first (use scripts/build-widget-app.sh for --widget).'
fi
bundle="$(cd "$(dirname "$bundle")" && pwd -P)/$(basename "$bundle")"
source_info="$task_root/Resources/Info.plist"
widget_source_info="$task_root/Resources/WidgetInfo.plist"
mkdir -p "$task_root/dist"
stage="$(mktemp -d "$task_root/dist/.package.XXXXXX")"
trap 'rm -rf "$stage"' EXIT

validate_component() {
    local candidate="$1"
    local source="$2"
    local identifier="$3"
    local executable_name="$4"
    local package_type="$5"
    local info="$candidate/Contents/Info.plist"
    local executable="$candidate/Contents/MacOS/$executable_name"
    local key expected actual arch minimums minimum
    [ -f "$info" ] && [ -f "$executable" ] || fail 'The bundle is missing an expected plist or executable.'
    plutil -lint "$info" >/dev/null
    for key in CFBundleShortVersionString CFBundleVersion LSMinimumSystemVersion; do
        expected="$(/usr/libexec/PlistBuddy -c "Print $key" "$source")"
        actual="$(/usr/libexec/PlistBuddy -c "Print $key" "$info")"
        if [ "$actual" != "$expected" ]; then
            printf 'Bundle metadata does not match source: %s\n' "$key" >&2
            return 2
        fi
    done
    [ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$info")" = "$identifier" ] || fail 'Unexpected bundle identifier.'
    [ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$info")" = "$executable_name" ] || fail 'Unexpected bundle executable.'
    [ "$(/usr/libexec/PlistBuddy -c 'Print CFBundlePackageType' "$info")" = "$package_type" ] || fail 'Unexpected bundle package type.'
    [ "$(/usr/libexec/PlistBuddy -c 'Print LSMinimumSystemVersion' "$info")" = '14.4' ] || fail 'The bundle must target macOS 14.4.'
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

validate_widget_signing() {
    local candidate="$1"
    local group="$2"
    local executable_name="$3"
    local arch signing_details team entitlements actual_group extra_group debug_allowed signed_team
    for arch in $(lipo -archs "$candidate/Contents/MacOS/$executable_name"); do
        signing_details="$(codesign --display --verbose=4 --arch "$arch" "$candidate" 2>&1)"
        team="$(printf '%s\n' "$signing_details" | sed -n 's/^TeamIdentifier=//p')"
        [[ "$team" =~ ^[A-Z0-9]{10}$ ]] || fail 'The widget release requires a real signing team for both components.'
        [ "$group" = "$team.vn.levie.NahtV0Mixer" ] || fail 'The App Group does not match the signing team.'
        entitlements="$stage/entitlements.plist"
        codesign --display --entitlements :- --arch "$arch" "$candidate" > "$entitlements" 2>/dev/null
        plutil -lint "$entitlements" >/dev/null
        actual_group="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups:0' "$entitlements" 2>/dev/null || true)"
        extra_group="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups:1' "$entitlements" 2>/dev/null || true)"
        [ "$actual_group" = "$group" ] && [ -z "$extra_group" ] || fail 'Signed App Group entitlements do not match the bundle configuration.'
        signed_team="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.team-identifier' "$entitlements" 2>/dev/null || true)"
        if [ -n "$signed_team" ] && [ "$signed_team" != "$team" ]; then
            fail 'The team entitlement does not match the signing team.'
        fi
        debug_allowed="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.get-task-allow' "$entitlements" 2>/dev/null || true)"
        [ -z "$debug_allowed" ] || [ "$debug_allowed" = false ] || fail 'Release entitlements must not enable get-task-allow.'
        debug_allowed="$(/usr/libexec/PlistBuddy -c 'Print :get-task-allow' "$entitlements" 2>/dev/null || true)"
        [ -z "$debug_allowed" ] || [ "$debug_allowed" = false ] || fail 'Release entitlements must not enable get-task-allow.'
        if [ "$executable_name" = NahtV0MixerWidget ]; then
            [ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$entitlements" 2>/dev/null || true)" = true ] || fail 'The widget extension must be sandboxed.'
        fi
    done
}

validate_bundle() {
    local candidate="$1"
    local extension="$candidate/Contents/PlugIns/NahtV0MixerWidget.appex"
    local host_info="$candidate/Contents/Info.plist"
    local extension_info="$extension/Contents/Info.plist"
    local key host_value extension_value group host_arch extension_arch plugin
    validate_component "$candidate" "$source_info" vn.levie.NahtV0Mixer NahtV0Mixer APPL
    if [ "$widget" -eq 0 ]; then
        for plugin in "$candidate/Contents/PlugIns"/*.appex; do
            [ ! -e "$plugin" ] || fail 'An embedded extension requires the explicit --widget package mode.'
        done
        return
    fi
    [ -d "$extension" ] || fail '--widget requires the embedded NahtV0MixerWidget extension.'
    validate_component "$extension" "$widget_source_info" vn.levie.NahtV0Mixer.Widget NahtV0MixerWidget 'XPC!'
    [ "$(/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionPointIdentifier' "$extension_info")" = com.apple.widgetkit-extension ] || fail 'The extension is not a WidgetKit extension.'
    for key in CFBundleShortVersionString CFBundleVersion; do
        host_value="$(/usr/libexec/PlistBuddy -c "Print $key" "$host_info")"
        extension_value="$(/usr/libexec/PlistBuddy -c "Print $key" "$extension_info")"
        [ "$host_value" = "$extension_value" ] || fail 'Host and widget versions must match.'
    done
    host_arch="$(lipo -archs "$candidate/Contents/MacOS/NahtV0Mixer" | tr ' ' '\n' | sort)"
    extension_arch="$(lipo -archs "$extension/Contents/MacOS/NahtV0MixerWidget" | tr ' ' '\n' | sort)"
    [ "$host_arch" = "$extension_arch" ] || fail 'Host and widget architectures must match.'
    group="$(/usr/libexec/PlistBuddy -c 'Print NahtV0MixerAppGroup' "$host_info" 2>/dev/null || true)"
    [[ "$group" =~ ^[A-Z0-9]{10}\.vn\.levie\.NahtV0Mixer$ ]] || fail 'The host App Group must be a resolved team-qualified group.'
    extension_value="$(/usr/libexec/PlistBuddy -c 'Print NahtV0MixerAppGroup' "$extension_info" 2>/dev/null || true)"
    [ "$group" = "$extension_value" ] || fail 'Host and widget App Group configuration must match.'
    validate_widget_signing "$candidate" "$group" NahtV0Mixer
    validate_widget_signing "$extension" "$group" NahtV0MixerWidget
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
archive="NahtV0Mixer-${version}-macOS-${architecture}.zip"
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
