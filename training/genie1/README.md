# Genie 1 — how it's trained

Genie 1 is an open model: Apache-2.0 base weights plus a small adapter we train on the
OrangeGenie Mesh. Everything that makes it is here; the training data is not (it is people's
own words and stays on the machine that made it).

| Step | File | What it does |
|---|---|---|
| 1 | `pull_chain.py` | every skill block on the Mesh, from every author |
| 2 | `intent_labeler.py` | hindsight-labels what a person *meant* (the next messages are the ground truth: a correction means the first read was wrong) |
| 3 | `build_dataset.py` | scrubs keys, addresses, emails, phones, IPs, home paths and private names; drops anything it can't make safe |
| 4 | `train.sh` | QLoRA on the base, exports the adapter |
| 5 | `export_adapter.py` | MLX LoRA → GGUF adapter for Ollama (a few MB, not a 5GB re-bake) |
| 6 | `eval_genie1.py`, `eval_intent.py` | house eval, 15-question leak probe, and a frozen held-out "does it understand what you mean" set |
| 7 | `gate.py` | a build ships only if it beats the base on both evals and leaks nothing |

**Current release** (`genie-1-weights`): house eval 7/16 vs base 6/16 · understands-intent
51/80 vs base 45/80 · leak probe 0/15.

Run it yourself: `ollama pull qwen2.5:7b`, download `genie1-lora.gguf` + `Modelfile` from the
release, `ollama create genie-1 -f Modelfile`. Base model: Qwen2.5-7B-Instruct, Apache-2.0
(see `NOTICE`).
