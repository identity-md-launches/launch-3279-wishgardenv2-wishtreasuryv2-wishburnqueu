# Restricted official bridge and real burn protocol

The treasury itself is the Ethereum queue. There is no intermediary adapter with discretion over funds. Production dependencies are the existing Ethereum IMD OFT, its official Base OFTAdapter peer, the underlying Base IMD and LayerZero V2 endpoints. Local ABI subsets are in `src/bridge/IMDBridgeInterfaces.sol`; verified upstream ABI/codec snapshots and provenance are in `docs/bridge/`. Nothing calls a guessed `bridge`, `deposit`, `burn` on Ethereum, or an owner-supplied arbitrary target.

## Setup and authority

`freezeBridge(endpoint, ethereumEid, baseEid, baseOFT, receiver, receiveGas, composeGas, evidence)` is owner-only and one-time. It pins the local token/endpoint runtime hashes, local endpoint/EID, remote peer/receiver, type-3 options and evidence hash. It checks the actual IMD `token`, `approvalRequired == false`, endpoint, peer, shared decimals, conversion rate and OFT version. Receives/compose gas each allow 100,000–5,000,000; recommended initial simulations use 300,000, not a promise that every future protocol configuration fits. No native drop/value options or arbitrary OFT command are permitted. Settings cannot be replaced after freezing, even before activation.

The separately deployed receiver pins its endpoint, official Base adapter, source queue, EIDs and return-message gas in static constructor arguments. It has no owner. For readiness it checks the Base adapter's underlying token, endpoint, reciprocal Ethereum IMD peer, OFT version/decimals, and a zero-amount public burn. A zero burn proves callable ABI only, not positive destination credit; final-address positive burn/credit simulations remain mandatory.

`sendAcknowledgement(0)` sends readiness via the real Base endpoint. Ethereum accepts it only from its frozen endpoint with the correct Base source EID and receiver address, and matching Base adapter/chain in the payload. Owner activation additionally requires garden binding and current local bridge checks. A frontend flag, signature, event pasted by an operator, owner call or arbitrary proof bytes cannot advance confirmed burn accounting.

The application pins its own settings. The existing bridge/token administrators and LayerZero default message libraries/DVNs remain external trust boundaries; this application cannot freeze their governance. Neither application grants an endpoint delegate or exposes endpoint administration. Verify the **default** routes used by these new applications; if defaults are unsuitable, leave purchases disabled. Do not claim that immutable application settings make the entire bridge immutable.

## Ethereum dispatch

1. Payments add exactly 0.3 IMD per candle to `pendingBurn` and `totalBurnAllocated`. Revenue buckets are separate.
2. `quoteDispatch(requestedAmount)` returns the rounded debit, retained requested dust, native fee and next batch ID. `dispatch(requestedAmount, expectedBatchId)` is permissionless and requires that exact fresh native fee. Concurrent dispatches cause stale batch IDs to revert.
3. Debit is `floor(requestedAmount / 10^12) * 10^12`. The 10^12 conversion rate comes from 18 local / 6 shared decimals. Zero sends, over-pending amounts and uint64 shared-decimal overflow revert. All unsent remainder stays pending; no rounding is assigned to revenue. Whole-candle allocations are naturally divisible, but arbitrary partial operator selections still retain their remainder.
4. Only `IMD.send(SendParam, MessagingFee, msg.sender)` executes. The destination receiver and Base EID are frozen, `minAmountLD == amountLD`, `oftCmd` empty, `composeMsg = abi.encode(uint256(1), batchId, amountLD)`, and type-3 options are fixed. The official Ethereum OFT burns its caller's balance without an ERC20 approval; our approval bound is therefore **zero**.
5. The queue checks exact local balance debit, exact quoted source/destination amounts, fees and a unique nonzero OFT GUID. Any inconsistency, revert or out-of-gas reverts the entire transaction and restores pending state/batch ID. A failed transaction has no durable onchain failure event; use its receipt.
6. A successful send creates a GUID-bound batch and moves the debit to `inTransitBurn`. Source-chain supply debit is only an OFT bridge operation, never credited as a final burn.

