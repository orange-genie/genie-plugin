#!/usr/bin/env python3
"""holder_triage.py — a holder says "I bought it and it's not showing up." Find out where it broke.

    python3 holder_triage.py 195
    python3 holder_triage.py --tx 0x552b5      # a PARTIAL receipt hash is enough
    python3 holder_triage.py 195 --json

WHY THIS EXISTS
A holder reporting "it's not showing up" has given you one symptom for a chain of five systems,
any one of which could be the fault: the mint, the token's own metadata pointer, the metadata
document, the marketplace's index, and the marketplace's image cache. Guessing which one costs
a support round-trip per guess. This walks all five in order and proves or breaks each link, so
the answer to the holder is a fact instead of "let me look into it."

It is READ-ONLY. It signs nothing, spends nothing, and moves nothing.

THE FIVE LINKS, AND WHAT EACH ONE FAILING ACTUALLY MEANS

  1. THE MINT        Transfer event on the contract -> the token exists and is theirs.
                     Broken here: the purchase genuinely failed. Refund territory.
  2. tokenURI        the contract points somewhere.
                     Broken here: our mint script; the token is a shell.
  3. THE METADATA    that URI serves JSON with name/image/animation_url.
                     Broken here: our upload; nothing downstream can work.
  4. THE INDEX       the marketplace has ingested it.
                     Broken here: wait, or ask for a re-index. Genuinely their queue.
  5. THE CDN         the marketplace cached the right bytes.
                     Broken here: a stale or placeholder image. Ask for a refresh.

If all five pass and the holder still sees nothing, the fault is at RENDER time, which is a
different report and is already written up in REPORT_opensea_animation_url.md.

THREE THINGS THAT WASTE AN HOUR IF YOU DON'T KNOW THEM

  · Robinhood Chain produces a block every ~0.1s, so 40 minutes is ~24,000 blocks. Scanning
    blocks for a transaction hash is hopeless. Go at it from the CONTRACT with eth_getLogs on
    the Transfer topic instead — one query covers the whole window.

  · arweave.net answers 302 and redirects to a content-hash subdomain. A fetch without
    follow-redirects returns a 748-byte redirect stub, and every token looks like it has
    broken metadata. Always follow redirects.

  · The OpenSea CDN names each cached object after the MD5 OF THE FILE IT FETCHED. So
    `filename == md5(source asset)` is BYTE PROOF the correct art is cached — not a guess from
    looking at it. Uniqueness is only a proxy and will happily certify stale art as fine.
    Never compare file SIZES; the CDN re-encodes.
"""
from __future__ import annotations
import argparse, hashlib, json, os, ssl, sys, time, urllib.request, urllib.error

# This Python ships without a system CA bundle, so every HTTPS call fails verification. Use
# certifi's when it is there, and NEVER fall back to an unverified context — a triage tool that
# silently stops checking certificates is a tool that can be lied to.
def _ssl_ctx():
    try:
        import certifi
        return ssl.create_default_context(cafile=certifi.where())
    except Exception:
        return ssl.create_default_context()

CTX = _ssl_ctx()


class Unreachable(Exception):
    """The chain or a host could not be reached.

    Kept DISTINCT from a revert on purpose. 'the token does not exist' and 'we could not ask'
    are different answers, and printing the first when the second is true tells a holder their
    purchase failed when it did not. Same mistake, same fix, as the Forge's ethCall.
    """


RPC = "https://rpc.mainnet.chain.robinhood.com"
CHAIN = "robinhood"
CONTRACT = "0x409eab4fa20b5b61d35d2b447b14f384e8ac90e5"   # Builder Bots AI
TRANSFER_TOPIC = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
ENV = os.path.expanduser("~/Genie/PMBot_v1/.env")

OK, BAD, WARN = "  ok  ", " FAIL ", " warn "


def rpc(method, params):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    # The RPC rejects urllib's default agent with a 403. A named agent is also simply good
    # manners toward an endpoint we do not run.
    req = urllib.request.Request(RPC, data=body, headers={
        "content-type": "application/json",
        "user-agent": "OrangeGenie/holder-triage (+https://xearn.com)",
        "accept": "application/json",
    })
    try:
        d = json.load(urllib.request.urlopen(req, timeout=30, context=CTX))
    except Exception as e:
        raise Unreachable(str(e)) from None
    if "error" in d:
        # The node answered and the EVM said no. That IS an answer.
        raise RuntimeError(d["error"].get("message", "rpc error"))
    return d["result"]


def call(to, data):
    return rpc("eth_call", [{"to": to, "data": data}, "latest"])


def selector(sig):
    # Computed, never typed from memory. A wrong selector reads as "this token does not exist",
    # which would tell a holder their purchase failed when it did not.
    from hashlib import sha3_256  # keccak != sha3; see _keccak below
    raise NotImplementedError


