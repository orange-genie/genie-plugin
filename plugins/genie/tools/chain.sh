#!/usr/bin/env bash
# chain.sh — the dependency-free wire from an installed Genie to the shared Wildflower Chain.
# Every node writes as its OWN identity marker (chazz.agent, mikes.agent, novo.agent…). No admin
# key, no local chain tooling required — just curl. The server (orange-genie API) holds the DB key,
# forces authorship to the marker (unspoofable), and seals the block. This is what makes
# "everyone puts their skills on chain when they log in" real. Value in = Work out.
#
# Usage:
#   chain.sh login                         # genesis-block login handshake (announce presence)
#   chain.sh skill <slug> <summary> [body] # inscribe a skill you built/learned (immediate network write)
#   chain.sh queue <slug> <summary> [body] # STAGE a skill locally (instant, offline-safe) — the Stop hook syncs it
#   chain.sh sync                         # inscribe everything staged in the queue (called by the Stop hook)
#   chain.sh search <query> [limit]        # READ the chain: skills the commons already has
#   chain.sh mine [limit]                  # READ the chain: skills already inscribed under YOUR marker
#   chain.sh whoami                        # print this node's marker
#
# The write loop (why skills actually land): during a session the Genie STAGES each reusable skill
# with `queue` — a trivial, local, always-succeeds append. At session end the Stop hook runs `sync`,
# which does the real network inscription under the marker. Propose (model, cheap) is decoupled from
# write (hook, deterministic), so a skill lands even if the model never composed a curl itself.
#
# Marker resolution: ~/.claude/genie_marker if set, else <osuser>.agent.
# Override the API base with GENIE_API (default = the live orange-genie API).
set -euo pipefail

API="${GENIE_API:-https://orangegenie-api-production.up.railway.app}"
MARKER_FILE="$HOME/.claude/genie_marker"
QUEUE_FILE="$HOME/.claude/genie/pending_skills.jsonl"   # staged, not-yet-inscribed skills
RETRY_FILE="$HOME/.claude/genie/failed_skills.jsonl"    # writes that failed the network call (kept for retry)
RECEIPT_FILE="$HOME/.claude/genie/inscribed.log"        # what actually landed (greet.sh reports this next wake)
SYNC_CAP="${GENIE_SYNC_CAP:-5}"                        # max skills inscribed per sync (keeps the Stop hook bounded)

marker() {
  if [ -f "$MARKER_FILE" ]; then
    local m; m="$(tr -d '[:space:]' < "$MARKER_FILE" 2>/dev/null || true)"
    [ -n "$m" ] && { printf '%s' "$m"; return; }
  fi
  printf '%s.agent' "$(id -un 2>/dev/null || echo node)"
}

