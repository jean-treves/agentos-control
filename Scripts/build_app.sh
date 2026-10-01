#!/usr/bin/env bash
# `zsh build_app.sh` reads this file as zsh (no shopt): run it under bash instead.
[ -n "$ZSH_VERSION" ] && exec bash "$0" "$@"
# Release build → ad hoc signature → "/Applications/AgentOS.app", then archive the former
# "AgentOS Control.app" (moved, never deleted; spec §16.2). Idempotent: rerun after every change.
# APPS_DIR / ARCHIVE_DIR override the destinations, to test the script away from /Applications.
set -euo pipefail

cd "$(dirname "$0")/.."
readonly APP_NAME="AgentOS"
readonly APPS_DIR="${APPS_DIR:-/Applications}"
readonly ARCHIVE_DIR="${ARCHIVE_DIR:-$HOME/PyCharmMiscProject/_a-trier}"
readonly DEST="$APPS_DIR/$APP_NAME.app"
readonly OLD_APP="$APPS_DIR/AgentOS Control.app"
readonly BUILT="build/Build/Products/Release/$APP_NAME.app"

die() { echo "build_app: $*" >&2; exit 1; }

# Never move or overwrite a bundle whose code is running.
if pgrep -f "$OLD_APP/Contents/MacOS/" >/dev/null; then die "AgentOS Control tourne : menu › Quitter d'abord"; fi
if pgrep -f "$DEST/Contents/MacOS/" >/dev/null; then die "AgentOS tourne : menu › Quitter d'abord"; fi

[[ -f AgentOSControl/Assets.xcassets/AppIcon.appiconset/Contents.json ]] || swift Scripts/make_icon.swift
xcodegen generate --quiet
# The log hides Xcode 27's harmless CoreSimulator/CoreDevice noise; it is shown only on failure.
mkdir -p build
if ! xcodebuild -project AgentOSControl.xcodeproj -scheme AgentOSControl -configuration Release \
  -derivedDataPath build build -quiet >build/build_app.log 2>&1; then
  grep -E 'error:|BUILD FAILED' build/build_app.log >&2 || tail -n 40 build/build_app.log >&2
  die "build Release en échec (journal complet : build/build_app.log)"
fi
codesign --force --sign - "$BUILT"

mkdir -p "$APPS_DIR"
rsync -a --delete "$BUILT/" "$DEST/"
codesign --verify --strict "$DEST"
echo "installé : $DEST ($(codesign -dv "$DEST" 2>&1 | grep -o 'Signature=.*'))"

# Build copies share the bundle id: Spotlight opened the Xcode Debug build instead of this one
# (T9.6, 2026-09-30). Keep only $DEST in Launch Services; the copies stay on disk.
readonly LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
shopt -s nullglob
for copy in build/Build/Products/*/"$APP_NAME.app" \
            "$HOME"/Library/Developer/Xcode/DerivedData/AgentOSControl-*/Build/Products/*/"$APP_NAME.app"; do
  "$LSREGISTER" -u "$copy" 2>/dev/null || true
done
shopt -u nullglob
"$LSREGISTER" -f "$DEST"

if [[ -d "$OLD_APP" ]]; then
  mkdir -p "$ARCHIVE_DIR"
  # No .app suffix: the archive must not register as a second launchable app.
  target="$ARCHIVE_DIR/AgentOS Control.app.archive-$(date +%Y%m%d-%H%M%S)"
  mv "$OLD_APP" "$target"
  echo "ancienne app archivée : $target"
else
  echo "AgentOS Control absente de $APPS_DIR : rien à archiver"
fi
