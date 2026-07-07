---
name: video-genie
description: [5 free/day, then BYOK:anthropic] Branded video maker: generates captions + stitches clips into an .mp4 (ffmpeg). Caption gen uses Claude. TRIGGER when the user asks: make a video, build a promo clip, generate a branded video, caption + stitch clips.
---

# video-genie

Branded video maker: generates captions + stitches clips into an .mp4 (ffmpeg). Caption gen uses Claude.

**Cost lane:** `metered` · provider `anthropic`

## How to run
This skill **costs us credits**, so it's metered: **5 free/day**, then BYOK `anthropic`. Before running, gate it:

```
V=$(bash "$CLAUDE_PLUGIN_ROOT/tools/meter.sh" gate video-genie anthropic)
case "$V" in
  ALLOW*) zsh ~/Genie/_video_build/build_video.sh <args> ;;                       # under the daily free cap → run
  KEYED*) zsh ~/Genie/_video_build/build_video.sh <args> ;;                       # user's own key → unlimited, run
  BYOK*)  echo "Used today's 5 free video-genie runs. Add your anthropic key to keep going (yours alone — we never see it): meter.sh setkey anthropic" ;;
esac
```

_Generated from capabilities.json by wrap_agents.py — edit the manifest, not this file._
