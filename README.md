# Auster

<img src="design/AppIcon/preview@512.png" alt="Auster app icon" width="128" align="right"/>

An open-source Dropbox sync client for macOS: a plain local folder (default
`~/Dropbox`) kept in two-way sync with your Dropbox account, driven from a
menu bar icon. No Electron, no daemons, no on-demand placeholder files — just
your files, on disk, synced.

**Status: in development.** The full design and implementation plan live in
[`docs/`](docs/), starting from [`docs/PLAN.md`](docs/PLAN.md).

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
  `Config/Secrets.xcconfig.template`)

## Building

```sh
git clone git@github.com:itsjoshpark/auster.git
cd auster
Scripts/test.sh          # AusterCore tests, then an app build
Scripts/build.sh         # app build only (pass Release for a release build)
```

Both scripts are plain `xcodebuild`/`swift` wrappers — you can also just open
`Auster.xcodeproj` in Xcode and hit Run. Swift package dependencies resolve on
the first build.

### The Dropbox app key

Auster talks to Dropbox through an API app key. Builds succeed without one; it
is only needed at runtime, to link an account.

```sh
cp Config/Secrets.xcconfig.template Config/Secrets.xcconfig
# then edit Config/Secrets.xcconfig and set DROPBOX_APP_KEY
```

`Config/Secrets.xcconfig` is gitignored. `Config/Shared.xcconfig` picks it up
via `#include?`, and the key becomes the app's OAuth redirect URL scheme
(`db-<key>`). There is no client secret: OAuth uses PKCE.

### Layout

| Path | What |
|---|---|
| `AusterCore/` | The engine, as a local Swift package. No AppKit or SwiftUI. |
| `Auster/` | The app: menu bar, settings, onboarding. No sync logic. |
| `Config/` | Shared build settings and the secrets template. |
| `Scripts/` | Build and test entry points. |
| `docs/` | Design, decisions, research, and the phased implementation plan. |
| `design/` | Reference artwork and its generators. Never referenced by the build. |

## Tech

Swift 6 / SwiftUI, [SwiftyDropbox](https://github.com/dropbox/SwiftyDropbox),
[GRDB](https://github.com/groue/GRDB.swift),
[Sparkle](https://github.com/sparkle-project/Sparkle).

## License

MIT — see [LICENSE](LICENSE).
