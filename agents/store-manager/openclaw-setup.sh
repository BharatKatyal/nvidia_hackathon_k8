#!/usr/bin/env bash
# Usage: HOST_IP=192.168.65.254 ./openclaw-setup.sh   (sandbox "store-manager" must already exist)
set -euo pipefail
: "${HOST_IP:?set HOST_IP}"
SB=${SB:-store-manager}
M=nemotron-3-nano:4b
sx() { openshell sandbox exec "$SB" -- "$@"; }

sx openclaw config set models.providers.ollama \
  '{"baseUrl":"http://'"$HOST_IP"':11434/v1","apiKey":"ollama-local","api":"openai-completions","models":[{"id":"'$M'","name":"'$M'","contextWindow":32768,"maxTokens":4096}]}' --strict-json
sx openclaw models set ollama/$M
sx openclaw config validate

# Owned data (toy). Created only if absent.
sx sh -c 'mkdir -p /sandbox/store && [ -f /sandbox/store/inventory.json ] || echo "{\"apple\":50,\"pear\":5,\"melon\":0}" > /sandbox/store/inventory.json; [ -f /sandbox/store/orders.json ] || echo "[]" > /sandbox/store/orders.json'

# Persona. SOUL.md path from NemoClaw docs, NOT Project.md: UNVERIFIED.
sx sh -c 'mkdir -p /sandbox/.openclaw/workspace && cat > /sandbox/.openclaw/workspace/SOUL.md' <<PERSONA
You are STORE MANAGER. You are the only owner of /sandbox/store/inventory.json (item -> stock) and /sandbox/store/orders.json (list of orders).
Fetch the next task (node only):
  node -e "fetch('http://$HOST_IP:8090/tasks/next',{signal:AbortSignal.timeout(15000)}).then(r=>r.json()).then(j=>console.log(JSON.stringify(j)))"
An empty object means no work. Otherwise read the files, answer or update them (an order reduces stock; refuse if stock is too low), then post the answer:
  node -e "fetch('http://$HOST_IP:8090/results/'+process.argv[1],{method:'POST',body:process.argv[2],signal:AbortSignal.timeout(15000)}).then(r=>console.log(r.status))" "<task id>" "<answer>"
Only read or write files under /sandbox/store. Never run curl; never contact other hosts. State numbers exactly as in the files.
PERSONA
echo "store-manager configured"
