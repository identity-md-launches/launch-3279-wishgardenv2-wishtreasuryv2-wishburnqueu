# Independent replacement-contract test review

This contribution adds tests only. Production contracts, deployment configuration, dependencies, scripts, and the existing suites are unchanged. No dependency was installed, no transaction was broadcast, and no real-fund purchase was made.

## Revision for the surplus-burn / frozen-maximum-batch implementation (commit 703dd34)

The author answered all three findings from the previous round as **fixed**. Each fix was checked with tests in this suite; none is reported again.

- **8336590 (donation consumes max-wallet headroom): fix confirmed.** `BaseCreditLimits.t.sol` uses the supplied Base token and adapter runtimes with local storage, limits on and maxWallet 1e18. `test_actualDonationFillingMaxWalletIsBurnedByReadiness`: a 1e18 donation sets `maxCredit()` to 0, and `sendAcknowledgement(0)` from any caller still succeeds. It burns the donation (supply −1e18, `surplusBurned` 1e18, `totalBurned` 0) and sends READY. `test_actualDonationBlockingCreditIsClearedByAnyoneAndBatchBurnsOnce`: the donation makes the actual adapter `lzReceive` revert `Max wallet exceeded`. A stranger's `burnSurplus()` clears it, the same packet then lands and burns exactly once, and the batch acknowledges. `testFuzz_actualSurplusBurnBeforeComposeAttributesExactly` covers a front-runner who burns a credited batch plus a donation before its compose: the compose still completes, takes the shortfall from surplus, and records the exact amount. A replay reverts `DuplicateBurn`. `testFuzz_actualRandomSurplusAndComposeSequencesConserveSupply` runs random sequences of 24 credit/donation/surplus-burn/compose steps on the actual runtimes. After every step, the real supply reduction equals `totalBurned + surplusBurned`. At the end, each batch's recorded burn equals its credit and `surplusBurned` equals the donations exactly. A short argument shows why a compose can never be stuck: held + surplusBurned − uncomposed credits = donations ≥ 0. `burnSurplus` is Base-only and checked at a wallet's gas.
- **89832d9 (unbounded permissionless dispatch): fix confirmed.** `BridgeAdversarial.t.sol::test_thirdPartyUnboundedDispatchIsSplitAtFrozenMaximum`: with 60 IMD pending, bob's `dispatch(max, max)` sends 30 + 30 and then reverts `InvalidBatch`. The Ethereum `maxBatch` equals the derived receiver's `maxBatch`, and the owner cannot change it after freezing. The independent dispatch model fuzz now reaches pending balances above the cap (up to 200 candles) and models min(request, pending, maxBatch). `ActivationBoundary.t.sol` adds four refused `maxBatch` classes to the atomic-freeze fuzz (zero, below one candle's share, not a shared unit, above uint64 shared units). It also checks that the frozen maximum batch is part of the derived receiver address. `BaseCreditLimits.t.sol` checks on the actual runtimes that readiness is refused while maxWallet < maxBatch, even with room for a minimum batch, and that a receiver cannot be built with maxBatch < `MIN_CREDIT`.
- **df03c1f (tradingActive ignored): fix confirmed.** `test_actualTradingInactiveRefusesReadinessUntilEnabled`: with limits on and trading off, `maxCredit()` is 0, readiness reverts `CreditRestricted`, and the actual adapter credit reverts `Trading is not active.`. Once trading is on, readiness, credit and burn all succeed.
- `BridgeLifecycleInvariant.t.sol`: the handler now models the frozen maximum batch. Without that, the suite failed to start under forge 1.8 ("failed to set up invariant testing environment"). A new `burnSurplus` action is reachable by any actor. The model tracks real Base burns separately from attributed batch burns, and a compose's burn failure only matters when something is left to burn. New invariants: `surplusBurned` equals the model, real burns = attributed + surplus, and Base custody/supply equal credits + donations − real burns. The deterministic lifecycle test now includes a surplus burn that front-runs a compose.
- Changes for the new signatures: `freezeBridge`/`predictReceiver` take `maxBatch` and the receiver constructor takes `maxBatch`. `ReviewComposeEndpoint` now uses the author's `MockEndpoint.sendCompose`; the compose source and index are checked with `vm.expectCall`.

Residuals the author disclosed are accepted, not asserted as defects. After activation, the Base token owner can lower maxWallet below maxBatch, and credits then wait (retryable). A donor can delay one credit per donation until someone calls `burnSurplus`, and each such delay burns the donor's own IMD. The receiver trusts LayerZero to deliver only composes that the adapter queued after crediting, so a compose for a guid that was never credited is outside this model. With nothing held and no surplus, such a compose reverts (`test_actualComposeWithoutCreditAndWithoutSurplusReverts`). This round found no new defect, so no `.imd-findings.json` was written.

Local validation for this revision: Foundry 1.8.3, required seed, **195 tests passed, 0 failed, 0 skipped across 30 suites**. The review invariant completed 256 × 96 = 24,576 calls with zero reverts.

## Revision for the derived-receiver implementation (commit 13398fa)

The implementation changed after this review was first accepted: `freezeBridge` now takes the Base endpoint, adapter, three gas limits, a salt and evidence, and **derives** the receiver as the CREATE2 address of the compiled `BaseBurnReceiver` bound to the treasury (fixed endpoint ids 30101/30184). Dispatch clamps to the pending balance, refuses partial batches below one candle's share (`MIN_DISPATCH`) and treats the batch id as an upper bound. The receiver now refuses readiness under Base blacklist/max-wallet restrictions. Changes to this suite:

- `ActivationBoundary.t.sol`: the fourteen invalid freeze classes were rewritten for the new arguments (endpoint without code, zero Base endpoint/adapter, adapter equal to IMD or to the Base endpoint, zero evidence, each of three gas limits below/above bounds, token endpoint mismatch, token peer mismatch); every new storage field is checked unchanged after a refusal. New: the prediction equals a real deterministic-deployer deployment for fuzzed salt/gas, and changing queue, salt, endpoint or gas moves the address. New: an identical-code receiver at a non-derived address (plain CREATE, another salt, another treasury's receiver) cannot signal readiness.
- `BridgeLifecycleInvariant.t.sol`: the dispatch action models the minimum-batch rule (a refused split changes nothing); the forged-origin action uses `ETHEREUM_EID()`.
- `BridgeAdversarial.t.sol`: new fuzz property comparing `quoteDispatch` and `dispatch` with an independent model of clamp/rounding/minimum/batch-bound rules, including stale bounds and refusals that leave state unchanged.
- `BaseCreditLimits.t.sol` (new): supplied Base token and adapter runtimes with local storage and Base limits switched on in the token's own storage (slots located with `vm.accesses`). Covers readiness headroom vs `MIN_CREDIT`, an oversized credit reverting inside the actual adapter with nothing consumed, an in-limit credit burned exactly, retry of the oversized packet after limits are lifted with no double counting, and readiness at a wallet's gas under limits.

Three defects found in this revision are reported in `.imd-findings.json` rather than asserted, each with concrete inputs (reproduced in scratch tests against the supplied runtimes):

1. **medium**: IMD sent straight to the receiver uses up its max-wallet headroom. Nothing can burn or release it, so readiness can be blocked for good, or every later credit reverts.
2. **medium**: anyone can call dispatch, and no limit on batch size stops them from sending the whole pending balance as one batch larger than the Base credit limit.
3. **low**: readiness ignores the Base token's `tradingActive` flag. With limits on and trading off it signals READY even though every credit fails.

All three only apply while the Base token's limits are in effect. Live Base storage was not read.

## Added coverage

| File | Evidence |
| --- | --- |
| `ActivationBoundary.t.sol` | Fourteen invalid configuration classes, atomic rollback and corrected retry; malformed or unauthenticated readiness cannot enable purchases; valid readiness still requires owner activation; pending and successor owners cannot change a frozen destination. |
| `BridgeAdversarial.t.sol` | Fourteen malformed compose classes with sufficient token custody, followed by a valid retry; GUID and batch replay protection independently; malformed authenticated receipts; ten local dependency changes; non-native fee quotes and malformed acknowledgement receipts; wallet-gas checks for readiness, burn acknowledgements, fresh/duplicate receipts and every withdrawal bucket. |
| `BridgeLifecycleInvariant.t.sol` | Independent accounting model over 256 sequences of depth 96. Purchases, donations to all three value-holding contracts, revenue withdrawals, ownership transfer, dispatch failures/dust, partial Base credit, burn failures/replay, acknowledgement failure, delayed/duplicate receipt delivery, forged receipts, and elapsed time are separate actions. |
| `PaymentAtomicity.t.sol` | False returns, recipient taxes, no-op transfers and sender surcharges on both purchase legs and all three withdrawal buckets. Existing records and donations cannot hide a deficient payment. Failure restores allowance, records, wishes, custody and every financial counter; retry reuses the unconsumed candle IDs. Also forbidden destinations, overdraw, no-return tokens, interleaved purchasers and pagination. |
| `UnicodeAndLegacy.t.sol` | Independent RFC 3629 byte-range oracle, random byte strings and scalar round trips, all 256 leading/continuation classes at important boundaries, error offsets after valid prefixes, byte/codepoint/acknowledgement limits at purchase, immutable author/text, repeated NFT transfers, unchanged lifetime free claims, namespace rejection and zero writes to legacy garden/treasury/sink/NFT during registration. |
| `BaseAdapterRuntime.t.sol` | Supplied Base token and adapter bytecode, with fresh local storage and mock endpoint transport: adapter reserve unlock, exact queued compose bytes/index/source, subsequent supply burn, acknowledgement payload, insufficient-reserve rollback and retry. Receiver execution also uses the supplied wallet-gas search. |

The invariant model calculates expected allocations from successful action inputs, not from production ledger totals. It checks:

- Purchase receipts equal exactly 1 IMD per candle, with 30/50/10/10 conservation after withdrawals.
- Ethereum custody equals remaining allocations plus separately tracked donations; garden donations remain intact.
- Dispatched amounts stay in transit until authenticated receipt delivery, even after the Base burn or acknowledgement send has succeeded.
- Base custody and total supply equal credited amounts plus donations minus completed burns. Credited but unburned balances persist across random actions.
- Confirmed amounts never exceed burned amounts; burned amounts never exceed completed credits; credits never exceed dispatched amounts.
- Every source batch, consumed GUID, burn receipt and confirmation agrees with the model. Ethereum bridge debits are not counted as final burns.
- Old candle endpoints, positions, purchaser, timestamp, style and wish remain unchanged after later actions. All new records are paid candles.
- Treasury/receiver bridge allowances and retained native currency remain zero.

The deterministic lifecycle test ensures partial credit, failed source send, failed burn, failed acknowledgement, delayed receipt, duplicate receipt/compose, donation and ownership changes are exercised even when a random sequence does not reach a particular transition. Some random handler calls return without mutation when their prerequisite state does not yet exist; expected external failures are asserted inside the handler. Unexpected handler reverts remain failures under the repository's existing invariant configuration.

## Review conclusions and boundaries

No new actionable contract defect was reproduced by this review. This is bounded test evidence, not a claim of complete correctness or approval to activate purchases. No failing property was removed or changed into an assertion that the defective behavior was correct.

The application source has no explicit `gasleft()`, fixed-gas call, or caught failed-call path. The supplied, unchanged `test/helpers/WalletGas.sol` is nevertheless used for the new acknowledgement, receipt, withdrawal, registry and actual-token burn checks. It compares returns and events at the lowest successful gas limit and with gas to spare, restoring state between probes. Existing wallet-gas tests for paid purchases and dispatch remain in the full suite.

Mock tests authenticate callbacks by impersonating the configured endpoint. Runtime tests use the supplied bytecode and initialized **local** balances/peers, with a mocked endpoint. Neither approach verifies distributed bridge security, current live settings, message libraries/DVNs, executor service, default routes, final deployed receiver credit, or liquidity. No fork test, new live read, deployment, explorer verification or GitHub publication was performed by this contribution. The runtime hashes are checked against the supplied fixtures, not independently retrieved from a live chain.

The tests preserve the brief's setup boundary: deploy Ethereum applications disabled; independently verify the final contracts, official peer/endpoint relationships, encoding/options/fees, default routes, available reserves and positive destination credit; separately deploy the Base receiver; freeze reviewed configuration; deliver its authenticated readiness; then have the owner activate. A zero-amount readiness burn establishes callable ABI, not positive transfer availability. External token/bridge governance remains a dependency after activation. Direct donations and legacy sink custody do not become confirmed burns. Source dispatch is never a substitute for the Base burn and authenticated return receipt.

The supplied protected checks were read. Their service-provided environment and imported `floor/OwnerChecks.sol` are not part of this local test harness; no claim is made that those wrappers ran here. Existing constructor/owner/opcode tests remain enabled in the full suite. Actual deployment addresses, transaction receipts and publication are explicitly pending in the existing `docs/deployment/status.json`; this test assignment does not fill them with stand-ins.

## Reproduction

Use the repository's installed Foundry and Solidity versions and supplied dependencies. Output/cache are directed into scratch solely to keep generated files within the allowed test paths; ordinary `forge build` / `forge test` use the same source and compiler configuration.

```sh
forge build --out test/scratch/out --cache-path test/scratch/cache
FOUNDRY_FUZZ_SEED=0x7554a2451008692ee4ae2ec4178aadddb50df0feb65239512362826da72be2ac \
  forge test --out test/scratch/out --cache-path test/scratch/cache
```

The review adds 28 tests across eight test contracts, including one stateful invariant. Fuzz tests use the repository's 512 runs, except the two independent Unicode byte-string properties, which use 1,000 each. The new invariant uses 256 runs × 96 calls = 24,576 generated handler calls. These settings are in test-source comments only. All executable test dependencies are already supplied in the repository; scratch outputs are not required to build or run the submitted tests.

Final local validation (this revision): Foundry 1.8.3 / Solidity 0.8.26; `forge build` succeeded; the full required-seed run completed with **174 tests passed, 0 failed, 0 skipped across 30 suites**. (Previous round: 161 across 29.) The new invariant completed all 24,576 generated calls with zero unexpected reverts. `forge fmt --check test/review` passed. The compiler's existing source lint warnings remain warnings, not compiler errors. No production or configuration file was changed.
