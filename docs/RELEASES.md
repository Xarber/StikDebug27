# Fork releases

The existing Xcode workflow remains the sole IPA publication workflow. It builds the pinned remote-control idevice overlay, archives the application, packages StikDebug.ipa, then publishes the actual build through softprops/action-gh-release. Failed archives do not publish an IPA release.

Automatic pushes and manual `release__nightly: true` dispatches create unique prerelease tags `nightly-RUN-SHA`. Existing releases are retained. A manual dispatch with the existing `release__nightly: false` input creates/updates the marketing-version stable release. The input declaration is unchanged.

Before publication, `.github/scripts/release_notes.py` reads the real Git history since the latest non-draft, non-prerelease application release (excluding metadata tag 1.0). Conventional Commits are grouped into features, fixes, maintenance and breaking changes; other upstream titles are also included. Each entry links its actual commit. Notes identify the source build commit. IPA SHA256SUMS is attached beside the IPA. Failure to resolve an existing baseline is a publication failure, not silently omitted history.

The persistent 1.0/apps.json asset is updated afterward using the source-history-preserving updater and is never marked Latest. Internal releaseChannels creation and the explicit final removal line remain in place. The workflow does not delete releases. Tests run before the archive.

Upstream now uses project.xcproj. CI selects the newest installed Xcode; full Xcode is not installed in this local checkout's environment. The post-push workflow must establish native archive success independently of static checks. No large SDK is installed locally by these changes.
