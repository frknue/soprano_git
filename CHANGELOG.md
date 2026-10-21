# Changelog

All notable changes to Soprano Git are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Commit graph with colored lanes, branch and tag labels, stashes, and a `// WIP` row for uncommitted changes; loads 2,000 commits at a time as you scroll.
- Graph search over messages, authors and commit ids (`⌘F` or `/`, `n` / `⇧N`).
- Left panel with local branches (folders by `/`), remotes, tags and stashes, ahead/behind counts, and a filter (`⌘⇧F` or `/`).
- Commit panel with message, author, parents and changed files, and for the working copy the conflicted, unstaged and staged files with a commit composer and Amend.
- „Discard all“ im Working-Copy-Panel (`⇧D`): verwirft nach Bestätigung alle ungestagten Änderungen und löscht ungetrackte Dateien; gestagte Änderungen und Konflikte bleiben erhalten.
- Dateiauswahl per Ctrl-/⌘-Klick und Bereichsauswahl per ⇧-Klick im Commit-Panel; „Stage N“, „Unstage N“ und „Discard N“ sowie `s` / `u` / `d` bearbeiten nur die ausgewählten Dateien. Die Auswahl bleibt bei Statusaktualisierungen erhalten.
- Diff view with hunk staging, unstaging and discarding (`s` / `u` / `d`) and file-to-file navigation (`⇧J` / `⇧K`).
- Split (side-by-side) diff view, toggled with `v` and remembered for every diff, and syntax highlighting in both diff views.
- Long lines in the diff scroll sideways (trackpad, ⇧ + mouse wheel, the scroll bar at the bottom, or `←` / `→`); line numbers stay in place and both split sides scroll together.
- Checkout, branch, rename, delete, merge (fast-forward, merge commit, or fast-forward only), rebase, cherry-pick, revert, reset (soft, mixed, hard), tags, stashes, fetch, pull (`pull.mode`) and push with upstream setup and force-with-lease after a rejected push.
- Banner for a paused merge, rebase, cherry-pick or revert with Continue (`⌃A c`), Abort (`⌃A x`) and Skip; conflicted files resolve with ours (`o`) or theirs (`t`).
- GitKraken's shortcuts plus Soprano's `⌃A` prefix and single-key actions in each panel; the command palette (`⌘P`) and the shortcut sheet (`?`).
- Repository tabs restored on relaunch, a welcome screen with recent repositories, and opening folders with `open -a "Soprano Git"` or a Dock drop.
- `~/.config/soprano-git/settings.json` with live reload: theme (follows Soprano by default), git path and extra PATH, graph page size and date style, pull mode, diff context, and key bindings.
- Settings screen (`⌘,`) as its own tab with General, Git, Keyboard and About pages: theme, graph, diff, git executable and extra PATH, pull mode, prefix key and timeout, and every shortcut with Record (press the new chord; `⌃A` first for a prefix chord), Off and Reset. Changes are written to `settings.json` immediately, keeping its comments, and problems in the file are listed at the top. `j` / `k` switch pages, `/` filters shortcuts, `Esc` closes; "Open settings.json" moved to the palette and the app menu.
- Password and passphrase prompts for git and ssh in the Folio style.

### Changed

- New Folio look: light Paper and dark Ink themes that follow macOS (`"theme": "folio"`) or, by default, Soprano's theme and appearance; pin one with `folio-paper` or `folio-ink`. The `mission-control` theme is gone and falls back to `folio`. The toolbar has Refs (`⌘J`) and Commit panel (`⌘K`) toggles, and the diff highlights the changed words within a line.

### Fixed

- `Esc` closes an open diff also while the commit panel has focus, e.g. after clicking another file in its list or moving through the files with `j` / `k`.
