# Soprano Git

**A keyboard-first Git client for macOS, in the Soprano family.**

Soprano Git takes GitKraken's layout (the commit graph in the middle, branches and tags
on the left, the commit panel on the right) and GitKraken's shortcuts, and builds them in
Soprano's "Mission Control" chrome. Everything you can click has a key. Every key can be
changed in `settings.json`.

It drives the `git` CLI you already have, so your config, credentials, hooks and signing
behave exactly as they do in the terminal.

## Install

```bash
./scripts/install.sh        # release build → /Applications/Soprano Git.app
```

The installer never restarts a running Soprano Git; the update applies on the next
launch. Open a repository from the welcome screen, with `⌘O`, by dropping a folder on
the window or the Dock icon, or from a terminal:

```bash
open -a "Soprano Git" .
```

In Soprano, `⌃A` → `G` (**Open in Soprano Git**, also in its command palette) opens the
repository of the active terminal tab. A repository that is already open just gets its
tab selected.

## The first five minutes

1. `⌘O` and pick a repository, or press `Enter` on one of the recent repositories.
2. `j` / `k` move through the commit graph. The commit panel on the right follows.
3. `l` moves into the commit panel, `Enter` opens the selected file's diff, and `Esc`
   brings the graph back. `h` goes the other way.
4. On the `// WIP` row (`w`), `s` stages a file, `u` unstages it. Write a summary
   (`⌘⇧M` jumps there) and commit with `⌘↩`.
5. `⌃A p` pulls, `⌃A ⇧P` pushes. `⌘P` finds any command; `?` lists every shortcut.

## The window

- **Tab bar**: one tab per open repository (`⌘T`, `⌘W`, `⌘1`–`⌘9`). Open tabs come back
  on relaunch.
- **Toolbar**: repository, current branch with commits ahead/behind its upstream, and
  Pull, Push, Branch, Stash and Pop keys showing their shortcuts.
- **Left panel** (`⌘J`): local branches (grouped into folders by `/`), remotes, tags and
  stashes, with ahead/behind counts. `/` filters. `Enter` checks out a branch, or reveals
  a tag or stash.
- **Commit graph**: every branch, remote branch, tag and stash in date order, with
  colored lanes, branch and tag labels, and a `// WIP` row while you have changes. `⌘F`
  or `/` searches messages, authors and commit ids.
- **Commit panel** (`⌘K`): the selected commit's message, author, parents and changed
  files, or for the working copy its conflicted, unstaged and staged files and the commit
  composer (with Amend).
- **Diff view**: replaces the graph while a file is open. `j` / `k` move between hunks,
  `s` / `u` / `d` stage, unstage or discard the current hunk, `⇧J` / `⇧K` move to the
  next or previous file, and `Esc` closes it.
- **Banner**: while a merge, rebase, cherry-pick or revert is paused, it shows the
  conflict count with Continue (`⌃A c`), Abort (`⌃A x`) and Skip.
- **Status bar**: `NORMAL` / `PREFIX` key mode, the running or last git operation with
  its progress, the current branch, and the number of loaded commits.

Right-click any commit, branch, tag or stash for the same actions GitKraken offers.

## Keyboard shortcuts

`⌃A` is the prefix, as in Soprano: press it, release, then press the key. Single keys work
in the focused panel, never while you type in a text field.

**App and tabs**

| Keys | Action |
|---|---|
| `⌘P` | Command palette |
| `⌘/`, `?` | Keyboard shortcuts |
| `⌘,` | Open `settings.json` |
| `⌘O` / `⌘⇧O` | Open repository / open a recent one |
| `⌘T` / `⌘W` | New tab / close tab |
| `⌃Tab` / `⌃⇧Tab`, `⌘1`–`⌘9` | Next / previous tab, go to tab |
| `⌘J` / `⌘K` | Toggle left panel / commit panel |
| `h` / `l`, `⌃A h` / `⌃A l` | Focus the panel to the left / right |

**Repository**

| Keys | Action |
|---|---|
| `⌘L`, `⌃A f` | Fetch all |
| `⌃A p` / `⌃A ⇧P` | Pull / push |
| `⌘B`, `b` | Create branch (at the selected commit) |
| `⌃A s` / `⌃A ⇧S` | Stash / pop stash |
| `⌃A c` / `⌃A x` | Continue / abort a paused merge, rebase, cherry-pick or revert |

