#!/usr/bin/env bash
# video.sh — the node-side Video Genie wire. Dependency-free (curl + python3 only).
#
# Video Genie = Genie aimed at video: pull what a YouTube video actually SAYS, so Genie can
# extract the idea/skill from it and inscribe that to the shared Wildflower Chain (chain.sh skill).
# This is the NODE capability — it needs NO backend, NO Supabase, NO creds. (AUTO's full external
# Video-Genie intel agent — creator subscriptions, replay-density, private table — stays his.)
#
# Usage:
#   video.sh transcript <youtube-url-or-id>   # print "TITLE\t<title>" then the plain transcript text
#   video.sh id <youtube-url-or-id>           # print just the normalized 11-char video id
#
# Best-effort: if YouTube gates the transcript (consent wall, no captions, bot check), it prints a
# single line beginning "FALLBACK" — the caller (Genie) should then fetch the video via its own
# WebFetch/WebSearch and proceed. Never hard-fail; Video Genie still works, just via the model's fetch.
set -euo pipefail

sub="${1:-}"; arg="${2:-}"

norm_id() { # extract an 11-char youtube id from a url or bare id
  printf '%s' "$1" | python3 -c '
import sys,re,urllib.parse
s=sys.stdin.read().strip()
if re.fullmatch(r"[A-Za-z0-9_-]{11}", s): print(s); raise SystemExit
m=re.search(r"(?:v=|/shorts/|/embed/|youtu\.be/)([A-Za-z0-9_-]{11})", s)
if m: print(m.group(1)); raise SystemExit
u=urllib.parse.urlparse(s)
q=urllib.parse.parse_qs(u.query)
if "v" in q and re.fullmatch(r"[A-Za-z0-9_-]{11}", q["v"][0]): print(q["v"][0]); raise SystemExit
print("", end="")'
}

case "$sub" in
  id)
    vid="$(norm_id "$arg")"; [ -n "$vid" ] || { echo "FALLBACK: not a recognizable YouTube URL/id"; exit 0; }
    echo "$vid" ;;
  transcript)
    [ -n "$arg" ] || { echo "usage: video.sh transcript <youtube-url-or-id>"; exit 1; }
    vid="$(norm_id "$arg")"
    [ -n "$vid" ] || { echo "FALLBACK: not a recognizable YouTube URL/id"; exit 0; }

    # ── PRIMARY: yt-dlp if present (robust; handles YouTube's caption gating) ──
    if command -v yt-dlp >/dev/null 2>&1; then
      d="$(mktemp -d -t vgy.XXXXXX)"; trap 'rm -rf "$d"' EXIT
      yt-dlp -q --no-warnings --skip-download --write-subs --write-auto-subs \
             --sub-langs 'en.*,en' --sub-format vtt \
             -o "$d/s.%(ext)s" "https://www.youtube.com/watch?v=$vid" >/dev/null 2>&1 || true
      vtt="$(ls "$d"/*.vtt 2>/dev/null | head -1)"
      title="$(yt-dlp -q --no-warnings --skip-download --print '%(title)s' "https://www.youtube.com/watch?v=$vid" 2>/dev/null | head -1)"
      if [ -n "$vtt" ] && [ -s "$vtt" ]; then
        result="$(VTT="$vtt" TITLE="$title" python3 - <<'PY'
import os,re,html as H
lines=open(os.environ["VTT"],encoding="utf-8",errors="ignore").read().splitlines()
out=[]
for ln in lines:
    if not ln.strip(): continue
    if ln.startswith(("WEBVTT","Kind:","Language:")): continue
    if "-->" in ln: continue
    if re.fullmatch(r"\d+", ln.strip()): continue
    t=re.sub(r"<[^>]+>","",ln)               # strip <c>/<00:00:00.000> inline tags
    t=H.unescape(t).strip()
    if t and (not out or out[-1]!=t): out.append(t)  # drop consecutive dup lines (auto-sub rolling)
text=re.sub(r"[ \t]+"," "," ".join(out)).strip()
if text:
    ti=os.environ.get("TITLE","").strip()
    if ti: print("TITLE\t"+ti)
    w=text.split()
    if len(w)>4000: text=" ".join(w[:4000])+" …[transcript truncated at 4000 words]"
    print(text)