# json-escape a string (portable: no jq dependency)
esc() { printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null \
        || printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"; }

post() { # post <src_id> <type> <symbol> <summary> <body>
  local mk sid typ sym sum bod
  mk="$(marker)"; sid="$1"; typ="$2"; sym="$3"; sum="$4"; bod="${5:-}"
  local payload
  payload="{\"marker\":$(esc "$mk"),\"src_id\":$(esc "$sid"),\"type\":$(esc "$typ"),\"symbol\":$(esc "$sym"),\"summary\":$(esc "$sum"),\"body\":$(esc "$bod")}"
  curl -fsS --max-time 12 -X POST "$API/api/chain/node-inscribe" \
       -H 'Content-Type: application/json' -d "$payload" 2>/dev/null \
    || { echo "⚠️  chain unreachable (work saved locally is unaffected)"; return 1; }
}

# read + filter the live chain client-side (the server has no query param; we pull recent blocks
# and match locally). Args: <query|""> <limit> <only-mine:0|1> <marker>
read_chain() {
  local q lim mine mk
  q="$1"; lim="${2:-200}"; mine="${3:-0}"; mk="$4"
  curl -fsS --max-time 15 "$API/api/chain?limit=$lim" 2>/dev/null \
    | Q="$q" MINE="$mine" MK="$mk" python3 -c '
import json,sys,os
q=os.environ.get("Q","").lower().strip()
mine=os.environ.get("MINE","0")=="1"
mk=os.environ.get("MK","").lower()
try: blocks=json.load(sys.stdin).get("blocks",[])
except Exception: print("(chain unreachable)"); sys.exit(0)
# skills = real work; drop RENAME/LOGON/NODE bookkeeping from the readout
def is_skill(b): return (b.get("type","") or "").upper() not in ("RENAME","LOGON","NODE","REGISTER")
def hay(b):
    d=b.get("data") or {}
    return " ".join(str(x) for x in (b.get("summary"),b.get("body"),b.get("src"),b.get("type"),d.get("for"))).lower()
rows=[]
for b in blocks:
    if not is_skill(b): continue
    src=(b.get("src","") or "").lower()
    if mine and src!=mk: continue
    if q and q not in hay(b): continue
    rows.append(b)
if not rows:
    print("mine: nothing under your marker yet — build one and it lands here." if mine
          else "no matches on chain — this looks like a genuine gap worth building.")
    sys.exit(0)
for b in rows[:25]:
    src=str(b.get("src","?")); summ=str(b.get("summary",""))[:72]
    print("  ⬢ " + src.ljust(20) + " " + summ)
scope=" under your marker" if mine else ""
print("\n  (" + str(len(rows)) + " on chain" + scope + "; showing up to 25)")
' 2>/dev/null || echo "  (chain unreachable — offline)"
}

cmd="${1:-}"
case "$cmd" in
  login)
    # Confirm identity + chain reachability ONLY. Does NOT broadcast presence to the chain —
    # nobody should be able to see when a user is "live" (privacy: data is property, not observance).
    # Your identity on the shared chain is established by your WORK (chain.sh skill), not a login ping.
    mk="$(marker)"
    if curl -fsS --max-time 8 "$API/api/chain?limit=1" >/dev/null 2>&1; then
      echo "⬢ $mk — chain reachable. Your work inscribes under this name."
    else
      echo "⬢ $mk — offline (chain unreachable); work will inscribe when you're back online."
    fi
    ;;
  skill)
    slug="${2:?usage: chain.sh skill <slug> <summary> [body]}"
    summary="${3:?usage: chain.sh skill <slug> <summary> [body]}"
    body="${4:-}"
    mkdir -p "$(dirname "$RECEIPT_FILE")"
    if out="$(post "skill.$slug" "SKILL" "⬢" "$summary" "$body")"; then
      h="$(printf '%s' "$out" | grep -o '"height":[0-9]*' | head -1)"
      echo "⬢ inscribed skill '$slug' as $(marker). $h"
      printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$slug" "$h" >> "$RECEIPT_FILE"
    else
      # LOUD failure (was silently `exit 0`): stage for retry so the work is never lost.
      echo "✗ skill '$slug' did NOT land (chain write failed) — staged for retry." >&2
      printf '{"slug":%s,"summary":%s,"body":%s}\n' "$(esc "$slug")" "$(esc "$summary")" "$(esc "$body")" >> "$RETRY_FILE"
      exit 0   # never break the user's session over a chain hiccup
    fi
    ;;
  queue)
    # STAGE a skill locally — instant, offline-safe, cannot fail. The Stop hook syncs it later.
    slug="${2:?usage: chain.sh queue <slug> <summary> [body]}"
    summary="${3:?usage: chain.sh queue <slug> <summary> [body]}"
    body="${4:-}"
    mkdir -p "$(dirname "$QUEUE_FILE")"
    printf '{"slug":%s,"summary":%s,"body":%s}\n' "$(esc "$slug")" "$(esc "$summary")" "$(esc "$body")" >> "$QUEUE_FILE"
    echo "⬢ staged skill '$slug' — it inscribes to the chain when this session ends."
    ;;
  sync)
    # Inscribe everything staged (queue + any prior failures), under the marker. Idempotent: the
    # server dedups by src_id (skill.<slug>), so a re-sync never double-writes. Bounded by SYNC_CAP.
    mkdir -p "$(dirname "$QUEUE_FILE")"
    src_lines=""
    [ -s "$QUEUE_FILE" ] && src_lines="$(cat "$QUEUE_FILE")"
    [ -s "$RETRY_FILE" ] && src_lines="$(printf '%s\n%s' "$src_lines" "$(cat "$RETRY_FILE")")"
    src_lines="$(printf '%s\n' "$src_lines" | grep -v '^[[:space:]]*$' || true)"
    [ -z "$src_lines" ] && exit 0     # nothing staged → silent no-op (no noise on trivial sessions)
    : > "$RETRY_FILE"                 # rebuild retry from this run's failures only
    ok=0; fail=0; n=0
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      n=$((n+1)); [ "$n" -gt "$SYNC_CAP" ] && { printf '%s\n' "$line" >> "$RETRY_FILE"; continue; }
      slug="$(printf '%s' "$line" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("slug",""))' 2>/dev/null)"
      summary="$(printf '%s' "$line" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("summary",""))' 2>/dev/null)"
      body="$(printf '%s' "$line" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("body",""))' 2>/dev/null)"
      [ -z "$slug" ] && continue
      if out="$(post "skill.$slug" "SKILL" "⬢" "$summary" "$body")"; then
        ok=$((ok+1))
        printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$slug" "$(printf '%s' "$out" | grep -o '"height":[0-9]*' | head -1)" >> "$RECEIPT_FILE"
      else
        fail=$((fail+1)); printf '%s\n' "$line" >> "$RETRY_FILE"
      fi
    done <<EOF
