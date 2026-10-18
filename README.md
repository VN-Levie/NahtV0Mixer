# NahtV0Mixer

A native macOS menu-bar volume mixer. Adjust each application's volume directly from the macOS menu, with a workflow inspired by the Windows Volume Mixer.

**Early development — version 0.1.1.** [Download the latest release](https://github.com/VN-Levie/NahtV0Mixer/releases/latest).

## Requirements

- **macOS 14.4 or later**.
- System audio recording permission for per-app volume control.
- An output device using mono or stereo Float32 audio for per-app processing.

## Usage

1. Open NahtV0Mixer and click its menu-bar icon.
2. Play audio in an application to make it appear in the list.
3. Enable **Per-app mixer**, then adjust an application's slider. Mute and reset buttons sit beside each application's name.
4. Allow system audio recording access if macOS asks. Audio is processed locally; the app does not save recordings or upload audio.

- Per-app levels are remembered. Each launch starts with the mixer disabled; enable it to apply your saved levels.
- Use the **Output** submenu and system-volume controls to manage the current output device. Hardware controls are disabled when the device does not support them.
- Reset an application's volume to return it to its normal level. Disable the mixer to stop per-app processing.
- Settings include English/Vietnamese, system/light/dark appearance, and launch at login.
- Reopening the app uses the existing instance and keeps a single menu-bar icon.
- Quit the app before replacing or updating it.

## Current limitations

The initial version processes supported applications on the system output. It does not route each application to a separate device. Some helper processes may appear as separate applications.

The controlled audio fixture has passed on built-in MacBook Pro speakers on Apple Silicon. Bluetooth, HDMI, conferencing/duplex devices, Intel hardware, and device changes during playback still need compatibility testing. Device-failure recovery is under review; this is an experimental build.

Local builds are ad-hoc signed by default and are not Apple-notarized. This does not provide a Developer ID distribution signature.

## Build

Requires **Xcode 26 or later**, Swift 6, and the Icon Composer build tools. There are no external package dependencies.

```sh
swift test
./scripts/build-app.sh
open build/NahtV0Mixer.app
```

Use `./scripts/build-app.sh --universal` to build for Apple Silicon and Intel. `./scripts/package-release.sh` creates a ZIP and SHA-256 checksum. After quitting the app, `./scripts/install-local.sh` installs the built copy into Applications.

See the [development guide](docs/development.md) for signing, packaging, and the scope of audio verification.

## Credits and license

Thanks to the projects and documentation listed in [CREDITS.md](CREDITS.md). NahtV0Mixer is independently implemented: those references informed concepts and user experience; their source code and artwork were not copied into the app.

The N-speaker icon was created for NahtSoft with ImageGen and selected by the project owner. Its sources and prompts are documented in [Resources/Brand](Resources/Brand/README.md).

[MIT License](LICENSE).
