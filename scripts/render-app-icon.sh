#!/bin/bash
# Renders the app icon from scripts/render-app-icon.swift and writes
# Sources/SopranoGit/Resources/AppIcon.icns. Usage: render-app-icon.sh [png-output]
# The optional argument keeps a copy of the 1024×1024 master PNG at that path.
set -euo pipefail

if [[ $# -gt 1 ]]; then
    echo "Usage: $0 [png-output]" >&2
    exit 2
fi

export DEVELOPER_DIR=/Library/Developer/CommandLineTools
export PATH="/opt/homebrew/opt/swift/bin:$PATH"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
icns_path="$repo_root/Sources/SopranoGit/Resources/AppIcon.icns"

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/soprano-git-icon.XXXXXX")"
cleanup() {
    rm -rf "$work_dir"
}
trap cleanup EXIT

master_png="$work_dir/app-icon.png"
swift "$script_dir/render-app-icon.swift" "$master_png"

iconset="$work_dir/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
    /usr/bin/sips -z "$size" "$size" "$master_png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    /usr/bin/sips -z "$double" "$double" "$master_png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done

staged_icns="$work_dir/AppIcon.icns"
/usr/bin/iconutil -c icns -o "$staged_icns" "$iconset"
mv -f "$staged_icns" "$icns_path"
echo "Wrote $icns_path"

if [[ $# -eq 1 ]]; then
    mkdir -p "$(dirname "$1")"
    cp "$master_png" "$1"
    echo "Wrote $1"
fi
