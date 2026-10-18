# Soprano Git architecture

Soprano Git is a keyboard-first Git client for macOS in the Soprano family: GitKraken's
layout and shortcuts (commit graph, left ref panel, right commit panel) in Soprano's
"Mission Control" chrome. Swift 6 + programmatic AppKit, SPM, macOS 14+, git CLI only.

## Toolchain

Homebrew Swift with the Command Line Tools SDK. Xcode's newer SDK breaks Homebrew Swift,
so always pin `DEVELOPER_DIR`:

```bash
export DEVELOPER_DIR=/Library/Developer/CommandLineTools PATH="/opt/homebrew/opt/swift/bin:$PATH"
swift build
swift test
swift test --filter GraphLayoutTests
```

The `ld: warning: building for macOS-14.0 …` link warnings are expected.

## Modules and ownership

| Path | Module | Contents |
|---|---|---|
| `Sources/SopranoGitCore/` | Core | `GitRunner` (process), `Repository` (reads + writes), parsers, `PatchBuilder`, `Graph/GraphLayout`. Foundation only, no AppKit. |
| `Sources/SopranoGit/Vendored/` | — | Copied from Soprano by `scripts/sync-soprano-chrome.sh`. **Never edit.** |
| `Sources/SopranoGit/App/`, `Shell/`, `Repo/`, `Commands/`, `Views/Common/` | Shell | App delegate, menus, main window, repo tabs, welcome screen, workspace layout, toolbar, status bar, operation banner, `RepositoryController`, settings/theme/keymap, keyboard router, palette, shortcut sheet, dialogs, shared list/row components, snapshot harness, askpass. |
| `Sources/SopranoGit/Views/Graph/` + `Core/Graph/` | Graph | Commit graph table, lane layout and drawing, graph search, `GraphCommands`. |
| `Sources/SopranoGit/Views/Sidebar/` | Sidebar | Ref tree (local, remote, tags, stashes), filter, `SidebarCommands`. |
| `Sources/SopranoGit/Views/Detail/`, `Views/Diff/` | Commit panel | Commit/stash details, working-copy staging + commit composer, diff view with hunk staging, `CommitPanelCommands`, `DiffCommands`. |
| `Sources/SopranoGit/Actions/` | Actions | `GitActions` flows, shared context menus, `GitActionCommands`. |

