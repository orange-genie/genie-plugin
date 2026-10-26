#!/usr/bin/env python3
"""genie_screen.py — capture the selected screen scope and OCR it to TEXT, on-device.

    genie_screen.py full                 # whole screen
    genie_screen.py <x> <y> <w> <h>      # a rect in GLOBAL top-left screen coords

Pipeline (ALL local, zero-egress — the pixels never leave this machine):
  1. `screencapture -x [-R x,y,w,h]` writes a PNG to a temp file (no shutter sound).
  2. OCR via Apple's **Vision** framework (VNRecognizeTextRequest, .accurate) through a tiny
     Swift helper we compile ONCE and cache. Vision ships with macOS — no pip/brew dep.
     Fallback: pytesseract, if present. If neither works we print a NOTE to stderr (never a
     silent empty result) so the caller can tell the user OCR needs a backend.
  3. The temp PNG is DELETED immediately after OCR (nothing is retained).

Recognized text is printed to stdout. Nothing is ever sent off-box by this tool.
"""
import os, sys, subprocess, tempfile, shutil

CACHE = os.path.expanduser("~/.claude/genie/ocr")
HELPER = os.path.join(CACHE, "ocr_helper")
SRC = os.path.join(CACHE, "ocr.swift")

# The Vision OCR helper: reads an image path, prints the recognized lines. Compiled once, cached.
OCR_SWIFT = r'''
import Foundation
import Vision
import AppKit
guard CommandLine.arguments.count > 1 else { exit(2) }
let path = CommandLine.arguments[1]
guard let img = NSImage(contentsOfFile: path),
      let tiff = img.tiffRepresentation,
      let bmp = NSBitmapImageRep(data: tiff),
      let cg = bmp.cgImage else { exit(3) }
let req = VNRecognizeTextRequest()
req.recognitionLevel = .accurate
req.usesLanguageCorrection = true
let handler = VNImageRequestHandler(cgImage: cg, options: [:])
do { try handler.perform([req]) } catch { exit(4) }
var lines: [String] = []
for obs in (req.results ?? []) {
    if let top = obs.topCandidates(1).first { lines.append(top.string) }
}
print(lines.joined(separator: "\n"))
'''


def note(msg):
    sys.stderr.write("[genie_screen] " + msg + "\n")


def ensure_vision_helper():
    """Compile+cache the Swift Vision OCR helper. Returns the helper path or None."""
    if os.path.exists(HELPER) and os.access(HELPER, os.X_OK):
        return HELPER
    swiftc = shutil.which("swiftc")
    if not swiftc:
        return None
    os.makedirs(CACHE, exist_ok=True)
    with open(SRC, "w") as f:
        f.write(OCR_SWIFT)
    r = subprocess.run([swiftc, "-O", SRC, "-o", HELPER],
                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    if r.returncode != 0 or not os.path.exists(HELPER):
        note("Vision helper failed to compile: " + r.stderr.decode("utf-8", "ignore")[:200])
        return None
    return HELPER


def ocr(png):
    # Preferred: Apple Vision (accurate, on-device, no deps).
    helper = ensure_vision_helper()
    if helper:
        r = subprocess.run([helper, png], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        if r.returncode == 0:
            return r.stdout.decode("utf-8", "ignore").strip()
        note("Vision OCR returned code %d" % r.returncode)
    # Fallback: pytesseract, if the user happens to have it.
    try:
        import pytesseract          # noqa
        from PIL import Image       # noqa
        return pytesseract.image_to_string(Image.open(png)).strip()
    except Exception:
        pass
    note("OCR needs a backend: install Xcode command-line tools (Vision, preferred) "
         "or `pip install pytesseract pillow` + `brew install tesseract`.")
    return None


def capture(args):
    fd, png = tempfile.mkstemp(prefix="genie_screen_", suffix=".png")
    os.close(fd)
    cmd = ["screencapture", "-x"]           # -x = no shutter sound
    if not (len(args) == 1 and args[0].lower() == "full"):
        try:
            x, y, w, h = (int(round(float(a))) for a in args[:4])
        except (ValueError, IndexError):
            note("usage: genie_screen.py full | <x> <y> <w> <h>")
            os.unlink(png)
            sys.exit(2)
        if w <= 0 or h <= 0:
            note("empty rect — nothing to capture")
            os.unlink(png)
            sys.exit(2)
        cmd += ["-R%d,%d,%d,%d" % (x, y, w, h)]
    cmd.append(png)
    subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return png


def main():
    args = sys.argv[1:]
    if not args:
        note("usage: genie_screen.py full | <x> <y> <w> <h>")
        sys.exit(2)
    png = capture(args)
    try:
        if not os.path.exists(png) or os.path.getsize(png) == 0:
            note("capture produced no image — grant Screen Recording permission to OrangeGenie.")
            sys.exit(5)
        text = ocr(png)
    finally:
        try:
            os.unlink(png)          # never retain the pixels
        except OSError:
            pass
    if text is None:
        sys.exit(6)                 # backend missing — caller shows the note, never a fake blank
    sys.stdout.write(text)


if __name__ == "__main__":
    main()
