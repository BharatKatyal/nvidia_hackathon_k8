#!/usr/bin/env bash
# Verify and finish the OpenShell + OpenClaw stack on the k3s host. Run ON the box.
# ArgoCD owns agent-sandbox + OpenShell (apps/); this script only does what Argo can't:
# CLI gateway registration, the openclaw sandbox, OpenClaw->Ollama wiring, and the checks.
# Idempotent. Needs on PATH: kubectl, helm (unused for install, kept for parity), openshell, curl, nc.
set -euo pipefail
cd "$(dirname "$0")/.."
RUN=$PWD/.run
mkdir -p "$RUN"
export PATH="$HOME/.local/bin:$PATH"

# ---- pinned versions / names -------------------------------------------------
CTX=${CTX:-default}                      # k3s's kubeconfig context name
OPENSHELL_CLI_VERSION=0.1.5
OPENCLAW_REPO=ghcr.io/nvidia/openshell-community/sandboxes/openclaw
# Image pin: the sandbox pod is pulled by k3s's containerd, so a local retag (needs root) is not
# possible. The `:latest` tag is mutable, so at run time we resolve it to a digest via the registry
# API (no root, no docker) and create the sandbox from <repo>@sha256:... (immutable, IfNotPresent).
# Override with OPENCLAW_REF=<repo>:<fixed-tag-or-@digest> to pin by hand.
OPENCLAW_REF=${OPENCLAW_REF:-}
GW_NAME=k8s
GW_DIR=$HOME/.config/openshell/gateways/$GW_NAME/mtls
MODEL=nemotron-3-nano:4b

# ---- helpers -----------------------------------------------------------------
PASS=0; FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $*"; FAIL=$((FAIL+1)); }
step() { echo; echo "==> $*"; }
check_ctx() {
  local cur; cur=$(kubectl config current-context)
  [[ $cur == "$CTX" ]] || { echo "ABORT: kubectl context is '$cur', expected '$CTX' (set CTX=... to override)"; exit 1; }
}
k() { check_ctx; kubectl --context "$CTX" "$@"; }
stop_portforward() {
  pkill -f "kubectl --context $CTX -n openshell port-forward" 2>/dev/null || true
  rm -f "$RUN/portforward.pid"
}
ready_pods() { k -n openshell get pods --no-headers | grep -E 'openclaw|os-supervisor' | grep -c ' 1/1 *Running' || true; }

# ---- 0. preflight ------------------------------------------------------------
step "0. Preflight"
for t in kubectl openshell nc curl; do command -v $t >/dev/null || { echo "missing: $t"; exit 1; }; done
check_ctx
[[ $(openshell --version) == *"$OPENSHELL_CLI_VERSION"* ]] || { echo "openshell CLI must be v$OPENSHELL_CLI_VERSION (got $(openshell --version))"; exit 1; }
if ss -ltn 2>/dev/null | grep -q '127.0.0.1:11434'; then
  echo "WARN: Ollama listens on 127.0.0.1 only; pods cannot reach it. Set OLLAMA_HOST=0.0.0.0 (and OLLAMA_CONTEXT_LENGTH=32768) in its systemd unit. This script will not do it."
fi
# address pods see for the host: flannel's cni0 address (10.42.0.1 on stock k3s)
HOST_IP=${HOST_IP:-$(ip -4 -o addr show cni0 2>/dev/null | awk '{sub(/\/.*/,"",$4); print $4; exit}')}
HOST_IP=${HOST_IP:-10.42.0.1}
echo "host IP as seen from pods: $HOST_IP"

# ---- 1-3. wait for what ArgoCD installs ---------------------------------------
step "1-3. Wait for ArgoCD-managed agent-sandbox and OpenShell"
for _ in $(seq 90); do k -n openshell get statefulset openshell >/dev/null 2>&1 && break; sleep 4; done
k -n agent-sandbox-system rollout status deploy --timeout=300s
if k -n agent-sandbox-system get pods --no-headers | grep -q Running \
   && k get crd sandboxes.agents.x-k8s.io -o jsonpath='{.spec.versions[?(@.served==true)].name}' | grep -q v1beta1; then
  pass "2. Agent Sandbox controller Running, CRD serves v1beta1"
else
  fail "2. Agent Sandbox controller / CRD"
fi
k -n openshell rollout status statefulset/openshell --timeout=300s
if [[ $(k -n openshell get pod openshell-0 -o jsonpath='{.status.phase}') == Running ]]; then
  pass "3. gateway openshell-0 Running in namespace openshell"
else
  fail "3. gateway openshell-0 not Running"
fi

# ---- 4. CLI connection -------------------------------------------------------
step "4. Connect the OpenShell CLI (gateway '$GW_NAME')"
stop_portforward
# port-forward dies on a single connection reset, so keep it in a restart loop
nohup bash -c "while true; do kubectl --context $CTX -n openshell port-forward svc/openshell 8080:8080; sleep 1; done" \
  >"$RUN/portforward.log" 2>&1 &
echo $! > "$RUN/portforward.pid"
for _ in $(seq 30); do nc -z 127.0.0.1 8080 2>/dev/null && break; sleep 1; done
# openshell 0.1.5 on Linux: `gateway add --local` REQUIRES the mtls files to exist already (verified on the GB10),
# so copy the chart's client certs BEFORE adding. Copy again after in case an older CLI overwrites them.
copy_certs() {
  mkdir -p "$GW_DIR"
  for f in ca.crt tls.crt tls.key; do
    k -n openshell get secret openshell-client-tls -o jsonpath="{.data.${f/./\\.}}" | base64 -d > "$GW_DIR/$f"
  done
  chmod 600 "$GW_DIR/tls.key"
}
openshell gateway remove $GW_NAME >/dev/null 2>&1 || true
copy_certs
openshell gateway add https://127.0.0.1:8080 --local --name $GW_NAME
openshell gateway select $GW_NAME >/dev/null 2>&1 || true
copy_certs
STATUS=$(openshell status 2>&1 || true)
if grep -q "BadSignature" <<<"$STATUS"; then   # stale certs: restart gateway, re-copy, retry once
  k -n openshell rollout restart statefulset/openshell >/dev/null
  k -n openshell rollout status statefulset/openshell --timeout=300s
  sleep 5; copy_certs
  STATUS=$(openshell status 2>&1 || true)
