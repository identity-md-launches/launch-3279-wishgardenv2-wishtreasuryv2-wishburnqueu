// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {WalletGas} from "../helpers/WalletGas.sol";
import {BaseIMDRuntime} from "../fixtures/BaseIMDRuntime.sol";
import {BaseAdapterRuntime} from "../fixtures/BaseAdapterRuntime.sol";
import {ReviewComposeEndpoint} from "./BaseAdapterRuntime.t.sol";
import {BaseBurnReceiver} from "../../base/src/BaseBurnReceiver.sol";
import {WishGardenTreasury} from "src/WishGardenTreasury.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IIMDOFT, IBaseIMDRestrictions, Origin} from "src/bridge/IMDBridgeInterfaces.sol";

interface IReviewAdapterReceive {
    function setPeer(uint32 eid, bytes32 peer) external;
    function lzReceive(
        Origin calldata origin,
        bytes32 guid,
        bytes calldata message,
        address executor,
        bytes calldata extraData
    ) external payable;
}

/// @notice Supplied Base IMD and adapter runtimes with LOCAL storage (not a fork): transfer limits are switched
///         on by writing the token's own storage (slot 0x0b byte 0 = limitsInEffect, byte 1 = tradingActive,
///         slot 0x0a = maxWallet; located with vm.accesses against the supplied runtime). Live values of these
///         settings were NOT read; this only shows what the receiver does under each setting.
contract BaseCreditLimitsReviewTest is Test, WalletGas {
    address constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address constant BASE_IMD = 0xFF0C532FDB8Cd566Ae169C1CB157ff2Bdc83E105;
    address constant BASE_ADAPTER = 0xab152db8aaC047b6757fFCF495FfE88d7712690A;
    address constant OWNER = 0x48E4E74fE1d0c14404cEB57B9fec5b21329C6ec9;
    bytes32 constant FLAGS_SLOT = bytes32(uint256(0x0b));
    bytes32 constant MAX_WALLET_SLOT = bytes32(uint256(0x0a));
    /// @dev Frozen maximum batch of the receiver under test (equal to the 1e18 max-wallet used below).
    uint256 constant MAX_BATCH = 1e18;
    ReviewComposeEndpoint internal endpoint;
    BaseBurnReceiver internal receiver;
    WishGardenTreasury internal queue;
    IERC20 internal token;

    function setUp() public {
        vm.chainId(8453);
        vm.deal(address(this), 1 ether);
        vm.etch(BASE_IMD, BaseIMDRuntime.code());
        vm.etch(BASE_ADAPTER, BaseAdapterRuntime.code());
        token = IERC20(BASE_IMD);
        address endpointAddress = IIMDOFT(BASE_ADAPTER).endpoint();
        vm.etch(endpointAddress, address(new ReviewComposeEndpoint()).code);
        vm.store(endpointAddress, bytes32(0), bytes32(uint256(30184)));
        endpoint = ReviewComposeEndpoint(endpointAddress);
        endpoint.setFee(0.001 ether);
        vm.store(BASE_ADAPTER, bytes32(0), bytes32(uint256(uint160(OWNER))));
        vm.prank(OWNER);
        IReviewAdapterReceive(BASE_ADAPTER).setPeer(30101, bytes32(uint256(uint160(IMD))));
        queue = new WishGardenTreasury(OWNER);
        receiver = new BaseBurnReceiver(
            endpointAddress, BASE_ADAPTER, address(queue), 30101, 30184, 300_000, MAX_BATCH
        );
    }

    function _limits(bool limitsOn, bool tradingOn, uint256 maxWallet) private {
        vm.store(BASE_IMD, FLAGS_SLOT, bytes32(uint256(limitsOn ? 1 : 0) | uint256(tradingOn ? 0x100 : 0)));
        vm.store(BASE_IMD, MAX_WALLET_SLOT, bytes32(maxWallet));
        IBaseIMDRestrictions restrictions = IBaseIMDRestrictions(BASE_IMD);
        assertEq(restrictions.limitsInEffect(), limitsOn);
        assertEq(restrictions.maxWallet(), maxWallet);
    }

    function _packet(uint256 batchId, uint256 amount) private view returns (bytes memory) {
        return abi.encodePacked(
            bytes32(uint256(uint160(address(receiver)))),
            uint64(amount / 1e12),
            bytes32(uint256(uint160(address(queue)))),
            abi.encode(uint256(1), batchId, amount)
        );
    }

    function _credit(bytes32 guid, uint256 batchId, uint256 amount) private {
        vm.prank(address(endpoint));
        IReviewAdapterReceive(BASE_ADAPTER)
            .lzReceive(
                Origin(30101, bytes32(uint256(uint160(IMD))), uint64(batchId)),
                guid,
                _packet(batchId, amount),
                address(this),
                ""
            );
    }

    function _compose(bytes32 guid) private {
        bytes memory message = endpoint.composeMessage();
        vm.prank(address(endpoint));
        receiver.lzCompose(BASE_ADAPTER, guid, message, address(this), "");
    }

    /// @notice Under a max-wallet limit, readiness reports the headroom, a credit above it reverts inside the
    ///         actual adapter with nothing consumed, a credit within it burns exactly, and the oversized credit
    ///         is retryable once the limit is lifted, without double counting.
    function test_actualMaxWalletBoundsCreditAndOversizedBatchRetriesAfterLimitLifted() public {
        _limits(true, true, 1e18);
        assertEq(receiver.maxCredit(), 1e18);
        receiver.sendAcknowledgement{value: 0.001 ether}(0);
        deal(BASE_IMD, BASE_ADAPTER, 3.9e18, true);
        uint256 supply = token.totalSupply();
        bytes32 bigGuid = keccak256("oversized batch");
        vm.expectRevert(bytes("Max wallet exceeded"));
        _credit(bigGuid, 1, 3e18);
        assertEq(token.balanceOf(address(receiver)), 0);
        assertEq(token.balanceOf(BASE_ADAPTER), 3.9e18);
        assertEq(token.totalSupply(), supply);
        assertFalse(receiver.consumedGuid(bigGuid));
        assertEq(receiver.totalBurned(), 0);
        // A batch within the headroom is credited and burned exactly.
        bytes32 smallGuid = keccak256("in-limit batch");
        _credit(smallGuid, 2, 0.9e18);
        assertEq(receiver.maxCredit(), 0.1e18, "an unburned credit consumes headroom until composed");
        _compose(smallGuid);
        assertEq(receiver.maxCredit(), 1e18);
        assertEq(receiver.totalBurned(), 0.9e18);
        assertEq(token.totalSupply(), supply - 0.9e18);
        // Lifting the limit makes the same oversized packet deliverable; it burns once.
        _limits(false, true, 1e18);
        assertEq(receiver.maxCredit(), type(uint256).max);
        _credit(bigGuid, 1, 3e18);
        _compose(bigGuid);
        assertEq(receiver.totalBurned(), 3.9e18);
        assertEq(token.totalSupply(), supply - 3.9e18);
        assertEq(token.balanceOf(address(receiver)), 0);
        bytes memory message = endpoint.composeMessage();
        vm.prank(address(endpoint));
        vm.expectRevert(BaseBurnReceiver.DuplicateBurn.selector);
        receiver.lzCompose(BASE_ADAPTER, bigGuid, message, address(this), "");
        (bytes32 g1, uint256 a1) = receiver.burns(1);
        (bytes32 g2, uint256 a2) = receiver.burns(2);
        assertEq(g1, bigGuid);
        assertEq(a1, 3e18);
        assertEq(g2, smallGuid);
        assertEq(a2, 0.9e18);
    }

    /// @notice Headroom below the frozen maximum batch refuses readiness; exactly one maximum batch accepts it.
    function testFuzz_actualMaxWalletBelowMaximumBatchRefusesReadiness(uint96 walletSeed) public {
        uint256 wallet = bound(walletSeed, 0, 2e18);
        _limits(true, true, wallet);
        assertEq(receiver.maxCredit(), wallet);
        assertEq(receiver.maxBatch(), MAX_BATCH);
        if (wallet < MAX_BATCH) {
            vm.expectRevert(BaseBurnReceiver.CreditRestricted.selector);
            receiver.sendAcknowledgement{value: 0.001 ether}(0);
            assertEq(endpoint.lastMessage().length, 0);
        } else {
            receiver.sendAcknowledgement{value: 0.001 ether}(0);
            assertEq(
                endpoint.lastMessage(),
                abi.encode(uint8(1), uint256(0), bytes32(uint256(uint160(BASE_ADAPTER))), uint256(8453))
            );
        }
    }

    /// @notice Readiness reads several token restriction views; it behaves the same at a wallet's gas.
    function test_readinessUnderLimitsAtWalletGas() public {
        _limits(true, true, 1e18);
        address keeper = makeAddr("keeper");
        vm.deal(keeper, 1 ether);
        assertSameAtWalletGas(
            keeper, address(receiver), 0.001 ether, abi.encodeCall(receiver.sendAcknowledgement, (0))
        );
    }

    // ---------------------------------------------------------------------------------------------------
    // Settlement of the previous round's findings, on the supplied runtimes with local storage.
    // ---------------------------------------------------------------------------------------------------

    function _donate(address donor, uint256 amount) private {
        deal(BASE_IMD, donor, amount, true);
        vm.prank(donor);
        assertTrue(token.transfer(address(receiver), amount));
    }

    /// @notice Finding 8336590 case A: a donation filling the max-wallet no longer blocks readiness. The
    ///         readiness call burns it (a real supply burn) and records it as surplus, never as a batch.
    function test_actualDonationFillingMaxWalletIsBurnedByReadiness() public {
        _limits(true, true, 1e18);
        _donate(makeAddr("donor"), 1e18);
        assertEq(receiver.maxCredit(), 0);
        uint256 supply = token.totalSupply();
        address anyone = makeAddr("anyone");
        vm.deal(anyone, 1 ether);
        vm.prank(anyone);
        receiver.sendAcknowledgement{value: 0.001 ether}(0);
        assertEq(token.balanceOf(address(receiver)), 0);
        assertEq(token.totalSupply(), supply - 1e18);
        assertEq(receiver.surplusBurned(), 1e18);
        assertEq(receiver.totalBurned(), 0, "a donation is never an attributed batch burn");
        assertEq(receiver.maxCredit(), 1e18);
        assertEq(
            endpoint.lastMessage(),
            abi.encode(uint8(1), uint256(0), bytes32(uint256(uint160(BASE_ADAPTER))), uint256(8453))
        );
    }

    /// @notice Finding 8336590 case B: after readiness, a donation that blocks the actual adapter credit is
    ///         cleared by anyone with burnSurplus; the same packet then lands and burns exactly once.
    function test_actualDonationBlockingCreditIsClearedByAnyoneAndBatchBurnsOnce() public {
        _limits(true, true, 1e18);
        receiver.sendAcknowledgement{value: 0.001 ether}(0);
        deal(BASE_IMD, BASE_ADAPTER, 0.3e18, true);
        _donate(makeAddr("donor"), 1e18);
        bytes32 guid = keccak256("blocked batch");
        vm.expectRevert(bytes("Max wallet exceeded"));
        _credit(guid, 1, 0.3e18);
        uint256 supply = token.totalSupply();
        vm.prank(makeAddr("stranger"));
        assertEq(receiver.burnSurplus(), 1e18);
        assertEq(token.totalSupply(), supply - 1e18);
        _credit(guid, 1, 0.3e18);
        _compose(guid);
        assertEq(receiver.totalBurned(), 0.3e18);
        assertEq(receiver.surplusBurned(), 1e18);
        assertEq(token.totalSupply(), supply - 1.3e18);
        assertEq(token.balanceOf(address(receiver)), 0);
        // Nothing left: a second surplus burn reverts rather than emitting a zero burn.
        vm.expectRevert(BaseBurnReceiver.InexactBurn.selector);
        receiver.burnSurplus();
        receiver.sendAcknowledgement{value: 0.001 ether}(1);
        assertEq(endpoint.lastMessage(), abi.encode(uint8(2), uint256(1), guid, uint256(0.3e18)));
    }

    /// @notice A front-runner burning a credited batch (plus a donation) before its compose cannot make the
    ///         batch fail, burn twice or be over-reported: the compose draws the shortfall from surplus.
    function testFuzz_actualSurplusBurnBeforeComposeAttributesExactly(
        uint64 creditUnits,
        uint64 donationUnits
    ) public {
        uint256 amount = bound(creditUnits, 300_000, 1_000_000) * 1e12;
        uint256 donation = bound(donationUnits, 0, 1e18 - amount);
        _limits(true, true, 1e18);
        deal(BASE_IMD, BASE_ADAPTER, amount, true);
        bytes32 guid = keccak256(abi.encode("front-run", amount));
        _credit(guid, 7, amount);
        if (donation != 0) _donate(makeAddr("donor"), donation);
        uint256 supply = token.totalSupply();
        assertEq(receiver.burnSurplus(), amount + donation);
        assertEq(receiver.surplusBurned(), amount + donation);
        _compose(guid);
        assertEq(receiver.totalBurned(), amount);
        assertEq(receiver.surplusBurned(), donation);
        assertEq(token.totalSupply(), supply - amount - donation, "no burn beyond what was really held");
        assertEq(supply - token.totalSupply(), receiver.totalBurned() + receiver.surplusBurned());
        (bytes32 g, uint256 a) = receiver.burns(7);
        assertEq(g, guid);
        assertEq(a, amount);
        bytes memory message = endpoint.composeMessage();
        vm.prank(address(endpoint));
        vm.expectRevert(BaseBurnReceiver.DuplicateBurn.selector);
        receiver.lzCompose(BASE_ADAPTER, guid, message, address(this), "");
    }

    /// @notice A compose with no credit held and no surplus to draw from reverts and changes nothing; the real
    ///         credit then composes normally. (The receiver trusts that the endpoint only delivers a compose the
    ///         adapter queued after crediting; that is LayerZero's guarantee, not something tested here.)
    function test_actualComposeWithoutCreditAndWithoutSurplusReverts() public {
        _limits(false, true, 1e18);
        bytes32 guid = keccak256("credit arrives later");
        bytes memory message = abi.encodePacked(
            uint64(3),
            uint32(30101),
            uint256(0.6e18),
            bytes32(uint256(uint160(address(queue)))),
            abi.encode(uint256(1), uint256(3), uint256(0.6e18))
        );
        vm.prank(address(endpoint));
        vm.expectRevert(BaseBurnReceiver.InexactBurn.selector);
        receiver.lzCompose(BASE_ADAPTER, guid, message, address(this), "");
        assertFalse(receiver.consumedGuid(guid));
        assertEq(receiver.totalBurned(), 0);
        deal(BASE_IMD, BASE_ADAPTER, 0.6e18, true);
        _credit(guid, 3, 0.6e18);
        assertEq(endpoint.composeMessage(), message, "the actual adapter queues the same compose bytes");
        _compose(guid);
        assertEq(receiver.totalBurned(), 0.6e18);
        assertEq(receiver.surplusBurned(), 0);
    }

    /// @notice Finding df03c1f: trading inactive (limits on) refuses readiness, matching the token, which
    ///         rejects the actual adapter credit; enabling trading allows both.
    function test_actualTradingInactiveRefusesReadinessUntilEnabled() public {
        _limits(true, false, 1e18);
        assertEq(receiver.maxCredit(), 0);
        vm.expectRevert(BaseBurnReceiver.CreditRestricted.selector);
        receiver.sendAcknowledgement{value: 0.001 ether}(0);
        deal(BASE_IMD, BASE_ADAPTER, 0.3e18, true);
        bytes32 guid = keccak256("trading off");
        vm.expectRevert(bytes("Trading is not active."));
        _credit(guid, 1, 0.3e18);
        _limits(true, true, 1e18);
        assertEq(receiver.maxCredit(), 1e18);
        receiver.sendAcknowledgement{value: 0.001 ether}(0);
        _credit(guid, 1, 0.3e18);
        _compose(guid);
        assertEq(receiver.totalBurned(), 0.3e18);
    }

    /// @notice A receiver whose frozen maximum batch exceeds the max-wallet cannot signal readiness even with
    ///         room for a minimum batch (finding 89832d9 settlement on the Base side).
    function test_actualMaxWalletBelowFrozenBatchRefusesReadiness() public {
        BaseBurnReceiver big = new BaseBurnReceiver(
            address(endpoint), BASE_ADAPTER, address(queue), 30101, 30184, 300_000, 30e18
        );
        _limits(true, true, 29.999999e18);
        assertGe(big.maxCredit(), big.MIN_CREDIT());
        vm.expectRevert(BaseBurnReceiver.CreditRestricted.selector);
        big.sendAcknowledgement{value: 0.001 ether}(0);
        _limits(true, true, 30e18);
        big.sendAcknowledgement{value: 0.001 ether}(0);
    }

    /// @notice A receiver cannot be built with a maximum batch below one candle's burn share.
    function test_receiverRejectsMaximumBatchBelowMinimumCredit() public {
        vm.expectRevert(BaseBurnReceiver.InvalidConfiguration.selector);
        new BaseBurnReceiver(
            address(endpoint), BASE_ADAPTER, address(queue), 30101, 30184, 300_000, 0.3e18 - 1
        );
    }

    /// @notice burnSurplus works only on Base and behaves the same at a wallet's gas.
    function test_burnSurplusOnlyOnBaseAndAtWalletGas() public {
        _donate(makeAddr("donor"), 0.5e18);
        vm.chainId(1);
        vm.expectRevert();
        receiver.burnSurplus();
        vm.chainId(8453);
        address keeper = makeAddr("keeper");
        assertSameAtWalletGas(keeper, address(receiver), 0, abi.encodeCall(receiver.burnSurplus, ()));
    }

    /// @notice Random sequences of credits, donations, surplus burns and composes on the actual runtimes:
    ///         real supply reduction always equals totalBurned + surplusBurned; every credited batch burns
    ///         exactly once and its recorded amount equals its credit; nothing remains once all compose.
    function testFuzz_actualRandomSurplusAndComposeSequencesConserveSupply(uint8[24] memory ops) public {
        _limits(false, true, 0);
        uint256 supply = token.totalSupply();
        uint256 credits;
        uint256 composed;
        uint256 donated;
        uint256[] memory amounts = new uint256[](ops.length);
        for (uint256 i; i < ops.length; ++i) {
            uint8 op = ops[i] % 4;
            if (op == 0) {
                uint256 amount = (uint256(ops[i]) + 300) * 1e15;
                deal(BASE_IMD, BASE_ADAPTER, token.balanceOf(BASE_ADAPTER) + amount, true);
                supply += amount;
                ++credits;
                amounts[credits - 1] = amount;
                _credit(keccak256(abi.encode(credits)), credits, amount);
            } else if (op == 1) {
                uint256 amount = (uint256(ops[i]) + 1) * 1e14;
                deal(BASE_IMD, address(this), amount, true);
                supply += amount;
                assertTrue(token.transfer(address(receiver), amount));
                donated += amount;
            } else if (op == 2) {
                if (token.balanceOf(address(receiver)) != 0) receiver.burnSurplus();
            } else if (composed < credits) {
                ++composed;
                _composeId(composed, amounts[composed - 1]);
            }
            assertEq(supply - token.totalSupply(), receiver.totalBurned() + receiver.surplusBurned());
        }
        while (composed < credits) {
            ++composed;
            _composeId(composed, amounts[composed - 1]);
        }
        if (token.balanceOf(address(receiver)) != 0) receiver.burnSurplus();
        uint256 sum;
        for (uint256 i; i < credits; ++i) {
            (bytes32 g, uint256 a) = receiver.burns(i + 1);
            assertEq(g, keccak256(abi.encode(i + 1)));
            assertEq(a, amounts[i]);
            sum += amounts[i];
        }
        assertEq(receiver.totalBurned(), sum);
        assertEq(receiver.surplusBurned(), donated, "after every compose, surplus is exactly the donations");
        assertEq(token.balanceOf(address(receiver)), 0);
        assertEq(supply - token.totalSupply(), sum + donated);
    }

    function _composeId(uint256 batchId, uint256 amount) private {
        bytes memory message = abi.encodePacked(
            uint64(batchId),
            uint32(30101),
            amount,
            bytes32(uint256(uint160(address(queue)))),
            abi.encode(uint256(1), batchId, amount)
        );
        vm.prank(address(endpoint));
        receiver.lzCompose(BASE_ADAPTER, keccak256(abi.encode(batchId)), message, address(this), "");
    }
}
