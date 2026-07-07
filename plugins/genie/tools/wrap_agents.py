#!/usr/bin/env python3
"""wrap_agents.py — wrap every agent in capabilities.json as a plugin SKILL.md.

'The things that make Genie Genie are all the agents' (AUTO). This makes them real to a woken
Genie: one SKILL.md per capability, whose `description` carries the natural-language triggers so
the model knows the skill exists and when to reach for it. COGS skills call meter.sh FIRST
(5 free/day → BYOK); free skills just run; money-gated skills refuse to auto-run.

  wrap_agents.py            # regenerate skills/<name>/SKILL.md for every manifest entry
  wrap_agents.py --list     # show what would be generated, write nothing
"""
import json, sys, os
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent          # plugins/genie
MANIFEST = ROOT / "capabilities.json"
SKILLS = ROOT / "skills"

def skill_md(c):
    name, cost, cmd = c["name"], c["cost"], c.get("cmd", "")
    prov = c.get("provider", "")
    trig = c.get("triggers", "")
    summ = c.get("summary", "")
    desc = f"{summ} TRIGGER when the user asks: {trig}."

    if cost == "free":
        gate = ("This skill is **free** (local compute, no metering). Just run it:\n\n"
                f"```\n{cmd} <args>\n```")
    elif cost.startswith("gated:money"):
        desc = "⛔ MONEY-GATED. " + desc + " NEVER runs without the owner's explicit per-action yes."
        gate = ("**MONEY-GATE — do not auto-run.** This touches funds. Stop and get the owner's "
                "explicit yes for THIS action, on a BYOK wallet only. Never sign/move value on your own.\n\n"
                f"```\n{cmd} <args>   # only after an explicit yes\n```")
    else:  # metered
        price = c.get("price_per_call", 0.0)
        creator = c.get("creator_marker", "orangegenie")
        paid = price and price > 0
        if paid:  # 3rd-party bazaar skill → 5 free/day, then PAY-per-call, creator earns their split
            desc = f"[5 free/day, then ${price:.2f}/call → creator {creator}] " + desc
            overcap = (f"  PAY*)   {cmd} <args> ;;   # past 5 free/day → ${price:.2f}/call, "
                       f"{creator} earns their share (settled from your credit)")
            note = (f"This is a **Bazaar skill by `{creator}`**. 5 free/day, then **${price:.2f}/call** — "
                    f"the meter records the earning to {creator} on-chain (proof-of-work); collection/payout "
                    f"is the gated settlement step.")
        else:  # our own platform skill → 5 free/day, then BYOK (COGS→0 for us)
            desc = f"[5 free/day, then BYOK:{prov}] " + desc
            overcap = (f"  BYOK*)  echo \"Used today's 5 free {name} runs. Add your {prov} key to keep "
                       f"going (yours alone — we never see it): meter.sh setkey {prov}\"")
            note = f"This skill **costs us credits**, so it's metered: **5 free/day**, then BYOK `{prov}`."
        gate = (f"{note} Before running, gate it:\n\n"
                f"```\nV=$(bash \"$CLAUDE_PLUGIN_ROOT/tools/meter.sh\" gate {name} {prov})\n"
                f"case \"$V\" in\n"
                f"  ALLOW*) {cmd} <args> ;;                       # under the daily free cap → run\n"
                f"  KEYED*) {cmd} <args> ;;                       # user's own key → unlimited, run\n"
                f"{overcap} ;;\n"
                f"esac\n```")

    return (f"---\nname: {name}\n"
            f"description: {desc}\n---\n\n"
            f"# {name}\n\n{summ}\n\n"
            f"**Cost lane:** `{cost}`" + (f" · provider `{prov}`" if prov else "") + "\n\n"
            f"## How to run\n{gate}\n\n"
            f"_Generated from capabilities.json by wrap_agents.py — edit the manifest, not this file._\n")

def main():
    m = json.load(open(MANIFEST))
    caps = m["capabilities"]
    if "--list" in sys.argv:
        for c in caps:
            print(f"  {c['name']:16} {c['cost']:14} {c.get('provider','')}")
        print(f"\n{len(caps)} capabilities → skills/")
        return
    SKILLS.mkdir(exist_ok=True)
    written = []
    for c in caps:
        d = SKILLS / c["name"]; d.mkdir(exist_ok=True)
        (d / "SKILL.md").write_text(skill_md(c))
        written.append(c["name"])
    print(f"wrapped {len(written)} agents → {SKILLS}")
    for n in written: print(f"  ✓ {n}")

if __name__ == "__main__":
    main()
