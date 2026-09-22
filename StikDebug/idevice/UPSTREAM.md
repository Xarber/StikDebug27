# Bundled idevice

This directory vendors the iOS arm64 slice of [`jkcoxson/idevice`](https://github.com/jkcoxson/idevice).

- Release: `v0.1.65`
- Source revision: `2bc6a05c80daaf8583884cf7f2d2563be17e6c2d`
- Retrieved from the release's `idevice-xcframework-v0.1.65.zip` artifact on 2026-08-25.

`module.modulemap` intentionally keeps StikDebug's existing `idevice` module name, so the Swift source can continue to use `import idevice`.

The GitHub workflow replaces this fallback archive with revision
`d32c8189c51c2789496b0768039419c3705498c3` and applies the small FFI overlay in
`.github/idevice`. That overlay exposes CoreDevice screen capture and HID control;
the pinned fallback remains available for repository browsing and non-CI setups.

The remote-pairing, live-display, and input design was validated against the
MIT-licensed [`device-hub-ios`](https://github.com/JaviSoto/device-hub-ios)
implementation. StikDebug uses its own Swift UI and a small FFI overlay on the
pinned `idevice` revision rather than embedding Device Hub.
