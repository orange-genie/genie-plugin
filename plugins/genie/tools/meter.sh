#!/usr/bin/env bash
# meter.sh — the usage meter. Every COGS skill calls this BEFORE it runs.
# Model (AUTO, 2026-07-04..07-06): N free uses per DAY (default 5, resets at local midnight).
# After the free tier, the user picks a door:
#     • BYOK          → add their own provider key → unlimited on their key (our COGS → 0)
#     • Genie credits → top up a prepaid balance → runs on our keys, 1 credit per call
# Free/local skills never call this.
#
#   meter.sh gate <feature> [provider]   # check+consume atomically. prints one of:
#        ALLOW <used>/<cap> today         → within the free tier, run the skill
#        KEYED <provider>                 → user has BYOK for this provider → unlimited, run on THEIR key
#        CREDITS <remaining>              → free tier used up, paid from prepaid credits → run on OUR key
#        TOPUP <feature> <price>          → free tier used up, no key + no credits → offer BYOK or top-up
#        BYOK <provider>                  → free tier used up on a platform skill, no credits → add a key
#   meter.sh status                       # today's usage table + BYOK providers configured
#   meter.sh setkey <provider>            # mark BYOK configured for a provider (presence flag only)
#   meter.sh credits [marker]             # show prepaid Genie-credit balance (server-verified)
#
# ENFORCEMENT: the free-tier count and the credit balance are verified SERVER-SIDE, keyed to the
# user's marker (GENIE_API/api/meter/*, /api/credits/*), so the free tier stays honest and can't be
# reset by reinstalling. A LOCAL daily counter is the offline fallback for the FREE tier only;
# credits are never spendable offline (no client-side balance to game).
set -euo pipefail

API="${GENIE_API:-https://orangegenie-api-production.up.railway.app}"
DIR="$HOME/.claude/genie"; USAGE="$DIR/usage.json"; KEYS="$DIR/byok.json"; OWED="$DIR/owed.json"
CHAIN="$(cd "$(dirname "$0")" && pwd)/chain.sh"
MANIFEST="$(cd "$(dirname "$0")/.." && pwd)/capabilities.json"
mkdir -p "$DIR"
[ -f "$USAGE" ] || echo '{}' > "$USAGE"
[ -f "$KEYS" ]  || echo '{}' > "$KEYS"
[ -f "$OWED" ]  || echo '{}' > "$OWED"

marker() { local f="$HOME/.claude/genie_marker"; [ -f "$f" ] && tr -d '[:space:]' <"$f" || printf 'genie'; }
# install_id — a STABLE per-install id (created once, never leaves this box). The free-tier
# bucket is keyed on this on the server, so renaming your marker can't reset your 5/day.
install_id() {
  local f="$HOME/.claude/genie/install.key"
  if [ ! -f "$f" ]; then
    mkdir -p "$(dirname "$f")" 2>/dev/null
    { uuidgen 2>/dev/null || python3 -c 'import uuid;print(uuid.uuid4())' 2>/dev/null || date +%s%N; } \
      | tr -d '[:space:]' > "$f" 2>/dev/null
  fi
  tr -d '[:space:]' <"$f" 2>/dev/null
}
today()  { date +%F; }

cap_for() { # free_per_day for a feature (manifest override, else default)
  python3 - "$MANIFEST" "$1" <<'PY'
import json,sys
m=json.load(open(sys.argv[1])); d=m.get("default_free_per_day",5)
for c in m["capabilities"]:
    if c["name"]==sys.argv[2]: print(c.get("free_per_day",d)); break
else: print(d)
PY
}

has_key() { python3 - "$KEYS" "$1" <<'PY'
import json,sys
try: print("1" if json.load(open(sys.argv[1])).get(sys.argv[2]) else "0")
except Exception: print("0")
PY
}

# pricing_for <feature> → prints: <creator_marker> <price_per_call> <take_rate>
pricing_for() { python3 - "$MANIFEST" "$1" <<'PY'
import json,sys
m=json.load(open(sys.argv[1])); plat=m.get("platform_marker","orangegenie"); take=m.get("take_rate",0.2)
for c in m["capabilities"]:
    if c["name"]==sys.argv[2]:
        print(c.get("creator_marker",plat), c.get("price_per_call",0.0), take); break
else: print(plat, 0.0, take)
PY
}

