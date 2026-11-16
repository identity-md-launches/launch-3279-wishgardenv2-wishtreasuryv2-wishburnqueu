# The Wish Garden — contracts-only replacement

Ethereum application source for permanent candles bought with **existing IMD**. No token, pool, lottery, rewards, transferable candle or holder investment rights. The later website order must integrate these contracts; this delivery includes no website or IPFS hosting.

**Deploy disabled.** The launch service publishes the accepted source commit, generates `launch.json`, deploys the Ethereum contracts and supplies confirmed addresses/explorer verification. This source assignment has not broadcast transactions or published a repository. The obsolete legacy manifest was removed; replacement constructor inputs are in [the manifest handoff](docs/deployment/manifest-handoff.json). [Deployment status](docs/deployment/status.json) deliberately contains no invented addresses.

| Application | Purpose |
| --- | --- |
| `WishGardenTreasury(owner)` | Separate 30/50/10/10 accounting, owner withdrawals from only the three revenue buckets, restricted official OFT burn queue |
| `WishGarden(owner, treasury)` | Paid-only permanent candles, stable namespaced positions, atomic optional full-text wishes |
| `LegacyWishRegistry()` | One immutable missing wish per legacy candle, bound to its recorded purchaser; legacy read-through |
| `base/src/BaseBurnReceiver.sol` | **Base-only separate owner deployment**; authenticated credits may only be burned, followed by authenticated acknowledgements |

Owner: `0x48E4E74fE1d0c14404cEB57B9fec5b21329C6ec9`. Ethereum IMD: `0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7`. Base IMD: `0xFF0C532FDB8Cd566Ae169C1CB157ff2Bdc83E105`.

## Fixed behavior

Each candle costs **1 IMD (10^18 base units)**. Each purchase accepts **1–50 candles**, one of **seven cosmetic styles (0–6)**, and an optional wish shared by that batch. Separate purchases allow different wishes. Styles remain Purity/white, Hope/blue, Love/red, Success/gold, Health/purple, Wealth/green, Happiness/pink. Candles and their positions never expire or move. Purchaser/global pages contain at most **100** entries.

Each payment allocates exactly **30% pending burn, 50% ecosystem, 10% operations, 10% founder**. All money remains accounted separately. Only the current treasury owner may withdraw each non-burn bucket, specifying destination and amount; each withdrawal emits both. Two-step owner transfer transfers all three withdrawal powers. Neither ownership nor any operator grants access to burn funds. Donations remain unallocated and cannot be relabeled as candle payments or withdrawn.

Ethereum IMD is an OFT with no public burn. Its source-chain bridge debit is **not** the final burn. `WishGardenTreasury.dispatch` calls the existing token's typed OFT `send`, fixed to the verified Base peer and the derived receiver. The receiver is not an owner-chosen address: the treasury embeds the compiled `BaseBurnReceiver` creation code and freezes the CREATE2 address that code, bound to this treasury and the fixed endpoint ids 30101/30184, gets from the deterministic deployer `0x4e59b44847b379578588920cA78FbF26c0B4956C` (same code on Ethereum and Base) for the owner's salt. Only that code can occupy the address, so no wallet can collect the 30% or forge readiness/burn confirmations. Dispatch sends up to the requested amount, never above the owner-frozen `maxBatch` (set once in `freezeBridge`, part of the receiver derivation, and the size the receiver proves it can accept under the Base token's transfer limits before it signals readiness), never below one candle's share (0.3 IMD) unless that is all that is left, and treats the batch id as an upper bound, so third parties cannot grief operators with micro-batches. **No token approval is needed or granted.** Native messaging fees are paid separately by the caller. Pending, in-transit and authenticated confirmed-burn amounts are separate. Source dust remains pending; failed source transactions revert; delayed delivery never becomes a second send. Base calls `burn(uint256)` and checks exact receiver-balance and `totalSupply` decreases before acknowledging. The Ethereum confirmed counter advances only through the fixed endpoint and Base receiver. [Protocol and retries](docs/bridge-protocol.md).

New paid IDs start at **2^255 + 1**, positions at **2^255**; `totalCandles` remains a count. Canonical UI/database keys are `(chainId, gardenAddress, candleId)` or the exposed hash, including for legacy records. Do not convert these IDs to JavaScript Number.

Wishes contain the entire valid UTF-8 string on Ethereum, at most **280 Unicode scalar codepoints / 1120 bytes**, without normalization. Nonempty text requires explicit `publicForeverAcknowledged = true`; there is no edit, deletion or admin override. Each paid batch stores its text once and every candle resolves its author/text through `wishOf`. Full text is public even in a reverted transaction's calldata. [Mandatory later website integration specification](docs/integration.md).

## Preserve legacy

Legacy garden: `0xaabd6a747359f5478803efa7b51e929e62ec4ca2`. Legacy treasury: `0x929a062e0ab6266534f1ce573ba34ca7980207aa`. Official NFT: `0x0000eC93127BAA929E58E97dd0095A2BFb38ec1D`.

The **legacy garden is the only free-claim ledger**. The replacement has no free-claim or collection-confirmation entrypoints. NFT transfers never reset a legacy ID's lifetime claim. No legacy contract or record is mutated by this revision. Legacy candles, purchaser pagination, consumed NFT IDs and funds stay visible through the [unchanged archived ABIs](docs/abi/legacy), the registry's read-through views and direct reads. Legacy sink funds stay permanently locked; they are never included in replacement confirmed burns.

For a free candle with a wish: first claim on the legacy garden, wait for confirmation, then call the companion registry. Only that candle's recorded purchaser may register once, regardless of later NFT ownership. If the second transaction fails, retry registration for the same candle without claiming or buying again. The legacy owner's separate decision/setup to activate its free-claim ledger remains outside this replacement's powers.

## Build and check offline

```sh
forge build
FOUNDRY_FUZZ_SEED=0x7554a2451008692ee4ae2ec4178aadddb50df0feb65239512362826da72be2ac forge test
python3 scripts/export-abis.py --check
python3 -m unittest discover -s test/replacement -p 'test_*.py'
```

Existing Solidity 0.8.26 / Cancun / optimizer 200 / metadata-hash-none configuration and vendored dependencies are unchanged. No network is required for compilation/tests. `python3 scripts/export-abis.py` regenerates all replacement ABIs and reproducible Ethereum/Base bytecode packages; the generated `docs/abi/*`, `docs/deployment/packages/*` and `base/package/*` are committed, and `--check` must print only `Checked` lines on a clean checkout. The Base source is compiled through its test and deployment script imports, and remains outside the Ethereum manifest.

[ADAPTATION.md](ADAPTATION.md) maps every revision to the brief/audit. [Validation](docs/validation.md) distinguishes legacy regression tests, replacement tests, verified-runtime tests, mocked transport and live observations. The original 82 tests now explicitly target archived `Legacy*` fixtures; they do not certify replacement behavior.

## Owner and operator handoff

Follow [deployment and activation](docs/deployment.md), [verification requirements](docs/verification.md), [Base package](base/README.md) and [maintenance](docs/operations.md). Read-only observations do not replace owner verification, destination-credit simulation or authenticated cross-chain receipts. Keep purchases disabled while any setup requirement remains unresolved.

No hosted automation is promised. Operators pay ETH separately, monitor pending batches and execute supplied scripts. The supplied contracts are immutable with no pause, upgrade, rescue or arbitrary execution. The existing token, official bridge administrators, LayerZero endpoint/default libraries, DVNs and executor remain external dependencies. Review their authority and availability before activation. An irreparable dependency change can strand pending funds; there is deliberately no emergency withdrawal of the 30% allocation.