else:
    print("__EMPTY__")
PY
)"
        # yt-dlp produced usable text → done; otherwise fall through to the no-dep scrape
        if [ -n "$result" ] && [ "$result" != "__EMPTY__" ]; then
          printf '%s\n' "$result"; exit 0
        fi
      fi
    fi

    UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124 Safari/537.36"
    # consent cookie sidesteps the EU consent wall that otherwise hides the player response
    page="$(mktemp -t vg.XXXXXX)"; cap="$(mktemp -t vgc.XXXXXX)"; trap 'rm -rf "${d:-}" "$page" "$cap"' EXIT
    curl -fsSL --max-time 20 -A "$UA" -H 'Accept-Language: en-US,en;q=0.9' \
         --cookie 'CONSENT=YES+1' "https://www.youtube.com/watch?v=$vid&hl=en" -o "$page" 2>/dev/null || true
    [ -s "$page" ] || { echo "FALLBACK: could not load the video page (network/geo/bot-gate)"; exit 0; }
    # python only PARSES the page (no network — sidesteps the macOS-python SSL cert bug);
    # it prints the chosen caption-track URL on line 1 (or FALLBACK), title on line 2.
    meta="$(PAGE="$page" python3 - <<'PY'
import os,re,json,html as H
page=open(os.environ["PAGE"],encoding="utf-8",errors="ignore").read()
mt=re.search(r"<title>(.*?)</title>", page, re.S)
title=H.unescape(mt.group(1)).replace(" - YouTube","").strip() if mt else ""
m=re.search(r'"captionTracks":(\[.*?\])', page)
if not m: print("FALLBACK: no captions/transcript available for this video"); raise SystemExit
try: tracks=json.loads(m.group(1))
except Exception: print("FALLBACK: could not parse caption tracks"); raise SystemExit
if not tracks: print("FALLBACK: no caption tracks"); raise SystemExit
def score(t):
    lang=(t.get("languageCode") or "").lower(); kind=t.get("kind","")
    return (lang.startswith("en"), kind!="asr")
base=sorted(tracks, key=score, reverse=True)[0].get("baseUrl","")
if not base: print("FALLBACK: caption track had no url"); raise SystemExit
base=base.encode().decode("unicode_escape")
print(base+("&" if "?" in base else "?")+"fmt=json3")
print("TITLE\t"+title)
PY
)"
    caps_url="$(printf '%s' "$meta" | sed -n '1p')"
    title_line="$(printf '%s' "$meta" | sed -n '2p')"
    case "$caps_url" in FALLBACK*) echo "$caps_url"; exit 0;; esac
    # fetch the transcript with curl (system CA store — works cross-platform)
    curl -fsSL --max-time 20 -A "$UA" "$caps_url" -o "$cap" 2>/dev/null || true
    [ -s "$cap" ] || { echo "FALLBACK: YouTube gated the transcript (POT). Install yt-dlp for a reliable pull (macOS: brew install yt-dlp · pip: pipx install yt-dlp), or paste the transcript."; exit 0; }
    CAP="$cap" TITLE="$title_line" python3 - <<'PY'
import os,re,json,html as H
raw=open(os.environ["CAP"],encoding="utf-8",errors="ignore").read()
text=""
try:
    data=json.loads(raw)
    text="".join(s.get("utf8","") for ev in data.get("events",[]) for s in (ev.get("segs") or []) if s.get("utf8"))
except Exception:
    parts=re.findall(r"<text[^>]*>(.*?)</text>", raw, re.S)
    text=H.unescape(re.sub(r"<[^>]+>"," "," ".join(parts)))
text=re.sub(r"[ \t]+"," ", text).strip()
if not text: print("FALLBACK: transcript came back empty"); raise SystemExit
t=os.environ.get("TITLE","")
if t.startswith("TITLE\t") and t.strip()!="TITLE": print(t)
words=text.split()
if len(words)>4000: text=" ".join(words[:4000])+" …[transcript truncated at 4000 words]"
print(text)
PY
    ;;
  *)
    echo "usage: video.sh {transcript <url> | id <url>}"; exit 1 ;;
esac
