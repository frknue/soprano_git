#!/usr/bin/env bash
# Builds a deterministic Git fixture: <dir>/origin.git (bare) + <dir>/work (clone).
# Usage: scripts/make-fixture-repo.sh <absolute-dir> [--conflict]
# Prints only the absolute path of the work repo on stdout.
set -euo pipefail

usage() {
	echo "usage: $0 <absolute-dir> [--conflict]" >&2
	exit 2
}

[[ $# -ge 1 && $# -le 2 ]] || usage
DIR=$1
CONFLICT=0
if [[ $# -eq 2 ]]; then
	[[ $2 == --conflict ]] || usage
	CONFLICT=1
fi

strip_slashes() {
	local p=$1
	while [[ ${#p} -gt 1 && $p == */ ]]; do p=${p%/}; done
	printf '%s' "$p"
}
DIR=$(strip_slashes "$DIR")
[[ $DIR == /* ]] || usage
[[ $DIR != / ]] || usage
[[ $DIR != "$(strip_slashes "${HOME:-/}")" ]] || usage

rm -rf "$DIR"
mkdir -p "$DIR"
ORIGIN=$DIR/origin.git
WORK=$DIR/work

# --- Isolation ---------------------------------------------------------------
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
	GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE GIT_COMMON_DIR \
	GIT_CONFIG GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT \
	GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL \
	GIT_AUTHOR_DATE GIT_COMMITTER_DATE GIT_TEMPLATE_DIR GIT_EXEC_PATH 2>/dev/null || true
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=$DIR/gitconfig
export GIT_TERMINAL_PROMPT=0
export GIT_EDITOR=true
export GIT_MERGE_AUTOEDIT=no
export LC_ALL=C

cat >"$GIT_CONFIG_GLOBAL" <<'EOF'
[user]
	name = Fixture Author
	email = fixture@example.com
[init]
	defaultBranch = main
[commit]
	gpgsign = false
[tag]
	gpgsign = false
[core]
	autocrlf = false
[advice]
	detachedHead = false
[merge]
	conflictStyle = merge
[pull]
	rebase = false
EOF

# --- Helpers -----------------------------------------------------------------
T=1700000000
N=0
AUTHORS=("Fixture Author" "Ada Lovelace" "Grace Hopper")
EMAILS=("fixture@example.com" "ada@example.com" "grace@example.com")

tick() {
	T=$((T + 3600))
	export GIT_AUTHOR_DATE="@$T +0000"
	export GIT_COMMITTER_DATE="@$T +0000"
}

# All git output goes to stderr so stdout carries only the final path.
g() { git -C "$WORK" "$@" >&2; }

put() { # put <relpath> <content...>
	mkdir -p "$(dirname "$WORK/$1")"
	printf '%s\n' "${@:2}" >"$WORK/$1"
}

add() { # add <relpath> <line>
	mkdir -p "$(dirname "$WORK/$1")"
	printf '%s\n' "$2" >>"$WORK/$1"
}

commit() { # commit <message> [extra -m paragraphs...]
	tick
	local i=$((N % ${#AUTHORS[@]}))
	N=$((N + 1))
	local args=(-m "$1")
	local p
	for p in "${@:2}"; do args+=(-m "$p"); done
	g add -A
	GIT_AUTHOR_NAME=${AUTHORS[$i]} GIT_AUTHOR_EMAIL=${EMAILS[$i]} \
		g commit -q "${args[@]}"
}

# --- Repos -------------------------------------------------------------------
git init -q --bare -b main "$ORIGIN" >&2
git clone -q "$ORIGIN" "$WORK" >&2 2>/dev/null

# --- Main history ------------------------------------------------------------
put README.md "# Fixture" "" "A deterministic repository for Soprano Git tests."
put src/main.txt "main v1"
put src/util.txt "util v1"
put docs/guide.md "# Guide"
commit "Initial commit"

mkdir -p "$WORK/assets"
printf '\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x02\x00\x00\x00\x90wS\xde' >"$WORK/assets/logo.png"
commit "Add logo"

put "docs/Über Notizen/naïve file.md" "# Naïve notes" "Ümlaut and spaces in the path."
commit "Add notes with non-ASCII path"

for i in $(seq 1 20); do
	case $((i % 4)) in
	0) add src/main.txt "main line $i" ;;
	1) add src/util.txt "util line $i" ;;
	2) add docs/guide.md "Guide section $i" ;;
	3) add README.md "Readme note $i" ;;
	esac
	if ((i % 5 == 0)); then
		commit "Update batch $i" "This commit spans a longer description so that
multi-line messages are covered by the fixture." "Refs: #$i"
	else
		commit "Update batch $i"
	fi
done

git -C "$WORK" tag v0.1

g mv src/util.txt src/helpers.txt
commit "Rename util to helpers" "The util module is now called helpers."

for i in $(seq 21 30); do
	if ((i % 2)); then add src/helpers.txt "helpers line $i"; else add src/main.txt "main line $i"; fi
	commit "Refine sources $i"
done

printf '\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x00\x02\x00\x00\x00\x02\x08\x06\x00\x00\x00\xff\x01\x02' >"$WORK/assets/logo.png"
commit "Update logo"

add "docs/Über Notizen/naïve file.md" "More notes."
commit "Expand notes"

tick
g tag -a v1.0 -m "Release 1.0"

# feature/merged: merged into main with --no-ff
g checkout -q -b feature/merged
for i in 1 2 3; do
	add src/feature-merged.txt "merged feature step $i"
	commit "feature/merged: step $i"
done
g checkout -q main
add docs/guide.md "Main work while feature/merged was in flight"
commit "Document parallel work"
tick
g merge -q --no-ff feature/merged -m "Merge branch 'feature/merged'"

g push -q -u origin main
g push -q origin --tags

# feature/rebased: started earlier, rebased onto main
g checkout -q -b feature/rebased main~3
for i in 1 2 3; do
	add src/feature-rebased.txt "rebased feature step $i"
	commit "feature/rebased: step $i"
done
g checkout -q main
for i in $(seq 31 40); do
	add src/main.txt "main line $i"
	commit "Continue main $i"
done
g checkout -q feature/rebased
tick
g rebase -q main
g push -q -u origin feature/rebased
g checkout -q main

# feature/remote-only: exists only on origin
g checkout -q -b feature/remote-only
for i in 1 2; do
	add src/remote-only.txt "remote only step $i"
	commit "feature/remote-only: step $i"
done
g push -q origin feature/remote-only
g checkout -q main
g branch -q -D feature/remote-only

# Files the two local-only commits (and --conflict) will touch.
put src/conflict.txt "shared line 1" "shared line 2" "shared line 3"
put src/doomed.txt "this file will be modified on main and deleted on feature/conflict"
commit "Add conflict candidates"
for i in $(seq 41 46); do
	add docs/guide.md "Guide section $i"
	commit "Polish guide $i"
done
g push -q origin main

# Behind by 1: a commit pushed from a temporary second clone.
TMP_CLONE=$DIR/tmp-clone
git clone -q "$ORIGIN" "$TMP_CLONE" >&2
tick
printf '%s\n' "upstream change" >>"$TMP_CLONE/README.md"
git -C "$TMP_CLONE" add README.md >&2
GIT_AUTHOR_NAME="Grace Hopper" GIT_AUTHOR_EMAIL="grace@example.com" \
	git -C "$TMP_CLONE" commit -q -m "Upstream-only change" >&2
git -C "$TMP_CLONE" push -q origin main >&2
rm -rf "$TMP_CLONE"
g fetch -q origin

# Ahead by 2: local commits not pushed.
put src/conflict.txt "shared line 1" "main changed line 2" "shared line 3"
commit "Change line 2 on main"
add src/doomed.txt "main touched this file"
commit "Touch doomed file on main"

# --- Stashes -----------------------------------------------------------------
add src/main.txt "stashed change"
tick
g stash push -q -m "Older plain stash"
add src/helpers.txt "second stashed change"
put scratch/untracked-in-stash.txt "untracked content kept in stash"
tick
g stash push -q --include-untracked -m "Newer stash with untracked file"

if ((CONFLICT)); then
	# --- Paused merge with UU + UD -------------------------------------------
	g checkout -q -b feature/conflict main~2
	put src/conflict.txt "shared line 1" "feature changed line 2" "shared line 3"
	commit "Change line 2 on feature"
	g rm -q src/doomed.txt
	commit "Delete doomed file on feature"
	g checkout -q main
	tick
	if g merge feature/conflict -m "Merge branch 'feature/conflict'"; then
		echo "error: expected merge to conflict" >&2
		exit 1
	fi
else
	# --- Dirty working copy --------------------------------------------------
	add README.md "staged modification"
	g add README.md
	put src/staged-new.txt "a new staged file"
	g add src/staged-new.txt
	add src/main.txt "unstaged modification"
	add docs/guide.md "staged part"
	g add docs/guide.md
	add docs/guide.md "unstaged part"
	put notes.txt "untracked at root"
	put "untracked dir/inner file.txt" "untracked inside a new directory"
fi

printf '%s\n' "$WORK"
