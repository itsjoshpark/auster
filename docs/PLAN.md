# Auster — Master Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**This file is the single entry point.** You are building **Auster**, a macOS
menu-bar Dropbox sync client in SwiftUI that replicates the behavior of Maestral
(a discontinued open-source client). Everything you need is in this repo's
`docs/` — you do **not** need Maestral's source, and should not look for it.

**Goal:** A trustworthy two-way sync client: a plain local folder (default
`~/Dropbox`) mirrored with the user's Dropbox account, driven from a menu bar
icon, with onboarding, settings, selective sync, and notifications.

**Architecture:** One app, two layers — a UI-free Swift package `AusterCore`
(Dropbox service facade, GRDB sync database, FSEvents monitoring, sync engine +
coordinator actors) and a thin SwiftUI app target (MenuBarExtra, Settings scene,
onboarding wizard) observing an `@Observable` state object. See
[design.md](design.md).

**Tech stack:** Swift 6 (strict concurrency), SwiftUI, macOS 15+, SwiftyDropbox,
GRDB, Sparkle. Xcode 16+.

**Spec:** [design.md](design.md) — the plan argues from it; read it first.

## Reading order (before Phase 1)

1. [design.md](design.md) — architecture, boundaries, testing strategy.
2. [decisions.md](decisions.md) — locked decisions; **do not relitigate**. Note
   especially D4 (permanent non-features — build no hooks for them) and D9
   (engine safety principles — non-negotiable).
3. [research/maestral-sync-engine.md](research/maestral-sync-engine.md) — **the
   sync algorithm bible**. Phases 3–7 implement it; section references in the
   phase files (e.g. "§4.4") point here ("engine-doc").
4. [research/dropbox-api-notes.md](research/dropbox-api-notes.md) — API routes,
   OAuth/PKCE, limits, error mapping ("api-notes").
5. [research/maestral-ux.md](research/maestral-ux.md) — the UI spec, down to
   menu item order and copy ("ux").

## Global constraints

- macOS 15+ deployment target; Swift language mode 6; zero concurrency warnings.
- `AusterCore` never imports AppKit/SwiftUI. App target contains no sync logic.
- Dependencies: SwiftyDropbox, GRDB, Sparkle only. No others without asking Josh.
- Personal Dropbox accounts only; team accounts rejected at link with the exact
  copy "**Not supported**" (never "not yet supported"). Never implement:
  bandwidth limits, multiple accounts, ignore files, CLI, team support (D4).
- Safety principles D9 apply to every engine change: no data loss, conflicted
  copies over overwrites, ignore-wrapped local mutations, atomic downloads,
  index/cursor writes only after changes are applied, parentRev-guarded deletes.
- The Dropbox **app key** comes from Josh — ask when starting Phase 2; it goes
  in gitignored `Config/Secrets.xcconfig` (template committed).
- App name "Auster"; cache dir `.auster.cache`; local folder default `~/Dropbox`.
- TDD throughout (test first, red, green, commit). Commit at every green step;
  imperative-mood messages, no attribution footers.

## Phases

Execute in order; each produces working, testable software and ends with its
"definition of done" verified. Phase files contain the task-by-task detail.

| # | Phase | File | Depends on |
|---|---|---|---|
| 1 | Scaffolding & menu bar shell | [plan/01-scaffolding.md](plan/01-scaffolding.md) | — |
| 2 | Dropbox service layer & auth | [plan/02-dropbox-service-auth.md](plan/02-dropbox-service-auth.md) | 1 |
| 3 | Database, paths, hashing | [plan/03-state-database-paths-hashing.md](plan/03-state-database-paths-hashing.md) | 1, 2 |
| 4 | Download sync | [plan/04-download-sync.md](plan/04-download-sync.md) | 2, 3 |
| 5 | Local monitoring & upload sync | [plan/05-upload-sync.md](plan/05-upload-sync.md) | 4 |
| 6 | Coordination & lifecycle | [plan/06-coordination-lifecycle.md](plan/06-coordination-lifecycle.md) | 5 |
| 7 | Selective sync | [plan/07-selective-sync.md](plan/07-selective-sync.md) | 6 |
| 8 | App UI | [plan/08-app-ui.md](plan/08-app-ui.md) | 7 |
| 9 | Hardening & integration tests | [plan/09-hardening-integration.md](plan/09-hardening-integration.md) | 8 |
| 10 | Distribution | [plan/10-distribution.md](plan/10-distribution.md) | 9 |

## Working agreements

- **When docs conflict or are silent:** research docs beat your intuition; the
  phase plan beats the research docs on *what to build now*; decisions.md beats
  everything. Genuine gap → make the choice most consistent with D9, note it in
  `docs/decisions.md` under a new "Implementation notes" section, and continue.
- **Ask Josh** (don't guess): the app key (Phase 2), anything requiring his
  Dropbox account interactively, Developer ID credentials (Phase 10), and any
  scope change. Everything else: proceed autonomously.
- **Manual verification steps** in phase files that need a linked account can be
  run with Josh's test account; keep destructive experiments inside a dedicated
  test folder.
- **Interfaces are contracts:** the Swift signatures in phase files under
  "Interfaces produced" are what later phases compile against. Renaming them
  means updating every later phase file in the same commit.
- Track progress by checking off `- [ ]` boxes in the phase files (commit doc
  updates with the code).
