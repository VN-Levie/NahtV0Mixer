#!/bin/bash
set -euo pipefail

task_root="$(cd "$(dirname "$0")/.." && pwd)"
project="$task_root/NahtV0Mixer.xcodeproj"
derived_data="$task_root/.build/widget-xcode"
configuration=Release
architecture=""
unsigned=0

usage() {
	printf '%s\n' "Usage: $0 [--native|--universal] [--unsigned]"
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--native) architecture="native" ;;
		--universal) architecture="universal" ;;
		--unsigned) unsigned=1 ;;
		-h|--help) usage; exit 0 ;;
		*) usage >&2; exit 2 ;;
	esac
	shift
done

if [ ! -d "$project" ]; then
	printf '%s\n' "Missing Xcode project: $project" >&2
	exit 2
fi

default_output="$task_root/build/widget/NahtV0Mixer.app"
if [ "$unsigned" -eq 1 ]; then
	default_output="$task_root/build/widget-unsigned/NahtV0Mixer.app"
fi
output="${NAHTV0MIXER_APP_OUTPUT:-$default_output}"
case "$output" in
	*.app) ;;
	*) printf '%s\n' 'NAHTV0MIXER_APP_OUTPUT must end in .app.' >&2; exit 2 ;;
esac
if [ -L "$output" ]; then
	printf '%s\n' 'Refusing to replace a symlinked app bundle.' >&2
	exit 2
fi
mkdir -p "$(dirname "$output")"
output="$(cd "$(dirname "$output")" && pwd -P)/$(basename "$output")"

running_path="$output/Contents/MacOS/NahtV0Mixer"
if /bin/ps -ww -axo comm= | /usr/bin/grep -Fqx "$running_path"; then
	printf '%s\n' 'The output app is running. Quit it or choose a different NAHTV0MIXER_APP_OUTPUT.' >&2
	exit 2
fi
if [ -e "$output" ]; then
	old_identifier="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$output/Contents/Info.plist" 2>/dev/null || true)"
	if [ "$old_identifier" != 'vn.levie.NahtV0Mixer' ]; then
		printf '%s\n' 'The output path contains another app or an unrecognized bundle; refusing to overwrite it.' >&2
		exit 2
	fi
fi

local_config="$task_root/config/WidgetSigning.local.xcconfig"
development_team="${DEVELOPMENT_TEAM:-}"
if [ -z "$development_team" ] && [ -f "$local_config" ]; then
	development_team="$(sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*//p' "$local_config" | tail -n 1 | tr -d '[:space:]')"
fi
if [ "$unsigned" -eq 0 ] && [ -z "$development_team" ]; then
	printf '%s\n' 'A real DEVELOPMENT_TEAM is required for the signed build.' >&2
	printf '%s\n' 'Copy config/WidgetSigning.example.xcconfig to config/WidgetSigning.local.xcconfig, set your Personal Team ID, and select it in Xcode.' >&2
	printf '%s\n' 'For structural compile validation only, rerun with --unsigned.' >&2
	exit 2
fi

# Use the shared native-app scheme; the package also exposes a same-named
# NahtV0Mixer product scheme that does not build the host bundle or extension.
xcode_args=(-project "$project" -scheme NahtV0MixerWidgetApp -configuration "$configuration" -derivedDataPath "$derived_data" -destination 'platform=macOS'
	DEBUG_INFORMATION_FORMAT=dwarf-with-dsym
	SWIFT_SERIALIZE_DEBUGGING_OPTIONS=NO
	STRIP_INSTALLED_PRODUCT=YES
	ENABLE_DEBUG_DYLIB=NO
	DEPLOYMENT_POSTPROCESSING=YES)
if [ -f "$local_config" ]; then
	xcode_args+=(-xcconfig "$local_config")
elif [ -n "$development_team" ]; then
	xcode_args+=(DEVELOPMENT_TEAM="$development_team" NAHTV0MIXER_APP_GROUP="$development_team.vn.levie.NahtV0Mixer")