Modules talk only through the seams below. A module never reaches into another module's
views; it goes through `RepositoryController` (shared state), `RepoWorkspace` (focus,
panels, the other regions' public surface), `CommandRegistry` (commands by id), or
`GitActions` (git flows).

## Seams

### Core: `Repository`, `GitRunner` (`Sources/SopranoGitCore`)
Value-type, `Sendable`, `async` from any task. Reads parse machine formats; writes run
porcelain commands and throw `GitError` with git's stderr. Contract in the doc comments of
`Repository.swift` and `GitRunner.swift`; models in `Models.swift`.

Git invocation rules (all in `GitRunner`):
- `git --no-pager -c core.quotepath=false -c color.ui=never -c log.showSignature=false
  -c diff.noprefix=false -c diff.mnemonicPrefix=false -C <root> …`; reads add
  `--no-optional-locks` and `GIT_OPTIONAL_LOCKS=0`.
- Env: inherited + `GIT_TERMINAL_PROMPT=0`, `GIT_EDITOR=true`, askpass vars
  (`GIT_ASKPASS`, `SSH_ASKPASS` = app binary, `SSH_ASKPASS_REQUIRE=force`,
  `SOPRANO_GIT_ASKPASS=1`), `PATH` = settings `extraPath` + `/opt/homebrew/bin`,
  `/opt/homebrew/sbin`, `/usr/local/bin`, `~/.local/bin`, `~/.bun/bin`, `~/.cargo/bin` +
  inherited PATH.
- NUL-separated output wherever git offers it (`-z`, `%x00`, `%x1f` field separators).
- Message-taking commands get the message on stdin (`commit -F -`) or `--no-edit`.
- Diffs: `--no-color --no-ext-diff --no-textconv -U<n> -M`.

### `RepositoryController` (`Repo/RepositoryController.swift`)
One per tab, `@MainActor`. Holds `refs`, `stashes`, `status`, `commits` (paged),
`selection` (`.workingCopy` / `.commit` / `.stash`), `openDiff`, `activity`. Views read its
properties and observe `Event`s with `addObserver(self) { [weak self] event in … }`. All
git writes go through `run(_:refresh:_:)`, which logs, shows progress in the status bar,
refreshes, and reports failures (`.failed`) as an error toast. Full behavior contract in
its doc comment.

### `RepoWorkspace` (`Shell/Workspace.swift`)
The open tab. Gives access to the four region controllers, keyboard focus
(`focus(_:)`, `focusedRegion`, `addFocusObserver` — region headers highlight from it),
panel visibility, and selection providers.

Region controllers (`CommitGraphViewController`, `RefSidebarViewController`,
`CommitPanelViewController`, `DiffViewController`) keep their initializer
`init(controller:)` and `weak var workspace`, adopt `FocusRegionController`
(`focusRegion`, `focusRootView`, `takeFocus()`), and the first three adopt
`SelectionTargetProvider`.

Center area: the graph, replaced by the diff view while `controller.openDiff != nil`
(`showDiff(nil)` returns to the graph). Selecting a file anywhere calls
`controller.showDiff(OpenDiff(target:title:))`.

### Commands (`Commands/AppCommand.swift`)
Every user action is an `AppCommand` registered once at launch from its module's
`…Commands.all`. Commands are the single source for key bindings, the command palette,
menus, toolbar buttons, and the shortcut sheet. Commands act on `context.target`
(selection of the focused area, else the graph selection) or on `context.controller`.

### Settings, theme, keymap (`Shell/AppEnvironment.swift`)
- `~/.config/soprano-git/settings.json` (JSONC, `SOPRANO_GIT_CONFIG` overrides the path),
  live-reloaded; bad values become warnings, never launch failures (Soprano's
  `ConfigIssue` model).
- `theme`: a Soprano theme id, or `"soprano"` (default) to follow
  `~/.config/soprano/settings.json`'s `theme`, live; Mission Control when absent.
- `keybindings`: `prefixKey` (default `a` → ⌃A), `prefixTimeoutMs` (1500, 300–5000),
  `bindings: { "<command id>": "chord" | ["chord", …] | null }`.
- `ThemeCenter.shared.theme` + `addObserver`; `SettingsCenter.shared.settings`,
  `chords(for:)`, `shortcutText(for:)` + `addObserver`.

### `Dialogs` (`Shell/Dialogs.swift`) and `GitActions` (`Actions/GitActions.swift`)
`Dialogs.prompt/confirm/choose` are the only modal UI. `GitActions` are the only place a
git flow (ask → run → reselect) lives; context menus come from
`GitActions.contextMenu(for:in:)` so the graph and sidebar offer identical actions.

## Keyboard model

The router (Shell) is an `NSEvent` local monitor on keyDown, like Soprano's
`KeybindingManager`:

1. While a dialog, the palette, or the shortcut sheet is key, the router stays out.
2. **Prefix:** ⌃ + `prefixKey` enters prefix mode (status bar chip `PREFIX`) until the
   next key or the timeout. ⌃A ⌃A sends a literal ⌃A to the first responder.
3. **Scopes:** a command fires when its `scopes` contain the focused region, or its scopes
   are empty (global). A region-scoped binding beats a global one on the same chord.
4. **Text input:** chords without ⌘ or ⌃ never fire while a text field/view is first
   responder (typing "s" in the commit message types "s").
5. Events with ⌥ pass through untouched (German layouts type `@ [ ] { } | ~` with ⌥).
6. Symbol keys (`/ ? . , - =`) match ignoring Shift, so `?` (⇧ß) and `⌘/` (⌘⇧7) work on
   German layouts. Letters, digits and named keys compare Shift exactly.
7. Disabled commands let the event pass through.
8. Menu items show direct ⌘ chords as key equivalents; the router handles the key first.

### Default bindings

GitKraken's shortcuts where it has one; ⌃A prefix chords (Soprano) for the rest; single
keys inside lists (vim/lazygit). Owner = module that registers the command.

| Command id | Title | Scope | Keys | Owner |
|---|---|---|---|---|
| `palette.open` | Command Palette | global | ⌘P `cmd+p` | Shell |
| `help.shortcuts` | Keyboard Shortcuts | global | `cmd+/`, `?` | Shell |
| `settings.open` | Open settings.json | global | `cmd+,` | Shell |
| `repo.open` | Open Repository… | global | `cmd+o` | Shell |
| `repo.openRecent` | Open Recent Repository… | global | `cmd+shift+o` | Shell |
| `tab.new` / `tab.close` | New Tab / Close Tab | global | `cmd+t` / `cmd+w` | Shell |
| `tab.next` / `tab.previous` | Next / Previous Tab | global | `ctrl+tab` / `ctrl+shift+tab` | Shell |
| `tab.select.1`…`9` | Go to Tab N | global | `cmd+1`…`cmd+9` (not in palette) | Shell |
| `view.toggleSidebar` | Toggle Left Panel | global | `cmd+j` | Shell |
| `view.toggleCommitPanel` | Toggle Commit Panel | global | `cmd+k` | Shell |
| `focus.left` / `focus.right` | Focus Panel Left / Right | sidebar, graph, detail, diff | `h`, `prefix+h` / `l`, `prefix+l` | Shell |
| `toast.dismiss` | Dismiss Error | global (only while an error toast shows) | `escape` (not in palette) | Shell |
| `welcome.next` / `welcome.previous` / `welcome.open` | Recent repositories | welcome | `j` / `k` / `enter` (not in palette) | Shell |
| `repo.fetch` | Fetch All | global | `cmd+l`, `prefix+f` | Actions |
| `repo.pull` | Pull | global | `prefix+p` | Actions |
| `repo.push` | Push | global | `prefix+shift+p` | Actions |
| `branch.create` | Create Branch… | global | `cmd+b`, `b` | Actions |
| `stash.save` | Stash Changes | global | `prefix+s` | Actions |
| `stash.pop` | Pop Stash | global | `prefix+shift+s` | Actions |
| `operation.continue` | Continue Merge/Rebase/… | global | `prefix+c` | Actions |
| `operation.abort` | Abort Merge/Rebase/… | global | `prefix+x` | Actions |
| `operation.skip` | Skip Commit | global | — | Actions |
| `ref.checkout` | Checkout | graph, sidebar | `c` | Actions |
| `ref.merge` | Merge into Current Branch | graph, sidebar | `m` | Actions |
| `ref.rebase` | Rebase Current Branch onto… | graph, sidebar | `r` | Actions |
| `commit.cherryPick` | Cherry-pick Commit | graph | `p` | Actions |
| `commit.revert` | Revert Commit | graph | `v` | Actions |
| `commit.reset` | Reset Current Branch to Here… | graph | `shift+r` | Actions |
| `tag.create` | Create Tag Here… | graph, sidebar | `t` | Actions |
| `ref.delete` | Delete Branch/Tag/Stash… | sidebar | `d` | Actions |
| `branch.rename` | Rename Branch… | sidebar | `e` | Actions |
| `ref.copy` | Copy SHA / Name | graph, sidebar, detail | `y` | Actions |
| `branch.push`, `branch.setUpstream`, `stash.apply`, `tag.push` | — | — | palette/menu only | Actions |
| `graph.next` / `graph.previous` | Next / Previous Commit | graph | `j` / `k` (arrows native) | Graph |
| `graph.nextInBranch` / `graph.previousInBranch` | Follow First Parent / Child | graph | `shift+j` / `shift+k` | Graph |
| `graph.first` / `graph.last` | First / Last Commit | graph | `cmd+up`, `g` / `cmd+down`, `shift+g` | Graph |
| `graph.head` | Jump to HEAD | graph | `.` | Graph |
| `graph.workingCopy` | Jump to Working Copy | graph | `w` | Graph |
| `graph.search` | Search Commits | global | `cmd+f`, `/` | Graph |
| `graph.searchNext` / `graph.searchPrevious` | Next / Previous Match | graph | `cmd+g`, `n` / `cmd+shift+g`, `shift+n` | Graph |
| `graph.openDetails` | Focus Commit Panel | graph | `enter` | Graph |
| `sidebar.filter` | Filter Left Panel | global | `cmd+shift+f` | Sidebar |
| `sidebar.focusFilter` | Filter Left Panel | sidebar | `/` (not in palette) | Sidebar |
| `sidebar.next` / `sidebar.previous` | Next / Previous Ref | sidebar | `j` / `k` | Sidebar |
| `sidebar.activate` | Checkout / Reveal | sidebar | `enter` | Sidebar |
| `sidebar.toggle` | Expand / Collapse | sidebar | `space` | Sidebar |
| `panel.next` / `panel.previous` | Next / Previous File | detail | `j` / `k` | Commit panel |
| `panel.openFile` | Open Diff | detail | `enter`, `space` | Commit panel |
| `diff.openSelected` | Open Diff of Selected File | global | `cmd+d` | Commit panel |
| `wip.stageFile` / `wip.unstageFile` | Stage / Unstage Selected Files | detail | `s` / `u` | Commit panel |
| `wip.discardFile` | Discard Selected Changes… | detail | `d` | Commit panel |
| `wip.discardAll` | Discard All Unstaged Changes… | detail | `shift+d` | Commit panel |
| `wip.stageAll` / `wip.unstageAll` | Stage / Unstage All | global | `cmd+shift+s` / `cmd+shift+u` | Commit panel |
| `wip.commit` | Commit | global | `cmd+enter` | Commit panel |
| `wip.stageAllAndCommit` | Stage All and Commit | global | `cmd+shift+enter` | Commit panel |
| `wip.focusMessage` | Focus Commit Message | global | `cmd+shift+m` | Commit panel |
| `wip.toggleAmend` | Toggle Amend | detail | `a` | Commit panel |
| `conflict.takeOurs` / `conflict.takeTheirs` | Resolve with Ours / Theirs | detail | `o` / `t` | Commit panel |
| `diff.close` | Close Diff | diff | `escape` | Commit panel |
| `diff.nextHunk` / `diff.previousHunk` | Next / Previous Hunk | diff | `j` / `k` | Commit panel |
| `diff.nextFile` / `diff.previousFile` | Next / Previous File | diff | `shift+j` / `shift+k` | Commit panel |
| `diff.stageHunk` / `diff.unstageHunk` / `diff.discardHunk` | Stage / Unstage / Discard Hunk | diff | `s` / `u` / `d` | Commit panel |
| `diff.toggleLayout` | Toggle Split Diff (persisted app-wide; enabled whenever a tab is open) | diff | `v` | Commit panel |

## Layout and visual design

Everything uses the vendored chrome: `Retro*` components, `ThemeColors` tokens, Departure
Mono via `RetroFont.display` at **11 or 22 pt only** (small caps, never uppercase strings
by hand), `RetroFont.body` for running text (messages, paths, diff text, inputs). Square
corners; lamps (`RetroLamp`) are the only round chrome. Appearance forced to `.darkAqua`.

```
┌ tab bar 34pt: traffic-light inset 78pt · repo tabs (selected = accent block) · + ┐
├ toolbar 40pt: repo · ⎇ branch ↑a ↓b │ PULL PUSH │ BRANCH │ STASH POP │ … ⌘P      ┤
╞═══════════════ double rule ═══════════════════════════════════════════════════╡
│ sidebar 240 (180–420) │ center: banner? + graph | diff │ commit panel 380 (300–600)│
├ status bar 24pt: mode chip · activity lamp + text · ⎇ branch · N commits        ┤
```

- Surfaces: window `bgBase`, panels `bgPanel`, inputs/strips `bgRaised`, hover `bgOverlay`.
- Rows (`Views/Common`): selection `bgSelectedStrong` + 2 pt `accent` leading rail when
  the region has focus, `bgSelected` + `railMuted` rail when not; hover `bgOverlay`.
- Shared kit in `Views/Common`: `RetroTableView` / `RetroOutlineView` (hover tracking,
  vend `RetroRowView`), `RetroListStyle.apply(to:theme:rowHeight:)` /
  `makeScrollView(documentView:theme:)`, `PanelHeaderView` (`isFocused` → focus bar),
  `KeycapView`, `RetroSearchField`, `ChangeKindBadge`, `RetroCheckbox`,
  `DateText.format(_:style:)`. Leaf views re-style through `apply(theme:)`.
- Headings: `RetroHeadingView` (`LOCAL ─────`). Dividers: `RetroRuleView` (double between
  toolbar and body, single hairlines `borderSubtle` between panels).
- Focused panel: its header gets `bgRaised` + 4 pt `accent` leading bar (Soprano
  `PaneHeaderView`).
- Change kinds: modified `yellow`, added/untracked `success`, deleted/conflict `danger`,
  renamed/copied `cyan`, type change `blue`.
- Diff tints: added `success` α0.14, removed `danger` α0.14. Split fillers `textMuted`
  α0.06 with a diagonal `borderSubtle` hatch; a `borderSubtle` hairline divides the sides.
  Syntax colors use Soprano's editor mapping (`SyntaxTokenKind.color(in:)`).
- Graph: 28 pt rows; lanes 14 pt apart, 2 pt lines; commit nodes are lamps (10 pt, merges
  7 pt hollow), HEAD gets a ring, stashes a small square, the working copy a dashed ring.
  Lane colors come from the theme. Ref pills in the first column, display face 11, square,
  tinted with the lane color; HEAD's branch pill is lit.
- Toolbar keys are `RetroButton`s with their shortcut as a keycap hint.
- Working-Copy-Panel: Ohne Dateiauswahl stehen „Discard all“ und „Stage all“ im
  Unstaged-Abschnitt. Mit Auswahl zeigen die Abschnitts- und Zeilenaktionen deren
  Anzahl („Stage N“, „Discard N“, im Staged-Abschnitt „Unstage N“); sie bearbeiten
  nur die ausgewählten Pfade desselben Abschnitts. Bei wenig Platz entfallen
  die Shortcut-Hinweise. Discard bestätigt die Anzahl und das Löschen ungetrackter
  Dateien; nicht ausgewählte Dateien, Index und Konflikte bleiben unverändert.
- `PanelFileTableView` erweitert `RetroTableView` um Ctrl-/⌘-Klick zum Umschalten
  einzelner Dateien und ⇧-Klick für Bereiche; Abschnittsüberschriften sind nicht
  auswählbar. Modifizierte Klicks öffnen keinen Diff; ein einfacher Klick ersetzt
  die Auswahl und öffnet den Diff. AppKit übernimmt weiterhin die Tastaturauswahl.
  Der Controller erhält bei Statusaktualisierungen alle überlebenden
  `(section, path)`-Identitäten; das Öffnen eines bereits ausgewählten Diffs
  reduziert die Mehrfachauswahl nicht.

## Verification harness

`SopranoGit snapshot --repo <path> --out <png> [--size 1500x940] [--theme <id>]
[--keys "<chord> <chord> …"] [--wait <seconds>] [--recent <path>,…]
[--dialog prompt|confirm|choose|alert] [--fail <operation title>]
[--select wip|stash:<N>|<commit-ish>] [--diff unstaged:<path>|staged:<path>|<commit-ish>:<path>]
[--focus sidebar|graph|detail|diff] [--click-file [ctrl+|cmd+|shift+]<section>:<path>]` builds the real main
window offscreen (no Dock icon, no visible window, no persisted state), loads the repo
(welcome screen without `--repo`; `--recent` seeds its list), opens a sample dialog
(`--dialog`) or runs a failing operation through `controller.run` (`--fail`, error
toast), applies `--select` (controller selection), `--diff` (`controller.showDiff`) and
`--focus` (workspace focus), replays `--keys` through the keyboard router (into the dialog or panel while one
is shown), waits for async work to settle, and writes a PNG of the window including
dialogs and child panels (rendered through Core Animation, so lamps and fills are
exact). Offscreen, dialogs show as child panels at the sheet position, since AppKit
moves a sheet's parent on screen. Agents verify UI with it and `read` the PNG; they do
not launch the GUI.

`--click-file` ist wiederholbar: Die Klicks laufen in der angegebenen Reihenfolge
nach der Ansichts-/Fokuseinstellung und vor `--keys` über den echten Mouse-Down-Pfad
der Dateiliste, ohne das Fenster zu aktivieren. Abschnitte: `unstaged`, `staged`,
`conflicts`, `files`; Modifikatoren lassen sich kombinieren, etwa
`cmd+shift+staged:README.md`. Pfade mit Leerzeichen als ein Shell-Argument übergeben.

```bash
.build/debug/SopranoGit snapshot --repo /tmp/sg-fx/work --select wip \
  --click-file 'ctrl+unstaged:docs/guide.md' --click-file 'cmd+unstaged:notes.txt' \
  --keys s --out /tmp/selected-staged.png
```

`scripts/make-fixture-repo.sh <dir> [--conflict]` builds a disposable, deterministic repo
(branches, merges, remote with ahead/behind, tags, stashes, staged/unstaged/untracked
changes, a rename, a binary file; `--conflict` leaves a merge paused on conflicts).
**Only fixture repos may receive write operations or `--keys` that write.** Real repos
(e.g. `~/git/private/soprano`) are fine for read-only snapshots.

## Tests

swift-testing (`import Testing`, `@Test`, `#expect`), one `struct …Tests` per file,
sentence-style names. Test files `import AppKit` (never `Foundation`) plus
`@testable import SopranoGit` / `SopranoGitCore`. Integration tests run real git in a
temp directory with an isolated config: `HOME=<tmp>`, `GIT_CONFIG_NOSYSTEM=1`,
`GIT_CONFIG_GLOBAL=<tmp>/gitconfig` (user, `init.defaultBranch=main`,
`commit.gpgsign=false`), fixed `GIT_AUTHOR_DATE`/`GIT_COMMITTER_DATE`. Never touch the
user's repositories or settings. Tests that show a dialog run inside
`DialogTurn.exclusive { … }`: `Dialogs.current` is app-wide and suites run in parallel.

Out of scope for now: see `docs/ROADMAP.md`.
