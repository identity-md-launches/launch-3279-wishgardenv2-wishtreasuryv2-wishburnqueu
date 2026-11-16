# Manual operation and maintenance

No server, cron service or hosted relayer is included. Anyone may pay native gas for restricted dispatch, Base compose retry and acknowledgements; only the owner may withdraw revenue or perform initial Ethereum setup. No operation spends a buyer's approval except the buyer's own purchase.

All commands below either read state, export artifacts, simulate or produce **unsigned** calldata. They do not sign/broadcast. Run on the owner's/operator's machine using their chosen RPC and wallet after the deployment handoff is verified. Variables denote explicit caller-supplied values, never supplied dummy addresses.

## Dependency observations

```sh
python3 scripts/check-dependencies.py --ethereum-rpc "$ETH_RPC" --base-rpc "$BASE_RPC" --output reviewed-observations.json
```

The script obtains a block number/hash per chain and pins all subsequent reads to it. It verifies RPC chain IDs, reciprocal OFT peer, underlying Base token and EIDs, then records raw results and runtime hashes. It is not a complete approval checklist. In particular it does not validate final-address transfer fees, all message-security settings, credit/compose delivery or future liquidity. On any error it exits without producing a successful new evidence file; use a fresh output path to avoid confusing an older result with the latest attempt.

## Monitor and dispatch pending burns

```sh
python3 scripts/operator.py --rpc "$ETH_RPC" status --queue "$ETH_TREASURY"
python3 scripts/operator.py --rpc "$ETH_RPC" dispatch --queue "$ETH_TREASURY" --amount 300000000000000000
```

Amount is **IMD base units**, not native ETH or a candle count, and it is an upper bound: the queue sends `min(amount, pendingBurn)` rounded down to a shared-decimal unit. The second command prints chain, to, data, native value, quoted block, the next batch ID (sent as an upper bound) and retained requested dust. Review, simulate from the intended funded caller with `eth_call` / `eth_estimateGas`, add normal gas margin, then sign in that caller's wallet. Refresh the quote just before signing. Underpayment/overpayment reverts. If another caller dispatched first, your transaction still succeeds with the next id and the remaining pending amount; it reverts only when nothing sendable is left or your batch bound is already below the next id. A batch smaller than `MIN_DISPATCH` (0.3 IMD) is refused unless it is the whole remaining rounded balance, so nobody can split pending funds into micro-batches. While the Base token has transfer limits in effect, keep each batch at or below the receiver's `maxCredit()`.

Record the transaction receipt, batch ID and OFT GUID. A submitted transaction with no known receipt is not evidence of failure. If a source transaction succeeds, its tokens are in transit: never submit another source send “for” that same batch. The contract does not expose a source resend or cancellation method.

## Base credit and compose retry

Track the original GUID through the official LayerZero endpoint/executor and Base adapter `OFTReceived`/`ComposeSent` events. If credit has not occurred, the original verified bridge packet needs delivery/retry; application scripts do not mint substitute tokens or manufacture packets. Consult the bridge's supported delivery tooling and verified original packet, preserving source, nonce and GUID. Lack of executor liquidity, DVN finality or correct adapter settings is an operator dependency, not a confirmed burn.

Once credit exists but composition failed, obtain the exact `ComposeSent` bytes (172-byte message, index 0) from the authenticated Base endpoint:

```sh
python3 scripts/operator.py --rpc "$BASE_RPC" retry-compose \
  --receiver "$BASE_RECEIVER" --guid "$OFT_GUID" --message "$EXACT_COMPOSE_SENT_MESSAGE"
```

The planner checks receiver bindings, source queue/EID, application payload and the endpoint's pending `composeQueue` hash. It emits the actual V2 endpoint `lzCompose` calldata, with zero native value. If already delivered or the hash differs, it refuses. Simulate with sufficient gas; any token shortage, burn failure or low-gas failure leaves the original compose retryable. Never buy candles again to retry a wish or burn.

## Acknowledge readiness or completed burns

```sh
python3 scripts/operator.py --rpc "$BASE_RPC" ack --receiver "$BASE_RECEIVER" --batch 0
python3 scripts/operator.py --rpc "$BASE_RPC" ack --receiver "$BASE_RECEIVER" --batch "$COMPLETED_BATCH_ID"
```

Batch 0 is readiness only; it cannot increase confirmed burns. Positive batches must already be burned on Base. Native message fees come solely from the caller. Save the acknowledgement GUID and receipt. An acknowledgement can be sent again after a failure/delay; Ethereum exact-duplicate handling is idempotent. Monitor `BurnConfirmed` and match batch ID, original OFT GUID and amount. Unconfirmed burns remain in Ethereum's in-transit counter until the authenticated message arrives.

## Owner revenue and handoff

Use the exported treasury ABI for `withdrawEcosystem(destination, amount)`, `withdrawOperations(destination, amount)` or `withdrawFounder(destination, amount)` with the current owner wallet. Amounts cannot exceed the selected bucket. Publish `BucketWithdrawn` receipt links. There is no `withdrawBurn`, rescue or arbitrary-call method. Ownership changes use `transferOwnership` followed by `acceptOwnership`; all three revenue powers follow the new treasury owner. Garden ownership is a separate role with no text mutation or payment-routing controls.

Keep records of source commit, ABI/artifact hashes, configuration hash, both-chain receipts, finality policy, current pending/in-transit/confirmed amounts and external bridge admin/security changes. If the official peer or local runtime changes, new purchases and dispatch fail closed on local checks; this is dependency validation, not an admin pause. Already-sent valid burn acknowledgements can still settle. For immutable configurations that cannot be repaired, report the real stuck amounts; do not relabel them burned or withdraw them.
