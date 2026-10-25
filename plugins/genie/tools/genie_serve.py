#!/usr/bin/env python3
"""genie_serve.py — stand up the FREE LOCAL AI (genie-1) on macOS OR Windows OR Linux.

One cross-platform launcher (Python, which every target ships) so the app doesn't need OS-specific
glue. It:
  1. finds the Ollama binary (ollama / ollama.exe) — on PATH or bundled inside the app
  2. starts Ollama serving (the local base model — no key, no egress)
  3. pulls a small model if the machine is bare
  4. starts genie_llm.py on :8756 (OpenAI-compatible + Wildflower Chain grounding)
genie-1 then runs free + local: no key, nothing leaves the machine. Idempotent.

  python genie_serve.py            # ensure everything is up (safe to re-run)
  python genie_serve.py --status   # report only
"""
import os, sys, time, json, subprocess, platform, urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
LLM_PORT = int(os.environ.get("GENIE_LLM_PORT", "8756"))
OLLAMA_PORT = 11434
MODEL = os.environ.get("GENIE_LOCAL_MODEL", "qwen2.5:1.5b")   # small default (~1GB), Apache-2.0
IS_WIN = platform.system() == "Windows"
EXE = "ollama.exe" if IS_WIN else "ollama"


def _port_up(port):
    try:
        urllib.request.urlopen(f"http://127.0.0.1:{port}", timeout=2)
        return True
    except urllib.error.URLError as e:
        return not isinstance(getattr(e, "reason", None), ConnectionRefusedError)  # answered = up
    except Exception:
        # a socket connect is the reliable test when the HTTP root 404s
        import socket
        s = socket.socket(); s.settimeout(2)
        try: s.connect(("127.0.0.1", port)); return True
        except Exception: return False
        finally: s.close()


def find_ollama():
    # 1) PATH  2) bundled next to us or in the app's bin/ (mac: ../bin, win: ..\bin, or Resources/bin)
    import shutil
    p = shutil.which(EXE)
    if p:
        return p
    for c in [HERE / EXE, HERE / "bin" / EXE, HERE.parent / "bin" / EXE, HERE.parent / "Resources" / "bin" / EXE]:
        if c.exists() and os.access(c, os.X_OK if not IS_WIN else os.F_OK):
            return str(c)
    return None


def _spawn(args, **kw):
    # background process, no console window on Windows
    flags = subprocess.CREATE_NO_WINDOW if IS_WIN else 0
    return subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                            creationflags=flags, **kw)


def main():
    status = "--status" in sys.argv
    if status:
        print(f"ollama  ({OLLAMA_PORT}): {'UP' if _port_up(OLLAMA_PORT) else 'down'}")
        print(f"genie-1 ({LLM_PORT}): {'UP' if _port_up(LLM_PORT) else 'down'}")
        return

    ollama = find_ollama()
    if not ollama:
        print("⚠️  Ollama not found (PATH or bundle). Free local model needs it: https://ollama.com/download")
        print("    (genie-1 still works if you point it at a hosted model with your own key.)")
        sys.exit(1)

    # 1. serve
    if not _port_up(OLLAMA_PORT):
        print("⬢ starting ollama…")
        _spawn([ollama, "serve"])
        for _ in range(20):
            if _port_up(OLLAMA_PORT): break
            time.sleep(0.5)

    # 2. model
    have = ""
    try:
        tags = json.load(urllib.request.urlopen(f"http://127.0.0.1:{OLLAMA_PORT}/api/tags", timeout=5))
        have = (tags.get("models") or [{}])[0].get("name", "")
    except Exception:
        pass
    if not have:
        print(f"⬢ no local model — pulling {MODEL} (one-time, ~1.3GB)…")
        subprocess.run([ollama, "pull", MODEL])
        have = MODEL

    # 3. genie-1
    if _port_up(LLM_PORT):
        print(f"✓ genie-1 already live on :{LLM_PORT}")
        return
    print(f"⬢ starting genie-1 on :{LLM_PORT}  (local · free · model={have})")
    env = dict(os.environ, GENIE_UPSTREAM=f"http://localhost:{OLLAMA_PORT}/v1",
               GENIE_UPSTREAM_MODEL=have, GENIE_LLM_PORT=str(LLM_PORT))
    _spawn([sys.executable, str(HERE / "genie_llm.py")], env=env)
    for _ in range(20):
        if _port_up(LLM_PORT): break
        time.sleep(0.5)
    print("✅ genie-1 live → http://localhost:%d/v1  (model: genie-1, free, zero-egress)" % LLM_PORT
          if _port_up(LLM_PORT) else "⚠️  genie-1 didn't come up — check the log")


if __name__ == "__main__":
    main()