# accrue <feature> <creator> <price> <take> — record a PAID call as OWED (no money moves).
# Splits: creator earns price*(1-take), platform earns price*take. Best-effort chain inscribe.
accrue() {
  local feat="$1" creator="$2" price="$3" take="$4" user; user="$(marker)"
  python3 - "$OWED" "$feat" "$creator" "$price" "$take" "$user" "$(today)" <<'PY'
import json,sys
f,feat,creator,price,take,user,day=sys.argv[1:8]
price=float(price); take=float(take); creator_share=round(price*(1-take),6); plat_share=round(price*take,6)
o=json.load(open(f)); c=o.get(creator,{"earned":0.0,"calls":0,"by":{}})
c["earned"]=round(c["earned"]+creator_share,6); c["calls"]+=1
c["by"][feat]=round(c["by"].get(feat,0.0)+creator_share,6)
o[creator]=c
plat=o.get("__platform__",{"earned":0.0,"calls":0}); plat["earned"]=round(plat["earned"]+plat_share,6); plat["calls"]+=1
o["__platform__"]=plat
json.dump(o,open(f,"w"),indent=2)
print(f"{creator_share} {plat_share}")
PY
}

# credit_cost_for <feature> → credits charged per paid call (manifest override, else 1)
credit_cost_for() { python3 - "$MANIFEST" "$1" <<'PY'
import json,sys
m=json.load(open(sys.argv[1])); d=m.get("default_credit_cost",1)
for c in m["capabilities"]:
    if c["name"]==sys.argv[2]: print(c.get("credit_cost",d)); break
else: print(d)
PY
}

# credits_balance — server-verified prepaid balance for this marker. Prints an integer, or "" if
# the server is unreachable (credits are NEVER spendable offline; caller treats "" as zero).
credits_balance() {
  curl -fsS --max-time 5 "$API/api/credits/balance?marker=$(marker)" 2>/dev/null \
    | python3 -c 'import json,sys;print(json.load(sys.stdin).get("balance",""))' 2>/dev/null || true
}

# credits_charge <feature> <cost> — server-verified spend. Prints new balance on success, "" on fail
# (server down, insufficient balance). The SERVER is authoritative; the client never decrements locally.
credits_charge() {
  curl -fsS --max-time 6 -X POST "$API/api/credits/charge" -H 'Content-Type: application/json' \
    -d "{\"marker\":\"$(marker)\",\"feature\":\"$1\",\"cost\":$2}" 2>/dev/null \
    | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get("balance","") if d.get("ok") else "")' 2>/dev/null || true
}

# topup_link — hosted Square checkout for a credit pack (built server-side).
topup_link() {
  curl -fsS --max-time 6 -X POST "$API/api/payment/square/create-credit-checkout" \
    -H 'Content-Type: application/json' -d "{\"marker\":\"$(marker)\"}" 2>/dev/null \
    | python3 -c 'import json,sys;print(json.load(sys.stdin).get("url",""))' 2>/dev/null || true
}

