# Soprano Git

Keyboard-first Git client for macOS in the Soprano family: GitKraken's layout and shortcuts
(commit graph, left ref panel, right commit panel) in Soprano's "Mission Control" chrome.
Swift 6 + programmatic AppKit (no storyboards/xibs/SwiftUI), SPM, macOS 14+, drives the git
CLI. Shipped as a hand-packaged `.app` via `scripts/package-app.sh`. Local repo only for
now: no GitHub remote.

## Commands

Homebrew Swift with the Command Line Tools SDK. Xcode's newer SDK breaks Homebrew Swift,
so pin `DEVELOPER_DIR` on every direct Swift command:

```bash
export DEVELOPER_DIR=/Library/Developer/CommandLineTools PATH="/opt/homebrew/opt/swift/bin:$PATH"
swift build
swift test
swift test --filter GraphLayoutTests
./scripts/dev.sh --build-only        # package .build/debug/Soprano Git Dev.app (com.soprano.git.dev)
./scripts/install.sh                 # release build → /Applications/Soprano Git.app
scripts/make-fixture-repo.sh /tmp/sg-fx [--conflict]   # disposable repo at /tmp/sg-fx/work
.build/debug/SopranoGit snapshot --repo /tmp/sg-fx/work --out /tmp/shot.png [--select …] [--diff …] [--focus …] [--keys "…"]
```

`ld: warning: building for macOS-14.0 …` link warnings are expected. There is no linter or
formatter; match surrounding style.

## Verification

- Verify source changes with `swift build` and `swift test`.
- Verify UI with the offscreen `snapshot` subcommand and read the PNG (options in
  `docs/ARCHITECTURE.md` → Verification harness). Do not launch the GUI or run
  `./scripts/dev.sh` without `--build-only` unless the user asks.
- Write operations and write-triggering `--keys` only against fixture repos from
  `scripts/make-fixture-repo.sh`, never against the user's repositories.

## Installing completed changes

After a verified change to the app or its packaging, run `./scripts/install.sh` as the last
step. It replaces `/Applications/Soprano Git.app` without restarting a running instance.
Never use `sudo`; report permission problems instead. Docs-only work needs no install.

## Commits and changelog

- Short imperative subjects, `feat:` / `fix:` / `docs:` / `test:` / `chore:` prefixes.
- User-visible changes get a line under `## [Unreleased]` in `CHANGELOG.md` (Keep a
  Changelog groups: Added, Changed, Deprecated, Removed, Fixed, Security), written for the
  user and naming the shortcut or setting. Never add a version heading during feature work.
- Releases: rename `[Unreleased]` to `## [X.Y.Z] - YYYY-MM-DD`, add a fresh `[Unreleased]`,
  set `CFBundleShortVersionString` and `CFBundleVersion` in `Support/Info.plist` (the only
  version source), `swift test`, install, commit `release: vX.Y.Z`.

## Architecture

`docs/ARCHITECTURE.md` is the contract: module ownership, seams, git invocation rules,
keyboard model, the default binding table, and the visual spec. Keep it current when a
seam, binding, or harness option changes. `docs/ROADMAP.md` lists what is deliberately
not built yet.

- `Sources/SopranoGitCore/` — git engine, Foundation only: `GitRunner` (the only place that
  spawns git), `Repository` (reads + writes), parsers, `PatchBuilder`, `Graph/GraphLayout`
  + `GraphSequence` (lane layout).
- `Sources/SopranoGit/Repo/RepositoryController.swift` — per-tab state store: data, paging,
  selection, open diff, FS-watch refresh, `run(…)` for every git write.
- `Sources/SopranoGit/Shell/` — workspace layout, keyboard router (⌃A prefix, scopes),
  settings/theme/keymap, dialogs, palette, shortcut sheet. `Commands/` — `AppCommand`
  registry; every action is a command with an id that settings.json can rebind.
- `Sources/SopranoGit/Views/{Graph,Sidebar,Detail,Diff,Welcome,Common}` — regions and the
  shared list kit. `Actions/GitActions.swift` — every user-facing git flow and the shared
  context menus.
- `Sources/SopranoGit/App/` — startup, menus, window, tabs, `snapshot` harness, `askpass`.

## Conventions

- Chrome comes from Soprano: square corners, `ThemeColors` tokens only, Departure Mono via
  `RetroFont.display` at 11 or 22 pt only (small caps; never uppercase strings by hand),
  `RetroFont.body` for running text. Build on `Views/Common` and the `Retro*` components.
- New actions: add an `AppCommand` to the owning module's `…Commands.all`, add its row to
  the binding table in `docs/ARCHITECTURE.md`, and keep the README shortcut list in sync.
- Single-key bindings are scoped to a focus region; chords without ⌘/⌃ never fire in text
  fields; avoid ⌥ chords (Soprano's `KeyChord` rejects them, German layouts need ⌥).
- Views never run git: reads go through `controller.repository` off the main actor with a
  generation check, writes through `controller.run` or `GitActions`.
- Persisted UI state uses an injectable `UserDefaults`; settings live only in
  `~/.config/soprano-git/settings.json`.
- Tests: swift-testing, one `struct …Tests` per file, sentence-style names. Test files
  `import AppKit`, never `Foundation` (the `_Testing_Foundation` overlay breaks the build).
  Git tests run in temp dirs with an isolated config (`GitTestSupport.swift`).

## Gotchas

- `Sources/SopranoGit/Vendored/` is copied from Soprano by `scripts/sync-soprano-chrome.sh`
  (committed Soprano state only; source commit in `Vendored/SOPRANO_COMMIT`). Never edit
  it here: change Soprano, commit there, re-run the script.
- `SopranoResources` (App/) keeps Soprano's name so vendored files compile unchanged; the
  SPM resource bundle is `SopranoGit_SopranoGit.bundle`.
- GUI apps start with a minimal PATH; `GitRunner` prepends Homebrew/user tool dirs and
  `git.extraPath` so hooks find node/bun. Passwords go through the app binary in `askpass`
  mode (`SOPRANO_GIT_ASKPASS=1`).
- Signing reuses Soprano's "Soprano Local Development" identity and keychain.
- Dev (`com.soprano.git.dev`) and installed (`com.soprano.git`) apps keep separate state.
