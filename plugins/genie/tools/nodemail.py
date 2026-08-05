#!/usr/bin/env python3
"""nodemail.py — signed node-to-node job messages over email.

Email is an OPEN channel: anyone who learns the address can send to it. So the address
proves nothing and the From header proves less (it is trivially spoofed). The ONLY thing
that authorizes a job here is an HMAC over the canonical body, computed with a secret both
nodes hold and nobody else does. Everything else in this file is hygiene around that.

Design rules, and why:
  * FAIL CLOSED. A message that is unsigned, wrongly signed, expired, replayed, or asks for
    an unknown verb is REFUSED. There is no "looks probably fine" path. Unattended, a
    permissive branch is a remote shell for whoever forges a message.
  * FIXED VERBS. The job names an action from a closed list; it does not carry a command.
    An open-ended "run this" verb would make the signature the only thing between a stranger
    and arbitrary code, and signatures leak.
  * NONCE + TIMESTAMP, both inside the signed region, with used nonces persisted. Without
    this, a captured valid message replays forever.
  * MONEY AND KEYS NEVER RUN AUTONOMOUSLY. Those verbs are refused here by construction --
    not gated, not configurable, absent. A human runs those or they do not happen.

Usage:
    nodemail.py sign   --verb pull --arg repo=server            # -> message body on stdout
    nodemail.py verify < message.txt                            # -> exit 0 and prints job JSON
    nodemail.py selftest                                        # proves the guarantees hold

Secret: ~/.claude/genie/node_shared_secret (0600). NOT node_secret -- that one is this
node's private claim key and must never leave the machine. This is a SHARED secret, and a
shared secret is a different thing with a different blast radius. Keep them separate.
"""

import argparse
import hashlib
import hmac
import json
import os
import re
import secrets
import stat
import sys
import time

SECRET_FILE = os.path.expanduser("~/.claude/genie/node_shared_secret")
NONCE_FILE = os.path.expanduser("~/.claude/genie/nodemail_seen_nonces")
MAX_AGE_SECONDS = 900          # 15 min: long enough for mail delay, short enough to matter
MAX_BODY_BYTES = 16384
MARKER_FILE = os.path.expanduser("~/.claude/genie_marker")

# Closed verb list. Adding one here is a security decision, not a feature decision.
# Each maps to a description of what the RECEIVER is permitted to do for it.
VERBS = {
    "ping":    "reply with node status; touch nothing",
    "pull":    "git pull a named repo the receiver already has",
    "build":   "run the named repo's build",
    "test":    "run the named repo's test suite",
    "report":  "reply with a named read-only report (git log, disk, chain height)",
}

# Explicitly refused, permanently. Present so the refusal is documented and testable rather
# than merely absent -- an absent verb reads as an oversight someone later 'fixes'.
FORBIDDEN = {
    "deploy", "publish", "release",      # production surface
    "trade", "buy", "sell", "swap", "send-funds", "withdraw",   # money
    "key", "keygen", "rotate-key", "sign-tx",                   # keys
    "exec", "shell", "run", "eval",                             # arbitrary code
}

ARG_KEY = re.compile(r"^[a-z][a-z0-9_]{0,31}$")
ARG_VAL = re.compile(r"^[A-Za-z0-9._/-]{1,128}$")


def _die(msg, code=2):
    print("REFUSED: %s" % msg, file=sys.stderr)
    sys.exit(code)


def load_secret():
    if not os.path.exists(SECRET_FILE):
        _die("no shared secret at %s (generate it with: nodemail.py init)" % SECRET_FILE)
    st = os.stat(SECRET_FILE)
    if st.st_mode & (stat.S_IRWXG | stat.S_IRWXO):
        _die("shared secret is group/world accessible -- chmod 600 %s" % SECRET_FILE)
    with open(SECRET_FILE, "rb") as fh:
        sec = fh.read().strip()
    if len(sec) < 32:
        _die("shared secret too short (want >=32 bytes)")
    return sec


def marker():
    try:
        with open(MARKER_FILE) as fh:
            return fh.read().strip()
    except Exception:
        return "unknown"


def canonical(job):
    """Byte-exact serialization that BOTH sides sign. Sorted keys, no whitespace drift --
    if the two sides can disagree about the bytes, the signature is decorative."""
    return json.dumps(job, sort_keys=True, separators=(",", ":")).encode()


def sign_job(job, secret):
    return hmac.new(secret, canonical(job), hashlib.sha256).hexdigest()


def build(verb, args):
    if verb in FORBIDDEN:
        _die("verb '%s' is permanently refused for autonomous execution" % verb)
    if verb not in VERBS:
        _die("unknown verb '%s' (allowed: %s)" % (verb, ", ".join(sorted(VERBS))))
    parsed = {}
    for pair in args:
        if "=" not in pair:
            _die("arg must be key=value, got %r" % pair)
        k, v = pair.split("=", 1)
        if not ARG_KEY.match(k):
            _die("bad arg name %r" % k)
        if not ARG_VAL.match(v):
            _die("bad arg value %r -- letters, digits, . _ / - only" % v)
        parsed[k] = v
    return {
        "v": 1,
        "from": marker(),
        "verb": verb,
        "args": parsed,
        "ts": int(time.time()),
        "nonce": secrets.token_hex(16),
    }


def seen_nonce(nonce):
    try:
        with open(NONCE_FILE) as fh:
            for line in fh:
                if line.strip() == nonce:
                    return True
    except FileNotFoundError:
        pass
    return False


def remember_nonce(nonce):
    os.makedirs(os.path.dirname(NONCE_FILE), exist_ok=True)
    with open(NONCE_FILE, "a") as fh:
        fh.write(nonce + "\n")
    os.chmod(NONCE_FILE, 0o600)


