#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
build_root="$(mktemp -d "${TMPDIR:-/tmp}/spotlight-emoji-build.XXXXXX")"
trap 'rm -rf "$build_root"' EXIT
xcodebuild -project "$repo_root/SpotlightEmoji.xcodeproj" -scheme SpotlightEmoji \
  -configuration Release -derivedDataPath "$build_root" -jobs 2 build
built_app="$build_root/Build/Products/Release/Spotlight Emoji.app"
"$built_app/Contents/MacOS/Spotlight Emoji" --check-search
mkdir -p "$HOME/Applications"
ditto "$built_app" "$HOME/Applications/Spotlight Emoji.app"
printf 'Installed Spotlight Emoji. Open it once to add emoji to Spotlight.\n'
open "$HOME/Applications/Spotlight Emoji.app"