$src_lines
EOF
    : > "$QUEUE_FILE"                 # queue fully consumed; failures live in RETRY_FILE for next sync
    [ "$ok" -gt 0 ] && echo "⬢ inscribed $ok skill(s) under $(marker)."
    [ "$fail" -gt 0 ] && echo "✗ $fail skill(s) failed to land — kept for retry next session." >&2
    exit 0
    ;;
  search)
    q="${2:?usage: chain.sh search <query> [limit]}"
    lim="${3:-200}"
    echo "⬢ chain · skills matching \"$q\":"
    read_chain "$q" "$lim" 0 ""
    ;;
  mine)
    lim="${2:-200}"
    mk="$(marker)"
    echo "⬢ chain · skills already inscribed under $mk:"
    read_chain "" "$lim" 1 "$mk"
    ;;
  install)
    # PULL a skill's package OFF the chain and install it into ~/.claude/skills/<slug>/.
    # SECURITY MODEL (v2): a SKILL.md we write is instructions a Genie then READS AND EXECUTES,
    # so a public Bazaar = anyone can publish a payload that compromises whoever installs it.
    # This case is a QUARANTINE + INFORMED-CONSENT gate. NOTHING is written to ~/.claude/skills
    # until a human at the terminal explicitly approves. Four defenses, all client-side (no key,
    # no paid API, works today):
    #   (1) CONSENT   — fetch to a temp sandbox, SHOW the full body (the exact text Genie would
    #                   execute) + author + risk, require explicit approval BEFORE any write/enable.
    #   (2) IDENTITY  — resolve the author's on-chain IDENTITY block (the X-verified mirror) →
    #                   trust tier: verified (blue/business/gov) > connected > ANONYMOUS.
    #   (3) INTEGRITY — recompute the block's own seal, sha256(prev|height|ts|summary|body), and
    #                   compare to the stored hash. Mismatch = body altered since sealing → refuse.
    #   (4) RISK SCAN — grep the body for shell/exec/exfil/persistence tokens (curl, wget, rm -rf,
    #                   eval, base64 -d, sudo, chmod, launchctl, crontab, /dev/tcp, nc, mkfifo …)
    #                   and show the offending lines. Presence escalates the approval friction.
    # Friction ladder: clean+identified → [y/N]; anon-author OR shell present → type 'yes';
    #   critical token → type the slug; integrity MISMATCH → type 'install anyway'. Default = NO.
    # Non-interactive (no TTY, e.g. a hook) NEVER installs — consent can't be faked.
    slug="${2:?usage: chain.sh install <slug>}"
    dest="$HOME/.claude/skills/$slug"
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/genie-install.XXXXXX")" || { echo "✗ cannot create sandbox"; exit 0; }
    body_f="$tmp/body"; report_f="$tmp/report"; flags_f="$tmp/flags"
    trap 'rm -rf "$tmp"' EXIT

    curl -fsS --max-time 15 "$API/api/chain?limit=500" 2>/dev/null \
      | SLUG="$slug" python3 -c '
import json,sys,os,re,hashlib
slug=os.environ["SLUG"].lower()
body_f,report_f,flags_f=sys.argv[1],sys.argv[2],sys.argv[3]
try: blocks=json.load(sys.stdin).get("blocks",[])
except Exception: sys.exit(2)

def matches(b):
    sid=str(b.get("src_id","")).lower(); summ=str(b.get("summary","")).lower()
    return sid.endswith("skill."+slug) or ("skill."+slug) in sid or slug in summ
hits=[b for b in blocks if (b.get("type","")=="SKILL" and matches(b))]
if not hits: sys.exit(3)                                  # not found in recent window
b=sorted(hits, key=lambda x:x.get("height",0))[-1]        # newest match wins
body=b.get("body") or ""
author=str(b.get("src","?"))
if not body.strip():
    open(report_f,"w").write("author=%s (summary-only, no package)"%author); sys.exit(4)