## Base credit, compose and final burn

The official adapter unlocks existing Base IMD to the fixed receiver and asks its endpoint to queue compose index **0**. The verified default OFT v1 codec is:

| Bytes | Meaning |
| --- | --- |
| 0–7 | source nonce, uint64, packed |
| 8–11 | source Ethereum EID, uint32, packed |
| 12–43 | actual reported credit, uint256 |
| 44–75 | original source caller (the Ethereum treasury), bytes32 |
| 76–171 | our ABI-encoded version, batch ID, expected amount (three uint256 words) |

The receiver requires its endpoint as caller, its official Base adapter as `from`, the frozen Ethereum EID/queue, exact 172-byte length, version 1, nonzero batch/GUID/amount and credit equal to expected amount. It rejects consumed GUIDs or batch IDs. Only then may it call **Base IMD `burn(amount)`**. It checks receiver balance and totalSupply both decrease by exactly that amount. A shortage, revert, false burn or OOG rolls back the receipt and permits retry of the same endpoint-queued compose. There is no transfer, approval, rescue, arbitrary call or owner escape for the receiver's IMD.

Direct donations are not acknowledged as garden allocations. They have no withdrawal path. The receiver deliberately offers no “burn all balance” function: that could consume another batch's credited-but-not-composed tokens. The official adapter's default source reports its requested credit without a balance-delta check; its Base transfer must therefore be verified lossless for the final receiver. A wrong fee/blacklist/liquidity configuration is an activation blocker, not a reason to accept reduced credit. The receiver's exact burn check still prevents reporting a burn that did not reduce actual supply.

## Return acknowledgement and retry

`sendAcknowledgement(batchId)` uses native fees funded by its caller. Positive IDs can encode only a stored completed burn. It sends `(uint8(2), batchId, originalOFTGuid, amount)` to the immutable Ethereum queue. Readiness uses `(uint8(1), 0, baseAdapterAsBytes32, 8453)`. Both payloads are exactly 128 ABI bytes. Return delivery uses LayerZero V2 `lzReceive(Origin, guid, message, executor, extraData)`; `allowInitializePath` only admits the frozen Base sender and `nextNonce` selects unordered delivery.

Ethereum matches stored batch ID, GUID and amount before marking it confirmed. Exact duplicates are harmless no-ops; wrong amounts/GUIDs/unknown batches revert. Out-of-order batches work. An acknowledgement that fails or arrives late leaves the amount in transit even if the Base burn already succeeded; retrying it never reburns or rebridges. Both sides reject native value in callbacks, so native gas is never mixed with token custody.

| Failure point | Recovery |
| --- | --- |
| Source transaction reverted | Refresh quote and pending/next-batch state; retry source dispatch. No successful source debit exists. |
| Source succeeded; Base credit delayed/failed | Track the original OFT GUID and have the official endpoint/executor deliver/retry its verified packet. **Do not dispatch this batch again.** |
| Base credit succeeded; compose failed | Retry endpoint `lzCompose` with the exact queued message/GUID, index 0; supplied operator script checks the queue hash. No new IMD purchase/send. |
| Base burn succeeded; ack send failed | Retry `sendAcknowledgement(batchId)` with fresh native quote. |
| Ack sent; Ethereum receipt delayed | Retry verified endpoint delivery, or resend the same stored acknowledgement. Duplicates do not increase counters. |
| Bridge settings changed irreparably | Keep honest pending/in-transit state. There is no admin rescue or lock-as-burn substitution. |

Conservation: `totalBurnAllocated = pendingBurn + inTransitBurn + confirmedBurn`. Locally held accounted IMD is `pendingBurn + ecosystemBalance + operationsBalance + founderBalance`. Confirmed is a **bridge-authenticated statement of the Base receiver's exact burn**, secured by the selected LayerZero verification routes; it is not a native Ethereum verification of a Base state proof. The website must disclose that trust boundary.
