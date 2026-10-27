#!/bin/bash
# Double-click to update and launch AeroBench: pulls the latest code, syncs
# the engine, rebuilds the app (incrementally) and opens it. If a step fails
# it says why and launches the last build that worked.
#
#   ./AeroBench.command               update, build, launch
#   ./AeroBench.command --no-pull     skip git pull
#   ./AeroBench.command --no-launch   build only (used by CI)

# Everything is in a function so bash reads the whole file before running
# it: git pull may rewrite this very script.
main() {
  cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
  export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$HOME/.cargo/bin:$PATH"

  PULL=1
  LAUNCH=1
  for arg in "$@"; do
    case "$arg" in
      --no-pull) PULL=0 ;;
      --no-launch) LAUNCH=0 ;;
    esac
  done

  APP="build/DerivedData/Build/Products/Release/AeroBench.app"
  LOG="build/last-build.log"
  mkdir -p build

  step() { printf '\n\033[1m%s\033[0m\n' "$1"; }
  warn() { printf '\033[33m%s\033[0m\n' "$1"; }
  fail() { printf '\033[31m%s\033[0m\n' "$1"; }

  if [ "$PULL" = 1 ]; then
    step "Getting the latest version"
    if ! git diff --quiet || ! git diff --cached --quiet; then
      warn "You have local changes, so the update was skipped (git status shows them)."
    elif ! git pull --ff-only; then
      warn "Could not update (offline?). Carrying on with what you have."
    fi
  fi

  step "Updating the engine"
  if ! command -v uv >/dev/null 2>&1; then
    fail "uv is not installed. Install it with: brew install uv"
  elif ! (cd engine && uv sync --frozen --quiet); then
    warn "The engine could not be updated. The app will still open, but jobs may fail."
  fi

  step "Building the app (only what changed; the first build takes a minute or two)"
  if xcodebuild -project app/AeroBench.xcodeproj -scheme AeroBench -configuration Release \
       -derivedDataPath build/DerivedData -destination 'platform=macOS,arch=arm64' build >"$LOG" 2>&1; then
    echo "Built."
  else
    fail "The build failed. The first errors:"
    grep -m 10 'error:' "$LOG" || tail -20 "$LOG"
    echo "Full log: $(pwd)/$LOG"
    if [ "$LAUNCH" = 0 ]; then exit 1; fi
    [ -d "$APP" ] && warn "Opening the last build that worked."
  fi

  if [ "$LAUNCH" = 1 ]; then
    if [ ! -d "$APP" ]; then
      fail "There is no app to open yet."
      read -r -p "Press Return to close." _
      exit 1
    fi
    # Quit a running copy so the new build is the one that opens.
    osascript -e 'if application "AeroBench" is running then tell application "AeroBench" to quit' >/dev/null 2>&1
    sleep 1
    open "$APP"
    step "AeroBench is open. You can close this window."
  fi
}

main "$@"
exit
