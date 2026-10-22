# NahtV0Mixer working agreements

## Product and ownership

- Native macOS menu-bar mixer, Swift/SwiftUI/AppKit with public Core Audio APIs; macOS 14.4 or later. Keep one audio-owning app process and one menu-bar item; the WidgetKit extension only exchanges state and commands.
- Prefer the Control Center style using native macOS popover materials and standard controls. Keep panels compact and sized to their content; avoid bespoke backgrounds, shadows and oversized fixed layouts. Do not use private Control Center APIs.
- This repository is public at the user's request. Do not publish a release or change repository visibility without an explicit user request. A push is not authorization to publish a release or change repository visibility.
- Learn from external projects; implement independently. Do not transplant source, binaries, icons or other assets. Record meaningful conceptual references in `CREDITS.md` with links and what was learned. Reassess licensing before adding any dependency.
- Preserve unrelated work. Do not create branches, worktrees, PRs or extra preview copies just to organize ordinary changes. Commit only scoped paths when authorized; use `type(scope): summary` subjects.

## Audio safety and permissions

- A fresh installation starts with the mixer disabled. Remember the user's explicit mixer on/off choice and restore it on subsequent launches and updates (user instruction, 2026-10-18). Opening a never-enabled app or merely adding a widget must not start capture; only the main app owns audio routing.
- Use public APIs. Do not query private TCC databases/APIs, read another app's session data, or assume permission is granted because status is unknown.
- No audio recordings, telemetry, analytics, network upload or microphone capture. Keep transient audio buffers in memory; do not log samples or private user content.
- Audio callbacks must avoid allocations, locks, synchronous I/O and UI work. Keep one owner for each route and make partial-start failure and repeated stop safe.
- On stop, failure or termination, release owned resources and restore normal audio. Device changes, process exit and sleep/wake need deliberate handling rather than silent success claims.
- Runtime validation that changes real output volume, starts capture, switches the default device or reroutes user audio needs task authorization. Prefer a controlled local fixture and built-in stereo output first; preserve the user's current audio state.

## Build and verification

- Follow the NahtKey/NahtPaint workflow: targeted tests, release build, strip local paths, sign, verify and then package. Keep unit-test, fixture-test, UI and real audio evidence distinct.
- Run `swift test` for core changes. For routing changes include a deterministic DSP/route-lifecycle check and, when authorized, controlled real audio validation. Passing tests or compilation does not prove audible output, Bluetooth compatibility or latency.
- Use `scripts/build-app.sh [--native|--universal]`. Set `NAHTV0MIXER_APP_OUTPUT` for another build destination; do not overwrite a running app. Do not start another app instance just for a preview.
- Use `NAHTV0MIXER_SIGN_IDENTITY` for a deliberate signing identity; default is ad-hoc, not notarized. Never claim notarization or Intel runtime validation from a universal build alone.
- `scripts/package-release.sh` checks metadata, architectures, deployment target, local-path leakage and signatures, then creates ZIP and SHA-256 files. Verify the downloaded artifact after any future publication.
- Only run `scripts/install-local.sh` when local installation is requested. Never terminate the running app, launch it automatically or change launch-at-login preferences from scripts.
- Keep scripts compatible with macOS system Bash 3.2. Do not add developer paths, credentials or generated build artifacts to Git.

## Documentation

- README and release notes are concise Vietnamese user guidance: features, requirements, installation, usage, material limitations, credit and license. Keep implementation details in `docs/development.md`.
- Keep wording operational. Clearly label experimental support and verification limits; do not announce completed runtime behavior from source presence.