fi
if [ "$architecture" = "native" ]; then
	xcode_args+=(ARCHS="$(uname -m)" ONLY_ACTIVE_ARCH=YES)
elif [ "$architecture" = "universal" ]; then
	xcode_args+=(ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO)
fi
if [ "$unsigned" -eq 1 ]; then
	xcode_args+=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=)
elif [ -n "${NAHTV0MIXER_SIGN_IDENTITY:-}" ]; then
	# Let Xcode sign the stripped host and extension with their own entitlements.
	# Re-signing the finished bundle here would risk replacing those entitlements.
	xcode_args+=(CODE_SIGN_IDENTITY="$NAHTV0MIXER_SIGN_IDENTITY")
fi

xcodebuild "${xcode_args[@]}" build
built_app="$derived_data/Build/Products/$configuration/NahtV0Mixer.app"
if [ ! -d "$built_app" ]; then
	printf '%s\n' "Xcode did not produce the expected app: $built_app" >&2
	exit 2
fi

# A successful package-product build can leave an old native app in Products.
# Reject stale or incomplete host/widget output before copying it to staging.
built_widget="$built_app/Contents/PlugIns/NahtV0MixerWidget.appex"
for key in CFBundleShortVersionString CFBundleVersion; do
	source_version="$(/usr/libexec/PlistBuddy -c "Print $key" "$task_root/Resources/Info.plist")"
	widget_source_version="$(/usr/libexec/PlistBuddy -c "Print $key" "$task_root/Resources/WidgetInfo.plist")"
	host_version="$(/usr/libexec/PlistBuddy -c "Print $key" "$built_app/Contents/Info.plist" 2>/dev/null || true)"
	widget_version="$(/usr/libexec/PlistBuddy -c "Print $key" "$built_widget/Contents/Info.plist" 2>/dev/null || true)"
	if [ -z "$source_version" ] || [ "$source_version" != "$widget_source_version" ] || \
		[ "$host_version" != "$source_version" ] || [ "$widget_version" != "$source_version" ]; then
		printf 'Host/widget build metadata is missing, stale or inconsistent with source: %s\n' "$key" >&2
		exit 2
	fi
done

staging_dir="$(mktemp -d "$(dirname "$output")/.nahtv0mixer-widget-build.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT
staged_app="$staging_dir/$(basename "$output")"
ditto "$built_app" "$staged_app"

# Release binaries must not retain developer-machine paths. Scan the host and
# extension executables after staging, before any output bundle is replaced.
privacy_failed=0
for executable in "$staged_app/Contents/MacOS/NahtV0Mixer" "$staged_app/Contents/PlugIns/NahtV0MixerWidget.appex/Contents/MacOS/NahtV0MixerWidget"; do
	if [ ! -f "$executable" ]; then
		printf 'Missing expected executable: %s\n' "$executable" >&2
		privacy_failed=1
		continue
	fi
	if LC_ALL=C /usr/bin/grep -aEq '/Users/|/home/|/private/var/|/var/folders/' "$executable"; then
		printf 'The executable contains local build paths; refusing to package it: %s\n' "$executable" >&2
		privacy_failed=1
	fi
done
if [ "$privacy_failed" -ne 0 ]; then
	exit 2
fi

if [ "$unsigned" -eq 1 ]; then
	printf '%s\n' 'Unsigned structural build; App Group authorization and signed widget registration are not verified.'
else
	codesign --verify --deep --strict --all-architectures "$staged_app"
	codesign --verify --deep --strict --all-architectures "$staged_app/Contents/PlugIns/NahtV0MixerWidget.appex"
fi

# Recheck after the build and immediately before replacement.
if /bin/ps -ww -axo comm= | /usr/bin/grep -Fqx "$running_path"; then
	printf '%s\n' 'The output app started running during the build. Refusing to replace it.' >&2
	exit 2
fi
if [ -e "$output" ]; then
	rm -rf "$output"
fi
mv "$staged_app" "$output"
touch "$output"
printf 'Built: %s\n' "$output"
