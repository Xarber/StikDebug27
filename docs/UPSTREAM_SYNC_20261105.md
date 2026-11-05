# Upstream integration — 2026-11-05

Integrated all 41 upstream commits through `1c3801b` as a merge, preserving fork history. A local rollback reference exists at `refs/backup/pre-upstream-20261105`.

Conflict decisions:

- Keep the fork's native Devices tab, battery, advanced tools, StikServer relay/mesh and persistent condition sessions; add upstream Launch Apps, guided pairing, diagnostics, DDI/cryptex fixes and location route cleanup.
- Adopt upstream project.xcproj, preserving the fork's archive assembly, explicit linker input, synchronized-folder exclusions and remote-control FFI build. Keep the richer fork FFI header/archive fallback: its header contains upstream's declarations plus 93 additional lines. CI still builds the pinned idevice overlay. No native capability downgrade.
- Keep one fork release workflow; do not re-enable upstream's duplicate Build Debug IPA workflow. Preserve the manual stable/nightly input and source-history correction.
- Combine upstream pairing-placement targets and dynamic local pairing ports with the fork's pinned remote targets and address fallback. Preserve upstream privacy-safe logging and diagnostic reports.
- Keep fork download/source links and use the newly imported pairing guide in the fork.

Validation so far: all Swift files parse with the installed command-line Swift compiler; Info.plist validates; no conflict markers remain in Swift. Full Xcode is not installed locally, so no native compile or physical-device regression test is claimed. Project syntax/schema decisions were checked against Apple's xcode-project-format schema and Xcode format documentation. Remote archive validation is required.

No docs/IDEAS.json collection was present in either checkout; no on-device ideas collection was accessed or inferred. This work does not implement an unrelated Ideas subsystem.

Imported commits:

- 1c3801b docs: add pairing and supported app guides
- 647738b feat: add connection diagnostics and copyable error reports
- 9ed2b84 fix: restore idevice file logging at info level
- 5672e44 chore: migrate Xcode project to xcproj format
- 97530a9 3.2.0
- 51713a7 fix: disable raw idevice file logging
- 24c239d ci: build all fork branches with Xcode 27.1
- e997266 feat: add PID JIT, app launching tools and connection status
- 1376137 feat: add guided on-device pairing and AFC file placement
- 117c158 fix: release the route when playback finishes so a new spot can be set (#490)
- 96f008e fix: merge discovery and LocalDevVPN connection updates
- 76efd52 fix: add connection troubleshooting and LocalDevVPN shortcut
- a391ee8 fix: prefer loopback services for remote pairing discovery
- 17b1e1d fix: merge pairing and DDI cleanup
- be0ec90 Revert "Prevent stale legacy pairing files overriding fresh imports (#479)" (#486)
- 61da473 Prevent stale legacy pairing files overriding fresh imports (#479)
- dcfd1b0 fix: clean up legacy pairing and DDI files and warn on self-attachment
- 70f761c fix: discover remote pairing ports and apply connection settings
- 1256c52 Fix DeepWiki embed
- 3422fc4 3.1.15
- 734361b fix: handle legacy and cryptex DDI service discovery
- cd5e609 Update README.md
- e4665d7 Update SettingsView.swift
- 300ebff 3.1.14
- 775fba1 Update AutoScriptAssignments.swift
- 871f146 Update README.md
- 4bdfc92 3.1.13
- 4b3c8d6 Rename 'MeloCafe' to 'MeloCafé'
- c03abca Update AutoScriptAssignments.swift
- d4306e7 3.1.12 ReadMe
- 50766f5 3.1.12
- e7ef949 fix: preserve background activity sessions
- 6a078be fix: require a background keep alive
- 2d09a40 fix: limit idevice log file size
- f50353c perf: reduce redundant device queries
- cbaf467 fix: restore personalized DDI mounting
- 534b6da Update AutoScriptAssignments.swift
- 5e3e1bc 3.1.11
- 3abf9d5 feat: warn before manually enabling LiveContainer JIT
- e85e0b3 feat: smooth cryptex DDI migration
- f766728 feat: migrate to cryptex DDI

