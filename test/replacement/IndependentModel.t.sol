// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {ReplacementTestBase} from "./ReplacementTestBase.sol";
import {WishGarden} from "../../src/WishGarden.sol";
import {WishGardenTreasury} from "../../src/WishGardenTreasury.sol";
import {BaseBurnReceiver} from "../../base/src/BaseBurnReceiver.sol";
import {MockIMDOFT, MockBaseIMD, MockEndpoint, MockBaseAdapter} from "./Mocks.sol";
import {Origin} from "../../src/bridge/IMDBridgeInterfaces.sol";

/// @notice Independently maintained integer model. Every amount derives from actions, not production ledger getters.
contract ReplacementModel is Test {
    WishGarden public garden;
    WishGardenTreasury public treasury;
    BaseBurnReceiver public receiver;
    MockIMDOFT public token;
    MockBaseIMD public baseToken;
    address public owner;
    address public ethEndpoint;
    address public baseEndpoint;
    address public adapter;
    uint256 public candles;
    uint256 public sent;
    uint256 public burned;
    uint256 public confirmed;
    uint256[3] public withdrawals;

    struct Batch {
        uint256 amount;
        bytes32 guid;
        bool burned;
        bool confirmed;
    }
    Batch[] public batches;

    constructor(WishGarden g, WishGardenTreasury t, BaseBurnReceiver r) {
        garden = g;
        treasury = t;
        receiver = r;
        token = MockIMDOFT(g.IMD());
        baseToken = MockBaseIMD(r.IMD());
        owner = t.owner();
        ethEndpoint = t.endpoint();
        baseEndpoint = r.endpoint();
        adapter = r.baseOFT();
    }

    function buy(uint8 q, uint8 style) external {
        vm.chainId(1);
        uint256 n = uint256(q) % 5 + 1;
        token.mint(address(this), n * 1e18);
        token.approve(address(garden), n * 1e18);
        garden.buyCandlesWithWish(n, style % 7, "model", true);
        candles += n;
    }

    function withdraw(uint8 seed, uint96 portion) external {
        vm.chainId(1);
        uint256 bucket = seed % 3;
        uint256 entitlement = candles * (bucket == 0 ? 0.5e18 : 0.1e18) - withdrawals[bucket];
        if (entitlement == 0) return;
        uint256 amount = uint256(portion) % entitlement + 1;
        withdrawals[bucket] += amount;
        vm.prank(owner);
        if (bucket == 0) treasury.withdrawEcosystem(address(this), amount);
        else if (bucket == 1) treasury.withdrawOperations(address(this), amount);
        else treasury.withdrawFounder(address(this), amount);
    }

    function dispatch(uint96 portion, bool fail) external {
        vm.chainId(1);
        uint256 available = candles * 0.3e18 - sent;
        if (available < 0.3e18) return;
        // Whole-candle multiples (the minimum batch), or an over-asking request that the queue clamps.
        uint256 amount = (uint256(portion) % (available / 0.3e18) + 1) * 0.3e18;
        uint256 requested = portion % 5 == 0 ? available + 1e18 : amount;
        uint256 expectedSent = requested > available ? available : requested;
        if (expectedSent > 30e18) expectedSent = 30e18; // independently stated frozen fixture cap
        if (fail) {
            token.setSendMode(1);
            vm.expectRevert();
            treasury.dispatch{value: 0.001 ether}(requested, batches.length + 1);
            token.setSendMode(0);
            return;
        }
        uint256 id = treasury.dispatch{value: 0.001 ether}(requested, batches.length + 1);
        require(id == batches.length + 1, "model batch id");
        (bytes32 guid, uint256 recorded,) = treasury.batches(id);
        require(recorded == expectedSent, "model clamp");
        batches.push(Batch(recorded, guid, false, false));
        sent += recorded;
    }

    function burnBatch(uint256 seed) external {
        if (batches.length == 0) return;
        uint256 i = seed % batches.length;
        Batch storage b = batches[i];
        if (b.burned) return;
        vm.chainId(8453);
        baseToken.mint(address(receiver), b.amount);
        bytes memory message = abi.encodePacked(
            uint64(i + 1),
            uint32(30101),
            b.amount,
            bytes32(uint256(uint160(address(treasury)))),
            abi.encode(uint256(1), i + 1, b.amount)
        );
        vm.prank(baseEndpoint);
        receiver.lzCompose(adapter, b.guid, message, address(this), "");
        b.burned = true;
        burned += b.amount;
        vm.chainId(1);
    }

    function acknowledge(uint256 seed) external {
        if (batches.length == 0) return;
        uint256 i = seed % batches.length;
        Batch storage b = batches[i];
        if (!b.burned) return;
        vm.chainId(8453);
        receiver.sendAcknowledgement{value: 0.001 ether}(i + 1);
        bytes memory message = MockEndpoint(baseEndpoint).lastMessage();
        vm.chainId(1);
        vm.prank(ethEndpoint);
        treasury.lzReceive(
            Origin(30184, bytes32(uint256(uint160(address(receiver)))), 1),
            keccak256(message),
            message,
            address(this),
            ""
        );
        if (!b.confirmed) {
            b.confirmed = true;
            confirmed += b.amount;
        }
    }
}

contract ReplacementModelTest is ReplacementTestBase {
    ReplacementModel internal model;

    function setUp() public override {
        super.setUp();
        model = new ReplacementModel(garden, treasury, receiver);
        vm.deal(address(model), 1000 ether);
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = model.buy.selector;
        selectors[1] = model.withdraw.selector;
        selectors[2] = model.dispatch.selector;
        selectors[3] = model.burnBatch.selector;
        selectors[4] = model.acknowledge.selector;
        targetSelector(FuzzSelector(address(model), selectors));
        targetContract(address(model));
    }

    function invariant_independentAllocationsCustodyAndCrossChainState() public view {
        uint256 n = model.candles();
        _assertAccounting(n);
        assertEq(treasury.pendingBurn(), n * 0.3e18 - model.sent());
        assertEq(treasury.inTransitBurn(), model.sent() - model.confirmed());
        assertEq(treasury.confirmedBurn(), model.confirmed());
        assertEq(receiver.totalBurned(), model.burned());
        assertLe(model.confirmed(), model.burned());
        assertLe(model.burned(), model.sent());
        assertEq(treasury.ecosystemBalance(), n * 0.5e18 - model.withdrawals(0));
        assertEq(treasury.operationsBalance(), n * 0.1e18 - model.withdrawals(1));
        assertEq(treasury.founderBalance(), n * 0.1e18 - model.withdrawals(2));
        assertEq(
            token.balanceOf(address(treasury)),
            n * 1e18 - model.sent() - model.withdrawals(0) - model.withdrawals(1) - model.withdrawals(2)
        );
        assertEq(baseToken.balanceOf(address(receiver)), 0);
    }
}
