#!/usr/bin/env bash
# Orchestrator loop (host side). Telegram goes only through the `openclaw` sandbox (the only one with Telegram egress):
#   outbound: openshell sandbox exec openclaw -- openclaw message send ...
#   inbound : Maya's DM text is read from the openclaw gateway's session transcript (no new egress anywhere).
# Flow: task "approval_needed <id>" -> ask Maya -> "approve" => POST /promo/<id>/approve ; "reject" => drop.
# After approval, when the lift shows up (/demo/after), report it once.
set -u
export PATH=$HOME/.local/bin:$HOME/.local/node/bin:$PATH
HUB=${HUB:-http://10.42.0.1:8090}; INTERVAL=${INTERVAL:-5}; STATE=${STATE:-$HOME/.run/state}
CHAT=${CHAT:?set CHAT to the owner Telegram chat id (env, not committed)}; TG=${TG:-openclaw}; mkdir -p "$STATE"
hub() { curl -sS -m 8 -H 'X-Agent: orchestrator' "$@"; }
j() { node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{try{const v=JSON.parse(d)[process.argv[1]];console.log(v??"")}catch{console.log("")}})' "$1"; }
tg() { openshell sandbox exec "$TG" -- openclaw message send --channel telegram -t "$CHAT" -m "$1" >/dev/null 2>&1 || echo "telegram send failed"; }

# prints "approve"/"reject" if Maya's newest DM after epoch-ms $1 says so
reply_since() {
  openshell sandbox exec "$TG" -- sh -c 'cat /sandbox/.openclaw/agents/main/sessions/*.jsonl' 2>/dev/null | SINCE=$1 node -e '
    let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{let r="";
      for(const l of d.split("\n")){try{const m=JSON.parse(l).message;if(!m||m.role!=="user"||m.timestamp<=+process.env.SINCE)continue;
        const t=m.content.map(c=>c.text||"").join("").split("\n").pop().trim().toLowerCase();
        const w=t.replace(/[^a-z ]/g,"").split(" ")[0]; if(w==="approve"||w==="reject")r=w}catch{}}
      console.log(r)})'
}

while true; do
  t=$(curl -sS -m 5 -H 'X-Agent: orchestrator' "$HUB/tasks/next" || true); text=$(echo "$t" | j text); tid=$(echo "$t" | j id)
  if [[ "$text" =~ ^approval_needed\ (p[0-9]+)$ ]]; then
    id=${BASH_REMATCH[1]}; p=$(hub "$HUB/promo/$id")
    msg=$(echo "$p" | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{const p=JSON.parse(d);
      console.log(`Capture rate is ${process.argv[1]}%. Proposal: ${p.headline} ${p.price} until ${p.until}. Reason: ${p.reason}. Reply approve or reject.`)})' "$(hub "$HUB/status" | j capture_rate)")
    node -e 'console.log(Date.now())' > "$STATE/ask_since"; echo "$id" > "$STATE/waiting"
    tg "$msg"; echo "$(date +%T) asked Maya about $id"
  fi
  w=$(cat "$STATE/waiting" 2>/dev/null || true)
  if [ -n "$w" ]; then
    a=$(reply_since "$(cat "$STATE/ask_since")")
    if [ "$a" = "approve" ]; then
      hub -X POST "$HUB/promo/$w/approve" >/dev/null && echo "$w" > "$STATE/awaiting_lift"; rm -f "$STATE/waiting" "$STATE/open_promo"
      tg "Approved. The menu board now shows the offer. I will report the lift."; echo "$(date +%T) approved $w"
    elif [ "$a" = "reject" ]; then rm -f "$STATE/waiting" "$STATE/open_promo"; tg "Rejected, nothing changed."; echo "$(date +%T) rejected $w"; fi
  fi
  if [ -f "$STATE/awaiting_lift" ]; then
    l=$(hub "$HUB/lift"); dn=$(echo "$l" | j delta_orders)
    if [ "${dn:-0}" -gt 0 ] 2>/dev/null; then
      msg=$(echo "$l" | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{const l=JSON.parse(d);console.log(`Capture rate ${l.before.capture_rate}% -> ${l.after.capture_rate}%, +${l.delta_orders} orders, +$${l.delta_revenue}`)})')
      tg "$msg"; rm -f "$STATE/awaiting_lift"; echo "$(date +%T) lift reported: $msg"
    fi
  fi
  sleep "$INTERVAL"
done
