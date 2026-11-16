> Historical legacy regression suite. These tests now import archived `Legacy*` fixtures. They retain the original review evidence; they do not certify the replacement contracts. Replacement coverage and limits are in `docs/validation.md` and `test/replacement/`.

# Independent contract tests

This contribution adds tests only. The application contracts, configuration, dependency fixtures,
and original contributor tests are unchanged. No new dependency is required. No production defect
requiring a source fix was reproduced by this suite; this is test evidence, not deployment approval.

## Added coverage

| File | Checks |
| --- | --- |
| `WishGardenPaymentFailures.t.sol` | All three payment transfer legs and all three withdrawal buckets, with false returns, recipient taxes, no-op transfers, and sender surcharges. Tests begin with existing records, revenue, and donations; compare complete financial state after failure; then retry successfully. No-return withdrawal transfers must still pay exact amounts. |
| `WishGardenBatchFailures.t.sol` | Random batch lengths and failure positions; duplicate IDs within a batch, IDs consumed earlier, another wallet's NFT, nonexistent maximum uint256 ID, and a mocked reverting ownership lookup. Failed batches preserve prior records and release all newly attempted IDs for retry. Also tests operator-wide approval, consumption across a round trip through several owners, and wrong-chain rejection after confirmation. |
| `WishGardenReentrancy.t.sol` | Token callbacks attempt paid purchases and both free-claim entrypoints during pull and push legs. An authorized contract wallet attempts same-bucket and cross-bucket treasury reentry across all combinations. The same payload is executed successfully afterward to establish that its rejection was the reentrancy guard. NFT safe-transfer receivers can claim unused IDs but cannot reuse consumed IDs. |
| `WishGardenWalletGas.t.sol` | Supplied `WalletGas` helper compares success, return data and events at the lowest successful gas limit and with gas to spare. Covers both claim entrypoints (which reach `ownerOf`'s try/catch), token zero, new/current NFT owners, 1/10/50-element batches, existing history, maximum purchases, and every withdrawal bucket. |
| `WishGardenModelInvariant.t.sol` | 256 random sequences of depth 96 over purchases, insufficient approvals, individual/batch claims, NFT transfers, withdrawals, donations, ownership proposals/cancellations/acceptance, privilege attacks, time changes, and history pagination. |

The stateful model derives expected payments, bucket obligations, recipient balances, approvals,
NFT owners, lifetime consumption, candle records, and owner/pending-owner roles from input actions.
It does not copy production accounting or claim state into its model. Invariants check conservation,
solvency, immutable beneficiaries, permissions and record persistence after each action. Every
historical candle and purchaser index is compared against the model at the end of each sequence.
Expected application reverts are checked inside the handler; unexpected handler reverts fail the
suite. A deterministic mixed sequence exercises successful batches, owner acceptance, drained
buckets, and rejected calls without relying on random reachability.

The existing suite additionally covers exact 1/10/50 prices, all seven styles, more than 10,000
persistent candles, empty/boundary inputs, launch constructors, one-time configuration, dependency
validation, pagination, nonpayable behavior, and a separate conservation invariant.

## Evidence boundaries

- Most tests execute the repository's bundled IMD and identity NFT runtime bytecode at their fixed
  addresses using `vm.etch`. Balances, minted NFTs, timestamps, and owners are local test state.
  The existing runtime-hash checks remain in the full suite. This contribution does not independently
  fetch or re-attest those runtime fixtures, their provenance, or current Ethereum state.
- Payment-failure and token-reentrancy tests substitute the existing `AdversarialIMD` test contract.
  Those failures are deliberate fault injection, not claims about deployed IMD behavior.
- One batch-failure case mocks an `ownerOf` revert. Other NFT ownership/transfer/receiver cases run
  the bundled NFT runtime without replacing its ownership implementation.
- Test beneficiaries and contract wallets are scenario fixtures, not proposed launch recipients.
  Separate beneficiary and shared-beneficiary permissions are both exercised.
- Sink allocations are checked as permanently held IMD. `totalSupply` is unchanged; the suite does
  not describe those transfers as a supply-reducing burn.
- No fork, live RPC, deployment, broadcast, environment mutation, or service attestation is involved.
  The approved assignment specifies no fork block or RPC variable. All tests run offline.
- Wallet-gas test totals include the helper's repeated binary-search calls; they are not the gas
  usage of one application transaction. Each probe uses the supplied helper's gas ceiling.

## Reproduction

From the repository root, with the pinned Solidity compiler available:

```sh
forge build --offline --out test/scratch/final-out --cache-path test/scratch/final-cache
FOUNDRY_FUZZ_SEED=0x97c94f0a2c3e7194aefb08855d149d84c076632dfc983f4f1421acdc6c07edef forge test --offline --out test/scratch/final-out --cache-path test/scratch/final-cache
```

Artifact and cache flags only keep generated files in disposable scratch space. Delivered tests
have no imports or other runtime dependencies on `test/scratch/` or `.imd/reads/`.

## Recorded results

- Clean offline `forge build`: passed with Solidity 0.8.26 (56 source files).
- Full offline `forge test`, using the seed above: **82 passed, 0 failed, 0 skipped**, across 12 suites.
- Added stateful invariant: **256 runs, 24,576 handler calls, 0 unexpected reverts**.
- Existing stateful invariant: **128 runs, 8,192 handler calls, 0 unexpected reverts**.
- Each added fuzz property ran **512 cases**. All eight wallet-gas tests passed.
- Only seven new files under `test/` are delivered; the supplied wallet-gas helper is copied verbatim.
