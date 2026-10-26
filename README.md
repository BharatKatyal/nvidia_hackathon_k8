# Store Autopilot

An always-on, 100% local agent system for a small café (fake data: Leaf & Pearl Café, Market St, owner Maya). It notices that the sidewalk is busy but the café is quiet, drafts a promotion, asks the owner to approve it on Telegram, updates the menu board, measures the lift, and blocks a prompt-injected review that tries to exfiltrate data. No cloud LLM is used; all inference runs on one GB10 box.

## Stack
- k3s (single node) + ArgoCD (GitOps: `bootstrap/root.yaml` -> `apps/`)
- Agent Sandbox controller v1.0.2
- OpenShell gateway (Helm chart 0.1.5, CLI 0.1.5): per-sandbox policies, deny-by-default egress, per-binary and per-method rules; chart NetworkPolicies keep each workload behind its supervisor
- OpenClaw 2026.3.11 in three sandboxes (openclaw gateway + Telegram bot, orchestrator, store-manager)
- Ollama serving `nemotron-3-nano:4b`; all inference is local (host 10.42.0.1:11434)
- NemoClaw: not running. This is built on the NemoClaw stack components, OpenShell + OpenClaw, deployed directly on Kubernetes. The `nemoclaw` CLI/installer is not used (it targets a single Docker host).
- Honesty note: the 4B model writes the text (proposals, replies); the control loop (task queue, polling, lift math) is plain code.

## Architecture
```
 Maya (Telegram) <---> [openclaw sandbox: gateway + bot] --+
                                                            |  (all sandboxes -> Ollama)
 [orchestrator sandbox] --POST /tasks--> +--------------+   |      10.42.0.1:11434
                                         | hub/mailbox  |   +--> Ollama nemotron-3-nano:4b
 [store-manager sandbox] <-GET /tasks/next-| 10.42.0.1:8090|
        ^                                | task queue   |
        |                                | store data   |
  host loop (watch.sh)                   | /tv/page     |--> menu board (browser)
  wakes store-manager                    +--------------+
```
Each sandbox has its own OpenShell policy (`policies/`, `agents/*/policy.yaml.tmpl`); only listed binaries may reach listed hosts and methods.

## Run
On the GB10 (needs ArgoCD, Ollama with `nemotron-3-nano:4b` pulled, listening on 0.0.0.0):
1. `kubectl apply -f bootstrap/root.yaml` (Argo installs Agent Sandbox, then OpenShell)
2. `scripts/up.sh` (wires gateway/CLI, renders policies, creates the openclaw sandbox, runs PASS/FAIL checks); `scripts/down.sh` tears it down
3. Start the hub: `BIND=10.42.0.1 node agents/mailbox/server.js`
4. Run `agents/*/openclaw-setup.sh` for the orchestrator and store-manager, and `agents/store-manager/watch.sh` (the host loop)
5. Demo scripts: `demo/lull.sh`, `demo/after.sh`, `demo/attack.sh`

## Demo steps
1. `demo/lull.sh`: sidewalk 380 passed, 14 entered (3.7% capture); 18 croissants would otherwise be binned.
2. The agents draft the proposal: "Any drink + a croissant for $7 until 4 pm".
3. Maya approves on Telegram.
4. The menu board (`http://10.42.0.1:8090/tv/page`) updates.
5. `demo/after.sh`: capture rises 3.7% -> 6.1%, +9 orders, +$63.
6. `demo/attack.sh`: a poisoned customer review tries to exfiltrate data; the OpenShell policy denies the egress (`openshell logs <sandbox> --source sandbox | grep Denied`).

## Security notes
- Deny-by-default egress per sandbox; allowed: Ollama, the hub (specific paths/methods), and Telegram API (openclaw sandbox only).
- Blocked: any other host (including attacker endpoints in the poisoned review), and tools such as curl that are not on a binary allow-list.
- Honest limits: the hub has no authentication (bound to the host bridge IP, local network only); single node, no HA; the OpenShell gateway runs unauthenticated (local eval only); agent config lives inside the sandboxes, so recreating a sandbox needs the setup scripts re-run; Telegram bot token is set at runtime, never committed.

## Known limits
- A 4B model can fumble tool-call recipes; the control loop is code to keep the demo reliable.
- Data (traffic, inventory, sales) is simulated; lift numbers come from the demo scripts, not a real A/B test.
- First inference after idle is slow while the model loads.

## Layout
`bootstrap/` app-of-apps, `apps/` ArgoCD Applications, `agent-sandbox/` vendored v1.0.2 manifest, `policies/` sandbox policy template (`__HOST_IP__` rendered by `up.sh`), `scripts/` up/down, `optional/vllm.yaml` (not synced), `agents/` hub, orchestrator, store-manager, `agents/DEMO.md` isolation walkthrough.
