#!/bin/bash
# Renders the Folio app icon with scripts/render-app-icon.swift (Soprano-owned, vendored by
# scripts/sync-soprano-chrome.sh) as an Icon Composer document, compiles it with Xcode's
# actool into Support/Assets.car (Paper, Ink, tinted and clear variants) and writes the
# Support/AppIcon.icns fallback: every iconset member is the Default appearance rendered by
# Icon Composer's ictool at the body size (824 of 1024), padded to the macOS icon canvas
# (actool's own .icns stops at 256 px). Both are committed, so packaging needs no Xcode;
# this script does (Xcode 26 or later, default /Applications/Xcode.app, override with
# XCODE_DIR).
# Usage: render-app-icon.sh [icon-output]
# The optional argument keeps a copy of the AppIcon.icon document at that path.
set -euo pipefail

if [[ $# -gt 1 ]]; then
    echo "Usage: $0 [icon-output]" >&2
    exit 2
fi
# The copy replaces only an earlier .icon document, never an unrelated path.
if [[ $# -eq 1 ]]; then
    if [[ "$1" != *.icon ]]; then
        echo "The icon output must end in .icon: $1" >&2
        exit 2
    fi
    if [[ -e "$1" && ! -f "$1/icon.json" ]]; then
        echo "Refusing to replace $1: it exists and is not an Icon Composer document" >&2
        exit 2
    fi
fi

xcode_app="${XCODE_DIR:-/Applications/Xcode.app}"
xcode_developer="$xcode_app/Contents/Developer"
actool="$xcode_developer/usr/bin/actool"
ictool="$xcode_app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
for tool in "$actool" "$ictool"; do
    if [[ ! -x "$tool" ]]; then
        echo "Missing $tool (needs Xcode 26 or later; set XCODE_DIR)" >&2
        exit 1
    fi
done

export DEVELOPER_DIR=/Library/Developer/CommandLineTools
export PATH="/opt/homebrew/opt/swift/bin:$PATH"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
support_dir="$repo_root/Support"

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/soprano-git-icon.XXXXXX")"
cleanup() {
    rm -rf "$work_dir"
}
trap cleanup EXIT

icon_document="$work_dir/AppIcon.icon"
swift "$script_dir/render-app-icon.swift" git "$icon_document"

compiled="$work_dir/compiled"
mkdir -p "$compiled"
if ! DEVELOPER_DIR="$xcode_developer" "$actool" "$icon_document" \
    --compile "$compiled" \
    --app-icon AppIcon \
    --platform macosx \
    --minimum-deployment-target 14.0 \
    --output-partial-info-plist "$work_dir/partial-info.plist" \
    >"$work_dir/actool.log" 2>&1; then
    echo "actool failed:" >&2
    cat "$work_dir/actool.log" >&2
    exit 1
fi
if [[ ! -s "$compiled/Assets.car" ]]; then
    echo "actool produced no Assets.car:" >&2
    cat "$work_dir/actool.log" >&2
    exit 1
fi

# One iconset member: the tile at 824/1024 of the member size, centred on a transparent canvas.
render_member() {
    local pixels="$1" output="$2"
    local tile=$(((pixels * 824 + 512) / 1024))
    rm -f "$work_dir/tile.png"
    if ! "$ictool" "$icon_document" --export-image --output-file "$work_dir/tile.png" \
        --platform macOS --rendition Default --width "$tile" --height "$tile" --scale 1 \
        >"$work_dir/ictool.log" 2>&1 || [[ ! -s "$work_dir/tile.png" ]]; then
        echo "ictool failed for $pixels px:" >&2
        cat "$work_dir/ictool.log" >&2
        exit 1
    fi
    /usr/bin/sips --padToHeightWidth "$pixels" "$pixels" "$work_dir/tile.png" --out "$output" >/dev/null
}

iconset="$work_dir/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
    render_member "$size" "$iconset/icon_${size}x${size}.png"
    render_member $((size * 2)) "$iconset/icon_${size}x${size}@2x.png"
done
/usr/bin/iconutil -c icns -o "$work_dir/AppIcon.icns" "$iconset"

mv -f "$compiled/Assets.car" "$support_dir/Assets.car"
mv -f "$work_dir/AppIcon.icns" "$support_dir/AppIcon.icns"
echo "Wrote $support_dir/Assets.car and $support_dir/AppIcon.icns"

if [[ $# -eq 1 ]]; then
    rm -rf "$1"
    mkdir -p "$(dirname "$1")"
    cp -R "$icon_document" "$1"
    echo "Wrote $1"
fi
