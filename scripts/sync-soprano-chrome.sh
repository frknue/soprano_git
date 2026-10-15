#!/bin/bash
set -euo pipefail

# Copies Soprano's design system and shared infrastructure into this repo.
# Soprano is the source of truth: never edit the files under
# Sources/SopranoGit/Vendored/ here. Change them in Soprano, commit there, then
# re-run this script.
#
# Usage: scripts/sync-soprano-chrome.sh [soprano-checkout] [ref]
#   soprano-checkout  absolute path; defaults to $SOPRANO_DIR or ~/git/private/soprano
#   ref               commit-ish; defaults to HEAD. Files come from that commit,
#                     so uncommitted work in the Soprano checkout is never copied.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$script_dir/.." && pwd)"
soprano_dir="${1:-${SOPRANO_DIR:-$HOME/git/private/soprano}}"
ref="${2:-HEAD}"

if [[ "$soprano_dir" != /* ]]; then
    echo "The Soprano checkout must be an absolute path: $soprano_dir" >&2
    exit 1
fi
if ! git -C "$soprano_dir" rev-parse --verify --quiet "$ref^{commit}" >/dev/null; then
    echo "No commit '$ref' in Soprano checkout $soprano_dir" >&2
    exit 1
fi
commit="$(git -C "$soprano_dir" rev-parse "$ref^{commit}")"

# source path in Soprano  →  destination path in this repo
files=(
    "Sources/Soprano/Views/RetroChrome.swift|Sources/SopranoGit/Vendored/RetroChrome.swift"
    "Sources/Soprano/Config/Theme.swift|Sources/SopranoGit/Vendored/Theme.swift"
    "Sources/Soprano/Utilities/NSColor+Hex.swift|Sources/SopranoGit/Vendored/NSColor+Hex.swift"
    "Sources/Soprano/Controllers/ThemeManager.swift|Sources/SopranoGit/Vendored/ThemeManager.swift"
    "Sources/Soprano/Models/KeyBinding.swift|Sources/SopranoGit/Vendored/KeyBinding.swift"
    "Sources/Soprano/Config/KeyChord.swift|Sources/SopranoGit/Vendored/KeyChord.swift"
    "Sources/Soprano/Config/JSONCText.swift|Sources/SopranoGit/Vendored/JSONCText.swift"
    "Sources/Soprano/Views/CommandPalettePanel.swift|Sources/SopranoGit/Vendored/CommandPalettePanel.swift"
    "Sources/Soprano/Controllers/FileSystemWatcher.swift|Sources/SopranoGit/Vendored/FileSystemWatcher.swift"
    "Sources/Soprano/Utilities/AppVersion.swift|Sources/SopranoGit/Vendored/AppVersion.swift"
    "Sources/Soprano/Views/CodeSyntaxHighlighter.swift|Sources/SopranoGit/Vendored/CodeSyntaxHighlighter.swift"
    "Sources/Soprano/App/MainWindowSizing.swift|Sources/SopranoGit/Vendored/MainWindowSizing.swift"
    "Sources/Soprano/Resources/DepartureMono-Regular.woff2|Sources/SopranoGit/Resources/DepartureMono-Regular.woff2"
    "Support/Licenses/LICENSE-departure-mono|Support/Licenses/LICENSE-departure-mono"
)

staging="$(mktemp -d)"
cleanup() { rm -rf "$staging"; }
trap cleanup EXIT

# Stage everything first so a missing file leaves the repo untouched.
for entry in "${files[@]}"; do
    source_path="${entry%%|*}"
    staged="$staging/${entry##*|}"
    mkdir -p "$(dirname "$staged")"
    if ! git -C "$soprano_dir" show "$commit:$source_path" >"$staged"; then
        echo "Soprano $commit has no $source_path" >&2
        exit 1
    fi
done

for entry in "${files[@]}"; do
    destination="$root/${entry##*|}"
    mkdir -p "$(dirname "$destination")"
    mv "$staging/${entry##*|}" "$destination"
done

printf '%s\n' "$commit" >"$root/Sources/SopranoGit/Vendored/SOPRANO_COMMIT"
printf 'Synced %d files from Soprano %s\n' "${#files[@]}" "$commit"
