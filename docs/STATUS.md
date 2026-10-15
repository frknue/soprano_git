# Status

## Goal

Soprano Git: a keyboard-first GitKraken copy in the Soprano family (Mission Control chrome,
GitKraken layout and shortcuts, Soprano's ⌃A prefix). Phase 1 is the basics: a good commit
graph and the everyday commands. The "cool features" follow in `docs/ROADMAP.md` order.

## Done (phase 1)

- Git engine over the git CLI (`SopranoGitCore`): every read the UI needs, every write in the
  roadmap's phase 1, hunk staging, paused-operation detection, askpass.
- Commit graph (lanes, pills, WIP and stash rows, paging, search), left panel, commit panel
  with composer, diff view with hunk staging, merge/rebase/cherry-pick/revert/reset/tag/
  stash/fetch/pull/push flows with shared context menus, conflict banner.
- Keyboard: GitKraken shortcuts, ⌃A prefix, scoped single keys, palette, shortcut sheet,
  remapping in `~/.config/soprano-git/settings.json`.
- Packaging (`scripts/install.sh`, `scripts/dev.sh`), app icon, offscreen `snapshot`
  harness, fixture repos, 330+ tests.

## Next

1. Roadmap "Next" items, starting with line staging, split/inline diffs and the merge
   conflict editor.
2. Horizontal scrolling for long diff lines (they are clipped today).

## Open decisions

- **Palette list bug (Soprano upstream)**: in the vendored `CommandPalettePanel`, the
  results document view is only constrained `bottom >= clip bottom`, so after the result
  count shrinks the list keeps its old height and the remaining rows sink to the bottom.
  Same code in Soprano. Fix there (pin the document height to the stack with a low-priority
  equality, e.g. `documentView.heightAnchor == stackView.heightAnchor` at
  `.defaultLow`), then run `scripts/sync-soprano-chrome.sh`.
- **Option chords**: Soprano's `KeyChord` rejects ⌥, so GitKraken's ⌘⌥F / ⌥T / ⌥O have
  other defaults here. Adding ⌥ support belongs in Soprano first.
- **GitHub remote**: the repo is local only; create `frknue/soprano-git` when wanted.
- **Shared design package**: vendoring via the sync script was chosen over extracting a
  `SopranoChrome` package; revisit if the two apps drift.
