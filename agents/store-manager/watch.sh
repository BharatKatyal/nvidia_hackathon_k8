#!/usr/bin/env bash
# Always-on driver for the store manager. Runs on the GB10 host next to the mailbox.
# Polling is plain code (no model call); the agent runs only when a task is pending.
set -u
MAILBOX=${MAILBOX:-http://10.42.0.1:8090}  # mailbox is bound to the pod-network address only
SANDBOX=${SANDBOX:-store-manager}
INTERVAL=${INTERVAL:-5}
while true; do
  n=$(curl -sS -m 5 "$MAILBOX/tasks/pending" | sed -n 's/.*"pending":\([0-9]*\).*/\1/p')
  if [ "${n:-0}" -gt 0 ]; then
    echo "$(date +%T) $n pending, waking $SANDBOX"
    openshell sandbox exec "$SANDBOX" -- openclaw agent --local --agent main \
      --message "Process the next task." --timeout 170 || echo "agent run failed, will retry"
  fi
  sleep "$INTERVAL"
done