# ── (2) IDENTITY: newest IDENTITY block for this author ──
ids=[x for x in blocks if str(x.get("type",""))=="IDENTITY" and str(x.get("src",""))==author]
tier="anon"; badge=""; vlabel="ANONYMOUS — no verified identity on chain"; xh=""
if ids:
    idb=sorted(ids,key=lambda x:x.get("height",0))[-1]; d=idb.get("data") or {}
    vt=str(d.get("verified_type","none")); xh=str(d.get("x_handle","")); badge=str(d.get("badge",""))
    if vt in ("blue","business","government"):
        tier="verified"; vlabel="X-VERIFIED (%s) as @%s"%(vt,xh)
    else:
        tier="connected"; vlabel="X-connected but UNVERIFIED as @%s"%xh

# ── (3) INTEGRITY: recompute the server seal exactly ──
prev=str(b.get("prev_hash","")); h=str(b.get("height","")); ts=str(b.get("ts","")); summ=str(b.get("summary",""))
calc=hashlib.sha256(("%s|%s|%s|%s|%s"%(prev,h,ts,summ,body)).encode("utf-8")).hexdigest()
stored=str(b.get("hash",""))
integrity="ok" if (stored and calc==stored) else "bad"

# provenance signals (real, computed — never fabricated)
authored=sum(1 for x in blocks if str(x.get("type",""))=="SKILL" and str(x.get("src",""))==author)
installs=sum(1 for x in blocks if str(x.get("type",""))=="INSTALL" and ("install."+slug) in str(x.get("src_id","")).lower())

# ── (4) RISK SCAN ──
CRIT=[("rm -rf / -f recursive delete", r"\brm\s+-[rfRF]"),("sudo escalation", r"\bsudo\b"),
      ("base64 decode (hidden payload)", r"base64\s+(-d|--decode|-D)"),
      ("pipe-to-shell", r"\|\s*(sh|bash|zsh)\b"),("eval", r"\beval\b"),
      ("launchd persistence", r"launchctl|LaunchAgents|LaunchDaemons"),("cron persistence", r"\bcrontab\b"),
      ("reverse shell", r"/dev/tcp|\bmkfifo\b|\bncat\b|\bnc\s+-"),("raw disk write", r"\bdd\s+if="),
      ("world-writable chmod", r"chmod\s+(-R\s+)?[0-7]*7[0-7]{2}"),("fork bomb", r":\s*\(\s*\)\s*\{"),
      ("ssh key access", r"\.ssh/|id_rsa|authorized_keys"),("write to system dir", r">\s*/(etc|Library|System)\b"),
      ("secret exfil", r"AWS_SECRET|PRIVATE_KEY|MNEMONIC|SEED_PHRASE")]
SHELL=[("network fetch", r"\bcurl\b|\bwget\b"),("chmod", r"\bchmod\b"),
       ("inline interpreter", r"(python3?|node|perl|ruby)\s+-[ec]\b"),("applescript", r"\bosascript\b"),
       ("background/detach", r"\bnohup\b|&\s*disown|&\s*$"),("file redirect write", r">\s*[~/$]")]
lines=body.splitlines(); flagged=[]
def scan(rules,sev):
    for i,ln in enumerate(lines,1):
        for label,pat in rules:
            if re.search(pat,ln,re.I): flagged.append((sev,i,label,ln.strip()[:80]))
scan(CRIT,"CRIT"); scan(SHELL,"SHELL")
risk="critical" if any(s=="CRIT" for s,*_ in flagged) else ("shell" if flagged else "none")

# ── write body (quarantined) + flags + human report ──
open(body_f,"w").write(body)
open(flags_f,"w").write("TIER=%s\nINTEGRITY=%s\nRISK=%s\n"%(tier,integrity,risk))
R=[]
R.append("\n  ━━━━━━━━━━━━━━━  INSTALL REVIEW · %s  ━━━━━━━━━━━━━━━"%slug)
R.append("  author      : %s   %s %s"%(author,badge,vlabel))
R.append("  provenance  : block #%s · sealed %s · %d skill(s) inscribed by this author"%(h,ts,authored))
R.append("  install sig : %s"%("%d prior install receipt(s) on chain"%installs if installs else "none yet (new/unrated — judge on the code below)"))
R.append("  integrity   : %s"%("✔ body matches the sealed on-chain hash" if integrity=="ok"
         else "✘ MISMATCH — body does NOT match its seal; treat as TAMPERED"))
