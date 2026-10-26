#!/usr/bin/env bash
# Tear down the box-side bits: openclaw sandbox, port-forward loop, `k8s` gateway entry.
# Leaves the cluster, ArgoCD apps (they self-heal), and Ollama alone.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.local/bin:$PATH"
CTX=${CTX:-default}
openshell sandbox delete openclaw >/dev/null 2>&1 || true
# the restart loop's command line contains this string, so -f matches the loop and its kubectl child
pkill -f "kubectl --context $CTX -n openshell port-forward" 2>/dev/null || true
rm -f .run/portforward.pid
openshell gateway remove k8s >/dev/null 2>&1 || true
rm -rf ~/.config/openshell/gateways/k8s
echo "down: done"
