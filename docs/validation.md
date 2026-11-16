# Validation and adversarial review

This is the implementing contributor's validation and adversarial review. The new invariant model maintains its own accounting independently of production ledger getters, but it is **not** represented as a second contributor's independent approval. The launch service's independent source/manifest review and protected checks are still required. No production transaction or real-fund candle purchase was sent.

## Reproducible checks

Foundry **1.8.3** (the latest revision re-ran every command with 1.8.5), Solidity **0.8.26**, unchanged Cancun/optimizer-200/bytecode-hash-none project configuration. Required fuzz seed:

`0x7554a2451008692ee4ae2ec4178aadddb50df0feb65239512362826da72be2ac`

Commands:

```sh
forge build
FOUNDRY_FUZZ_SEED=0x7554a2451008692ee4ae2ec4178aadddb50df0feb65239512362826da72be2ac forge test
python3 scripts/export-abis.py --check
python3 -m unittest discover -s test/replacement -p 'test_*.py'
forge fmt --check src test script base/src
```

A clean build compiled 80 files successfully. Exports generated from the preceding incremental build matched the clean build, including compiler settings, ABI, bytecode and source hashes. Artifact immutable reference groups retain exact offsets but omit unstable AST IDs. All tests operate without network, environment variables or FFI. The scripts require ordinary Python standard library plus the supplied Foundry tools; no new build dependency was installed.

