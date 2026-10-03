#!/bin/zsh
# CPU over 6 s in a given state. Usage: scripts/cpu-baseline.sh <list|detail|history|hidden> "<experiment flags>"
cd "$(dirname "$0")/.."
pkill -x AgentDeck 2>/dev/null; sleep 0.5
AGENTDECK_EXPERIMENT="$2" build/Build/Products/Release/AgentDeck.app/Contents/MacOS/AgentDeck -mock -stress -automation >/dev/null 2>&1 &
sleep 5
case "$1" in
  detail) build/debugctl open 1; sleep 1.5 ;;
  history) build/debugctl section history; sleep 1.5 ;;
  hidden) osascript -e 'tell application "System Events" to set visible of process "AgentDeck" to false' 2>/dev/null; sleep 1.5 ;;
esac
PID=$(pgrep -x AgentDeck)
T0=$(ps -o cputime= -p $PID); sleep 6; T1=$(ps -o cputime= -p $PID)
pkill -x AgentDeck
python3 -c "
def s(t):
    p=t.strip().split(':'); return float(p[-1])+60*float(p[-2])+(3600*float(p[-3]) if len(p)>2 else 0)
d=s('$T1')-s('$T0'); print(f'state=$1 flags=[$2] cpu: {d/6*100:.0f}%')"
