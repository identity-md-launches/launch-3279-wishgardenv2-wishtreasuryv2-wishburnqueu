#!/usr/bin/env python3
"""Read-only status and unsigned transaction generation. Never signs, broadcasts, or buys candles."""
import argparse
import importlib.util
import json
from pathlib import Path
import re
import subprocess

spec = importlib.util.spec_from_file_location("dependencies", Path(__file__).with_name("check-dependencies.py"))
dep = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dep)


def address(value):
    if not re.fullmatch(r"0x[0-9a-fA-F]{40}", value) or int(value, 16) == 0:
        raise argparse.ArgumentTypeError("a confirmed nonzero address is required")
    return value


def nonnegative(value):
    number = int(value, 0)
    if not 0 <= number < 2**256:
        raise argparse.ArgumentTypeError("uint256 base units required")
    return number


def words(raw):
    if not re.fullmatch(r"0x(?:[0-9a-fA-F]{64})+", raw):
        raise ValueError("unexpected ABI response")
    return [int(raw[i:i+64], 16) for i in range(2, len(raw), 64)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rpc", required=True)
    sub = parser.add_subparsers(dest="action", required=True)
    status = sub.add_parser("status"); status.add_argument("--queue", type=address, required=True)
    dispatch = sub.add_parser("dispatch"); dispatch.add_argument("--queue", type=address, required=True); dispatch.add_argument("--amount", type=nonnegative, required=True)
    ack = sub.add_parser("ack"); ack.add_argument("--receiver", type=address, required=True); ack.add_argument("--batch", type=nonnegative, required=True)
    surplus = sub.add_parser("burn-surplus"); surplus.add_argument("--receiver", type=address, required=True)
    receiver_status = sub.add_parser("receiver-status"); receiver_status.add_argument("--receiver", type=address, required=True)
    retry = sub.add_parser("retry-compose"); retry.add_argument("--receiver", type=address, required=True); retry.add_argument("--guid", required=True); retry.add_argument("--message", required=True)
    args = parser.parse_args()
    chain = int(dep.rpc(args.rpc, "eth_chainId", []), 16)
    expected = 1 if args.action in ("status", "dispatch") else 8453
    if chain != expected:
        raise SystemExit("wrong chain")
    block = dep.rpc(args.rpc, "eth_blockNumber", [])

    def read(target, signature, *params):
        return dep.rpc(args.rpc, "eth_call", [{"to": target, "data": dep.calldata(signature, *params)}, block])

    target = getattr(args, "queue", None) or args.receiver
    if dep.rpc(args.rpc, "eth_getCode", [target, block]) == "0x":
        raise SystemExit("application has no code")
    if args.action == "status":
        names = ["purchasesEnabled", "bridgeFrozen", "receiverReady", "pendingBurn", "pendingDust", "inTransitBurn", "confirmedBurn", "totalBurnAllocated", "batchCount", "maxBatch", "ecosystemBalance", "operationsBalance", "founderBalance"]
        print(json.dumps({"chainId": chain, "block": block, **{n: str(words(read(target, n+"()"))[0]) for n in names}}, indent=2)); return
    if args.action == "receiver-status":
        token = dep.address_word(read(target, "IMD()"))
        names = ["maxBatch", "maxCredit", "totalBurned", "surplusBurned"]
        print(json.dumps({"chainId": chain, "block": block, **{n: str(words(read(target, n+"()"))[0]) for n in names}, "heldIMD": str(words(read(token, "balanceOf(address)", target))[0]), "note": "maxCredit below maxBatch means a maximum batch cannot land now; held IMD can be burned by anyone with burn-surplus"}, indent=2)); return
    if args.action == "dispatch":
        if words(read(target, "purchasesEnabled()")) != [1]:
            raise SystemExit("purchases/bridge are disabled")
        amount, dust, fee, batch = words(read(target, "quoteDispatch(uint256)", args.amount))
        data = dep.calldata("dispatch(uint256,uint256)", args.amount, batch)
        note = {"batch": str(batch), "sentBaseUnits": str(amount), "retainedRequestedDust": str(dust), "semantics": "amount is an upper bound clamped to pendingBurn and the frozen maxBatch; batch is an upper bound, so an earlier dispatch by someone else does not revert this one", "retry": "Only retry this source send if its transaction reverted. Never resend an in-transit batch."}
    elif args.action == "burn-surplus":
        token = dep.address_word(read(target, "IMD()"))
        held, = words(read(token, "balanceOf(address)", target))
        if held == 0:
            raise SystemExit("receiver holds no IMD; nothing to burn")
        data = dep.calldata("burnSurplus()"); fee = 0
        note = {"heldBaseUnits": str(held), "semantics": "Burns every IMD the receiver holds (real supply burn) and frees max-wallet headroom. A batch credit burned before its compose is remembered in surplusBurned and that compose still completes once.", "retry": "Safe to repeat; reverts when nothing is held."}
    elif args.action == "ack":
        fee, = words(read(target, "quoteAcknowledgement(uint256)", args.batch))
        data = dep.calldata("sendAcknowledgement(uint256)", args.batch)
        note = {"batch": str(args.batch), "retry": "Repeat acknowledgement after failure or delay; it never burns twice. Batch 0 signals readiness only."}
    else:
        if not re.fullmatch(r"0x[0-9a-fA-F]{64}", args.guid) or int(args.guid,16) == 0 or not re.fullmatch(r"0x[0-9a-fA-F]{344}", args.message):
            raise SystemExit("supply the exact nonzero OFT GUID and 172-byte ComposeSent message")
        endpoint = dep.address_word(read(target, "endpoint()")); adapter = dep.address_word(read(target, "baseOFT()"))
        source_queue = dep.address_word(read(target, "ethereumQueue()")); source_eid = words(read(target, "ethereumEid()"))[0]
        raw = bytes.fromhex(args.message[2:])
        if int.from_bytes(raw[8:12],"big") != source_eid or int.from_bytes(raw[44:76],"big") != int(source_queue,16):
            raise SystemExit("message source does not match receiver")
        if int.from_bytes(raw[76:108],"big") != 1 or int.from_bytes(raw[108:140],"big") == 0 or int.from_bytes(raw[12:44],"big") != int.from_bytes(raw[140:172],"big"):
            raise SystemExit("invalid application payload")
        queued = read(endpoint,"composeQueue(address,address,bytes32,uint16)",adapter,target,args.guid,0)
        digest = subprocess.check_output(["cast","keccak",args.message],text=True).strip()
        if queued.lower() != digest.lower():
            raise SystemExit("message is not pending in the authenticated endpoint compose queue (already delivered or wrong payload)")
        data = dep.calldata("lzCompose(address,address,bytes32,uint16,bytes,bytes)",adapter,target,args.guid,0,args.message,"0x")
        target = endpoint; fee = 0
        note = {"retry": "Re-executes the exact endpoint-queued compose; does not send or purchase IMD again."}
    print(json.dumps({"chainId": chain, "quotedAtBlock": block, "to": target, "data": data, "value": hex(fee), "unsigned": True, "instructions": "Review and simulate using the funded caller, then sign in your own wallet. Refresh quotes before sending; fees are native ETH separate from IMD.", **note}, indent=2))


if __name__ == "__main__":
    main()