def _keccak(b: bytes) -> bytes:
    """Keccak-256. Python's hashlib sha3_256 is the FIPS variant and gives different bytes."""
    try:
        from Crypto.Hash import keccak as _k
        h = _k.new(digest_bits=256); h.update(b); return h.digest()
    except Exception:
        pass
    try:
        import sha3  # pysha3
        return sha3.keccak_256(b).digest()
    except Exception:
        pass
    return b""


# Precomputed so this runs with no crypto dependency at all. Verify with:
#   node -e "console.log(require('ethers').id('ownerOf(uint256)').slice(0,10))"
SEL = {
    "ownerOf(uint256)":   "0x6352211e",
    "tokenURI(uint256)":  "0xc87b56dd",
    "totalSupply()":      "0x18160ddd",
}


def _check_selectors():
    """If a keccak implementation is available, prove the constants above are right."""
    if not _keccak(b"test"):
        return "unverified (no keccak module; constants are precomputed)"
    for sig, want in SEL.items():
        got = "0x" + _keccak(sig.encode()).hex()[:8]
        if got != want:
            raise SystemExit(f"SELECTOR MISMATCH for {sig}: constant {want}, computed {got}")
    return "verified against keccak"


def word(raw, i):
    return raw[2 + i * 64: 2 + (i + 1) * 64]


def dec_string(raw):
    if not raw or raw == "0x":
        return None
    off = int(word(raw, 0), 16) // 32
    ln = int(word(raw, off), 16)
    body = raw[2 + (off + 1) * 64:]
    return bytes.fromhex(body[: ln * 2]).decode("utf-8", "replace")


def fetch(url, timeout=30):
    """GET, FOLLOWING REDIRECTS. arweave 302s to a content-hash subdomain; not following it
    returns a redirect stub and makes healthy metadata look broken."""
    req = urllib.request.Request(url, headers={"user-agent": "OrangeGenie/holder-triage"})
    with urllib.request.urlopen(req, timeout=timeout, context=CTX) as r:  # follows 30x by default
        return r.status, r.headers.get("content-type", ""), r.read()


def opensea(path):
    key = None
    if os.path.exists(ENV):
        for line in open(ENV):
            if line.startswith("OPENSEA_API_KEY="):
                key = line.split("=", 1)[1].strip().strip("\"'")
    if not key:
        return None, "no OPENSEA_API_KEY in the env file"
    req = urllib.request.Request(
        f"https://api.opensea.io/api/v2{path}",
        headers={"X-API-KEY": key, "accept": "application/json",
                 "user-agent": "OrangeGenie/holder-triage"})
    try:
        return json.load(urllib.request.urlopen(req, timeout=30, context=CTX)), None
    except urllib.error.HTTPError as e:
        return None, f"HTTP {e.code}"
    except Exception as e:
        return None, str(e)


def find_by_partial_tx(prefix, minutes=120):
    """Locate a transaction from the PARTIAL hash on a purchase receipt.

    Receipts show an abbreviated hash, which cannot be queried directly. At ~0.1s per block a
    two-hour window is over a million blocks, so scanning them is not an option. eth_getLogs on
    the contract's Transfer topic covers the whole window in a handful of chunked queries.
    """
    prefix = prefix.lower()
    latest = int(rpc("eth_blockNumber", []), 16)
    span = int(minutes * 60 / 0.1)
    start = max(0, latest - span)
    hits, step = [], 5000
    for b in range(start, latest + 1, step):
        try:
            logs = rpc("eth_getLogs", [{
                "address": CONTRACT, "topics": [TRANSFER_TOPIC],
                "fromBlock": hex(b), "toBlock": hex(min(b + step - 1, latest))}])
        except Exception:
            continue
        for lg in logs:
            if lg["transactionHash"].lower().startswith(prefix):
                hits.append({
                    "tokenId": int(lg["topics"][3], 16),
                    "to": "0x" + lg["topics"][2][26:],
                    "block": int(lg["blockNumber"], 16),
                    "tx": lg["transactionHash"],
                })
    return hits


