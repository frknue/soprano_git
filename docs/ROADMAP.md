# Roadmap

Soprano Git starts with the basics: a good commit graph and the everyday commands
(checkout, branch, merge, rebase, cherry-pick, revert, reset, tags, stashes, fetch/pull/push,
staging by file and hunk, committing, conflict resolution by side). The GitKraken features
below come after that, roughly in this order.

## Next

- Line-level staging in the diff view (select lines, stage/unstage/discard them).
- Inline (whole-file) diff layout and an ignore-whitespace toggle.
- Three-way merge-conflict editor (ours / theirs / output, take hunks or lines, edit output).
- Interactive rebase editor (reorder, pick/reword/squash/fixup/drop).
- File history and blame (⌘⇧H to search a file).
- Undo / redo of git actions (⌘Z / ⌘Y): checkout, commit, discard, reset, branch create/delete.
- Drag and drop: branch onto branch to merge/rebase, onto a remote to push.
- Hide and solo branches in the graph; pin a branch to the left.

## Later

- Open, clone and init dialogs (clone from URL or GitHub repo list).
- Auto-fetch on an interval.
- Submodules, worktrees and LFS sections in the left panel.
- Author avatars in the graph.
- GitHub pull requests and issues via `gh` (list, create from branch, check out).
- AI actions via agent CLIs (commit message, explain commit, PR description).
- ⌥T opens the repo in a Soprano tab; Agent Sessions view fed by Soprano's agent status.
- ⌥ chords in keybindings (needs Option support in Soprano's `KeyChord`, then a sync).
