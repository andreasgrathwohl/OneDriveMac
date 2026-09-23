#!/bin/bash
# Klont bzw. aktualisiert das Repository, baut "OneDrive Opener.app" und installiert sie nach /Applications.
#
#   bash install-mac.sh <Repo-URL> [Branch]
#
# Optionale Umgebungsvariablen: DEST (Arbeitsordner), BUNDLE_ID, SIGN_IDENTITY (siehe build.sh)
set -euo pipefail

REPO_URL="${1:-${REPO_URL:-}}"
BRANCH="${2:-${BRANCH:-main}}"
DEST="${DEST:-$HOME/Developer/OneDriveMac}"
APP_NAME="OneDrive Opener"

if [[ -z "$REPO_URL" && ! -d "$DEST/.git" ]]; then
  echo "Aufruf: bash install-mac.sh <Repo-URL> [Branch]" >&2
  exit 1
fi

if ! xcode-select -p >/dev/null 2>&1; then
  echo "→ Xcode Command Line Tools fehlen – Installation wird gestartet."
  xcode-select --install || true
  echo "Nach Abschluss der Installation dieses Skript bitte erneut ausführen."
  exit 1
fi

if [[ -d "$DEST/.git" ]]; then
  echo "→ Aktualisiere $DEST"
  git -C "$DEST" fetch --prune
  git -C "$DEST" checkout "$BRANCH"
  git -C "$DEST" pull --ff-only
else
  echo "→ Klone $REPO_URL nach $DEST"
  mkdir -p "$(dirname "$DEST")"
  git clone --branch "$BRANCH" "$REPO_URL" "$DEST"
fi

cd "$DEST"

if [[ -w /Applications ]]; then
  bash build.sh install
else
  bash build.sh
  TARGET="/Applications/$APP_NAME.app"
  echo "→ Installation nach /Applications benötigt Administratorrechte"
  osascript -e "quit app \"$APP_NAME\"" 2>/dev/null || true
  sudo rm -rf "$TARGET"
  sudo cp -R "build/$APP_NAME.app" "$TARGET"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$TARGET"
  open "$TARGET"
  echo "✓ Installiert: $TARGET"
fi

echo
echo "Fertig. Im Menüleisten-Symbol → Einstellungen → „OneDrive Opener als Standard festlegen“ klicken."
