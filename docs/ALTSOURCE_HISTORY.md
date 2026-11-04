# Stable source history across nightly builds

The public source intentionally strips `releaseChannels` immediately before writing JSON, retaining the existing `#! DELETE THIS TO RESTORE RELEASECHANNELS` block. The generator still creates stable/nightly channel structures internally.

The prior architecture check required those stripped channels on the next run. It therefore rejected the saved source and erased `versions` on nightly builds. Canonical name, bundle identifier and a versions list now identify valid state. Missing channel data is optional; every saved stable version is preserved across nightlies. A stable build prepends its entry and replaces an older entry for that same marketing version.

When old output already contains no stable versions, recovery queries GitHub Releases for actual stable StikDebug IPA assets, excluding drafts, prereleases and metadata release 1.0. The tag supplies the recorded version; no build number is invented. No IPA is downloaded. This does not delete or recreate releases.

Validation: `python3 -m unittest discover -s .github/tests -v`. Tests cover channel-free persistent state, historical versions, actual output from a mocked nightly run and recovery filtering. Mocked tests do not publish metadata or releases. The next successful release workflow publishes the recovered source.
