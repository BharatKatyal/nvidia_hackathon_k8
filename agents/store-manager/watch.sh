#!/usr/bin/env bash
# Store-manager loop (host side, plain code; the model only phrases one text line).
# Every INTERVAL s: GET /status; on alert=low_capture with no open proposal, POST /promo then hand an
# "approval_needed <id>" task to the orchestrator sandbox (its node does the POST /tasks, policy-enforced).
# Customer feedback is untrusted DATA: only its COUNT is used; its text never reaches a command or the model.
# Idempotent: open proposal id kept in $STATE/open_promo; cleared by orchestrator/loop.sh or when alert clears.
set -u
export PATH=$HOME/.local/bin:$HOME/.local/node/bin:$PATH
HUB=${HUB:-http://10.42.0.1:8090}; INTERVAL=${INTERVAL:-30}; STATE=${STATE:-$HOME/.run/state}
SM=${SM:-store-manager}; ORCH=${ORCH:-orchestrator}; mkdir -p "$STATE"
hub() { curl -sS -m 8 -H 'X-Agent: store-manager' "$@"; }
j() { node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{try{const v=JSON.parse(d)[process.argv[1]];console.log(v??"")}catch{console.log("")}})' "$1"; }

phrase() { # $1 = numbers-only facts; falls back to $2 on any failure or if the output omits the real rate $3
  out=$(timeout 60 openshell sandbox exec "$SM" -- openclaw agent --local --agent main --timeout 50 \
    --message "Say in one short sentence why a croissant deal helps: $1." 2>/dev/null | grep -v '^\s*$' | tail -1)
  case "$out" in ""|*[\`\$\<\>]*) echo "$2";; *"$3"*) [ ${#out} -le 200 ] && echo "$out" || echo "$2";; *) echo "$2";; esac  # must quote the real rate
}

while true; do
  st=$(hub "$HUB/status" || true); alert=$(echo "$st" | j alert)
  open=$(cat "$STATE/open_promo" 2>/dev/null || true)
  if [ -n "$open" ] && [ "$alert" != "low_capture" ]; then rm -f "$STATE/open_promo"; open=""; fi  # e.g. after /demo/after
  live=$(hub "$HUB/tv" | j headline)  # a promo already on the board: do not propose another
  if [ "$alert" = "low_capture" ] && [ -z "$open" ] && [ "$live" = "Leaf & Pearl Café" ]; then
    rate=$(echo "$st" | j capture_rate); left=$(echo "$st" | j croissants_left)
    passed=$(echo "$st" | j passed); entered=$(echo "$st" | j entered)
    nfb=$(hub "$HUB/feedback" | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>console.log(JSON.parse(d||"[]").length))')
    base="Capture rate is $rate% ($entered of $passed passers came in) and $left croissants would otherwise be binned."
    reason=$(phrase "only $rate percent of passers came in and $left croissants would be wasted" "$base" "$rate")
    body=$(R="$reason" L="$left" node -e 'console.log(JSON.stringify({headline:"Any drink + a croissant",detail:process.env.L+" croissants would otherwise be binned",price:"$7",until:"4 pm",reason:process.env.R}))')
    id=$(echo "$body" | hub -X POST -H 'Content-Type: application/json' -d @- "$HUB/promo" | j promo_id)
    if echo "$id" | grep -qE '^p[0-9]+$'; then
      echo "$id" > "$STATE/open_promo"
      openshell sandbox exec "$ORCH" -- node -e "fetch('$HUB/tasks',{method:'POST',body:process.argv[1],signal:AbortSignal.timeout(15000)}).then(r=>console.log('task posted',r.status))" "approval_needed $id" || rm -f "$STATE/open_promo"
      echo "$(date +%T) proposed $id (feedback items seen: $nfb)"
    else echo "$(date +%T) promo POST failed"; fi
  fi
  sleep "$INTERVAL"
done