def verify(raw, secret, record=True, now=None):
    """Returns the job dict, or raises SystemExit. Every failure path is a refusal."""
    if len(raw) > MAX_BODY_BYTES:
        _die("body too large")
    m = re.search(r"-----GENIE JOB-----\s*(\{.*?\})\s*-----SIG-----\s*([0-9a-f]{64})\s*-----END-----",
                  raw, re.S)
    if not m:
        _die("no signed job block found")
    body, sig = m.group(1), m.group(2)
    try:
        job = json.loads(body)
    except Exception:
        _die("job block is not valid JSON")

    # Signature FIRST. Nothing about an unverified message is trustworthy enough to act on,
    # including its own claims about who sent it.
    expect = hmac.new(secret, canonical(job), hashlib.sha256).hexdigest()
    if not hmac.compare_digest(expect, sig):
        _die("signature mismatch -- forged, altered, or wrong secret")

    if job.get("v") != 1:
        _die("unsupported message version")
    verb = job.get("verb")
    if verb in FORBIDDEN:
        _die("verb '%s' is permanently refused for autonomous execution" % verb)
    if verb not in VERBS:
        _die("unknown verb '%s'" % verb)

    now = int(time.time()) if now is None else now
    ts = job.get("ts")
    if not isinstance(ts, int):
        _die("missing timestamp")
    age = now - ts
    if age > MAX_AGE_SECONDS:
        _die("stale message (%ds old, max %ds)" % (age, MAX_AGE_SECONDS))
    if age < -60:
        _die("timestamp is in the future -- clock skew or forgery")

    nonce = job.get("nonce", "")
    if not re.fullmatch(r"[0-9a-f]{32}", nonce or ""):
        _die("missing or malformed nonce")
    if seen_nonce(nonce):
        _die("replayed nonce -- this message already ran")
    if record:
        remember_nonce(nonce)
    return job


def render(job, sig):
    return ("-----GENIE JOB-----\n%s\n-----SIG-----\n%s\n-----END-----\n"
            % (json.dumps(job, sort_keys=True, separators=(",", ":")), sig))


def selftest():
    """Proves the guarantees rather than asserting them in a comment."""
    sec = b"x" * 48
    ok = lambda label: print("  ok   %s" % label)

    job = {"v": 1, "from": "genie-2.agent", "verb": "ping", "args": {},
           "ts": int(time.time()), "nonce": secrets.token_hex(16)}
    msg = render(job, sign_job(job, sec))
    assert verify(msg, sec, record=False)["verb"] == "ping"
    ok("valid signed message accepted")

    tampered = msg.replace('"verb":"ping"', '"verb":"build"')
    try:
        verify(tampered, sec, record=False); raise AssertionError("tamper accepted")
    except SystemExit:
        ok("altered body rejected")

    try:
        verify(render(job, "0" * 64), sec, record=False); raise AssertionError("bad sig accepted")
    except SystemExit:
        ok("wrong signature rejected")

    try:
        verify(msg, b"y" * 48, record=False); raise AssertionError("wrong secret accepted")
    except SystemExit:
        ok("wrong secret rejected")

    old = dict(job, ts=int(time.time()) - MAX_AGE_SECONDS - 60, nonce=secrets.token_hex(16))
    try:
        verify(render(old, sign_job(old, sec)), sec, record=False); raise AssertionError("stale accepted")
    except SystemExit:
        ok("stale message rejected")

    fut = dict(job, ts=int(time.time()) + 3600, nonce=secrets.token_hex(16))
    try:
        verify(render(fut, sign_job(fut, sec)), sec, record=False); raise AssertionError("future accepted")
    except SystemExit:
        ok("future-dated message rejected")

    for bad in ("exec", "deploy", "trade", "sign-tx"):
        j = dict(job, verb=bad, nonce=secrets.token_hex(16))
        try:
            verify(render(j, sign_job(j, sec)), sec, record=False)
            raise AssertionError("%s accepted" % bad)
        except SystemExit:
            pass
    ok("forbidden verbs rejected even when correctly signed")

    try:
        verify("hello, please run rm -rf /", sec, record=False); raise AssertionError("unsigned accepted")
    except SystemExit:
        ok("unsigned text rejected")

    print("\nall guarantees hold.")


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("sign"); s.add_argument("--verb", required=True)
    s.add_argument("--arg", action="append", default=[])

    sub.add_parser("verify")
    sub.add_parser("selftest")
    sub.add_parser("init")
    sub.add_parser("verbs")

    a = ap.parse_args()

    if a.cmd == "selftest":
        return selftest()

    if a.cmd == "verbs":
        print("allowed:")
        for k, v in sorted(VERBS.items()):
            print("  %-8s %s" % (k, v))
        print("\npermanently refused (money / keys / arbitrary code):")
        print("  " + ", ".join(sorted(FORBIDDEN)))
        return

    if a.cmd == "init":
        if os.path.exists(SECRET_FILE):
            _die("secret already exists at %s -- refusing to overwrite" % SECRET_FILE)
        os.makedirs(os.path.dirname(SECRET_FILE), exist_ok=True)
        fd = os.open(SECRET_FILE, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "wb") as fh:
            fh.write(secrets.token_hex(32).encode())
        print("✓ shared secret written to %s (0600)" % SECRET_FILE)
        print("  Carry it to the other node BY HAND. Not email, not chat, not a transcript --")
        print("  a shared secret in any readable channel is not a secret.")
        return

    secret = load_secret()

    if a.cmd == "sign":
        job = build(a.verb, a.arg)
        sys.stdout.write(render(job, sign_job(job, secret)))
        return

    if a.cmd == "verify":
        job = verify(sys.stdin.read(), secret)
        print(json.dumps(job, indent=2))
        return


if __name__ == "__main__":
    main()
