// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMDRuntime} from "../fixtures/IMDRuntime.sol";
import {BaseIMDRuntime} from "../fixtures/BaseIMDRuntime.sol";
import {BaseAdapterRuntime} from "../fixtures/BaseAdapterRuntime.sol";
import {MockEndpoint} from "./Mocks.sol";
import {WishGarden} from "../../src/WishGarden.sol";
import {WishGardenTreasury} from "../../src/WishGardenTreasury.sol";
import {BaseBurnReceiver} from "../../base/src/BaseBurnReceiver.sol";
import {IIMDOFT, IBaseIMDRestrictions, Origin} from "../../src/bridge/IMDBridgeInterfaces.sol";

interface IPeerSetup {
    function setPeer(uint32, bytes32) external;
}

/// @notice Real verified token/adapter RUNTIMES with local storage and mocked endpoint transport, not a fork.
contract VerifiedRuntimeTest is Test {
    address constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address constant BASE_IMD = 0xFF0C532FDB8Cd566Ae169C1CB157ff2Bdc83E105;
    address constant BASE_ADAPTER = 0xab152db8aaC047b6757fFCF495FfE88d7712690A;
    address constant OWNER = 0x48E4E74fE1d0c14404cEB57B9fec5b21329C6ec9;
    uint256 constant MAX_BATCH = 30e18;

    function test_actualOFTSendUsesCallerBalanceNoApprovalAndExactCodec() public {
        vm.chainId(1);
        vm.deal(address(this), 1 ether);
        vm.etch(IMD, IMDRuntime.code());
        address endpoint = IIMDOFT(IMD).endpoint();
        vm.etch(endpoint, address(new MockEndpoint(30101)).code);
        vm.store(endpoint, bytes32(0), bytes32(uint256(30101)));
        MockEndpoint(endpoint).setFee(0.001 ether);
        vm.store(IMD, bytes32(0), bytes32(uint256(uint160(OWNER))));
        vm.prank(OWNER);
        IPeerSetup(IMD).setPeer(30184, bytes32(uint256(uint160(BASE_ADAPTER))));
        WishGardenTreasury t = new WishGardenTreasury(OWNER);
        WishGarden g = new WishGarden(OWNER, address(t));
        bytes32 salt = keccak256("fixture salt");
        // The receiver is derived; it does not need to exist for the freeze (it lives on Base).
        address receiver = t.predictReceiver(endpoint, BASE_ADAPTER, 300_000, MAX_BATCH, salt);
        vm.startPrank(OWNER);
        t.bindGarden(address(g));
        t.freezeBridge(
            endpoint,
            endpoint,
            BASE_ADAPTER,
            300_000,
            300_000,
            300_000,
            MAX_BATCH,
            salt,
            keccak256("fixture evidence")
        );
        vm.stopPrank();
        assertEq(t.baseReceiver(), receiver);
        vm.prank(endpoint);
        t.lzReceive(
            Origin(30184, bytes32(uint256(uint160(receiver))), 1),
            keccak256("ready"),
            abi.encode(uint8(1), uint256(0), bytes32(uint256(uint160(BASE_ADAPTER))), uint256(8453)),
            address(this),
            ""
        );
        vm.prank(OWNER);
        t.activatePurchases();
        deal(IMD, address(this), 10e18, true);
        IERC20(IMD).approve(address(g), 10e18);
        g.buyCandles(10, 0);
        uint256 supply = IERC20(IMD).totalSupply();
        t.dispatch{value: 0.001 ether}(3e18, 1);
        assertEq(IERC20(IMD).balanceOf(address(t)), 7e18);
        assertEq(IERC20(IMD).totalSupply(), supply - 3e18);
        assertEq(IERC20(IMD).allowance(address(t), IMD), 0);
        // Actual OFTMsgCodec message: destination (32), amountSD (8), composeFrom (32), application payload (96).
        assertEq(MockEndpoint(endpoint).lastReceiver(), bytes32(uint256(uint160(BASE_ADAPTER))));
        assertEq(
            MockEndpoint(endpoint).lastMessage(),
            abi.encodePacked(
                bytes32(uint256(uint160(receiver))),
                uint64(3e6),
                bytes32(uint256(uint160(address(t)))),
                abi.encode(uint256(1), uint256(1), uint256(3e18))
            )
        );
        assertEq(t.confirmedBurn(), 0, "source-chain bridge debit is not a confirmed final burn");
    }

    function test_actualBaseBurnDecreasesCallerAndSupplyOnly() public {
        vm.chainId(8453);
        vm.etch(BASE_IMD, BaseIMDRuntime.code());
        vm.etch(BASE_ADAPTER, BaseAdapterRuntime.code());
        assertEq(BASE_IMD.codehash, 0x15021fda4613ae853a7e3199f62df75e6f547ca11d32df53c0b1616f4a80ef4f);
        assertEq(BASE_ADAPTER.codehash, 0x1ad0c62178c048836ae25bc3c56a69579ae1ac8498209281c36acd344063e4da);
        assertEq(IIMDOFT(BASE_ADAPTER).token(), BASE_IMD);
        assertTrue(IIMDOFT(BASE_ADAPTER).approvalRequired());
        assertEq(IIMDOFT(BASE_ADAPTER).decimalConversionRate(), 1e12);
        address endpoint = IIMDOFT(BASE_ADAPTER).endpoint();
        address queue = makeAddr("local queue fixture");
        BaseBurnReceiver receiver =
            new BaseBurnReceiver(endpoint, BASE_ADAPTER, queue, 30101, 30184, 300_000, MAX_BATCH);
        deal(BASE_IMD, address(receiver), 3e18, true);
        uint256 supply = IERC20(BASE_IMD).totalSupply();
        vm.prank(endpoint);
        receiver.lzCompose(
            BASE_ADAPTER,
            keccak256("guid"),
            abi.encodePacked(
                uint64(1),
                uint32(30101),
                uint256(3e18),
                bytes32(uint256(uint160(queue))),
                abi.encode(uint256(1), uint256(1), uint256(3e18))
            ),
            address(this),
            ""
        );
        assertEq(IERC20(BASE_IMD).totalSupply(), supply - 3e18);
        assertEq(IERC20(BASE_IMD).balanceOf(address(receiver)), 0);
        assertEq(receiver.totalBurned(), 3e18);
    }

    /// @notice Real Base token runtime: a blacklisted receiver can still burn(0), but readiness now refuses
    ///         because the token's own `isBlacklisted` view is consulted; lifting it restores readiness.
    function test_actualBaseBlacklistBlocksReadinessUntilLifted() public {
        vm.chainId(8453);
        vm.deal(address(this), 1 ether);
        vm.etch(BASE_IMD, BaseIMDRuntime.code());
        vm.etch(BASE_ADAPTER, BaseAdapterRuntime.code());
        address endpoint = IIMDOFT(BASE_ADAPTER).endpoint();
        vm.etch(endpoint, address(new MockEndpoint(30184)).code);
        vm.store(endpoint, bytes32(0), bytes32(uint256(30184)));
        MockEndpoint(endpoint).setFee(0.001 ether);
        vm.store(BASE_ADAPTER, bytes32(0), bytes32(uint256(uint160(OWNER))));
        vm.prank(OWNER);
        IPeerSetup(BASE_ADAPTER).setPeer(30101, bytes32(uint256(uint160(IMD))));
        address tokenOwner = makeAddr("base token owner fixture");
        vm.store(BASE_IMD, bytes32(uint256(5)), bytes32(uint256(uint160(tokenOwner))));
        assertEq(IOwnable(BASE_IMD).owner(), tokenOwner);
        address queue = makeAddr("local queue fixture");
        BaseBurnReceiver receiver =
            new BaseBurnReceiver(endpoint, BASE_ADAPTER, queue, 30101, 30184, 300_000, MAX_BATCH);
        assertFalse(IBaseIMDRestrictions(BASE_IMD).limitsInEffect());
        assertEq(receiver.maxCredit(), type(uint256).max);
        vm.prank(tokenOwner);
        IBlacklistAdmin(BASE_IMD).blacklist(address(receiver));
        assertTrue(IBaseIMDRestrictions(BASE_IMD).isBlacklisted(address(receiver)));
        vm.expectRevert(BaseBurnReceiver.CreditRestricted.selector);
        receiver.sendAcknowledgement{value: 0.001 ether}(0);
        vm.prank(tokenOwner);
        IBlacklistAdmin(BASE_IMD).unblacklist(address(receiver));
        receiver.sendAcknowledgement{value: 0.001 ether}(0);
        assertEq(
            MockEndpoint(endpoint).lastMessage(),
            abi.encode(uint8(1), uint256(0), bytes32(uint256(uint160(BASE_ADAPTER))), uint256(8453))
        );
        vm.prank(tokenOwner);
        IBlacklistAdmin(BASE_IMD).blacklist(BASE_ADAPTER);
        vm.expectRevert(BaseBurnReceiver.CreditRestricted.selector);
        receiver.sendAcknowledgement{value: 0.001 ether}(0);
    }

    // ---- Real Base token + adapter runtimes under the token's own transfer limits (local storage) ----

    struct BaseFixture {
        address endpoint;
        address tokenOwner;
        address queue;
        BaseBurnReceiver receiver;
    }

    /// @dev Slots observed on the live Base token: 0x0a maxWallet, 0x0b flags (byte0 limitsInEffect,
    ///      byte1 tradingActive), 5 owner. Live values at review time: limits on, trading on, maxWallet 3e42.
    function _baseFixture(uint256 flags, uint256 maxWallet) internal returns (BaseFixture memory f) {
        vm.chainId(8453);
        vm.deal(address(this), 1 ether);
        vm.etch(BASE_IMD, BaseIMDRuntime.code());
        vm.etch(BASE_ADAPTER, BaseAdapterRuntime.code());
        f.endpoint = IIMDOFT(BASE_ADAPTER).endpoint();
        vm.etch(f.endpoint, address(new MockEndpoint(30184)).code);
        vm.store(f.endpoint, bytes32(0), bytes32(uint256(30184)));
        MockEndpoint(f.endpoint).setFee(0.001 ether);
        vm.store(BASE_ADAPTER, bytes32(0), bytes32(uint256(uint160(OWNER))));
        vm.prank(OWNER);
        IPeerSetup(BASE_ADAPTER).setPeer(30101, bytes32(uint256(uint160(IMD))));
        f.tokenOwner = makeAddr("base token owner fixture");
        vm.store(BASE_IMD, bytes32(uint256(5)), bytes32(uint256(uint160(f.tokenOwner))));
        f.queue = makeAddr("local queue fixture");
        f.receiver = new BaseBurnReceiver(f.endpoint, BASE_ADAPTER, f.queue, 30101, 30184, 300_000, MAX_BATCH);
        deal(BASE_IMD, BASE_ADAPTER, 1_000e18, true); // adapter reserve for local credits
        vm.store(BASE_IMD, bytes32(uint256(0x0a)), bytes32(maxWallet));
        vm.store(BASE_IMD, bytes32(uint256(0x0b)), bytes32(flags));
        assertEq(IBaseIMDRestrictions(BASE_IMD).maxWallet(), maxWallet);
        assertEq(IBaseIMDRestrictions(BASE_IMD).limitsInEffect(), flags & 1 == 1);
        assertEq(IBaseIMDRestrictions(BASE_IMD).tradingActive(), flags & 0x0100 == 0x0100);
    }

    /// @dev The actual adapter lzReceive: OFTMsgCodec (to, amountSD, composeFrom, payload) from the peer.
    function _credit(BaseFixture memory f, uint256 batchId, uint256 amount, bytes32 guid) internal {
        vm.prank(f.endpoint);
        IAdapterReceive(BASE_ADAPTER)
            .lzReceive(
                Origin(30101, bytes32(uint256(uint160(IMD))), uint64(batchId)),
                guid,
                abi.encodePacked(
                    bytes32(uint256(uint160(address(f.receiver)))),
                    uint64(amount / 1e12),
                    bytes32(uint256(uint160(f.queue))),
                    abi.encode(uint256(1), batchId, amount)
                ),
                address(this),
                ""
            );
    }

    function _compose(BaseFixture memory f, bytes32 guid) internal {
        assertEq(MockEndpoint(f.endpoint).lastComposeTo(), address(f.receiver));
        assertEq(MockEndpoint(f.endpoint).lastComposeGuid(), guid);
        bytes memory message = MockEndpoint(f.endpoint).lastComposeMessage();
        vm.prank(f.endpoint);
        f.receiver.lzCompose(BASE_ADAPTER, guid, message, address(this), "");
    }

    /// @notice Reopened finding, case A: a donation that fills the max-wallet headroom before readiness used to
    ///         block READY forever. Readiness now burns it (real supply burn) and proceeds.
    function test_actualDonationFillingMaxWalletNoLongerBlocksReadiness() public {
        BaseFixture memory f = _baseFixture(0x0101, MAX_BATCH);
        address attacker = makeAddr("donor");
        deal(BASE_IMD, attacker, MAX_BATCH, true);
        vm.prank(attacker);
        IERC20(BASE_IMD).transfer(address(f.receiver), MAX_BATCH);
        assertEq(f.receiver.maxCredit(), 0);
        uint256 supply = IERC20(BASE_IMD).totalSupply();
        f.receiver.sendAcknowledgement{value: 0.001 ether}(0);
        assertEq(IERC20(BASE_IMD).balanceOf(address(f.receiver)), 0);
        assertEq(IERC20(BASE_IMD).totalSupply(), supply - MAX_BATCH);
        assertEq(f.receiver.surplusBurned(), MAX_BATCH);
        assertEq(f.receiver.totalBurned(), 0);
        assertEq(f.receiver.maxCredit(), MAX_BATCH);
        assertEq(
            MockEndpoint(f.endpoint).lastMessage(),
            abi.encode(uint8(1), uint256(0), bytes32(uint256(uint160(BASE_ADAPTER))), uint256(8453))
        );
    }

    /// @notice Reopened finding, case B: after readiness a donation makes the actual adapter credit revert
    ///         "Max wallet exceeded". Anyone can now burn the surplus and the same credit then lands and burns.
    function test_actualDonationBlockingCreditIsClearedByPermissionlessSurplusBurn() public {
        BaseFixture memory f = _baseFixture(0x0101, MAX_BATCH);
        f.receiver.sendAcknowledgement{value: 0.001 ether}(0);
        address attacker = makeAddr("donor");
        deal(BASE_IMD, attacker, MAX_BATCH, true);
        vm.prank(attacker);
        IERC20(BASE_IMD).transfer(address(f.receiver), MAX_BATCH);
        bytes32 guid = keccak256("batch 1");
        vm.expectRevert(bytes("Max wallet exceeded"));
        this.creditExternal(f, 1, 0.3e18, guid);
        uint256 supply = IERC20(BASE_IMD).totalSupply();
        vm.prank(makeAddr("any keeper"));
        assertEq(f.receiver.burnSurplus(), MAX_BATCH);
        assertEq(IERC20(BASE_IMD).totalSupply(), supply - MAX_BATCH);
        _credit(f, 1, 0.3e18, guid);
        assertEq(IERC20(BASE_IMD).balanceOf(address(f.receiver)), 0.3e18);
        _compose(f, guid);
        assertEq(f.receiver.totalBurned(), 0.3e18);
        assertEq(f.receiver.surplusBurned(), MAX_BATCH);
        assertEq(IERC20(BASE_IMD).balanceOf(address(f.receiver)), 0);
        assertEq(IERC20(BASE_IMD).totalSupply(), supply - MAX_BATCH - 0.3e18);
        // A whole maximum batch also lands, and a keeper burning it before the compose does not strand it.
        bytes32 guid2 = keccak256("batch 2");
        _credit(f, 2, MAX_BATCH, guid2);
        f.receiver.burnSurplus();
        _compose(f, guid2);
        assertEq(f.receiver.totalBurned(), 0.3e18 + MAX_BATCH);
        assertEq(f.receiver.surplusBurned(), MAX_BATCH);
        (bytes32 storedGuid, uint256 storedAmount) = f.receiver.burns(2);
        assertEq(storedGuid, guid2);
        assertEq(storedAmount, MAX_BATCH);
    }

    /// @notice Reopened finding: the receiver signals readiness only for the frozen maximum batch, and the
    ///         Ethereum queue cannot dispatch more than that, so a batch above the wallet limit is never created.
    function test_actualMaxWalletBelowFrozenMaximumBatchRefusesReadiness() public {
        BaseFixture memory f = _baseFixture(0x0101, MAX_BATCH - 1);
        assertEq(f.receiver.maxCredit(), MAX_BATCH - 1);
        vm.expectRevert(BaseBurnReceiver.CreditRestricted.selector);
        f.receiver.sendAcknowledgement{value: 0.001 ether}(0);
        vm.expectRevert(bytes("Max wallet exceeded"));
        this.creditExternal(f, 1, MAX_BATCH, keccak256("too large"));
        vm.store(BASE_IMD, bytes32(uint256(0x0a)), bytes32(MAX_BATCH));
        f.receiver.sendAcknowledgement{value: 0.001 ether}(0);
        _credit(f, 1, MAX_BATCH, keccak256("fits"));
        _compose(f, keccak256("fits"));
        assertEq(f.receiver.totalBurned(), MAX_BATCH);
    }

    /// @notice Reopened finding: limits on and trading off makes the actual adapter credit revert
    ///         "Trading is not active."; readiness is refused in exactly that state.
    function test_actualTradingInactiveRefusesReadinessAndMatchesTokenBehaviour() public {
        BaseFixture memory f = _baseFixture(0x01, MAX_BATCH);
        assertEq(f.receiver.maxCredit(), 0);
        vm.expectRevert(BaseBurnReceiver.CreditRestricted.selector);
        f.receiver.sendAcknowledgement{value: 0.001 ether}(0);
        vm.expectRevert(bytes("Trading is not active."));
        this.creditExternal(f, 1, 0.3e18, keccak256("inactive"));
        // The token lets fee-excluded parties transfer while trading is off; the view follows the token.
        vm.prank(f.tokenOwner);
        IFeeAdmin(BASE_IMD).excludeFromFees(address(f.receiver), true);
        assertEq(f.receiver.maxCredit(), MAX_BATCH);
        _credit(f, 1, 0.3e18, keccak256("excluded"));
        vm.prank(f.tokenOwner);
        IFeeAdmin(BASE_IMD).excludeFromFees(address(f.receiver), false);
        assertEq(f.receiver.maxCredit(), 0);
        vm.store(BASE_IMD, bytes32(uint256(0x0b)), bytes32(uint256(0x0101)));
        f.receiver.sendAcknowledgement{value: 0.001 ether}(0);
        _credit(f, 2, 0.3e18, keccak256("active"));
        _compose(f, keccak256("active"));
        assertEq(f.receiver.totalBurned(), 0.3e18);
    }

    function creditExternal(BaseFixture memory f, uint256 batchId, uint256 amount, bytes32 guid) external {
        _credit(f, batchId, amount, guid);
    }
}

interface IAdapterReceive {
    function lzReceive(Origin calldata, bytes32, bytes calldata, address, bytes calldata) external payable;
}

interface IFeeAdmin {
    function excludeFromFees(address account, bool excluded) external;
}

interface IOwnable {
    function owner() external view returns (address);
}

interface IBlacklistAdmin {
    function blacklist(address account) external;
    function unblacklist(address account) external;
}
