#!/bin/zsh
# Frame pacing in stress mode while scrolling, opening tasks, switching agents and toggling the inspector.
# Usage: scripts/frames.sh [debug|release] ["experiment flags"]
cd "$(dirname "$0")/.."
CONF="${1:-release}"
APP="build/Build/Products/$([ "$CONF" = debug ] && echo Debug || echo Release)/AgentDeck.app/Contents/MacOS/AgentDeck"
CTL=build/debugctl
OUT=$(mktemp -t agentdeck-meter)
pkill -x AgentDeck 2>/dev/null; sleep 0.5
AGENTDECK_EXPERIMENT="$2" $APP -mock -stress -automation >/dev/null 2>&1 &
sleep 5
$CTL resize 1100 760; sleep 0.5
phase() { $CTL meter start; sleep 0.3; eval "$2"; sleep 0.3; $CTL meter stop $OUT; sleep 0.4; echo "$1: $(cat $OUT)"; }
phase "idle-list   " "sleep 4"
phase "scroll-list " 'for i in 1 2 3 4 5 6 7 8; do $CTL scroll -200 500 400; sleep 0.2; done; for i in 1 2 3 4 5 6 7 8; do $CTL scroll 200 500 400; sleep 0.2; done'
phase "open-task   " '$CTL open 1; sleep 1.2'
phase "inspector   " '$CTL inspector on; sleep 1'
phase "switch-agent" 'for r in 1 2 3 4 5 6 7 8 9 10; do $CTL inspect $r; sleep 0.4; done'
phase "scroll-detail" 'for i in 1 2 3 4 5 6; do $CTL scroll -200 400 400; sleep 0.2; done; for i in 1 2 3 4 5 6; do $CTL scroll 200 400 400; sleep 0.2; done'
phase "close+switch" '$CTL inspector off; sleep 0.5; $CTL close; sleep 0.8; $CTL open 3; sleep 0.8; $CTL close; sleep 0.8; $CTL section history; sleep 0.8; $CTL section active; sleep 0.8'
phase "palette     " '$CTL palette on; sleep 0.8; $CTL palette off; sleep 0.8'
pkill -x AgentDeck
