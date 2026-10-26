#!/usr/bin/env python3
"""agent_key.py — every .agent gets its own key, so a skill's author is proven, not typed.

    agent_key.py init <name.agent>                 make this node's key for the name (once)
    agent_key.py bind-message <name.agent>         the text the name's HOLDER signs with their wallet
    agent_key.py bind <name.agent> <wallet_sig> <ts>   register the key (server checks the holder)
    agent_key.py status <name.agent>               is a key bound on the Mesh, and is it this one
    agent_key.py sign <name.agent> <src_id> <summary_file> <body_file>   -> {"sig","sig_ts"} (chain.sh)

The private key lives at ~/.claude/genie/keys/<name>.ed25519 (0600) and never leaves this machine.
The holder signs once with their wallet; the server checks that wallet against ownerOf(name) and
inscribes the public key as an AGENT_KEY block. From then on every write by that name must be
signed with this key, and royalty pays only signed (verified) authors.
"""
import datetime, hashlib, json, os, sys, urllib.request

API = os.environ.get("GENIE_API", "https://orangegenie-api-production.up.railway.app")
KEYS = os.path.expanduser("~/.claude/genie/keys")

# ── ed25519: the cryptography package when present, else the RFC 8032 reference (pure python) ──
try:
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
    from cryptography.hazmat.primitives import serialization as _ser

    def _pub(seed):
        return Ed25519PrivateKey.from_private_bytes(seed).public_key().public_bytes(_ser.Encoding.Raw, _ser.PublicFormat.Raw)

    def _sign(seed, msg):
        return Ed25519PrivateKey.from_private_bytes(seed).sign(msg)
except ImportError:
    _p = 2 ** 255 - 19
    _q = 2 ** 252 + 27742317777372353535851937790883648493
    _d = -121665 * pow(121666, _p - 2, _p) % _p
    _I = pow(2, (_p - 1) // 4, _p)

    def _xr(y):
        xx = (y * y - 1) * pow(_d * y * y + 1, _p - 2, _p)
        x = pow(xx, (_p + 3) // 8, _p)
        if (x * x - xx) % _p: x = x * _I % _p
        return _p - x if x % 2 else x

    _B = (_xr(4 * pow(5, _p - 2, _p) % _p), 4 * pow(5, _p - 2, _p) % _p)

    def _add(P, Q):
        x1, y1 = P; x2, y2 = Q
        t = _d * x1 * x2 * y1 * y2
        return ((x1 * y2 + x2 * y1) * pow(1 + t, _p - 2, _p) % _p, (y1 * y2 + x1 * x2) * pow(1 - t, _p - 2, _p) % _p)

    def _mul(P, e):
        R = (0, 1)
        while e:
            if e & 1: R = _add(R, P)
            P = _add(P, P); e >>= 1
        return R

    def _enc(P):
        x, y = P
        return (y | ((x & 1) << 255)).to_bytes(32, "little")

    def _h(m): return int.from_bytes(hashlib.sha512(m).digest(), "little")

    def _expand(seed):
        h = hashlib.sha512(seed).digest()
        a = int.from_bytes(h[:32], "little")
        a &= (1 << 254) - 8; a |= 1 << 254
        return a, h[32:]

    def _pub(seed):
        return _enc(_mul(_B, _expand(seed)[0]))

    def _sign(seed, msg):
        a, pre = _expand(seed)
        A = _enc(_mul(_B, a))
        r = _h(pre + msg) % _q
        R = _enc(_mul(_B, r))
        return R + ((r + _h(R + A + msg) * a) % _q).to_bytes(32, "little")


def _name(n):
    n = n.strip().lower()
    return n if n.endswith(".agent") else n + ".agent"

def _path(name): return os.path.join(KEYS, name + ".ed25519")

def _seed(name):
    try: return bytes.fromhex(open(_path(name)).read().strip())
    except OSError: sys.exit(f"no key for {name} on this machine: run  agent_key.py init {name}")

def _now(): return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")

def bind_message(name, pub, ts): return f"OrangeGenie Mesh: bind agent key\nname: {name}\nkey: {pub}\nts: {ts}"

def _http(method, path, body=None):
    req = urllib.request.Request(API + path, method=method, data=json.dumps(body).encode() if body else None,
                                 headers={"Content-Type": "application/json", "User-Agent": "genie-agent-key"})
    try:
        with urllib.request.urlopen(req, timeout=20) as r: return r.status, json.load(r)
    except urllib.error.HTTPError as e:
        try: return e.code, json.load(e)
        except ValueError: return e.code, {"error": str(e)}

def main(a):
    if len(a) < 2: sys.exit(__doc__)
    cmd, name = a[0], _name(a[1])
    if cmd == "init":
        os.makedirs(KEYS, mode=0o700, exist_ok=True)
        if os.path.exists(_path(name)):
            print(f"{name} already has a key here: {_pub(_seed(name)).hex()}"); return
        fd = os.open(_path(name), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as f: f.write(os.urandom(32).hex())
        print(f"{name} key made. Public key: {_pub(_seed(name)).hex()}\nNext: agent_key.py bind-message {name}")
    elif cmd == "bind-message":
        ts = _now()
        print(json.dumps({"message": bind_message(name, _pub(_seed(name)).hex(), ts), "ts": ts}))
    elif cmd == "bind":
        if len(a) < 4: sys.exit("usage: agent_key.py bind <name.agent> <wallet_sig> <ts>")
        code, r = _http("POST", "/api/agent/bind", {"name": name, "pubkey": _pub(_seed(name)).hex(), "ts": a[3], "wallet_sig": a[2]})
        print(("✓ bound " if code == 200 else f"✗ {code} ") + json.dumps(r)); sys.exit(0 if code == 200 else 1)
    elif cmd == "status":
        code, r = _http("GET", f"/api/agent/key/{name}")
        mine = os.path.exists(_path(name)) and r.get("pubkey") == _pub(_seed(name)).hex()
        print(json.dumps({**r, "this_machine": mine}))
    elif cmd == "sign":
        if len(a) < 5: sys.exit("usage: agent_key.py sign <name.agent> <src_id> <summary_file> <body_file>")
        summary, body = open(a[3], encoding="utf-8").read(), open(a[4], encoding="utf-8").read()
        ts = _now()
        digest = hashlib.sha256(f"{summary}\n{body}".encode("utf-8")).hexdigest()
        msg = f"{name}\n{a[2]}\n{digest}\n{ts}".encode("utf-8")
        print(json.dumps({"sig": _sign(_seed(name), msg).hex(), "sig_ts": ts}))
    else:
        sys.exit(__doc__)

if __name__ == "__main__":
    main(sys.argv[1:])
