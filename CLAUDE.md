# CLAUDE.md

Auster is a macOS menu-bar Dropbox sync client (SwiftUI, Swift 6, macOS 15+).

## Start here

**`docs/PLAN.md` is the entry point.** Read it first — it gives the reading
order (design → decisions → research docs), the global constraints, and the
10-phase implementation plan in `docs/plan/`. Work phases in order; check off
`- [ ]` boxes in the phase files as you go and commit them with the code.

The docs are self-contained: the sync-engine algorithms, Dropbox API notes,
and the UX spec are all captured in `docs/research/` — everything you need is
in this repo.

## Hard rules

- `docs/decisions.md` is settled — do not relitigate. D4 lists features that
  are **permanently** out of scope: build no hooks for them. D9's engine safety
  principles are non-negotiable (no data loss; conflicted copies over
  overwrites; ignore-wrapped local mutations; atomic downloads; guarded deletes).
- `AusterCore` never imports AppKit/SwiftUI; the app target contains no sync
  logic.
- Dependencies: SwiftyDropbox, GRDB, Sparkle only. Anything else: ask Josh.
- TDD: failing test first, then code, then commit. Swift 6 language mode with
  zero concurrency warnings.
- **Conventional Commits** for every commit message AND every PR title
  (`feat:`, `fix:`, `docs:`, `chore:`, `test:`, `refactor:`). Imperative mood,
  no attribution footers.
- Never commit secrets. The Dropbox app key lives in gitignored
  `Config/Secrets.xcconfig` — ask Josh for the key when Phase 2 needs it.

## Building & testing

From Phase 1 onward: `Scripts/test.sh` runs AusterCore tests then builds the
app; `Scripts/build.sh` builds only. Integration tests (Phase 9) run only with
`AUSTER_INTEGRATION=1`.

## When to ask Josh

The app key (Phase 2), anything needing his Dropbox account interactively,
signing/appcast credentials (Phase 10), and scope changes. Everything else:
proceed autonomously, and record any genuinely new decision in
`docs/decisions.md` under "Implementation notes".

## Xcode MCP

Xcode 26.3+ has a built-in MCP server (`xcrun mcpbridge`). If registered in
this session, its tools can drive Xcode directly (builds, tests, issues,
running the app) — but only while Josh has `Auster.xcodeproj` open in a
running Xcode. Prefer the CLI loop (`Scripts/test.sh`, `xcodebuild`) as the
default; use Xcode MCP when live build issues or running the app would help,
and ask Josh to open the project if it isn't. It cannot exist before Phase 1
creates the project.
