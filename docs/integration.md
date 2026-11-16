# Specification for the later website order

Use confirmed Ethereum deployment receipts/addresses from the launch service, verified against the exported ABIs and source commit. `docs/deployment/status.json` currently records that those are pending. Do not invent application addresses or use the old manifest. No website is part of this delivery.

## Display and identities

Always load **both** the legacy garden and replacement garden independently. Canonical key is `(1, gardenAddress, candleId)`; `keccak256(abi.encode(uint256(1), gardenAddress, candleId))` matches their key helpers. Local legacy IDs start at 1, new IDs at `CANDLE_ID_BASE + 1`. Treat all uint256 values as bigint/decimal strings. `totalCandles` is a count, not the largest new ID.

Use existing purchaser pagination (`candleIdsOf`, limit 1–100) and global pagination (`getCandles`) for both namespaces. For replacement global pages start at `CANDLE_ID_BASE + 1`; for legacy start at 1. Positions never change. Render distinct legacy/replacement areas; a replacement local slot is `position - CANDLE_ID_BASE`, a legacy slot is its unchanged position. Retain the namespace when deriving tile/section keys. Flames are permanent; an optional first-day glow may use `createdAt`, but never extinguishes the candle. All seven styles are cosmetic only.

Legacy ABI snapshots are in `docs/abi/legacy`. `LegacyWishRegistry.legacyCandle`, `legacyFunds`, `legacyGardenBalance` add convenient read-through. Display all old candles and treasury/sink balances even when a legacy flow is disabled. Legacy sink balances are **locked, not burned**. Never combine them with new confirmed burns or imply the replacement moved them. Show legacy free-claim eligibility using its `nftClaimedCandle(nftId)` and current NFT `ownerOf`; approvals are insufficient and transfers do not reset eligibility. The NFT ID 0 is valid.

## Mandatory public-forever acknowledgement

Before the first wallet prompt containing nonempty text, show an unchecked required acknowledgement with substantially this exact meaning:

> I understand that this wish, my wallet address and its candle association will be public on Ethereum forever. It cannot be edited, deleted or made private. I will not publish secrets or personal information I do not want permanently public.

Do not precheck it, hide it in general terms or send the text to an RPC for estimation until the user acknowledges. Full calldata may be public even if a transaction fails. No encryption, private wish, deletion or admin override is offered. Submit `publicForeverAcknowledged = true` only after the explicit acknowledgement. The contract rejects nonempty text without it, but cannot verify whether a UI actually obtained informed consent.

Validate UTF-8 bytes **and** Unicode codepoints: <=1120 bytes and <=280 Unicode scalar values. JavaScript `.length` counts UTF-16 units, not codepoints; use a scalar-aware iterator and reject unpaired UTF-16 surrogates before UTF-8 encoding. Grapheme clusters (e.g. joined emoji or combining marks) can contain multiple codepoints. No normalization or rewriting occurs onchain. Render as plain text (`textContent`), never raw HTML; controls/URLs/bidi text remain untrusted user content. Use local wrapping/escaping for display without implying the stored text changed.

## Paid transaction flow

1. Verify chain 1, replacement addresses and `treasury.purchasesEnabled()`, `bridgeFrozen()`, `receiverReady()` plus current dependency readiness. If disabled, explain owner setup is incomplete and do not request IMD approval or payment.
2. Choose 1–50 candles, style 0–6, optional **same text for every candle in this purchase**. Different texts need separate purchases. Quote exactly `quantity * 10^18` IMD. ETH pays gas; do not add fees to the IMD price or reduce the 30% allocation.
3. Obtain acknowledgement before any publication of nonempty text. Approve only that amount to the confirmed **garden**, not treasury or bridge. Then call `buyCandles` for no text or `buyCandlesWithWish` with text and acknowledgement.
4. Wait for a confirmed successful receipt; derive exact candle IDs from the event/first ID and quantity. Use `wishOf(candleId)` to read author and full text. `WishPublished` emits first ID, quantity and text for the entire batch. A failed purchase stores no candle or wish. Check the actual receipt before retrying to avoid purchasing twice; a wallet timeout is not a failed transaction.

Paid text is atomic and immutable. Choosing no text leaves that paid candle without a later attachment API. Each new paid candle always has `freeClaim=false`; there is no replacement free-claim ledger or entrypoint.

## Legacy claim plus wish flow (two transactions)

1. Read the legacy free-claim status and consumed NFT ledger. The owner may still need to activate legacy claims separately. The replacement cannot do this.
2. Call the legacy `claimFreeCandle`/`claimFreeCandles` using its unchanged ABI. Wait for its confirmed receipt; persist the **legacy garden address + actual candle ID** in the UI's pending-wish workflow.
3. Obtain the public-forever acknowledgement and call the companion `registerWish(legacyId, text, true)` from the recorded candle purchaser. Paid legacy candles may use this same once-only registry.
4. On failure/cancel/timeout, reload the receipt and `wishOf(legacyId)`. If still missing, retry **registration only**. Never purchase or claim again merely because wish registration failed. Another holder of the NFT cannot register for the former purchaser's candle. Existing wishes cannot be overwritten even by the author or owner.

A missing wish is `author == address(0)` in the legacy registry; empty registrations are rejected. Wishes for new candles are read from `WishGarden`, never from the legacy registry. An original legacy candle cannot already contain text: its pinned record ABI has none.

## Financial and operational display

Show separately: new `pendingBurn`, `pendingDust` (a subset, not an additional bucket), `inTransitBurn`, `confirmedBurn`, three revenue balances and each withdrawal event (bucket/caller/destination/amount). The Ethereum bridge source supply decrease does not establish a final burn. Only the authenticated confirmed counter supports a confirmed burn label; show Base burn and both-chain message links as supporting evidence. A browser assertion or operator screenshot cannot advance onchain accounting. Legacy locked funds remain separate.

Display absence of hosted automation honestly: operators fund bridge and acknowledgement gas separately and retry failed work. Candles confer no lottery entry, yield, financial rewards or investment/treasury rights. Keep Ethereum and Base transaction contexts explicit and never route a candle purchase onto Base.
