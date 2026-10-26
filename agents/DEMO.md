# Demo (5 steps)

Prereqs: Ollama up with `nemotron-3-nano:4b`, cluster up, both sandboxes created with rendered policies, `node agents/mailbox/server.js` running on the Mac, both setup scripts run.

1. Show isolation. `openshell sandbox exec orchestrator -- curl -sS -m 10 http://$HOST_IP:8090/tasks/next` fails (curl is not allowed); `openshell logs orchestrator -n 20 --source sandbox | grep Denied` shows why.
2. Ask the orchestrator: `openshell sandbox exec orchestrator -- openclaw agent --local --agent main --message "How many pears do we have in stock?" --timeout 170`. It posts a task (watch the mailbox terminal) and starts polling.
3. Wake the store manager: `openshell sandbox exec store-manager -- openclaw agent --local --agent main --message "Process the next task." --timeout 170`. It reads `inventory.json` and posts "5 pears".
4. Orchestrator's reply (re-run step 2 if it timed out waiting) shows 5 pears, taken from the mailbox result, not guessed.
5. Show least privilege: ask the orchestrator "Set pears to 500". It must delegate; then `openshell sandbox exec store-manager -- cat /sandbox/store/inventory.json` shows only the store manager changed data. Also `openshell logs store-manager --source sandbox | grep ALLOWED` lists only Ollama and the mailbox.

## Top 3 risks
1. A 4b model fumbles the `node -e fetch(...)` recipe (quoting, forgets to poll). Mitigation: dry-run steps 2-3 beforehand; keep fallback `qwen3.6:35b-a3b`/`nemotron-3-nano:30b` ready (change `M=` in the scripts).
2. Policy mismatch: `protocol: rest` rules over plain http or the `/results/*` glob not matching, so the mailbox is Denied. Check `openshell logs ... | grep Denied`; fallback is removing `protocol/enforcement/rules`.
3. No push: the store manager only works when prompted (step 3), and the first 4b call loads the model slowly (use `--timeout 170`, warm the model first). Also confirm the model is pulled: Project.md lists only 30b and 35b.