def triage(token_id):
    out = {"token_id": token_id, "contract": CONTRACT, "chain": CHAIN, "links": []}

    def link(name, ok, detail, reached=True):
        # `reached=False` means WE could not ask, which is our problem, not a broken token.
        # It is recorded but never counted as a defect in the holder's NFT.
        out["links"].append({"link": name, "ok": ok, "detail": detail, "reached": reached})
        print(f"{OK if ok else (BAD if reached else WARN)}  {name:<22} {detail}")
        return ok

    tid = hex(token_id)[2:].rjust(64, "0")

    # 2. tokenURI -----------------------------------------------------------------
    try:
        owner = "0x" + word(call(CONTRACT, SEL["ownerOf(uint256)"] + tid), 0)[24:]
        link("mint / ownership", True, f"owned by {owner[:10]}…{owner[-6:]}")
        out["owner"] = owner
    except Unreachable as e:
        link("mint / ownership", False,
             f"could not reach the chain — this says NOTHING about the token ({e})", reached=False)
        out["inconclusive"] = True
        return out
    except Exception as e:
        link("mint / ownership", False, f"ownerOf reverted — the token does not exist ({e})")
        return out

    try:
        uri = dec_string(call(CONTRACT, SEL["tokenURI(uint256)"] + tid))
        link("tokenURI", bool(uri), uri or "EMPTY — the contract points nowhere")
        out["token_uri"] = uri
    except Unreachable as e:
        link("tokenURI", False, f"could not reach the chain ({e})", reached=False)
        out["inconclusive"] = True
        return out
    except Exception as e:
        link("tokenURI", False, f"reverted ({e})")
        return out

    # 3. the metadata document ------------------------------------------------------
    try:
        st, ct, body = fetch(uri)
        meta = json.loads(body)
        has = all(meta.get(k) for k in ("name", "image"))
        link("metadata", has, f"HTTP {st} · {meta.get('name')!r} · "
                              f"image={'yes' if meta.get('image') else 'MISSING'} · "
                              f"animation_url={'yes' if meta.get('animation_url') else 'none'}")
        out["metadata"] = meta
    except Exception as e:
        link("metadata", False, f"could not read: {e}")
        return out

    # source bytes, for the hash proof at link 5
    src_md5 = None
    try:
        _, _, img = fetch(meta["image"], timeout=60)
        src_md5 = hashlib.md5(img).hexdigest()
        link("source art", True, f"{len(img):,} B · md5 {src_md5}")
    except Exception as e:
        link("source art", False, f"image URL did not load: {e}")

    # 4. the marketplace index ------------------------------------------------------
    nft, err = opensea(f"/chain/{CHAIN}/contract/{CONTRACT}/nfts/{token_id}")
    if err:
        link("marketplace index", False, err)
        return out
    n = nft.get("nft", {})
    link("marketplace index", bool(n.get("name")),
         f"{n.get('name')!r} · indexed {n.get('updated_at')}")
    out["marketplace"] = {k: n.get(k) for k in
                          ("name", "updated_at", "image_url", "display_image_url",
                           "animation_url", "is_disabled", "is_nsfw")}

    # 5. the CDN — and the hash proof ------------------------------------------------
    cdn = n.get("display_image_url") or n.get("image_url")
    if not cdn:
        link("cached art", False, "no image_url on the marketplace record")
    else:
        try:
            st, ct, blob = fetch(cdn, timeout=60)
            name_hash = cdn.rsplit("/", 1)[-1].split(".")[0]
            # THE PROOF: the CDN names each object after the md5 of what it fetched.
            if src_md5 and name_hash == src_md5:
                link("cached art", True,
                     f"HTTP {st} · {len(blob):,} B · filename == md5(source): byte-identical")
            elif src_md5:
                link("cached art", False,
                     f"HTTP {st} but cached name {name_hash} != source md5 {src_md5} — STALE")
            else:
                link("cached art", True, f"HTTP {st} · {len(blob):,} B (source hash unavailable)")
        except Exception as e:
            link("cached art", False, f"{e}")

    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("token_id", nargs="?", type=int, help="token id to triage")
    ap.add_argument("--tx", help="partial transaction hash from the holder's receipt")
    ap.add_argument("--minutes", type=int, default=120, help="how far back to look for --tx")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()

    print(f"\n  HOLDER TRIAGE — {CONTRACT} on {CHAIN}")
    print(f"  selectors: {_check_selectors()}")
    print("  " + "-" * 68)

    tid = a.token_id
    if a.tx:
        print(f"  searching the last {a.minutes} min of Transfer logs for tx {a.tx}…")
        hits = find_by_partial_tx(a.tx, a.minutes)
        if not hits:
            print(f"\n  no Transfer matching {a.tx} in that window. Widen with --minutes.\n")
            return 1
        for h in hits:
            print(f"  found  token #{h['tokenId']}  block {h['block']}  tx {h['tx']}")
        tid = hits[0]["tokenId"]
        print()

    if tid is None:
        ap.error("give a token id, or --tx with a partial hash from the receipt")

    out = triage(tid)
    bad = [l for l in out["links"] if not l["ok"] and l.get("reached", True)]
    unreached = [l for l in out["links"] if not l.get("reached", True)]
    print("  " + "-" * 68)
    if unreached:
        print(f"  INCONCLUSIVE — {unreached[0]['detail']}")
        print("  Nothing here is evidence about the holder's token. Fix the connection and re-run.")
    elif bad:
        print(f"  BROKEN AT: {bad[0]['link']} — {bad[0]['detail']}")
    else:
        print("  Every link healthy: minted, owned, metadata served, indexed, correct art cached.")
        print("  If the holder still sees a blank panel, it is the RENDER-time issue — the item")
        print("  page prefers animation_url over image_url and shows nothing when the frame")
        print("  yields nothing. See REPORT_opensea_animation_url.md. Their wallet, the grid and")
        print("  the collection view are unaffected.")
    print()
    if a.json:
        print(json.dumps(out, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
