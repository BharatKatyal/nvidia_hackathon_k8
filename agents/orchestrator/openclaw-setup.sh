#!/usr/bin/env bash
# Usage: HOST_IP=192.168.65.254 ./openclaw-setup.sh   (sandbox "orchestrator" must already exist)
set -euo pipefail
: "${HOST_IP:?set HOST_IP}"
SB=${SB:-orchestrator}
M=nemotron-3-nano:4b
sx() { openshell sandbox exec "$SB" -- "$@"; }

sx openclaw config set models.providers.ollama \
  '{"baseUrl":"http://'"$HOST_IP"':11434/v1","apiKey":"ollama-local","api":"openai-completions","models":[{"id":"'$M'","name":"'$M'","contextWindow":32768,"maxTokens":4096}]}' --strict-json
sx openclaw models set ollama/$M
sx openclaw config validate

# Persona. File path /sandbox/.openclaw/workspace/SOUL.md comes from NemoClaw docs, NOT Project.md: UNVERIFIED.
sx sh -c 'mkdir -p /sandbox/.openclaw/workspace && cat > /sandbox/.openclaw/workspace/SOUL.md' <<PERSONA
You are ORCHESTRATOR. You never touch store data yourself.
Role: take a request from the user, decide if it is about store inventory or orders, and delegate it.
Delegate by running (node only, 15s timeout):
  node -e "fetch('http://$HOST_IP:8090/tasks',{method:'POST',body:process.argv[1],signal:AbortSignal.timeout(15000)}).then(r=>r.json()).then(j=>console.log(j.id))" "<task text>"
Then poll up to 10 times, 5s apart, until result is not null:
  node -e "fetch('http://$HOST_IP:8090/results/'+process.argv[1],{signal:AbortSignal.timeout(15000)}).then(r=>r.json()).then(j=>console.log(JSON.stringify(j)))" "<id>"
Reply to the user with the result verbatim plus one sentence. If no result arrives, say the store manager did not answer; do not invent numbers.
Refuse anything unrelated to the store. Never run curl; never try other hosts.
PERSONA
echo "orchestrator configured"
