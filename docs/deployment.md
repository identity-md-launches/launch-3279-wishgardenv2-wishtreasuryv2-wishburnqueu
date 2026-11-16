# Ethereum deployment and owner activation

This assignment prepares reviewed source for the launch service. It does not hold keys, call the factory, publish to GitHub, attest a commit or broadcast. The service must supply the source commit/publication URL, deployment receipt, confirmed addresses and explorer verification. `docs/deployment/status.json` records those as pending. A source package or ABI is not evidence of deployment.

## Factory handoff

Ethereum chain **1**, deployment value **0**, approved owner **0x48E4E74fE1d0c14404cEB57B9fec5b21329C6ec9**.

| Order | Application | Static constructor arguments |
| --- | --- | --- |
| 1 | WishGardenTreasury | named owner |
| 2 | WishGarden | named owner, confirmed earlier WishGardenTreasury reference |
| 3 | LegacyWishRegistry | none |

All names fit the launch limit. All constructors are nonpayable, call no dependencies, create no other contracts, need no linked libraries and accept at most two arguments. The treasury runtime is about 22.1 KB because it embeds the Base receiver creation code it derives the receiver address from; it stays under the 24,576-byte limit but is the largest deployment of the three (roughly 5 M gas). Owners are explicit; neither factory nor tx.origin controls anything. No factory initialization is needed: the delivered state is intentionally disabled and all unknown bridge settings are one-time owner setup after launch. The registry is permissionless but author-bound and has no admin.

The stale root `launch.json` was removed because it redeployed the legacy sink/free-claim design. The manifest service must generate a new root manifest from [manifest-handoff.json](deployment/manifest-handoff.json). **Exclude BaseBurnReceiver, every Legacy* test fixture, the removed sink and all scripts/mocks.** No token or pool is deployed.

## Post-deployment sequence

1. Service publishes the accepted source commit to the requester's GitHub destination and verifies all Ethereum runtimes/constructor arguments on the explorer. Populate the confirmed handoff from receipts, never from local predictions. Compare bytecode to `docs/deployment/packages/*.deployment.json`, resolving the recorded immutable references with the actual constructor arguments. Independent reviewer inspects source plus final manifest.
2. Owner verifies reciprocal garden/treasury references and calls `bindGarden` once, using `script/OwnerSetup.s.sol:OwnerSetup` (`bind(address,address)`). Binding alone cannot enable purchases. Owner transfers must be coordinated before binding because matching current ownership is checked.
3. Independently verify the official two-way bridge, fees, codecs, defaults/DVNs/executor, reserve liquidity and positive destination-credit/burn semantics with final addresses as specified in [verification.md](verification.md). No real-fund test candle purchases. Do not substitute a nonofficial adapter or sink.
4. Owner chooses a salt and the maximum batch (IMD base units, at least 0.3e18, a multiple of 1e12, at or below the Base token's current `maxWallet` while its `limitsInEffect` is true; `scripts/check-dependencies.py` records those values) and reads `treasury.predictReceiver(baseEndpoint, baseOFT, acknowledgementGas, maxBatch, salt)` on Ethereum (or `DeployBaseReceiver.predict(...)` offline; both must agree). Owner deploys the separate Base receiver to exactly that address through the deterministic deployer `0x4e59b44847b379578588920cA78FbF26c0B4956C` with `script/DeployBaseReceiver.s.sol`, following [base/README.md](../base/README.md). The script refuses any other address. Verify its source, exact constructor arguments and runtime. This is a separate owner action after delivery, not part of Ethereum launch; it may happen before or after step 6, since the address is fixed by the derivation.
5. Review a durable evidence bundle including final receiver runtime, all dependencies, security configuration, destination-credit simulation, gas/fee tests and return path. Hash the exact reviewed bundle with `cast keccak`. The supplied observation file alone is not a complete bundle.
6. Owner uses `OwnerSetup.freeze(queue, endpoint, baseEndpoint, baseOFT, receiveGas, composeGas, acknowledgementGas, maxBatch, salt, evidence)` once. A `maxBatch` above what the Base token lets the receiver hold cannot be corrected after the freeze: the receiver then refuses readiness and purchases stay disabled until the Base token owner raises the limit or excludes the receiver, or a new treasury is deployed. The treasury derives and stores the receiver itself; no receiver argument exists. Check `configurationHash`, `BridgeFrozen`, `baseReceiver` equals the Base deployment address, every stored value and the frozen options. This is irreversible; a nonzero evidence hash by itself proves no external fact. Keep purchases disabled if anything is unverified.
7. Anyone funding Base ETH may call receiver `sendAcknowledgement(0)`. It refuses while the Base token blacklists the receiver or adapter, trading is inactive under limits, or its wallet limit cannot take one maximum batch; it first burns any IMD it already holds, so a donation cannot block it. Wait for the authenticated readiness receipt on Ethereum. Confirm the packet traversed the reviewed defaults/DVN route and `receiverReady == true`. This proves the return route and receiver's dependency checks, not positive token delivery.
8. Only after all verification is complete, owner calls `OwnerSetup.activate(queue, expectedConfigurationHash)`. The script checks the reviewed hash and readiness, and the contract rechecks local bridge dependencies. Verify `PurchasesActivated` and `purchasesEnabled`. No reconfiguration or pause follows activation.

Use `forge script` without `--broadcast` first to simulate with the named owner as sender. The owner then signs using their own Foundry account/hardware wallet and explicitly adds `--broadcast`. The source scripts never read a key or environment variable. No worker-provided signer/account is part of the package. See script function signatures; all inputs are confirmed addresses/parameters, not sample replacement addresses.

## Remaining launch responsibilities

- Service: source commit/GitHub publication, final manifest, independent review, factory deployment, confirmed Ethereum addresses, ABIs attached to those addresses and explorer verification.
- Owner: separate Base deployment and verification; complete cross-chain/default-security/credit/gas evidence; one-time binding/freezing; authenticated readiness and activation; separately decide/perform any legacy free-claim activation.
- Operators: fund native gas and run maintenance/retries. No hosted background service is included.

The legacy garden and treasury addresses remain unchanged. This replacement never enables, resets, upgrades, migrates or withdraws from them. Legacy sink funds cannot be recovered into the new burn flow and remain labeled locked.