gate() {
  local feat="$1" prov="${2:-}" cap used
  # BYOK short-circuit — if the user keyed this provider, it runs on THEIR key → unlimited.
  if [ -n "$prov" ] && [ "$(has_key "$prov")" = "1" ]; then echo "KEYED $prov"; return 0; fi

  # server-first: the server is authoritative for the free-tier count AND credits. It returns a
  # ready-to-print verdict line (ALLOW/KEYED/BYOK/CREDITS/TOPUP); the client just relays it. This
  # keeps the count honest and the credit spend server-verified. Falls through to local free-tier
  # handling only when the server is unreachable.
  local sv line
  sv="$(curl -fsS --max-time 5 -X POST "$API/api/meter/gate" -H 'Content-Type: application/json' \
        -d "{\"marker\":\"$(marker)\",\"install_id\":\"$(install_id)\",\"feature\":\"$feat\",\"provider\":\"$prov\"}" 2>/dev/null || true)"
  if [ -n "$sv" ]; then
    line="$(printf '%s' "$sv" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("line","").strip())
except Exception: print("")' 2>/dev/null || true)"
    [ -n "$line" ] && { echo "$line"; return 0; }
  fi

  # local fallback (offline / pre-server): daily counter, NOT server-verified (can be reset locally).
  cap="$(cap_for "$feat")"
  used="$(python3 - "$USAGE" "$(today)" "$feat" "$cap" <<'PY'
import json,sys
f,day,feat,cap=sys.argv[1],sys.argv[2],sys.argv[3],int(sys.argv[4])
u=json.load(open(f)); d=u.get(day,{}); n=d.get(feat,0)
if n>=cap: print(f"BLOCK {n} {cap}")
else:
    d[feat]=n+1; u[day]=d
    # prune old days so the file cannot grow unbounded
    for k in list(u):
        if k!=day: del u[k]
    json.dump(u,open(f,"w")); print(f"OK {n+1} {cap}")
PY
)"
  set -- $used
  if [ "$1" = "OK" ]; then echo "ALLOW $2/$3"; return 0; fi

  # over the free tier → the paid doors: prepaid Genie credits first, else prompt (BYOK or top-up).
  local cost bal; cost="$(credit_cost_for "$feat")"; bal="$(credits_balance)"
  if [ -n "$bal" ] && printf '%s' "$bal" | grep -qE '^[0-9]+$' && [ "$bal" -ge "$cost" ]; then
    local newbal; newbal="$(credits_charge "$feat" "$cost")"
    if [ -n "$newbal" ]; then
      # a real credit was spent → accrue the creator's share of that spend (bazaar payout ledger).
      local pr; pr="$(pricing_for "$feat")"; set -- $pr   # $1=creator $2=price $3=take
      if python3 -c "import sys;sys.exit(0 if float('$2')>0 else 1)"; then
        local split; split="$(accrue "$feat" "$1" "$2" "$3")"
        [ -x "$CHAIN" ] && "$CHAIN" skill "owed.$feat.$(date +%s)" \
            "payout accrual from a paid credit call on $feat" "proof-of-work earning; settlement gated" >/dev/null 2>&1 || true
      fi
      echo "CREDITS $newbal"; return 0
    fi
  fi
  # no credits (or server unreachable) → present both doors. TOPUP carries the provider (for the
  # BYOK option) and a hosted checkout link (for the top-up option); the caller shows both.
  echo "TOPUP $feat $cost ${prov:-none} $(topup_link)"
}

case "${1:-}" in
  gate)   shift; gate "$@";;
  status) python3 - "$USAGE" "$KEYS" "$(today)" <<'PY'
import json,sys
u=json.load(open(sys.argv[1])); k=json.load(open(sys.argv[2])); day=sys.argv[3]
print(f"— Genie usage · {day} —")
for feat,n in sorted(u.get(day,{}).items()): print(f"  {feat:16} {n} used today")
print("BYOK configured:", ", ".join(p for p,v in k.items() if v) or "(none)")
PY
  ;;
  setkey) prov="${2:?provider}"; python3 - "$KEYS" "$prov" <<'PY'
import json,sys
f,p=sys.argv[1],sys.argv[2]; k=json.load(open(f)); k[p]=True; json.dump(k,open(f,"w")); print(f"BYOK marked for {p}")
PY
  ;;
  # "payout balance" — the storefront read. Shows a dollar number; never says "crypto/wallet".
  balance) who="${2:-$(marker)}"; python3 - "$OWED" "$who" <<'PY'
import json,sys
o=json.load(open(sys.argv[1])); who=sys.argv[2]; c=o.get(who,{"earned":0.0,"calls":0,"by":{}})
print(f"💵 Payout balance for {who}: ${c['earned']:.2f}   ({c['calls']} paid calls)")
for feat,amt in sorted(c.get("by",{}).items(), key=lambda x:-x[1]): print(f"     {feat:16} ${amt:.2f}")
PY
  ;;
  # prepaid Genie-credit balance (server-verified; the user's spend wallet, distinct from OWED payouts)
  credits) bal="$(credits_balance)"
    if [ -n "$bal" ]; then echo "💳 Genie credits: $bal   (server-verified)"
    else echo "💳 Genie credits: unavailable — server unreachable (credits are never counted offline)"; fi ;;
  *) echo "usage: meter.sh gate <feature> [provider] | status | setkey <provider> | credits | balance [marker]"; exit 2;;
esac
