#!/usr/bin/env bash
# Canary mobile gate: backfill platform dirs (if needed), resolve deps, static analyze.
# Requires Flutter on PATH (see RUNME.md section 2.5). Exit 0 = analyze clean.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/mobile"

if ! command -v flutter >/dev/null 2>&1; then
  echo "[mobile_check] flutter not found on PATH."
  echo "  Install: brew install --cask flutter   (or git clone, see RUNME.md section 2.5)"
  exit 2
fi

cd "$ROOT" || exit 1
flutter --version

# Backfill android/ ios/ web/ if a fresh checkout (keeps lib/ + pubspec.yaml).
if [ ! -d web ] && [ ! -d android ] && [ ! -d ios ]; then
  echo "[mobile_check] generating platform folders…"
  flutter create --platforms=web,android,ios .
fi

flutter pub get
echo "==================== flutter analyze ===================="
flutter analyze
status=$?
if [ "$status" -eq 0 ]; then
  echo "MOBILE: PASS (analyze clean)"
else
  echo "MOBILE: issues found (exit $status)"
fi
exit "$status"