fi
echo "$STATUS"
if grep -q "Status: Connected" <<<"$STATUS" && grep -q "Gateway: $GW_NAME" <<<"$STATUS"; then
  pass "4. openshell status: Connected (gateway $GW_NAME)"
else
  fail "4. openshell status not Connected"
fi

# ---- 5. sandbox --------------------------------------------------------------
step "5. Sandbox 'openclaw'"
if [[ -z $OPENCLAW_REF ]]; then
  TOKEN=$(curl -fsSL "https://ghcr.io/token?service=ghcr.io&scope=repository:${OPENCLAW_REPO#ghcr.io/}:pull" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
  DIGEST=$(curl -fsSI -H "Authorization: Bearer $TOKEN" \
    -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
    "https://ghcr.io/v2/${OPENCLAW_REPO#ghcr.io/}/manifests/latest" | tr -d '\r' | awk -F': ' 'tolower($1)=="docker-content-digest"{print $2}')
  [[ $DIGEST == sha256:* ]] || { echo "could not resolve digest of $OPENCLAW_REPO:latest; set OPENCLAW_REF"; exit 1; }
  OPENCLAW_REF=$OPENCLAW_REPO@$DIGEST
fi
echo "image: $OPENCLAW_REF"
sed "s/__HOST_IP__/$HOST_IP/g" policies/openclaw-policy.yaml.tmpl > "$RUN/openclaw-policy.yaml"
openshell sandbox delete openclaw >/dev/null 2>&1 || true   # idempotent: recreate with the current policy/image
openshell sandbox create --name openclaw --from "$OPENCLAW_REF" --policy "$RUN/openclaw-policy.yaml" \
  --no-auto-providers --detach --no-tty -- sleep infinity
for _ in $(seq 90); do [[ $(ready_pods) -ge 2 ]] && break; sleep 4; done
k -n openshell get pods
if [[ $(ready_pods) -ge 2 ]]; then
  pass "5. openclaw workload pod and os-supervisor pod are 1/1 Running"
else
  fail "5. openclaw pods not both 1/1 Running"
fi

# ---- 6. per-binary policy ----------------------------------------------------
step "6. Per-binary network policy"
OLLAMA_URL=http://$HOST_IP:11434/api/tags
NODE_OUT=$(openshell sandbox exec openclaw -- node -e "fetch('$OLLAMA_URL',{signal:AbortSignal.timeout(15000)}).then(r=>r.json()).then(j=>console.log(j.models.map(m=>m.name).join(','))).catch(e=>console.log('ERR',e.cause&&e.cause.code||e.message))" 2>&1 || true)
echo "node  -> ${NODE_OUT:0:200}"
if grep -q "$MODEL" <<<"$NODE_OUT"; then pass "6a. node lists Ollama models"; else fail "6a. node could not list Ollama models"; fi
CURL_OUT=$(openshell sandbox exec openclaw -- curl -sS -m 10 "$OLLAMA_URL" 2>&1 || true)
echo "curl  -> ${CURL_OUT:0:200}"
sleep 2
if ! grep -q "$MODEL" <<<"$CURL_OUT" \
   && openshell logs openclaw -n 99 --source sandbox 2>&1 | grep -q "binary '/usr/bin/curl' not allowed in policy"; then
  pass "6b. curl to Ollama is blocked (supervisor log: binary not allowed in policy)"
else
  fail "6b. curl to Ollama was not blocked by policy"
fi
EX_OUT=$(openshell sandbox exec openclaw -- curl -sS -m 10 https://example.com 2>&1 || true)
echo "curl example.com -> ${EX_OUT:0:200}"
if grep -qi "Example Domain" <<<"$EX_OUT"; then fail "6c. curl https://example.com was NOT blocked"; else pass "6c. curl https://example.com is blocked"; fi

# ---- 7. OpenClaw -> Ollama ---------------------------------------------------
step "7. Configure OpenClaw for Ollama and run one agent turn"
PROVIDER=$(cat <<JSON
{"baseUrl":"http://$HOST_IP:11434/v1","apiKey":"ollama-local","api":"openai-completions","models":[{"id":"$MODEL","name":"$MODEL","contextWindow":32768,"maxTokens":8192}]}
JSON
)
openshell sandbox exec openclaw -- openclaw config set models.providers.ollama "$PROVIDER" --strict-json >/dev/null
openshell sandbox exec openclaw -- openclaw models set "ollama/$MODEL" >/dev/null
AGENT_OUT=$(openshell sandbox exec openclaw -- openclaw agent --local --agent main --message "Reply with exactly one word: PONG" --timeout 170 2>&1 || true)
echo "agent -> ${AGENT_OUT: -200}"
if grep -q "PONG" <<<"$AGENT_OUT"; then pass "7. OpenClaw answered via Ollama (model $MODEL)"; else fail "7. OpenClaw agent turn failed"; fi

echo; echo "SUMMARY: $PASS passed, $FAIL failed"
echo "Port-forward loop is running in the background; stop it with scripts/down.sh"
[[ $FAIL -eq 0 ]]
