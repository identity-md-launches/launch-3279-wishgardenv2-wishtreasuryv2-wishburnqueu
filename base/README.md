# Base-only receiver deployment package

**Not in the Ethereum launch manifest.** Source: `base/src/BaseBurnReceiver.sol`. ABI: `base/artifacts/BaseBurnReceiver.json`. Reproducible creation/runtime template, constructor ABI, immutable offsets, compiler settings and source SHA-256 hashes: `base/artifacts/BaseBurnReceiver.deployment.json`.

The owner deploys this only after receiving the confirmed Ethereum treasury address. No production Base receiver address or deployment transaction exists in this source assignment. No owner/withdrawal/approval/rescue/upgrade capability exists in the receiver; its IMD may only go through the fixed Base token's `burn`.

## Constructor parameters

| Parameter | Required verified value |
| --- | --- |
| endpoint_ | Official LayerZero V2 Base endpoint returned by the official Base IMD OFTAdapter |
| baseOFT_ | Official Base adapter that is the Ethereum IMD's Base peer and wraps Base IMD |
| ethereumQueue_ | Confirmed deployed Ethereum WishGardenTreasury address from service receipt |
| ethereumEid_ | Ethereum endpoint's actual EID, distinct from chain ID |
| baseEid_ | Base endpoint's actual EID, distinct from chain ID |
| acknowledgementGas_ | Native-free type-3 receive gas for the Ethereum ack; 100,000–5,000,000 allowed, start simulations at 300,000 |

Known input token constants are Ethereum IMD `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` and Base IMD `0xFF0C532FDB8Cd566Ae169C1CB157ff2Bdc83E105`. Endpoint/adapter observations in `docs/evidence/bridge-observations.json`, when available, are **observations, not permission to activate**. Reverify on both chains. Never supply a zero/fake queue address to get deployment past checks.

The constructor has six static arguments, is nonpayable and makes no external calls. The deployment script additionally checks Base chain 8453, endpoint/EID, adapter token, reciprocal Ethereum token peer and nonzero reviewed evidence before broadcasting. The script's evidence argument is a workflow check, not a claim that the receiver verified offchain evidence.

## Reproduce and sign

From the repository root, using its unchanged configuration and vendored dependencies:

```sh
forge build
python3 scripts/export-abis.py --check
FOUNDRY_FUZZ_SEED=0x7554a2451008692ee4ae2ec4178aadddb50df0feb65239512362826da72be2ac forge test --match-path 'test/replacement/*.t.sol'
```

Owner command template (the owner explicitly supplies these values in their own shell; no .env file is required or read by our scripts):

```sh
forge script script/DeployBaseReceiver.s.sol:DeployBaseReceiver \
  --sig 'run(address,address,address,uint32,uint32,uint128,bytes32)' \
  "$BASE_ENDPOINT" "$BASE_OFT" "$CONFIRMED_ETHEREUM_TREASURY" \
  "$ETHEREUM_EID" "$BASE_EID" 300000 "$REVIEWED_EVIDENCE_HASH" \
  --rpc-url "$BASE_RPC" --sender 0x48E4E74fE1d0c14404cEB57B9fec5b21329C6ec9
```

That command simulates. Review it and then use the owner's own hardware wallet or `--account` signing workflow with `--broadcast`. No key/account is supplied by this contribution. Save the real broadcast receipt and creation input. Verify source with the same compiler/settings and ABI-encoded constructor arguments; compare deployed runtime with immutable references resolved. Record address, chain 8453, tx/block, source commit and explorer link in the owner handoff.

After Ethereum freeze, use `scripts/operator.py ... ack --receiver ... --batch 0` to prepare readiness. Positive batches acknowledge completed burns only. Gas is separately funded native ETH. Read [the bridge protocol](../docs/bridge-protocol.md) for authenticated compose/retry semantics and [operations](../docs/operations.md) for maintenance.

This package is built/tested offline with mocked transport and verified runtime fixtures. It does not claim that a live Base receiver was deployed, that actual destination credit was exercised, or that protocol defaults have been approved. There is no automatic deploy-on-Ethereum wrapper and no new token.
