# Independent replacement-contract test review

This contribution adds tests only. Production contracts, deployment configuration, dependencies, scripts, and the existing suites are unchanged. No dependency was installed, no transaction was broadcast, and no real-fund purchase was made.

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

Final local validation: Foundry 1.8.3 / Solidity 0.8.26; `forge build` succeeded; the full required-seed run completed with **161 tests passed, 0 failed, 0 skipped across 29 suites**. The new invariant completed all 24,576 generated calls with zero unexpected reverts. `forge fmt --check test/review` passed. The compiler's existing source lint warnings remain warnings, not compiler errors. No production or configuration file was changed.
