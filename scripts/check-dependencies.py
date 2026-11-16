#!/usr/bin/env python3
"""Read-only, pinned-block dependency observations. Never activates, signs or buys candles."""
import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import subprocess

ETH_IMD = "0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7"
BASE_IMD = "0xFF0C532FDB8Cd566Ae169C1CB157ff2Bdc83E105"
NFT = "0x0000eC93127BAA929E58E97dd0095A2BFb38ec1D"
LEGACY = "0xaabd6a747359f5478803efa7b51e929e62ec4ca2"
LEGACY_TREASURY = "0x929a062e0ab6266534f1ce573ba34ca7980207aa"


def rpc(url, method, params):
    # Foundry's RPC transport works with the same RPCs used for operator simulation.
    # Every argument is a subprocess argv entry, never shell interpolation.
    command = ["cast", "rpc", "--rpc-url", url, method, *(json.dumps(p) for p in params)]
    result = subprocess.run(command, check=True, capture_output=True, text=True, timeout=35)
    return json.loads(result.stdout)


def calldata(signature, *args):
    return subprocess.check_output(["cast", "calldata", signature, *map(str, args)], text=True).strip()


def address_word(value):
    if not re.fullmatch(r"0x[0-9a-fA-F]{64}", value) or int(value[2:26], 16) != 0 or int(value, 16) == 0:
        raise ValueError("invalid/non-EVM address returned by dependency")
    return "0x" + value[-40:]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ethereum-rpc", required=True)
    parser.add_argument("--base-rpc", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    chains = {}
    for chain, url in [(1, args.ethereum_rpc), (8453, args.base_rpc)]:
        if int(rpc(url, "eth_chainId", []), 16) != chain:
            raise SystemExit("RPC returned wrong chain ID")
        block = rpc(url, "eth_blockNumber", [])
        header = rpc(url, "eth_getBlockByNumber", [block, False])
        chains[chain] = {"rpc": url, "block": block, "blockHash": header["hash"]}
    records = []

    def read(chain, address, signature, *params):
        ctx = chains[chain]
        data = calldata(signature, *params)
        value = rpc(ctx["rpc"], "eth_call", [{"to": address, "data": data}, ctx["block"]])
        records.append({"chainId": chain, "address": address, "signature": signature, "args": list(params), "calldata": data, "result": value})
        return value

    eth_endpoint = address_word(read(1, ETH_IMD, "endpoint()"))
    eth_eid = int(read(1, eth_endpoint, "eid()"), 16)
    # 30184 is the observed official Base route; the remote endpoint itself must confirm it below.
    base_adapter = address_word(read(1, ETH_IMD, "peers(uint32)", 30184))
    base_endpoint = address_word(read(8453, base_adapter, "endpoint()"))
    base_eid = int(read(8453, base_endpoint, "eid()"), 16)
    if base_eid != 30184:
        raise SystemExit("Ethereum peer is not attached to the Base endpoint")
    if address_word(read(8453, base_adapter, "token()")).lower() != BASE_IMD.lower():
        raise SystemExit("Base adapter underlying token mismatch")
    if address_word(read(8453, base_adapter, "peers(uint32)", eth_eid)).lower() != ETH_IMD.lower():
        raise SystemExit("Base reciprocal peer mismatch")
    tasks = [
        (1, ETH_IMD, "decimals()"), (1, ETH_IMD, "approvalRequired()"),
        (1, ETH_IMD, "decimalConversionRate()"), (1, ETH_IMD, "oftVersion()"),
        (8453, base_adapter, "approvalRequired()"), (8453, base_adapter, "decimalConversionRate()"),
        (8453, base_adapter, "oftVersion()"), (8453, BASE_IMD, "decimals()"),
        (8453, BASE_IMD, "balanceOf(address)", base_adapter),
        # Base token transfer restrictions that bound adapter credits to the receiver (choose maxBatch below them).
        (8453, BASE_IMD, "limitsInEffect()"), (8453, BASE_IMD, "tradingActive()"),
        (8453, BASE_IMD, "maxWallet()"), (8453, BASE_IMD, "maxTransactionAmount()"),
        (8453, BASE_IMD, "totalSupply()"), (8453, BASE_IMD, "owner()"),
        (8453, BASE_IMD, "isBlacklisted(address)", base_adapter),
        (8453, BASE_IMD, "isExcludedFromFees(address)", base_adapter),
        (1, LEGACY, "totalCandles()"), (1, LEGACY, "freeCandles()"),
        (1, LEGACY, "collectionConfirmed()"), (1, LEGACY_TREASURY, "garden()"),
        (1, LEGACY_TREASURY, "totalPayments()"), (1, LEGACY_TREASURY, "burnSink()")
    ]
    with ThreadPoolExecutor(max_workers=6) as pool:
        list(pool.map(lambda task: read(*task), tasks))
    code = []
    for chain, address in [(1, ETH_IMD), (1, NFT), (1, LEGACY), (1, LEGACY_TREASURY), (1, eth_endpoint), (8453, BASE_IMD), (8453, base_adapter), (8453, base_endpoint)]:
        raw = rpc(chains[chain]["rpc"], "eth_getCode", [address, chains[chain]["block"]])
        if raw in ("0x", "0x0"):
            raise SystemExit("Dependency has no code: " + address)
        digest = subprocess.check_output(["cast", "keccak", raw], text=True).strip()
        code.append({"chainId": chain, "address": address, "bytes": (len(raw)-2)//2, "keccak256": digest})
    output = {
        "observedAtUTC": datetime.now(timezone.utc).isoformat(),
        "status": "read-only observations, not an activation approval or end-to-end bridge proof",
        "blocks": {str(chain): {k: v for k, v in data.items() if k != "rpc"} for chain, data in chains.items()},
        "ethereumEndpoint": eth_endpoint, "ethereumEid": eth_eid,
        "baseAdapter": base_adapter, "baseEndpoint": base_endpoint, "baseEid": base_eid,
        "code": code,
        "calls": sorted(records, key=lambda r: (r["chainId"], r["address"].lower(), r["signature"])),
        "openRequirements": [
            "Confirmed Ethereum application receipt, published source commit and explorer verification",
            "Owner deployment and verification of BaseBurnReceiver for the confirmed Ethereum treasury",
            "Default send/receive libraries, DVNs, confirmations and executor settings for both OFT and acknowledgement paths",
            "Actual destination balance delta, reserve liquidity and fee/tax exclusions for the deployed Base receiver",
            "Owner choice of maxBatch at or below the Base token's maxWallet while limitsInEffect (the receiver refuses readiness otherwise), and re-check of limitsInEffect/tradingActive/maxWallet/blacklist for the final receiver",
            "Current native fee quotes, OFT compose encoding/options and gas simulation using final addresses",
            "Authenticated Base readiness receipt and owner activation only after review of all evidence"
        ]
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(output, indent=2) + "\n")
    print("Recorded pinned-block read-only observations in", args.output)


if __name__ == "__main__":
    main()
