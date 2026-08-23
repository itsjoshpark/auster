# Auster

<img src="design/AppIcon/preview@512.png" alt="Auster app icon" width="128" align="right"/>

An open-source Dropbox sync client for macOS: a plain local folder (default
`~/Dropbox`) kept in two-way sync with your Dropbox account, driven from a
menu bar icon. No Electron, no daemons, no on-demand placeholder files — just
your files, on disk, synced.

**Status: planning / pre-implementation.** The full design and implementation
plan live in [`docs/`](docs/); implementation starts from
[`docs/PLAN.md`](docs/PLAN.md).

## Planned features (v1)

- Two-way sync with conflict resolution (conflicted copies, never data loss)
- Menu bar app with status, recent changes, and sync issues
- Onboarding wizard with browser-based OAuth (PKCE — no secrets in the app)
- Selective sync
- Desktop notifications for remote changes
- Start at login, pause/resume

Deliberately out of scope (see [`docs/decisions.md`](docs/decisions.md)):
bandwidth limits, multiple accounts, ignore files, a CLI, and Dropbox
team/business accounts.

## Requirements

- macOS 15 (Sequoia) or later
- Xcode 26+ to build
- A Dropbox API app key (development builds; see
  `Config/Secrets.xcconfig.template` once scaffolding lands)

## Building

Build scripts arrive with Phase 1 of the implementation plan
(`Scripts/build.sh`, `Scripts/test.sh`). Until then there is nothing to build —
this repo is documentation.

## Tech

Swift 6 / SwiftUI, [SwiftyDropbox](https://github.com/dropbox/SwiftyDropbox),
[GRDB](https://github.com/groue/GRDB.swift),
[Sparkle](https://github.com/sparkle-project/Sparkle).

## License

MIT — see [LICENSE](LICENSE).
