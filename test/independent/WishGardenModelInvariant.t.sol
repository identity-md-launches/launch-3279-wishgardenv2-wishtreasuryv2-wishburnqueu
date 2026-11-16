// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {GardenTestBase, IIdentityNFT} from "../helpers/GardenTestBase.sol";
import {LegacyWishGarden as WishGarden} from "../legacy-src/LegacyWishGarden.sol";
import {LegacyWishGardenTreasury as WishGardenTreasury} from "../legacy-src/LegacyWishGardenTreasury.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/// @dev A specification model: obligations, owners, records and balances are derived from inputs
/// and successful actions. No model update copies a production ledger, counter or claim mapping.
contract IndependentGardenModel is Test {
    uint256 public constant NFT_COUNT = 16;
    WishGarden public immutable garden;
    WishGardenTreasury public immutable treasury;
    IERC20 public immutable token;
    IIdentityNFT public immutable nft;
    address public immutable sink;
    address[5] public actors; // two buyers, operations, founder, original owner

    uint256 public paid;
    uint256 public free;
    uint256[3] public withdrawn;
    uint256[3] public donations; // garden, treasury, sink
    mapping(address => uint256) public balance;
    mapping(address => uint256) public allowance;
    address[16] public nftOwner;
    uint256[16] public consumed;
    address[2] public owners; // garden, treasury
    address[2] public pending;
    WishGarden.Candle[] private records;
    mapping(address => uint256[]) private purchaserIds;
    uint256 public successes;
    uint256 public expectedRejections;

    constructor(WishGarden garden_, address[5] memory actors_) {
        garden = garden_;
        treasury = garden_.treasury();
        token = IERC20(garden_.IMD());
        nft = IIdentityNFT(garden_.OFFICIAL_COLLECTION());
        sink = treasury.burnSink();
        actors = actors_;
        balance[actors_[0]] = 1_000_000e18;
        balance[actors_[1]] = 1_000_000e18;
        owners = [actors_[4], actors_[4]];
        for (uint256 id; id < NFT_COUNT; ++id) {
            nftOwner[id] = actors_[id % 2];
        }
    }

    function buy(uint8 buyerSeed, uint8 quantitySeed, uint8 styleSeed, bool shortAllowance) external {
        address buyer = actors[buyerSeed % 2];
        uint256 quantity = uint256(quantitySeed) % 50 + 1;
        uint256 payment = quantity * 1e18;
        uint256 approval = shortAllowance ? payment - 1 : payment;
        vm.prank(buyer);
        token.approve(address(garden), approval);
        allowance[buyer] = approval;
        if (shortAllowance) {
            _reject(
                buyer,
                address(garden),
                abi.encodeCall(garden.buyCandles, (quantity, styleSeed % 7)),
                abi.encodeWithSelector(
                    IERC20Errors.ERC20InsufficientAllowance.selector, address(garden), approval, payment
                )
            );
            return;
        }
        vm.prank(buyer);
        assertEq(garden.buyCandles(quantity, styleSeed % 7), records.length + 1);
        allowance[buyer] = 0;
        paid += quantity;
        balance[buyer] -= payment;
        balance[address(treasury)] += payment * 70 / 100;
        balance[sink] += payment * 30 / 100;
        for (uint256 i; i < quantity; ++i) {
            _append(buyer, styleSeed % 7, false, 0);
        }
        ++successes;
    }

    function claim(uint8 idSeed, uint8 callerSeed, uint8 styleSeed) external {
        uint256 id = idSeed % NFT_COUNT;
        address caller = actors[callerSeed % 2];
        bytes memory data = abi.encodeCall(garden.claimFreeCandle, (id, styleSeed % 7));
        if (consumed[id] != 0) {
            _reject(
                caller,
                address(garden),
                data,
                abi.encodeWithSelector(WishGarden.NFTAlreadyClaimed.selector, id)
            );
        } else if (caller != nftOwner[id]) {
            _reject(
                caller, address(garden), data, abi.encodeWithSelector(WishGarden.NotNFTOwner.selector, id)
            );
        } else {
            vm.prank(caller);
            assertEq(garden.claimFreeCandle(id, styleSeed % 7), records.length + 1);
            _append(caller, styleSeed % 7, true, id);
            ++successes;
        }
    }

    function batch(uint64 idsSeed, uint8 lengthSeed, uint8 callerSeed, uint8 styleSeed) external {
        uint256 count = uint256(lengthSeed) % 5 + 1;
        uint256[] memory ids = new uint256[](count);
        address caller = actors[callerSeed % 2];
        uint256 seen;
        bytes memory failure;
        for (uint256 i; i < count; ++i) {
            uint256 id = ((idsSeed >> (8 * i)) & 0xff) % (NFT_COUNT + 2); // includes nonexistent IDs
            ids[i] = id;
            if (failure.length != 0) continue;
            if (id < NFT_COUNT && (consumed[id] != 0 || seen & (1 << id) != 0)) {
                failure = abi.encodeWithSelector(WishGarden.NFTAlreadyClaimed.selector, id);
            } else if (id >= NFT_COUNT || nftOwner[id] != caller) {
                failure = abi.encodeWithSelector(WishGarden.NotNFTOwner.selector, id);
            }
            seen |= 1 << id;
        }
        if (failure.length != 0) {
            _reject(
                caller,
                address(garden),
                abi.encodeCall(garden.claimFreeCandles, (ids, styleSeed % 7)),
                failure
            );
            return;
        }
        vm.prank(caller);
        assertEq(garden.claimFreeCandles(ids, styleSeed % 7), records.length + 1);
        for (uint256 i; i < count; ++i) {
            _append(caller, styleSeed % 7, true, ids[i]);
        }
        ++successes;
    }

    function transferNFT(uint8 idSeed, uint8 destinationSeed, bool viaOperator) external {
        uint256 id = idSeed % NFT_COUNT;
        address from = nftOwner[id];
        address to = actors[destinationSeed % 2];
        if (viaOperator && to != from) {
            vm.prank(from);
            nft.approve(to, id);
            vm.prank(to);
            nft.transferFrom(from, to, id);
        } else {
            vm.prank(from);
            nft.transferFrom(from, to, id);
        }
        nftOwner[id] = to;
        assertEq(nft.getApproved(id), address(0));
        ++successes;
    }

    function withdraw(uint8 bucketSeed, uint96 amountSeed, uint8 modeSeed, uint8 destinationSeed) external {
        uint8 bucket = bucketSeed % 3;
        uint8 mode = modeSeed % 6;
        uint256 available = paid * (bucket == 0 ? 0.5e18 : 0.1e18) - withdrawn[bucket];
        uint256 amount = available == 0 ? 1 : uint256(amountSeed) % available + 1;
        address caller = bucket == 0 ? owners[1] : actors[bucket + 1];
        address destination = bucket == 0 ? actors[destinationSeed % 2] : caller;
        bytes memory failure;
        if (mode == 2) amount = available + 1;
        if (mode == 3) amount = 0;
        if (mode == 4) {
            caller = bucket == 0 && owners[1] == actors[0] ? actors[1] : actors[0];
            failure = bucket == 0
                ? abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller)
                : abi.encodeWithSelector(WishGardenTreasury.UnauthorizedBeneficiary.selector);
        } else if (amount > available) {
            failure = abi.encodeWithSelector(WishGardenTreasury.InsufficientBucketBalance.selector);
        } else if (amount == 0 || (mode == 5 && bucket == 0)) {
            destination = sink;
            failure = abi.encodeWithSelector(WishGardenTreasury.InvalidWithdrawal.selector);
        }
        bytes memory data = bucket == 0
            ? abi.encodeCall(treasury.withdrawEcosystem, (destination, amount))
            : bucket == 1
                ? abi.encodeCall(treasury.claimOperations, (amount))
                : abi.encodeCall(treasury.claimFounder, (amount));
        if (failure.length != 0) {
            _reject(caller, address(treasury), data, failure);
            return;
        }
        vm.prank(caller);
        (bool ok, bytes memory result) = address(treasury).call(data);
        assertTrue(ok, "model-authorized withdrawal failed");
        assertEq(result.length, 0);
        withdrawn[bucket] += amount;
        balance[address(treasury)] -= amount;
        balance[destination] += amount;
        ++successes;
    }

    function donate(uint8 destinationSeed, uint96 amountSeed, uint8 buyerSeed) external {
        uint256 destinationIndex = destinationSeed % 3;
        address destination =
            destinationIndex == 0 ? address(garden) : destinationIndex == 1 ? address(treasury) : sink;
        address from = actors[buyerSeed % 2];
        uint256 amount = uint256(amountSeed) % 1e18 + 1;
        vm.prank(from);
        assertTrue(token.transfer(destination, amount));
        balance[from] -= amount;
        balance[destination] += amount;
        donations[destinationIndex] += amount;
        ++successes;
    }

    /// @dev Proposal, replacement, cancellation and acceptance occur in separate randomized actions.
    function changeOwner(uint8 contractSeed, uint8 actionSeed, uint8 nomineeSeed) external {
        uint256 which = contractSeed % 2;
        Ownable2Step target = Ownable2Step(which == 0 ? address(garden) : address(treasury));
        uint8 action = actionSeed % 5;
        address nominee = actors[nomineeSeed % actors.length];
        if (action == 0 || action == 2) {
            if (action == 2) nominee = address(0); // Ownable2Step's documented cancellation state
            vm.prank(owners[which]);
            target.transferOwnership(nominee);
            pending[which] = nominee;
        } else if (action == 1) {
            if (pending[which] != nominee) {
                _reject(
                    nominee,
                    address(target),
                    abi.encodeCall(target.acceptOwnership, ()),
                    abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nominee)
                );
                return;
            }
            vm.prank(nominee);
            target.acceptOwnership();
            owners[which] = nominee;
            pending[which] = address(0);
        } else if (action == 3) {
            address outsider = owners[which] == actors[0] ? actors[1] : actors[0];
            _reject(
                outsider,
                address(target),
                abi.encodeCall(target.transferOwnership, (nominee)),
                abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsider)
            );
            return;
        } else {
            _reject(
                owners[which],
                address(target),
                abi.encodeCall(target.renounceOwnership, ()),
                abi.encodeWithSelector(WishGarden.OwnershipRequired.selector)
            );
            return;
        }
        ++successes;
    }

    function attemptPrivilegedCalls(uint8 whoSeed) external {
        address caller = actors[whoSeed % actors.length];
        _reject(
            caller,
            address(treasury),
            abi.encodeCall(treasury.recordPayment, (caller, records.length + 1, 1)),
            abi.encodeWithSelector(WishGardenTreasury.OnlyGarden.selector)
        );
        vm.prank(caller);
        (bool ok,) = sink.call(abi.encodeWithSignature("withdraw(address,uint256)", caller, 1));
        assertFalse(ok, "burn allocation became recoverable");
        ++expectedRejections;
    }

    function advanceTime(uint32 secondsSeed) external {
        vm.warp(block.timestamp + uint256(secondsSeed) % 365 days + 1);
    }

    function auditPage(uint16 offsetSeed, uint8 limitSeed, uint8 buyerSeed) external view {
        address purchaser = actors[buyerSeed % 2];
        uint256 length = purchaserIds[purchaser].length;
        uint256 offset = uint256(offsetSeed) % (length + 1);
        uint256 limit = uint256(limitSeed) % 100 + 1;
        (uint256[] memory ids, uint256 next) = garden.candleIdsOf(purchaser, offset, limit);
        uint256 count = length - offset;
        if (count > limit) count = limit;
        assertEq(ids.length, count);
        assertEq(next, offset + count);
        for (uint256 i; i < count; ++i) {
            assertEq(ids[i], purchaserIds[purchaser][offset + i]);
        }
    }

    function assertModel() external view {
        uint256 paidIMD = paid * 1e18;
        assertEq(treasury.totalPayments(), paidIMD);
        assertEq(treasury.totalIMDLocked(), paidIMD * 30 / 100);
        assertEq(treasury.ecosystemBalance(), paidIMD * 50 / 100 - withdrawn[0]);
        assertEq(treasury.operationsBalance(), paidIMD * 10 / 100 - withdrawn[1]);
        assertEq(treasury.founderBalance(), paidIMD * 10 / 100 - withdrawn[2]);
        assertEq(treasury.totalEcosystemWithdrawn(), withdrawn[0]);
        assertEq(treasury.totalOperationsClaimed(), withdrawn[1]);
        assertEq(treasury.totalFounderClaimed(), withdrawn[2]);
        assertEq(treasury.accountedBalance(), balance[address(treasury)] - donations[1]);
        assertEq(treasury.unallocatedBalance(), donations[1]);
        assertEq(token.balanceOf(address(garden)), donations[0]);
        assertEq(token.balanceOf(address(treasury)), balance[address(treasury)]);
        assertEq(token.balanceOf(sink), paidIMD * 30 / 100 + donations[2]);
        assertEq(treasury.totalSupplyBurned(), 0);
        assertEq(token.totalSupply(), 2_000_000e18);

        uint256 held =
            token.balanceOf(address(garden)) + token.balanceOf(address(treasury)) + token.balanceOf(sink);
        for (uint256 i; i < actors.length; ++i) {
            assertEq(token.balanceOf(actors[i]), balance[actors[i]], "actor received or lost unmodeled IMD");
            assertEq(token.allowance(actors[i], address(garden)), allowance[actors[i]]);
            assertEq(garden.candleCountOf(actors[i]), purchaserIds[actors[i]].length);
            held += token.balanceOf(actors[i]);
        }
        assertEq(held, 2_000_000e18, "conservation across all custody and recipients");
        assertEq(garden.owner(), owners[0]);
        assertEq(treasury.owner(), owners[1]);
        assertEq(garden.pendingOwner(), pending[0]);
        assertEq(treasury.pendingOwner(), pending[1]);
        assertEq(treasury.operationsRecipient(), actors[2]);
        assertEq(treasury.founderRecipient(), actors[3]);
        assertEq(treasury.garden(), address(garden));
        assertTrue(garden.collectionConfirmed());
        assertEq(garden.paidCandles(), paid);
        assertEq(garden.freeCandles(), free);
        assertEq(garden.totalCandles(), records.length);
        assertEq(records.length, paid + free);
        for (uint256 id; id < NFT_COUNT; ++id) {
            assertEq(nft.ownerOf(id), nftOwner[id]);
            assertEq(
                garden.nftClaimedCandle(id), consumed[id], "transfer or failure reset lifetime consumption"
            );
            if (consumed[id] != 0) _assertRecord(consumed[id]);
        }
        if (records.length != 0) {
            _assertRecord(1);
            _assertRecord(records.length);
            _assertRecord(records.length / 2 + 1);
        }
    }

    /// @dev At the end of each random sequence compare every historical record and every owner index.
    function assertFullHistory() external view {
        for (uint256 first = 1; first <= records.length; first += 100) {
            (WishGarden.Candle[] memory page, uint256 next) = garden.getCandles(first, 100);
            uint256 count = records.length - first + 1;
            if (count > 100) count = 100;
            assertEq(page.length, count);
            assertEq(next, first + count);
            for (uint256 i; i < count; ++i) {
                assertEq(abi.encode(page[i]), abi.encode(records[first + i - 1]));
            }
        }
        for (uint256 a; a < actors.length; ++a) {
            uint256[] storage expected = purchaserIds[actors[a]];
            for (uint256 offset; offset < expected.length; offset += 100) {
                (uint256[] memory ids, uint256 next) = garden.candleIdsOf(actors[a], offset, 100);
                uint256 count = expected.length - offset;
                if (count > 100) count = 100;
                assertEq(ids.length, count);
                assertEq(next, offset + count);
                for (uint256 i; i < count; ++i) {
                    assertEq(ids[i], expected[offset + i]);
                }
            }
        }
    }

    function _append(address purchaser, uint8 style, bool freeClaim, uint256 tokenId) private {
        uint256 id = records.length + 1;
        records.push(WishGarden.Candle(purchaser, uint64(block.timestamp), style, freeClaim, id - 1, tokenId));
        purchaserIds[purchaser].push(id);
        if (freeClaim) {
            assertEq(consumed[tokenId], 0);
            consumed[tokenId] = id;
            ++free;
        }
    }

    function _assertRecord(uint256 id) private view {
        assertEq(
            abi.encode(garden.getCandle(id)),
            abi.encode(records[id - 1]),
            "persistent record differs from input model"
        );
    }

    function _reject(address caller, address target, bytes memory data, bytes memory expected) private {
        vm.prank(caller);
        (bool ok, bytes memory reason) = target.call(data);
        assertFalse(ok, "invalid action succeeded");
        assertEq(reason, expected, "failure path or authorization changed");
        ++expectedRejections;
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
contract IndependentWishGardenModelInvariantTest is GardenTestBase {
    IndependentGardenModel private model;

    function setUp() public override {
        super.setUp();
        _confirmCollection();
        for (uint256 id; id < 16; ++id) {
            _mintNFT(id % 2 == 0 ? alice : bob, id);
        }
        model = new IndependentGardenModel(garden, [alice, bob, operations, founder, OWNER]);
        targetContract(address(model));
        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = IndependentGardenModel.buy.selector;
        selectors[1] = IndependentGardenModel.claim.selector;
        selectors[2] = IndependentGardenModel.batch.selector;
        selectors[3] = IndependentGardenModel.transferNFT.selector;
        selectors[4] = IndependentGardenModel.withdraw.selector;
        selectors[5] = IndependentGardenModel.donate.selector;
        selectors[6] = IndependentGardenModel.changeOwner.selector;
        selectors[7] = IndependentGardenModel.attemptPrivilegedCalls.selector;
        selectors[8] = IndependentGardenModel.advanceTime.selector;
        selectors[9] = IndependentGardenModel.auditPage.selector;
        targetSelector(FuzzSelector({addr: address(model), selectors: selectors}));
    }

    function invariant_balancesPermissionsRecordsAndConsumptionMatchIndependentModel() public view {
        model.assertModel();
    }

    function afterInvariant() public view {
        model.assertFullHistory();
    }

    /// @dev A deterministic witness that successful batches, owner acceptance and failure branches
    /// are reachable. Random handlers must not be a suite of silent early returns.
    function test_modelExercisesMixedSuccessAndRejectionSequence() public {
        model.buy(0, 9, 6, false);
        model.buy(1, 49, 0, true);
        model.batch(0x0200, 1, 0, 5); // token IDs 0 and 2, both Alice's
        model.transferNFT(0, 1, true);
        model.claim(0, 1, 0); // consumed ID follows NFT, not the wallet
        model.batch(0x0301, 1, 1, 2); // token IDs 1 and 3, both Bob's
        model.donate(0, 111, 0);
        model.donate(1, 222, 1);
        model.donate(2, 333, 0);
        model.changeOwner(1, 0, 0); // nominate Alice
        model.withdraw(0, 0, 4, 1); // pending owner still unauthorized
        model.changeOwner(1, 1, 0); // Alice accepts treasury ownership
        model.withdraw(0, 5e18 - 1, 0, 1);
        model.withdraw(1, 1e18 - 1, 0, 0);
        model.withdraw(2, 1e18 - 1, 0, 0);
        model.withdraw(2, 0, 2, 0); // repeated withdrawal after draining
        model.advanceTime(365 days);
        model.attemptPrivilegedCalls(0);
        model.auditPage(0, 99, 0);
        model.assertModel();
        model.assertFullHistory();
        assertGt(model.successes(), 0);
        assertGt(model.expectedRejections(), 0);
    }
}
