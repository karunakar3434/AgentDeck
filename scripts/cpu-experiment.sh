#!/bin/zsh
# Measures main-process CPU while switching agents in an open stress task.
# Usage: scripts/cpu-experiment.sh "<experiment flags>"
cd "$(dirname "$0")/.."
pkill -x AgentDeck 2>/dev/null; sleep 0.5
AGENTDECK_EXPERIMENT="$1" build/Build/Products/Release/AgentDeck.app/Contents/MacOS/AgentDeck -mock -stress -automation >/dev/null 2>&1 &
sleep 5
build/debugctl open 1; sleep 1.5; build/debugctl inspector on; sleep 1
PID=$(pgrep -x AgentDeck)
T0=$(ps -o cputime= -p $PID)
for r in 1 2 3 4 5 6 7 8 9 10 11 12; do build/debugctl inspect $r; sleep 0.5; done
T1=$(ps -o cputime= -p $PID)
pkill -x AgentDeck
python3 -c "
import sys
def s(t):
    p=t.strip().split(':'); return float(p[-1])+60*float(p[-2])+(3600*float(p[-3]) if len(p)>2 else 0)
print(f'flags=[$1] cpu over 6s: {s(\"$T1\")-s(\"$T0\"):.2f}s ({(s(\"$T1\")-s(\"$T0\"))/6*100:.0f}%)')"
