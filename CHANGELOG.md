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
- Diff view with hunk staging, unstaging and discarding (`s` / `u` / `d`) and file-to-file navigation (`⇧J` / `⇧K`).
- Checkout, branch, rename, delete, merge (fast-forward, merge commit, or fast-forward only), rebase, cherry-pick, revert, reset (soft, mixed, hard), tags, stashes, fetch, pull (`pull.mode`) and push with upstream setup and force-with-lease after a rejected push.
- Banner for a paused merge, rebase, cherry-pick or revert with Continue (`⌃A c`), Abort (`⌃A x`) and Skip; conflicted files resolve with ours (`o`) or theirs (`t`).
- GitKraken's shortcuts plus Soprano's `⌃A` prefix and single-key actions in each panel; the command palette (`⌘P`) and the shortcut sheet (`?`).
- Repository tabs restored on relaunch, a welcome screen with recent repositories, and opening folders with `open -a "Soprano Git"` or a Dock drop.
- `~/.config/soprano-git/settings.json` with live reload: theme (follows Soprano by default), git path and extra PATH, graph page size and date style, pull mode, diff context, and key bindings.
- Password and passphrase prompts for git and ssh in the Mission Control style.