if risk=="none":
    R.append("  risk scan   : ✔ no shell / exec / exfil patterns found")
else:
    R.append("  risk scan   : %s %d flagged line(s) — this SKILL.md contains executable shell:"
             %("⛔ CRITICAL:" if risk=="critical" else "⚠️  SHELL:",len(flagged)))
    for sev,i,label,txt in flagged[:20]:
        R.append("      [%s] L%d  %-26s  %s"%(sev,i,label,txt))
R.append("  summary     : %s"%summ)
R.append("  ─────────── SKILL.md body — THIS TEXT BECOMES INSTRUCTIONS GENIE READS & EXECUTES ───────────")
prev_lines=lines if len(lines)<=200 else lines[:200]+["  … (%d more lines — full body written to sandbox) …"%(len(lines)-200)]
for ln in prev_lines: R.append("  | "+ln)
R.append("  ──────────────────────────────────────────────────────────────────────────────────────────")
open(report_f,"w").write("\n".join(R)+"\n")
' "$body_f" "$report_f" "$flags_f"
    rc=$?
    case "$rc" in
      2) echo "✗ chain unreachable."; exit 0;;
      3) echo "✗ no skill '$slug' found on the chain (recent window)."; exit 0;;
      4) echo "⚠️  '$slug' is on the chain but stored as a summary only — no installable package. Whoever inscribed it must include the full SKILL.md in the body."; exit 0;;
    esac

    # SHOW the review (author + verified tier + integrity + risk + full body)
    cat "$report_f"

    # load flags
    TIER=anon; INTEGRITY=bad; RISK=critical
    # shellcheck disable=SC1090
    . "$flags_f" 2>/dev/null || true

    # a human MUST be present — never install from a non-interactive context
    if [ ! -e /dev/tty ]; then
      echo "  ✗ no interactive terminal — refusing to install '$slug' without human approval."; exit 0
    fi

    # friction ladder — default is always NO
    need=""; prompt=""
    if [ "$INTEGRITY" = "bad" ]; then
      need="install anyway"; prompt="  ✘ INTEGRITY FAILED. To override a tamper warning, type exactly \`install anyway\` (or anything else to abort): "
    elif [ "$RISK" = "critical" ]; then
      need="$slug"; prompt="  ⛔ CRITICAL shell patterns above. To proceed, retype the slug \`$slug\` (or anything else to abort): "
    elif [ "$RISK" = "shell" ] || [ "$TIER" = "anon" ]; then
      need="yes"; prompt="  ⚠️  $( [ "$TIER" = anon ] && echo 'ANONYMOUS author' || echo 'contains shell' ). Type \`yes\` to install, anything else to abort: "
    else
      prompt="  Install '$slug' by $TIER author? [y/N]: "
    fi

    printf '%s' "$prompt"
    IFS= read -r answer </dev/tty || answer=""
    ok=0
    if [ -n "$need" ]; then
      [ "$answer" = "$need" ] && ok=1
    else
      case "$answer" in y|Y|yes|YES) ok=1;; esac
    fi
    if [ "$ok" != "1" ]; then echo "  ✗ aborted — nothing written."; exit 0; fi

    # APPROVED → now (and only now) write to the skills dir
    mkdir -p "$dest"
    [ -f "$dest/SKILL.md" ] && cp "$dest/SKILL.md" "$dest/SKILL.md.bak" 2>/dev/null || true
    cp "$body_f" "$dest/SKILL.md"
    echo "  ⬢ installed '$slug' → $dest/SKILL.md"
    echo "     restart Claude Code (or /reload) to pick it up."

    # OPT-IN, privacy-respecting: publish an install receipt so honest ratings can accrue.
    # Off by default (installs are private, like login). Set GENIE_INSTALL_RECEIPTS=1 to help rate.
    if [ "${GENIE_INSTALL_RECEIPTS:-0}" = "1" ]; then
      post "install.$slug" "INSTALL" "⇩" "installed $slug" "" >/dev/null 2>&1 \
        && echo "     (install receipt published — thanks for feeding the rating signal)"
    fi
    ;;
  whoami)
    echo "$(marker)"
    ;;
  *)
    echo "usage: chain.sh {login | skill <slug> <summary> [body] | queue <slug> <summary> [body] | sync | search <query> [limit] | mine [limit] | install <slug> | whoami}"; exit 1;;
esac
