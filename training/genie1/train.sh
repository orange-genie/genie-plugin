#!/bin/bash
# Genie 1 — one run: dataset -> LoRA (MLX, on this Mac) -> fuse -> ollama `genie-1` -> eval vs base.
# Base = Apache-2.0 weights, so the result is ours to name and sell. Re-run any time: more sessions,
# more chain skills, more consented exchanges = a better Genie 1.
set -e
cd "$(dirname "$0")"
BASE="${BASE:-mlx-community/Qwen2.5-7B-Instruct-4bit}"   # Apache-2.0 (3B is NOT; skip it)
OBASE="${OBASE:-qwen2.5:7b}"                             # the same weights in ollama: serve + eval base
HF_BASE="${HF_BASE:-Qwen/Qwen2.5-7B-Instruct}"           # config source for the adapter converter
TAG="$(date +%Y%m%d-%H%M)"
RUN="runs/$TAG"; mkdir -p "$RUN"
python3 pull_chain.py && { [ -n "$SKIP_LABEL" ] || python3 intent_labeler.py; } && python3 build_dataset.py | tee "$RUN/dataset.txt"
python3 -m mlx_lm lora --model "$BASE" --train --data data --adapter-path "$RUN/adapters" \
  --iters "${ITERS:-600}" --batch-size 2 --num-layers 8 --learning-rate 2e-5 --mask-prompt \
  --max-seq-length 2048 --grad-checkpoint --steps-per-eval 200 --save-every 400 2>&1 | tee "$RUN/train.log"
# Ship as an ADAPTER on the Apache base (tens of MB), not a re-baked 7B: fusing + re-quantizing a 7B
# needs ~35GB scratch disk, and every retrain would be a 4.7GB download for users.
python3 export_adapter.py "$RUN" "$HF_BASE" 2>&1 | tail -1
# The chat template is NOT optional: imported safetensors get `{{ .Prompt }}` (raw completion) and the
# model never chats. Run 1 (10/24) scored 2/16 vs base 6/16 for exactly this reason. Copy the base's.
ollama pull "$OBASE" >/dev/null && ollama show "$OBASE" --template > "$RUN/template.txt"
python3 - "$RUN" "$OBASE" <<'PY'
import sys, build_dataset as b
R, base = sys.argv[1], sys.argv[2]; t = open(f"{R}/template.txt").read()
open(f"{R}/Modelfile", "w").write(f'FROM {base}\nADAPTER ./genie1-lora.gguf\nTEMPLATE """{t}"""\nSYSTEM """{b.SYSTEM}"""\n'
    'PARAMETER temperature 0.6\nPARAMETER stop <|im_start|>\nPARAMETER stop <|im_end|>\n')
PY
(cd "$RUN" && ollama create "genie-1:$TAG" -f Modelfile)
python3 eval_genie1.py "genie-1:$TAG" "$OBASE" | tee "$RUN/eval.txt"
python3 eval_intent.py "$OBASE" "genie-1:$TAG" | tee "$RUN/intent_eval.txt" || true
python3 gate.py "$RUN" "genie-1:$TAG" --promote | tee -a "$RUN/eval.txt"