**Graph** (and the left panel where it makes sense)

| Keys | Action |
|---|---|
| `j` / `k` | Next / previous commit |
| `⇧J` / `⇧K` | Follow the branch down / up |
| `g`, `⌘↑` / `⇧G`, `⌘↓` | First / last commit |
| `.` / `w` | Jump to HEAD / to the working copy |
| `⌘F`, `/` | Search commits; `n` / `⇧N` (`⌘G` / `⌘⇧G`) next / previous match |
| `Enter` | Focus the commit panel |
| `c` | Checkout |
| `m` / `r` | Merge into the current branch / rebase the current branch onto it |
| `p` / `v` | Cherry-pick / revert |
| `⇧R` | Reset the current branch to the commit (soft, mixed or hard) |
| `t` | Create tag |
| `y` | Copy the commit id or ref name |

**Left panel**

| Keys | Action |
|---|---|
| `⌘⇧F`, `/` | Filter |
| `j` / `k`, `Space` | Move, expand or collapse |
| `Enter` | Checkout branch, reveal tag or stash |
| `e` / `d` | Rename branch / delete branch, tag or stash |

**Commit panel and diff**

| Keys | Action |
|---|---|
| `j` / `k`, `Enter` / `Space` | Move through files, open the diff |
| `⌘D` | Open the diff of the selected file |
| `s` / `u` / `d` | Stage / unstage / discard the file (or the hunk in the diff) |
| `⌘⇧S` / `⌘⇧U` | Stage all / unstage all |
| `⌘↩` / `⌘⇧↩` | Commit / stage all and commit |
| `⌘⇧M` | Focus the commit message |
| `a` | Toggle amend |
| `o` / `t` | Resolve a conflicted file with ours / theirs |
| `Esc` | Close the diff |

## Settings

Settings live in `~/.config/soprano-git/settings.json` (`SOPRANO_GIT_CONFIG` overrides the
path). The file is created with comments on first launch, accepts comments and trailing
commas, and reloads as soon as you save it. A bad value is ignored with a warning; it never
stops the app from starting.

```jsonc
{
  // A Soprano theme id, or "soprano" to follow Soprano's own theme setting.
  "theme": "soprano",
  "git": {
    "path": null,            // auto: Homebrew git, then the Command Line Tools git
    "extraPath": []          // directories hooks need on PATH (node, bun, …)
  },
  "graph": { "pageSize": 2000, "dateStyle": "relative" },   // or "absolute"
  "pull": { "mode": "ff" },                                  // "ff", "ff-only" or "rebase"
  "diff": { "contextLines": 3 },
  "keybindings": {
    "prefixKey": "a",
    "prefixTimeoutMs": 1500,
    // Command id → chord, list of chords, or null to unbind. Ids are listed in the
    // shortcut sheet (?) and the command palette.
    "bindings": { "repo.push": "cmd+shift+p", "commit.revert": null }
  }
}
```

Chords use Soprano's syntax: `cmd+shift+b`, `prefix+p`, `shift+j`, `enter`, `escape`,
`space`, `up`. Option chords are not supported.

## Development

```bash
export DEVELOPER_DIR=/Library/Developer/CommandLineTools PATH="/opt/homebrew/opt/swift/bin:$PATH"
swift build
swift test
./scripts/dev.sh                      # build, package and launch Soprano Git Dev.app
scripts/make-fixture-repo.sh /tmp/sg-fx --conflict
.build/debug/SopranoGit snapshot --repo /tmp/sg-fx/work --out /tmp/shot.png --keys "j j"
```

`DEVELOPER_DIR` pins the Command Line Tools SDK, because Homebrew Swift can't read Xcode's
newer one. The design system (`Sources/SopranoGit/Vendored/`) comes from Soprano; update it
with `scripts/sync-soprano-chrome.sh` instead of editing it here. `docs/ARCHITECTURE.md`
describes the modules, and `docs/ROADMAP.md` lists what comes next.

## License

[MIT](LICENSE). Departure Mono is © Helena Zhang, SIL Open Font License
(`Support/Licenses/LICENSE-departure-mono`).
