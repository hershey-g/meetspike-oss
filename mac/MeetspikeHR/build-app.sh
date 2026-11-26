#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
if [[ "$(uname -s)" != Darwin ]]; then
    printf '%s\n' 'Building the app bundle requires macOS.' >&2
    exit 1
fi

swift build --configuration release
bin_dir="$(swift build --configuration release --show-bin-path)"
app_dir="$PWD/.build/MeetspikeHR.app"

plutil -lint Info.plist
mkdir -p "$app_dir/Contents/MacOS"
install -m 755 "$bin_dir/MeetspikeHR" "$app_dir/Contents/MacOS/MeetspikeHR"
install -m 644 Info.plist "$app_dir/Contents/Info.plist"
mkdir -p "$app_dir/Contents/Resources"
install -m 644 Resources/AppIcon.icns "$app_dir/Contents/Resources/AppIcon.icns"
codesign --force --sign "${MEETSPIKE_SIGN_IDENTITY:--}" "$app_dir"
codesign --verify --strict "$app_dir"
printf '%s\n' "$app_dir"