Final Solidity suite: **151 passing tests, zero failures or skips**, including **82 original legacy regression tests** and **69 replacement tests** (Foundry's grouped invariant reporting counts a group as one suite item). Ordinary fuzz cases use the configured 512 runs. The replacement model runs 128 sequences of depth 64 (8,192 actions), with zero unexpected reverts. Six Python operator-plan tests pass separately. Historic independent legacy invariant settings are retained as they arrived, including their larger run/depth overrides.

## Coverage and evidence type

| Coverage | Delivered evidence |
| --- | --- |
| Paid-only replacement and namespaces | Removed free-claim selectors reject; high-bit IDs/positions, canonical contract/chain keys, permanent records, pagination/boundaries, seven styles and no holder rights |
| Exact 30/50/10/10 conservation | Fuzzed quantities, independent cumulative accounting model, exact token balance deltas, revenue withdrawals, owner transfer, unallocated donations and protected burn custody |
| Payment and wish atomicity | False/no-op/taxed/surcharge/no-return tokens, failed forwarding, insufficient caller authority, reentry and post-payment bridge-check failures; records/text/allowance/accounting roll back |
| Unicode | Valid 1/2/3/4-byte scalar boundaries including U+10FFFF; random valid scalars; isolated continuation/overlong/surrogate/truncated/above-range sequences; 280/281 codepoints and 1120/1121 bytes; combining marks without normalization |
| Legacy wishes and claims | Archived actual legacy implementation/ABI; recorded purchaser survives NFT transfer; duplicate lifetime claim rejection; one-shot text; unauthorized/admin/nonexistent/empty/unacknowledged writes reject; failed second transaction retries without new purchase; no legacy writes; old funds/donations visible |
| Owner authorization | All three revenue buckets follow current owner; old owner loses replacement powers; only bound garden can record; setup only owner and once; ownership renunciation blocked; owner cannot withdraw burn funds |
| Bridge state and failure | Pending/in-transit/confirmed conservation, dust retention, source failure/retry, unique GUIDs/batch-id upper bound, minimum batch and clamping (micro-batch front-run cannot revert a prepared dispatch or inflate batches), frozen maximum batch (no caller can create a larger one; fuzzed against request, pending and bound; unusable bounds rejected at freeze), exact native fee, dependency changes, delayed credit, partial shortages, wrong source/endpoint/adapter/peer/message/amount and unauthorized receipts |
| Derived receiver | `baseReceiver` equals the deterministic deployer's actual CREATE2 result for the compiled receiver code bound to the treasury; other treasury/salt/gas/adapter derive other addresses; the frozen address cannot be redeployed; an EOA named by nobody cannot pass READY, collect dispatched funds or forge BURNED; freeze and Base script agree on the prediction and the script refuses any other address |
| Base transfer restrictions | Readiness refuses while the token blacklists receiver or adapter, while trading is inactive under limits (unless adapter or receiver is fee-excluded), or while `maxWallet` headroom is below the frozen maximum batch (mock), and against the real Base IMD and adapter runtimes with the token's own limit storage: the actual adapter `lzReceive` credit reverts `Max wallet exceeded` / `Trading is not active.` in exactly the states readiness refuses, and lands otherwise; `maxCredit()` reports headroom |
| Donations and surplus | A direct transfer filling the max-wallet headroom no longer blocks readiness (burned first) or later credits (anyone calls `burnSurplus`, then the same real adapter credit lands and is burned); surplus is a real supply burn, never a batch; a credit burned before its compose is completed exactly once from `surplusBurned` (fuzzed split of donation/early burn); a compose with neither credit nor matching surplus still reverts and stays retryable |
| Base burn and return proof | Exact balance AND totalSupply decrease, false/non-decreasing burn rejection, duplicate compose rejection, authenticated ack, failed ack retry without another burn, duplicates and out-of-order receipts, no withdrawal/approval escape |
| Wallet-estimated gas behavior | Binary search for the lowest successful gas limit: 50 paid candles with 1120-byte shared wish, source dispatch and Base compose produce identical returns/events to execution with spare gas (under the 16,777,216 test ceiling); no silent skipped work |
| Constructor/deployment constraints | Three Ethereum constructors deployed in one factory call on empty dependencies, explicit owner, disabled defaults, supported static arguments, bounded init/runtime code, no reachable DELEGATECALL/CALLCODE/SELFDESTRUCT; separate Base constructor/package |
| Owner scripts/operator plans | Base chain/peer/evidence guards and deployment simulation; separate bind/freeze/activate and reviewed hash; unsigned dispatch/ack/compose retry, wrong chain/disabled/address/message-hash rejection; no signing or broadcast |

### Mocked and verified-runtime results

`test/replacement/Mocks.sol` deliberately supplies fault-injection ERC20s, endpoint transport and Base credit. End-to-end queue/receiver tests use these mocks. They prove application state transitions and authentication conditions, not LayerZero's distributed security, real bridge availability or live credit.

`VerifiedRuntime.t.sol` additionally executes the verified Ethereum IMD, Base IMD and Base OFTAdapter **deployed bytecode with fresh local storage**, using mocked endpoint transport. It verifies actual Ethereum OFT caller debit without approval and exact OFT v1 outbound encoding. Base runtime tests exercise its actual public burn and supply reduction, and run the actual adapter `lzReceive` credit and `sendCompose` into the receiver under the token's own `limitsInEffect`/`tradingActive`/`maxWallet` storage (slots observed live, values set locally). Their code hashes match recorded live observations. This is stronger than interface-only mocking but is **not a fork** and does not exercise actual DVNs/executors or live token transfer settings.

The original 82 tests still run against renamed `test/legacy-src/Legacy*` archives. Their existing successful free-claim/sink behavior is intentional legacy coverage, not acceptable replacement behavior. The new regression tests reproduce the imported legacy findings and separately prove the replacements. Read-only runtime comparison at the recorded block shows the archived original garden and treasury match live legacy runtimes after masking constructor immutables: `docs/evidence/legacy-runtime-comparison.json`.

### Live reads and absent results

`docs/evidence/bridge-observations.json` records read-only observations on **2026-11-16**, with a pinned block/hash per chain, raw selectors/results and runtime hashes. It confirms the Ethereum token's Base peer and the Base adapter's reciprocal Ethereum peer/underlying token, endpoint EIDs, decimals/interfaces and observed Base reserve balance. At that Ethereum block legacy candles/free claims/payments are zero, collection unconfirmed and treasury unbound. This is a point-in-time observation, not authority to erase legacy history or assume it stays empty.

No fork suite, production deployment, public-source publication, explorer verification, end-to-end live transfer, positive final-receiver destination-credit test or real-fund test purchase was performed. Slither and Mythril were not run; Slither was not available. The provided owner wrapper imports an unavailable `floor/OwnerChecks.sol` and depends on service environment variables. Local factory/owner/size/opcode rehearsals cover its visible requirements but are not a claim that the protected service checks ran here.

## Runtime and constructor sizes

Byte counts from the unchanged compiler configuration (initcode excludes ABI arguments):

| Application | Runtime | Initcode | Constructor words |
| --- | ---: | ---: | ---: |
| WishGardenTreasury (embeds the receiver creation code it derives the receiver from) | 23,471 | 23,751 | 1 |
| WishGarden | 7,940 | 8,381 | 2 |
| LegacyWishRegistry | 4,604 | 4,636 | 0 |
| BaseBurnReceiver (separate Base action) | 8,170 | 8,944 | 7 |

All runtimes are below 24,576 bytes, all initcode plus arguments below 49,152 bytes, and external link maps are empty. Compiler linter observations about strict balance equality and events after calls were reviewed: equality enforces exact-price/credit/burn behavior, and affected mutating paths are nonReentrant with atomic rollback. Solidity's default-zero scalar loop index is not an uninitialized storage pointer. Configuration changes are committed through the `BridgeFrozen` hash/event and public getters. No finding is dismissed solely because a linter labels it a warning.

## Adversarial review conclusions and remaining risk

- Every production token pull is caller-bound. Privileged withdrawal operations can consume only their chosen revenue bucket. No function can rescue/relabel pending burn funds or alter a frozen route.
- Cross-chain authenticity rests on the verified endpoints and their configured/default libraries/DVNs. Only an endpoint-authenticated message from the fixed Base receiver can confirm the exact source batch/GUID/amount. The owner cannot confirm it by attestation or supply a general proof verifier of their choice.
- Owner selection of the actual reviewed garden and remote receiver is a pre-activation trust boundary. Reciprocal getters/evidence hashes do not remotely prove source authenticity; the owner/service must compare deployed code. Once activated, no destination/option/configuration change exists in these apps.
- Existing token/adapter admins, Base transfer restrictions/reserves and message defaults can change. Local token/endpoint hashes and peers are rechecked where relevant; remote state cannot be verified by an Ethereum getter. Unsuitable defaults, unavailable liquidity or unverified positive credit keep activation blocked. An irreversible external change can strand funds; there is intentionally no emergency burn withdrawal.
- Missing ack delivery does not imply the Base burn failed, and source supply debit does not prove a final burn. Keep status/counters honest. Direct donations neither create candles nor inflate purchase allocations. Old sink funds remain locked.
- The reviewed synthetic namespace-end pagination overflow was reproduced and fixed by reserving the exclusive cursor. No practical token price, batch limit or existing legacy state changed as a result.
- Wishes are permanent public calldata/storage. Authorization and UTF-8 correctness cannot make them private or sanitize them for HTML; the later website must enforce acknowledgement before publishing and render untrusted text safely.

See `ADAPTATION.md` for every imported finding, reproduction and disposition. Remaining service/owner steps are explicitly enumerated in deployment, verification and Base-package documents; none is represented by a made-up deployment address or credential.

### Second reopened review (maximum batch, surplus burn, trading flag)

- The treasury runtime is now 23,471 bytes, 1,105 below the EIP-170 limit, because it embeds the larger receiver creation code. The protected reachable-opcode scan was replicated on the built runtimes and finds no DELEGATECALL, CALLCODE or SELFDESTRUCT. Any later growth of the receiver must re-check both.
- `burnSurplus` relies on the official adapter crediting the receiver before it queues the compose (exercised with the real adapter runtime). Under that order `balance + surplusBurned` always covers a pending compose, so burning early can never strand a batch, and `totalBurned` never exceeds real burns.
- Remaining external risk, not closable in code: after activation the Base token owner can lower `maxWallet`, change the trading flag where the token's code allows it, or blacklist the receiver or adapter. Credits then revert in the adapter and stay retryable; nothing is lost or mislabelled burned. When `maxWallet` is close to `maxBatch`, someone can also delay one credit by donating just before it lands; each attempt costs them IMD that is then burned, and the credit is retried after `burnSurplus`. At the recorded live block `maxWallet` (3e42) exceeds total supply, so neither applies today.
- A `maxBatch` chosen above the Base limit cannot be corrected after `freezeBridge`; the receiver refuses readiness and purchases stay disabled (fail closed). The deployment steps tell the owner to read the limits first.
