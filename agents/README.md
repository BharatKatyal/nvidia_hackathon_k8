# Agents: orchestrator + store manager

Two OpenClaw agents, each in its own OpenShell sandbox on the k3s cluster, both on Ollama `nemotron-3-nano:4b` (`http://__HOST_IP__:11434/v1`, contextWindow 32768).
Per-agent files: `<agent>/policy.yaml.tmpl` (sandbox policy) and `<agent>/openclaw-setup.sh` (model config + persona).

## Roles
| Agent | May do | May not do |
|---|---|---|
| orchestrator | Talk to the user, classify the request, POST a task to the mailbox, poll for the result, relay it. | Read or write store data, pop tasks, use any host but the Ollama host. |
| store-manager | Pop tasks, read/update `/sandbox/store/{inventory,orders}.json`, POST the answer. | Create tasks, touch files outside `/sandbox`, reach anything but Ollama + mailbox. |

## Hand-off: why a mailbox
Each sandbox's policy is deny-by-default and the workload pod can only talk to its own supervisor (Project.md). So orchestrator -> store-manager direct calls are impossible unless a policy lists the other pod's IP, and pod IPs change on restart (not verified that sandbox-to-sandbox traffic can be allowed at all). The simplest thing that works: the Mac host, which both sandboxes can already reach, runs `mailbox/server.js` (in-memory, port 8090, no auth, demo only).
Flow: orchestrator `POST /tasks` -> store-manager `GET /tasks/next` (it must be prompted to check; there is no push) -> store-manager `POST /results/<id>` -> orchestrator `GET /results/<id>`.
Both policies allow only `/usr/bin/node` to `__HOST_IP__:8090`, with method+path rules so neither agent can do the other's half.
Alternative if you want no host process: a mailbox Service in the cluster, but that needs `allowed_ips` for a ClusterIP and the NetworkPolicy path to be confirmed. Not attempted.

## Store manager data (toy)
`/sandbox/store/inventory.json` e.g. `{"apple":50,"pear":5,"melon":0}` and `orders.json` (list). Seeded by its setup script. Lives in the sandbox, so it is lost if the sandbox is recreated.

## Run order
1. Render policies with `sed "s/__HOST_IP__/$HOST_IP/g"`, create sandboxes with `--policy` (as in Project.md step 5; image `openclaw-sandbox:v1`).
2. `node agents/mailbox/server.js` on the Mac.
3. `HOST_IP=... agents/<name>/openclaw-setup.sh` for each agent.
4. Follow `DEMO.md`.

## Not verified (see end of DEMO.md too)
Persona path `/sandbox/.openclaw/workspace/SOUL.md` (from NemoClaw docs, not Project.md); `protocol: rest` rules over plain http; that the 4b model is pulled and can follow the tool-call-by-node recipe; whether OpenClaw lets the agent run `node -e` itself.
