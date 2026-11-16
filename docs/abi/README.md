# ABI exports

`WishGarden.json`, `WishGardenTreasury.json` and `LegacyWishRegistry.json` are the replacement **Ethereum** ABIs, deterministically generated from `forge build` by `python3 scripts/export-abis.py`. `--check` compares committed exports/bytecode packages with the build.

`legacy/` retains the original pinned garden, treasury and burn-sink ABIs unchanged for the existing deployed addresses. Never use those to deploy or interact with replacement contracts as though their semantics were unchanged.

The Base receiver ABI lives separately at `base/artifacts/BaseBurnReceiver.json`. Ethereum bytecode/source-hash packages live at `docs/deployment/artifacts/`; the separate Base package lives at `base/artifacts/BaseBurnReceiver.deployment.json`. These are reproducible source artifacts, not verified deployment addresses or receipts. The service attaches confirmed Ethereum addresses and explorer verification after launch.

See [integration.md](../integration.md) for paid purchases, namespaced IDs, full-text wishes, mandatory public acknowledgement, legacy two-transaction retry and honest burn/lock labels. See [operations.md](../operations.md) for privileged setup and permissionless maintenance.
