"""Offline tests of unsigned operator plans; no RPC server, signer or network."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("operator_tools", ROOT / "scripts/operator.py")
op = importlib.util.module_from_spec(spec)
spec.loader.exec_module(op)
# These addresses exist only in mocked tests; never deployment inputs/artifacts.
QUEUE = "0x" + "11" * 20
RECEIVER = "0x" + "22" * 20
ENDPOINT = "0x" + "33" * 20
ADAPTER = "0x" + "44" * 20
GUID = "0x" + "55" * 32


def words(*values):
    return "0x" + "".join(f"{v:064x}" for v in values)


class OperatorPlans(unittest.TestCase):
    def run_plan(self, args, chain, responses):
        calls = []
        def rpc(url, method, params):
            calls.append((method, params))
            if method == "eth_chainId": return hex(chain)
            if method == "eth_blockNumber": return "0x1234"
            if method == "eth_getCode": return "0x6000"
            if method == "eth_call":
                self.assertEqual(params[1], "0x1234")
                return responses[params[0]["data"]]
            self.fail("unexpected method (must never broadcast): " + method)
        output = io.StringIO()
        with patch.object(sys, "argv", ["operator.py", "--rpc", "https://test.invalid", *args]), patch.object(op.dep, "rpc", rpc), contextlib.redirect_stdout(output):
            op.main()
        return json.loads(output.getvalue()), calls

    def test_dispatch_uses_quoted_fee_expected_batch_and_retains_dust(self):
        requested = 300000000000000017
        result, calls = self.run_plan(["dispatch", "--queue", QUEUE, "--amount", str(requested)], 1, {
            op.dep.calldata("purchasesEnabled()"): words(1),
            op.dep.calldata("quoteDispatch(uint256)", requested): words(300000000000000000, 17, 12345, 7),
        })
        self.assertEqual(result["to"], QUEUE)
        self.assertEqual(result["value"], hex(12345))
        self.assertEqual(result["data"], op.dep.calldata("dispatch(uint256,uint256)", requested, 7))
        self.assertTrue(result["unsigned"])
        self.assertEqual(result["retainedRequestedDust"], "17")
        self.assertTrue(all(method.startswith("eth_") for method, _ in calls))

    def test_disabled_dispatch_and_wrong_chain_refused(self):
        with self.assertRaisesRegex(SystemExit, "disabled"):
            self.run_plan(["dispatch", "--queue", QUEUE, "--amount", "1"], 1, {op.dep.calldata("purchasesEnabled()"): words(0)})
        with self.assertRaisesRegex(SystemExit, "wrong chain"):
            self.run_plan(["ack", "--receiver", RECEIVER, "--batch", "1"], 1, {})

    def test_ack_never_purchases_or_rebridges(self):
        result, _ = self.run_plan(["ack", "--receiver", RECEIVER, "--batch", "9"], 8453, {op.dep.calldata("quoteAcknowledgement(uint256)", 9): words(54321)})
        self.assertEqual(result["data"], op.dep.calldata("sendAcknowledgement(uint256)", 9))
        self.assertEqual(result["value"], hex(54321))

    def test_compose_retry_authenticates_queue_hash_and_rejects_already_consumed(self):
        amount = 300000000000000000
        message = "0x" + f"{1:016x}{30101:08x}{amount:064x}{int(QUEUE,16):064x}{1:064x}{7:064x}{amount:064x}"
        responses = {
            op.dep.calldata("endpoint()"): words(int(ENDPOINT,16)),
            op.dep.calldata("baseOFT()"): words(int(ADAPTER,16)),
            op.dep.calldata("ethereumQueue()"): words(int(QUEUE,16)),
            op.dep.calldata("ethereumEid()"): words(30101),
        }
        import subprocess
        query = op.dep.calldata("composeQueue(address,address,bytes32,uint16)", ADAPTER, RECEIVER, GUID, 0)
        responses[query] = subprocess.check_output(["cast", "keccak", message],text=True).strip()
        args = ["retry-compose", "--receiver", RECEIVER, "--guid", GUID, "--message", message]
        result, _ = self.run_plan(args, 8453, responses)
        self.assertEqual(result["to"].lower(), ENDPOINT.lower())
        self.assertEqual(result["value"], "0x0")
        self.assertEqual(result["data"], op.dep.calldata("lzCompose(address,address,bytes32,uint16,bytes,bytes)",ADAPTER,RECEIVER,GUID,0,message,"0x"))
        responses[query] = words(1)
        with self.assertRaisesRegex(SystemExit,"not pending"):
            self.run_plan(args,8453,responses)

    def test_no_zero_addresses_or_non_evm_address_words(self):
        with self.assertRaises(Exception): op.address("0x" + "00"*20)
        with self.assertRaises(ValueError): op.dep.address_word(words(0))
        with self.assertRaises(ValueError): op.dep.address_word(words(1<<160))


if __name__ == "__main__":
    unittest.main()
