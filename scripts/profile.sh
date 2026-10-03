#!/bin/zsh
# Profiles the Release app in stress mock mode (20 tasks × 15 agents) with Instruments
# while a script scrolls, opens tasks, switches agents and toggles the inspector.
#
# Usage: scripts/profile.sh [template] [seconds]
#   template: "Animation Hitches" (default) | "SwiftUI" | "Time Profiler"
set -euo pipefail
cd "$(dirname "$0")/.."

TEMPLATE="${1:-Animation Hitches}"
SECONDS_LIMIT="${2:-40}"
APP="build/Build/Products/Release/AgentDeck.app"
OUT="profiles/$(echo "$TEMPLATE" | tr ' ' '-' | tr '[:upper:]' '[:lower:]')-$(date +%H%M%S).trace"
CTL="build/debugctl"

make release debugctl >/dev/null
mkdir -p profiles
pkill -x AgentDeck 2>/dev/null || true
sleep 0.5

drive() {
  sleep 4                                   # let the stress world spin up
  for round in 1 2 3; do
    for i in 1 2 3 4 5 6; do $CTL scroll -240 600 400; sleep 0.25; done   # scroll the card list
    for i in 1 2 3 4 5 6; do $CTL scroll 240 600 400; sleep 0.25; done
    $CTL open $((round - 1)); sleep 1
    $CTL inspector on; sleep 0.6
    for r in 1 2 3 4 5 6 7 8; do $CTL inspect $r; sleep 0.35; done      # switch agents
    $CTL inspector off; sleep 0.5
    $CTL close; sleep 0.8
    $CTL section history; sleep 0.8
    for i in 1 2 3 4; do $CTL scroll -240 600 400; sleep 0.25; done
    $CTL section active; sleep 0.8
    $CTL palette on; sleep 0.6; $CTL palette off; sleep 0.5
  done
}

drive &
DRIVER=$!
xcrun xctrace record --template "$TEMPLATE" --time-limit "${SECONDS_LIMIT}s" --output "$OUT" \
  --launch -- "$APP/Contents/MacOS/AgentDeck" -mock -stress -automation 2>&1 | tail -3
kill $DRIVER 2>/dev/null || true
pkill -x AgentDeck 2>/dev/null || true
echo "$OUT"
