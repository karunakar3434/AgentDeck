#!/bin/zsh
# Frame pacing for individual screen transitions in stress mode.
cd "$(dirname "$0")/.."
CTL=build/debugctl; OUT=$(mktemp -t agentdeck-meter)
pkill -x AgentDeck 2>/dev/null; sleep 0.5
AGENTDECK_EXPERIMENT="$1" build/Build/Products/Release/AgentDeck.app/Contents/MacOS/AgentDeck -mock ${SCENARIO:--stress} -automation >/dev/null 2>&1 &
sleep 5; $CTL resize 1100 760; sleep 0.8
phase() { $CTL meter start; sleep 0.2; eval "$2"; $CTL meter stop $OUT; sleep 0.3; printf "%-14s %s\n" "$1" "$(cat $OUT | sed 's/frames=[0-9]* secs=[0-9.]* refresh=[0-9.]*ms //')"; }
for i in 1 2; do
phase "open-task" '$CTL open 1; sleep 1'
phase "close-task" '$CTL close; sleep 1'
phase "to-history" '$CTL section history; sleep 1'
phase "to-active" '$CTL section active; sleep 1'
phase "palette-on" '$CTL palette on; sleep 1'
phase "palette-off" '$CTL palette off; sleep 1'
done
pkill -x AgentDeck
