#!/usr/bin/env python3
"""wallet_truth — what an EVM wallet can ACTUALLY realize. Read-only. No keys, ever.

Wallet UIs lie in three different ways, and each one costs somebody an afternoon:

  1. THE DISPLAY LIE.  Some wallets compute a balance by summing historical Transfer
     events instead of calling balanceOf(). For a rebasing or reflection token those
     two numbers diverge permanently. A wallet can show $900 of a token the contract
     says you hold four hundredths of a cent of. Every exchange, router and pool reads
     balanceOf() -- so balanceOf() is the only number that can ever be sold.
     -> we report BOTH and flag the gap.

  2. THE BAIT POOL.  A spam token is airdropped to thousands of wallets, and a pool is
     seeded with real WETH and almost no token side. Anyone who does the constant-product
     math sees a five-figure payout waiting. The token's transfer() then reverts for
     everyone but the operator, often with an advertisement as the revert string. The
     ETH is real, belongs to the operator, and is bait for the website in that message.
     A live DEX quote does NOT rule this out -- the quote is computed from real reserves.
     -> we SIMULATE the sell-side transfer with eth_call and quote the revert verbatim.

  3. THE MISSING POOL.  Indexers only know pools they have indexed. A pool holding real
     ETH that hasn't traded in a year can be invisible to every price API.
     -> we walk the FACTORIES directly (getPair / getPool) and read reserves on-chain.

Nothing here can move a token. There is no signing path in this file, no key is read,
and every call is eth_call or a balance read. It is safe to run against any address,
including one you do not own.

Usage
  python3 wallet_truth.py 0xADDRESS
  python3 wallet_truth.py 0xADDRESS --chain base
  python3 wallet_truth.py 0xADDRESS --token 0xTOKEN     # deep-dive one token
  python3 wallet_truth.py 0xADDRESS --json report.json

Token discovery uses Alchemy when ALCHEMY_API_KEY is set (fastest, complete), and falls
back to Blockscout, which needs no key at all. Pool math, simulation and the balanceOf
truth-check never need a key on any path.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import time

# ---------------------------------------------------------------- chains & constants

CHAINS = {
    "ethereum": {
        "rpc": "https://ethereum-rpc.publicnode.com",
        "alchemy": "eth-mainnet",
        "blockscout": "https://eth.blockscout.com",
        "wrapped": "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2",
        "wsym": "WETH",
        "v2": {  # uniswap-v2-compatible factories, all expose getPair(a,b)
            "UniV2": "0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f",
            "Sushi": "0xC0AEe478e3658e2610c5F7A4A2E1777cE9e4f2Ac",
            "Shiba": "0x115934131916C8b277DD010Ee02de363c09d037c",
        },
        "v3": "0x1F98431c8aD98523631AE4a59f267346ea31F984",
        "explorer": "https://etherscan.io",
    },
    "base": {
        "rpc": "https://base-rpc.publicnode.com",
        "alchemy": "base-mainnet",
        "blockscout": "https://base.blockscout.com",
        "wrapped": "0x4200000000000000000000000000000000000006",
        "wsym": "WETH",
        "v2": {"UniV2": "0x8909Dc15e40173Ff4699343b6eB8132c65e18eC6"},
        "v3": "0x33128a8fC17869897dcE68Ed026d694621f6FDfD",
        "explorer": "https://basescan.org",
    },
    "polygon": {
        "rpc": "https://polygon-bor-rpc.publicnode.com",
        "alchemy": "polygon-mainnet",
        "blockscout": "https://polygon.blockscout.com",
        "wrapped": "0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270",
        "wsym": "WMATIC",
        "v2": {"QuickSwap": "0x5757371414417b8C6CAad45bAeF941aBc7d3Ab32",
               "Sushi": "0xc35DADB65012eC5796536bD9864eD8773aBc74C4"},
        "v3": "0x1F98431c8aD98523631AE4a59f267346ea31F984",
        "explorer": "https://polygonscan.com",
    },
    "arbitrum": {
        "rpc": "https://arbitrum-one-rpc.publicnode.com",
        "alchemy": "arb-mainnet",
        "blockscout": "https://arbitrum.blockscout.com",
        "wrapped": "0x82aF49447D8a07e3bd95BD0d56f35241523fBab1",
        "wsym": "WETH",
        "v2": {"Sushi": "0xc35DADB65012eC5796536bD9864eD8773aBc74C4"},
        "v3": "0x1F98431c8aD98523631AE4a59f267346ea31F984",
        "explorer": "https://arbiscan.io",
    },
    "optimism": {
        "rpc": "https://optimism-rpc.publicnode.com",
        "alchemy": "opt-mainnet",
        "blockscout": "https://optimism.blockscout.com",
        "wrapped": "0x4200000000000000000000000000000000000006",
        "wsym": "WETH",
        "v2": {},
        "v3": "0x1F98431c8aD98523631AE4a59f267346ea31F984",
        "explorer": "https://optimistic.etherscan.io",
    },
}

# selectors
SEL = {
    "balanceOf": "0x70a08231", "decimals": "0x313ce567", "symbol": "0x95d89b41",
    "name": "0x06fdde03", "totalSupply": "0x18160ddd", "transfer": "0xa9059cbb",
    "getReserves": "0x0902f1ac", "token0": "0x0dfe1681", "token1": "0xd21220a7",
    "getPair": "0xe6a43905", "getPool": "0x1698ee82",
}
TRANSFER_TOPIC = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
GAS_SELL = 170_000  # a fee-on-transfer sell through a v2 router


# ---------------------------------------------------------------- rpc plumbing

class RPC:
    """Batched JSON-RPC over curl. No dependencies beyond curl and python3."""

    def __init__(self, url, quiet=False):
        self.url = url
        self.quiet = quiet
        self.calls = 0

    def _post(self, body, timeout=45):
        out = subprocess.run(
            ["curl", "-s", "--max-time", str(timeout), "-X", "POST",
             "-H", "Content-Type: application/json", "--data", json.dumps(body), self.url],
            capture_output=True, text=True).stdout
        try:
            return json.loads(out)
        except Exception:
            return None

    def one(self, method, params):
        self.calls += 1
        r = self._post({"jsonrpc": "2.0", "id": 1, "method": method, "params": params})
        return r if isinstance(r, dict) else {}

    def call(self, to, data, block="latest", frm=None):
        tx = {"to": to, "data": data}
        if frm:
            tx["from"] = frm
        return self.one("eth_call", [tx, block])

    def result(self, to, data, block="latest"):
        r = self.call(to, data, block)
        v = r.get("result")
        return None if (v is None or v == "0x") else v

    def batch_call(self, calls, size=40):
        """calls: [(to, data)] -> [hexresult|None], preserving order."""
        out = []
        for i in range(0, len(calls), size):
            chunk = calls[i:i + size]
            self.calls += len(chunk)
            body = [{"jsonrpc": "2.0", "id": j, "method": "eth_call",
                     "params": [{"to": to, "data": d}, "latest"]}
                    for j, (to, d) in enumerate(chunk)]
            res = self._post(body) or []
            by = {r.get("id"): r.get("result") for r in res if isinstance(r, dict)}
            out += [(None if by.get(j) in (None, "0x") else by.get(j)) for j in range(len(chunk))]
            time.sleep(0.08)
        return out


def pad(addr):
    return addr.lower().replace("0x", "").rjust(64, "0")


def word(n):
    return hex(n)[2:].rjust(64, "0")


def dec_string(hexdata):
    """Decode an ABI-encoded string return, tolerating bytes32-style tokens."""
    if not hexdata:
        return ""
    h = hexdata[2:]
    if len(h) >= 128:
        try:
            ln = int(h[64:128], 16)
            if 0 < ln <= 64 and len(h) >= 128 + ln * 2:
                return bytes.fromhex(h[128:128 + ln * 2]).decode("utf-8", "ignore").strip("\x00")
        except Exception:
            pass
    try:  # bytes32 symbol (very old tokens)
        return bytes.fromhex(h[:64]).decode("utf-8", "ignore").strip("\x00")
    except Exception:
        return ""


# ---------------------------------------------------------------- discovery

def curl_json(url, timeout=30):
    out = subprocess.run(["curl", "-s", "--max-time", str(timeout), url],
                         capture_output=True, text=True).stdout
    try:
        return json.loads(out)
    except Exception:
        return None


def discover_alchemy(addr, net, key):
    url = f"https://{net}.g.alchemy.com/v2/{key}"
    rpc = RPC(url)
    bals, pk = [], None
    while True:
        params = [addr, "erc20"] if pk is None else [addr, "erc20", {"pageKey": pk}]
        r = rpc.one("alchemy_getTokenBalances", params).get("result") or {}
        bals += [b for b in r.get("tokenBalances", [])
                 if b.get("tokenBalance") and int(b["tokenBalance"], 16) > 0]
        pk = r.get("pageKey")
        if not pk:
            break
    return [b["contractAddress"].lower() for b in bals]


def discover_blockscout(addr, base):
    d = curl_json(f"{base}/api/v2/addresses/{addr}/token-balances")
    if not isinstance(d, list):
        return None
    return [((t.get("token") or {}).get("address_hash")
             or (t.get("token") or {}).get("address") or "").lower()
            for t in d
            if ((t.get("token") or {}).get("type") or "ERC-20") == "ERC-20"
            and int(t.get("value") or 0) > 0]


def discover_logs(rpc, addr, span=800_000):
    """Last resort with no indexer at all: scan recent inbound Transfer logs."""
    head = rpc.one("eth_blockNumber", []).get("result")
    if not head:
        return []
    head = int(head, 16)
    r = rpc.one("eth_getLogs", [{"fromBlock": hex(max(0, head - span)), "toBlock": "latest",
                                "topics": [TRANSFER_TOPIC, None, "0x" + pad(addr)]}])
    return sorted({l["address"].lower() for l in (r.get("result") or [])})


# ---------------------------------------------------------------- the truth check

def transfer_sum(rpc, addr, token, is_alchemy=False):
    """Sum inbound minus outbound Transfer events -- what a naive wallet UI displays.

    Prefers alchemy_getAssetTransfers, which serves full history in one call. Falls back
    to chunked eth_getLogs, because public nodes refuse an unbounded range and answering
    'unknown' when the data is reachable would be its own kind of lie.

    Returns (net_raw, transfers) or (None, None) when history genuinely can't be read.
    """
    if is_alchemy:
        net, seen = 0, []
        for key, sign in (("toAddress", 1), ("fromAddress", -1)):
            page = None
            while True:
                p = {"fromBlock": "0x0", "toBlock": "latest", "contractAddresses": [token],
                     "category": ["erc20"], "withMetadata": True, "maxCount": "0x3e8", key: addr}
                if page:
                    p["pageKey"] = page
                r = rpc.one("alchemy_getAssetTransfers", [p])
                if "error" in r:
                    net = None
                    break
                res = r.get("result") or {}
                for t in res.get("transfers", []):
                    raw = t.get("rawContract", {}).get("value")
                    v = int(raw, 16) if raw else 0
                    net += sign * v
                    seen.append((((t.get("metadata") or {}).get("blockTimestamp") or "")[:10],
                                 sign, t.get("value"), t.get("hash")))
                page = res.get("pageKey")
                if not page:
                    break
            if net is None:
                break
        if net is not None:
            return net, sorted(seen)

    # keyless fallback: walk the range in chunks
    head = rpc.one("eth_blockNumber", []).get("result")
    if not head:
        return None, None
    head, step, net = int(head, 16), 2_000_000, 0
    topic_me = "0x" + pad(addr)
    start = 0
    while start <= head:
        end = min(start + step, head)
        for topics, sign in (([TRANSFER_TOPIC, None, topic_me], 1),
                             ([TRANSFER_TOPIC, topic_me, None], -1)):
            r = rpc.one("eth_getLogs", [{"fromBlock": hex(start), "toBlock": hex(end),
                                         "address": token, "topics": topics}])
            if "error" in r:
                return None, None
            for l in (r.get("result") or []):
                d = l.get("data") or "0x"
                net += sign * (int(d, 16) if len(d) > 2 else 0)
        start = end + 1
    return net, None


# ---------------------------------------------------------------- pools

def find_pools(rpc, chain, token):
    """Every venue that actually holds the wrapped native asset against this token."""
    c = CHAINS[chain]
    w = c["wrapped"]
    found = []

    names = list(c["v2"].keys())
    pairs = rpc.batch_call([(c["v2"][n], SEL["getPair"] + pad(token) + pad(w)) for n in names])
    live = [(n, "0x" + p[-40:]) for n, p in zip(names, pairs) if p and int(p, 16) != 0]
    if live:
        rs = rpc.batch_call([(p, SEL["getReserves"]) for _, p in live])
        t0 = rpc.batch_call([(p, SEL["token0"]) for _, p in live])
        for (n, p), r, a in zip(live, rs, t0):
            if not r or len(r) < 194 or not a:
                continue
            r0, r1 = int(r[2:66], 16), int(r[66:130], 16)
            is0 = ("0x" + a[-40:]).lower() == token.lower()
            rtok, rw = (r0, r1) if is0 else (r1, r0)
            if rw > 0 and rtok > 0:
                found.append({"kind": "v2", "dex": n, "pair": p, "rtok": rtok, "rw": rw})

    if c.get("v3"):
        fees = (500, 3000, 10000)
        pools = rpc.batch_call([(c["v3"], SEL["getPool"] + pad(token) + pad(w) + word(f))
                                for f in fees])
        got = [(f, "0x" + p[-40:]) for f, p in zip(fees, pools) if p and int(p, 16) != 0]
        if got:
            wb = rpc.batch_call([(w, SEL["balanceOf"] + pad(p)) for _, p in got])
            for (f, p), b in zip(got, wb):
                bal = int(b, 16) if b else 0
                if bal > 0:
                    found.append({"kind": "v3", "dex": f"UniV3-{f}", "pair": p, "rw": bal,
                                  "rtok": None})
    return found


def v2_out(rtok, rw, amount_in, tax=0.0):
    """Constant product with the 0.3% LP fee, tax taken before the pool sees the tokens."""
    ai = amount_in * (1 - tax)
    if rtok <= 0:
        return 0
    return (ai * 997 * rw) / (rtok * 1000 + ai * 997)


def simulate_sell(rpc, addr, token, pair, raw):
    """THE decisive test. Can this wallet move this token into that pool, at all?

    A quote proves nothing -- bait pools quote beautifully off real reserves. Only the
    token's own transfer() decides, and eth_call runs it exactly as a real tx would,
    without signing anything or spending gas.
    """
    r = rpc.call(token, SEL["transfer"] + pad(pair) + word(raw), frm=addr)
    if "error" in r:
        msg = (r["error"].get("message") or "").replace("execution reverted:", "").strip()
        return False, (msg or "reverted")[:90]
    v = r.get("result")
    if v in (None, "0x"):
        return True, ""                      # non-standard token, no return value
    return (int(v, 16) == 1), ("returned false (silent failure)" if int(v, 16) != 1 else "")


def is_lp_receipt(rpc, token):
    """An LP receipt answers all four. A claim on pool reserves -- burn it, get paid."""
    r = rpc.batch_call([(token, SEL["token0"]), (token, SEL["token1"]),
                        (token, SEL["getReserves"]), (token, SEL["totalSupply"])])
    if not all(r) or len(r[2]) < 194:
        return None
    return {"token0": "0x" + r[0][-40:], "token1": "0x" + r[1][-40:],
            "r0": int(r[2][2:66], 16), "r1": int(r[2][66:130], 16),
            "supply": int(r[3], 16)}


# ---------------------------------------------------------------- pricing

def native_usd(chain):
    sym = {"polygon": "MATIC-USD"}.get(chain, "ETH-USD")
    d = curl_json(f"https://api.coinbase.com/v2/prices/{sym}/spot", 20)
    try:
        return float(d["data"]["amount"])
    except Exception:
        return 0.0


# ---------------------------------------------------------------- report

def alchemy_key():
    """Optional. Everything in this file works without it; discovery is just faster with it."""
    k = os.environ.get("ALCHEMY_API_KEY", "")
    if k:
        return k
    for p in (os.path.expanduser("~/Genie/PMBot_v1/.env"), os.path.expanduser("~/.env"),
              os.path.join(os.getcwd(), ".env")):
        if os.path.exists(p):
            for line in open(p, errors="ignore"):
                m = re.match(r'^\s*ALCHEMY_API_KEY\s*=\s*["\']?([^"\'\s]+)', line)
                if m:
                    return m.group(1)
    return ""


def scan(addr, chain, min_usd, only_token=None, quiet=False):
    c = CHAINS[chain]
    alch = alchemy_key()
    rpc = RPC(f"https://{c['alchemy']}.g.alchemy.com/v2/{alch}" if alch else c["rpc"])

    say = (lambda *a: None) if quiet else (lambda *a: print(*a))
    px = native_usd(chain)
    gas_gwei = int((rpc.one("eth_gasPrice", []).get("result") or "0x0"), 16) / 1e9
    sell_cost = GAS_SELL * gas_gwei / 1e9 * px
    nat = int((rpc.one("eth_getBalance", [addr, "latest"]).get("result") or "0x0"), 16) / 1e18
    nonce = int((rpc.one("eth_getTransactionCount", [addr, "latest"]).get("result") or "0x0"), 16)

    say(f"\nwallet   {addr[:6]}…{addr[-4:]}   chain {chain}")
    say(f"native   {nat:.6f} ({c['wsym'][1:]})  ${nat * px:,.2f}    nonce {nonce}"
        f"{'   <- never sent a tx on this chain' if nonce == 0 else ''}")
    say(f"market   ${px:,.2f}   gas {gas_gwei:.3f} gwei   a sell costs ~${sell_cost:.3f}")

    if only_token:
        tokens = [only_token.lower()]
    else:
        tokens = None
        if alch:
            tokens = discover_alchemy(addr, c["alchemy"], alch)
        if tokens is None:
            tokens = discover_blockscout(addr, c["blockscout"])
        if tokens is None:
            say("  (no indexer available -- falling back to a recent-log scan)")
            tokens = discover_logs(rpc, addr)
    say(f"tokens   {len(tokens)} contracts to check\n")
    if not tokens:
        return {"address": addr, "chain": chain, "rows": []}

    meta = rpc.batch_call([(t, SEL["decimals"]) for t in tokens])
    syms = rpc.batch_call([(t, SEL["symbol"]) for t in tokens])
    bals = rpc.batch_call([(t, SEL["balanceOf"] + pad(addr)) for t in tokens])

    rows = []
    for t, d, s, b in zip(tokens, meta, syms, bals):
        raw = int(b, 16) if b else 0
        if raw <= 0:
            continue
        dec = int(d, 16) if d else 18
        rows.append({"token": t, "dec": dec, "sym": (dec_string(s) or "?")[:18],
                     "raw": raw, "bal": raw / (10 ** dec)})

    realizable, bait, empty, claims = [], [], [], []
    for r in rows:
        lp = is_lp_receipt(rpc, r["token"])
        if lp and lp["supply"]:
            share = r["raw"] / lp["supply"]
            wr = 0
            for tok, res in ((lp["token0"], lp["r0"]), (lp["token1"], lp["r1"])):
                if tok.lower() == c["wrapped"].lower():
                    wr = res * share / 1e18
            r["claim"] = {"share": share * 100, "native": wr, "usd": wr * px}
            claims.append(r)
            continue

        pools = find_pools(rpc, chain, r["token"])
        v2 = [p for p in pools if p["kind"] == "v2"]
        if not v2:
            r["why"] = ("v3 only -- needs a quoter" if pools else "no pool on any factory")
            empty.append(r)
            continue
        best, bout = None, -1
        for p in v2:
            o = v2_out(p["rtok"], p["rw"], r["raw"])
            if o > bout:
                best, bout = p, o
        r["venue"], r["pair"] = best["dex"], best["pair"]
        r["pool_native"] = best["rw"] / 1e18
        r["quote_usd"] = bout / 1e18 * px
        if r["quote_usd"] < min_usd:
            r["why"] = f"quote ${r['quote_usd']:,.2f} under threshold"
            empty.append(r)
            continue
        ok, msg = simulate_sell(rpc, addr, r["token"], best["pair"], r["raw"])
        r["sellable"], r["revert"] = ok, msg
        (realizable if ok else bait).append(r)

    realizable.sort(key=lambda x: -x["quote_usd"])
    bait.sort(key=lambda x: -x["quote_usd"])
    claims.sort(key=lambda x: -x["claim"]["usd"])

    if claims:
        say("CLAIMABLE -- LP receipts. Burning these pays out the pool's reserves to you.")
        for r in claims:
            cl = r["claim"]
            say(f"  {r['sym']:18} {cl['share']:8.4f}% of pool  ->  "
                f"{cl['native']:.6f} {c['wsym'][1:]}  ${cl['usd']:,.2f}")
        say("")

    if realizable:
        say("REALIZABLE -- sell simulated successfully against live reserves.")
        say(f"  {'token':18} {'balance':>20} {'venue':10} {'pool has':>12} {'you get':>10}")
        for r in realizable:
            say(f"  {r['sym']:18} {r['bal']:20,.2f} {r['venue']:10} "
                f"{r['pool_native']:12.4f} {r['quote_usd']:10,.2f}")
        say(f"\n  total ${sum(r['quote_usd'] for r in realizable):,.2f}"
            f"   less ~${sell_cost:.3f} gas per sell\n")

    if bait:
        say("BLOCKED -- the pool is real, the quote is real, the token will not move.")
        say("  The ETH in these pools belongs to whoever can transfer the token. Not you.")
        for r in bait:
            say(f"  {r['sym']:18} ${r['quote_usd']:>10,.2f}  \"{r['revert']}\"")
        say(f"\n  apparent value that is not real: "
            f"${sum(r['quote_usd'] for r in bait):,.2f}\n")

    say(f"NOTHING THERE -- {len(empty)} balances with no reachable pool.")
    for r in empty[:10]:
        say(f"  {r['sym']:18} {r.get('why','')}")
    if len(empty) > 10:
        say(f"  … and {len(empty) - 10} more")

    say(f"\n{rpc.calls} read-only calls. Nothing was signed and no key was used.")
    return {"address": addr, "chain": chain, "native": nat, "price": px,
            "realizable": realizable, "bait": bait, "claimable": claims, "empty": empty}


def deep_dive(addr, chain, token):
    """The display-lie check: what the contract says vs what a UI would show."""
    c = CHAINS[chain]
    alch = alchemy_key()
    rpc = RPC(f"https://{c['alchemy']}.g.alchemy.com/v2/{alch}" if alch else c["rpc"])
    dec = int(rpc.result(token, SEL["decimals"]) or "0x12", 16)
    sym = dec_string(rpc.result(token, SEL["symbol"])) or "?"
    raw = int(rpc.result(token, SEL["balanceOf"] + pad(addr)) or "0x0", 16)
    print(f"\n{sym}  ({token})")
    print(f"  balanceOf()          {raw / 10 ** dec:>28,.4f}   <- the only sellable number")
    s, hist = transfer_sum(rpc, addr, token, is_alchemy=bool(alch))
    if s is None:
        print("  sum of Transfers     (history unreadable from this node)")
        return
    print(f"  sum of Transfers     {s / 10 ** dec:>28,.4f}   <- what a naive UI displays")
    if raw == 0 and s > 0:
        print("\n  MISMATCH: history says you received this; the contract says you hold none.")
    elif s and abs(s - raw) / max(abs(s), 1) > 0.01:
        ratio = s / raw if raw else float("inf")
        print(f"\n  MISMATCH of {ratio:,.0f}x. The contract rebased or reflects; the events did not.")
        print("  A wallet showing the larger number is summing history, not asking the chain.")
        print("  Every router, pool and exchange reads balanceOf(). The smaller number is real.")
        if hist:
            print(f"\n  the {len(hist)} transfers a UI would be adding up:")
            for ts, sign, val, h in hist:
                try:
                    v = f"{float(val):,.2f}"
                except (TypeError, ValueError):
                    v = str(val)
                print(f"    {ts}  {'IN ' if sign > 0 else 'OUT'} {v:>26}  {h[:12]}…")
    else:
        print("\n  Consistent -- no display lie on this token.")


def main():
    ap = argparse.ArgumentParser(description="What an EVM wallet can actually realize. Read-only.")
    ap.add_argument("address")
    ap.add_argument("--chain", default="ethereum", choices=sorted(CHAINS))
    ap.add_argument("--all-chains", action="store_true", help="scan every supported chain")
    ap.add_argument("--token", help="deep-dive one token: balanceOf vs summed Transfers")
    ap.add_argument("--min-usd", type=float, default=0.50)
    ap.add_argument("--json", help="write the full result here")
    a = ap.parse_args()

    if not re.fullmatch(r"0x[0-9a-fA-F]{40}", a.address):
        sys.exit("not an EVM address")
    addr = a.address.lower()

    if a.token:
        deep_dive(addr, a.chain, a.token.lower())
        return

    chains = sorted(CHAINS) if a.all_chains else [a.chain]
    out = {}
    for ch in chains:
        try:
            out[ch] = scan(addr, ch, a.min_usd)
        except KeyboardInterrupt:
            raise
        except Exception as e:
            print(f"  {ch}: {e}")
    if a.json:
        with open(a.json, "w") as f:
            json.dump(out, f, indent=2, default=str)
        print(f"\nwritten -> {a.json}")


if __name__ == "__main__":
    main()
