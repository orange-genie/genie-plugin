#!/usr/bin/env python3
"""Ship Genie 1 as a small adapter on top of an Apache base, not as a re-baked full model.

    python3 export_adapter.py <run_dir> <hf_base_id>     # -> <run_dir>/genie1-lora.gguf

MLX LoRA adapter -> PEFT layout -> GGUF LoRA (llama.cpp converter, MIT). Ollama then serves
`FROM qwen2.5:7b` + `ADAPTER genie1-lora.gguf`: the base is pulled once and every retrain ships
as a ~tens-of-MB file. Fusing a 7B and re-quantizing needs ~35GB of scratch disk; this needs none.

MLX: y = W x + scale * (x @ A) @ B, A (in, r), B (r, out).
PEFT: y = W x + (alpha / r) * B' A' x, A' (r, in), B' (out, r). So A' = A.T, B' = B.T, alpha = scale * r.
"""
import json, os, subprocess, sys
from safetensors.numpy import load_file, save_file

run, base = sys.argv[1], sys.argv[2]
cfg = json.load(open(f"{run}/adapters/adapter_config.json"))
lp = cfg["lora_parameters"]
r = lp["rank"]
w = load_file(f"{run}/adapters/adapters.safetensors")

peft, modules = {}, set()
for k, t in w.items():
    mod, which = k.rsplit(".", 1)                     # model.layers.N.self_attn.q_proj, lora_a|lora_b
    modules.add(mod.rsplit(".", 1)[1])
    name = "A" if which == "lora_a" else "B"
    peft[f"base_model.model.{mod}.lora_{name}.weight"] = t.T.copy().astype("float32")

out = f"{run}/peft"
os.makedirs(out, exist_ok=True)
save_file(peft, f"{out}/adapter_model.safetensors")
json.dump({"peft_type": "LORA", "task_type": "CAUSAL_LM", "base_model_name_or_path": base, "r": r,
           "lora_alpha": lp["scale"] * r, "lora_dropout": 0.0, "bias": "none", "fan_in_fan_out": False,
           "target_modules": sorted(modules)}, open(f"{out}/adapter_config.json", "w"), indent=1)

conv = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "llama.cpp", "convert_lora_to_gguf.py")
subprocess.run([sys.executable, conv, out, "--base-model-id", base, "--outtype", "f16",
                "--outfile", f"{run}/genie1-lora.gguf"], check=True)
print(f"{run}/genie1-lora.gguf", os.path.getsize(f"{run}/genie1-lora.gguf") // 1024, "KB")
