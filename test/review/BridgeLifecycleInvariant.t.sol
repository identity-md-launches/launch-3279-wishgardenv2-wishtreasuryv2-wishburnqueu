// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ReplacementTestBase} from "../replacement/ReplacementTestBase.sol";
import {MockIMDOFT, MockBaseIMD, MockEndpoint} from "../replacement/Mocks.sol";
import {WishGarden} from "src/WishGarden.sol";
import {WishGardenTreasury} from "src/WishGardenTreasury.sol";
import {BaseBurnReceiver} from "../../base/src/BaseBurnReceiver.sol";
import {IMDBurnQueue} from "src/bridge/IMDBurnQueue.sol";
import {Origin} from "src/bridge/IMDBridgeInterfaces.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @dev Local transport model only: credit is explicitly minted by the fixture, not proven across chains.
/// Expectations derive from successful input actions. Production accounting getters never drive the model.
contract GardenLifecycleHandler is Test {
    WishGarden public immutable garden;
    WishGardenTreasury public immutable treasury;
    BaseBurnReceiver public immutable receiver;
    MockIMDOFT public immutable token;
    MockBaseIMD public immutable baseToken;
    address public currentOwner;
    address[3] public actors;
    uint256 public candles;
    uint256 public sent;
    uint256 public credited;
    uint256 public burned;
    uint256 public realBaseBurned; // every IMD the receiver really destroyed (batches and surplus)
    uint256 public surplus; // expected receiver.surplusBurned()
    uint256 public confirmed;
    uint256 public minted;
    uint256[3] public donated; // garden, treasury, Base receiver
    uint256[3] public withdrawn;
    uint256 public immutable initialSupply;

    struct Shipment {
        bytes32 guid;
        uint256 amount;
        uint256 credit;
        bool burned;
        bool ackSent;
        bool confirmed;
    }

    struct Purchase {
        uint256 first;
        uint256 count;
        address author;
        uint64 createdAt;
        uint8 style;
        string text;
    }
    Shipment[] internal shipments;
    Purchase[] internal purchases;

    constructor(WishGarden g, WishGardenTreasury t, BaseBurnReceiver r, address a, address b) {
        garden = g;
        treasury = t;
        receiver = r;
        token = MockIMDOFT(g.IMD());
        baseToken = MockBaseIMD(r.IMD());
        currentOwner = t.owner();
        actors = [a, b, address(this)];
        initialSupply = token.totalSupply();
    }

    function buy(uint8 quantitySeed, uint8 styleSeed, uint8 actorSeed, bool withWish) public {
        vm.chainId(1);
        uint256 quantity = uint256(quantitySeed) % 50 + 1;
        uint8 style = styleSeed % 7;
        address author = actors[actorSeed % 3];
        string memory text = withWish ? unicode"Public forever: é 🌱\x00" : "";
        token.mint(author, quantity * 1e18);
        minted += quantity * 1e18;
        vm.startPrank(author);
        token.approve(address(garden), quantity * 1e18);
        uint256 first = garden.buyCandlesWithWish(quantity, style, text, withWish);
        vm.stopPrank();
        assertEq(first, (1 << 255) + candles + 1);
        purchases.push(Purchase(first, quantity, author, uint64(block.timestamp), style, text));
        candles += quantity;
    }

    function donate(uint8 whereSeed, uint96 amountSeed) public {
        uint256 where = whereSeed % 3;
        uint256 amount = uint256(amountSeed) % 10e18 + 1;
        donated[where] += amount;
        if (where == 2) {
            vm.chainId(8453);
            baseToken.mint(address(receiver), amount);
        } else {
            vm.chainId(1);
            token.mint(address(this), amount);
            minted += amount;
            token.transfer(where == 0 ? address(garden) : address(treasury), amount);
        }
        vm.chainId(1);
    }

    function withdraw(uint8 bucketSeed, uint96 portion, bool unauthorized) public {
        vm.chainId(1);
        uint256 bucket = bucketSeed % 3;
        uint256 available = candles * (bucket == 0 ? 0.5e18 : 0.1e18) - withdrawn[bucket];
        if (available == 0) return;
        uint256 amount = uint256(portion) % available + 1;
        address caller = currentOwner;
        if (unauthorized) {
            caller = currentOwner == actors[0] ? actors[1] : actors[0];
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        }
        vm.prank(caller);
        if (bucket == 0) treasury.withdrawEcosystem(address(this), amount);
        else if (bucket == 1) treasury.withdrawOperations(address(this), amount);
        else treasury.withdrawFounder(address(this), amount);
        if (!unauthorized) withdrawn[bucket] += amount;
    }

    function transferOwner(uint8 actorSeed) public {
        vm.chainId(1);
        address successor = actors[actorSeed % 3];
        if (successor == currentOwner) return;
        vm.prank(currentOwner);
        treasury.transferOwnership(successor);
        assertEq(treasury.owner(), currentOwner, "nomination must not grant custody");
        vm.prank(successor);
        treasury.acceptOwnership();
        currentOwner = successor;
    }

    function dispatch(uint96 portion, uint8 failureSeed) public {
        vm.chainId(1);
        uint256 available = candles * 0.3e18 - sent;
        if (available < 1e12) return;
        uint256 request = uint256(portion) % (available - 1e12 + 1) + 1e12;
        // Every caller is bounded by the frozen maximum batch (fixture: 30 IMD).
        uint256 capped = request > treasury.maxBatch() ? treasury.maxBatch() : request;
        uint256 rounded = capped / 1e12 * 1e12;
        uint256 id = shipments.length + 1;
        uint8 mode = failureSeed % 4;
        if (mode == 3) mode = 4;
        if (rounded < 0.3e18 && rounded != available) {
            // A partial split below one candle's share is refused; nothing changes.
            vm.expectRevert(IMDBurnQueue.InvalidBatch.selector);
            treasury.dispatch{value: 0.001 ether}(request, id);
            return;
        }
        token.setSendMode(mode);
        if (mode != 0) vm.expectRevert();
        treasury.dispatch{value: 0.001 ether}(request, id);
        token.setSendMode(0);
        if (mode != 0) return;
        (bytes32 guid, uint256 amount, bool isConfirmed) = treasury.batches(id);
        assertEq(amount, rounded);
        assertFalse(isConfirmed);
        assertTrue(guid != bytes32(0));
        shipments.push(Shipment(guid, rounded, 0, false, false, false));
        sent += rounded;
    }

    /// @dev Credit and compose are distinct actions; random sequences retain real nonzero Base custody.
    function credit(uint256 seed, uint96 portion, bool finish) public {
        if (shipments.length == 0) return;
        Shipment storage s = shipments[seed % shipments.length];
        uint256 remaining = s.amount - s.credit;
        if (remaining == 0) return;
        uint256 amount = finish ? remaining : uint256(portion) % remaining + 1;
        vm.chainId(8453);
        baseToken.mint(address(receiver), amount);
        s.credit += amount;
        credited += amount;
        vm.chainId(1);
    }

    function compose(uint256 seed, uint8 failureSeed) public {
        if (shipments.length == 0) return;
        uint256 i = seed % shipments.length;
        Shipment storage s = shipments[i];
        // A legitimate endpoint queues this payload only after its corresponding credit succeeds.
        if (s.credit != s.amount) return;
        vm.chainId(8453);
        uint8 mode = failureSeed % 4;
        baseToken.setBurnMode(mode);
        address endpoint = receiver.endpoint();
        address adapter = receiver.baseOFT();
        // The compose burns what is held up to its credit; any part an earlier burnSurplus already
        // destroyed is drawn back out of the surplus counter, never burned twice. A failing token burn only
        // matters when something is left to burn (modes 2/3 are supply-neutral fakes of a positive burn).
        uint256 held = credited + donated[2] - realBaseBurned;
        uint256 fromBalance = held < s.amount ? held : s.amount;
        bool burnFails = mode == 1 || (mode != 0 && fromBalance != 0);
        if (s.burned) vm.expectRevert(BaseBurnReceiver.DuplicateBurn.selector);
        else if (burnFails) vm.expectRevert();
        vm.prank(endpoint);
        receiver.lzCompose(adapter, s.guid, _composeMessage(i), address(this), "");
        if (!s.burned && !burnFails) {
            s.burned = true;
            burned += s.amount;
            surplus -= s.amount - fromBalance;
            realBaseBurned += fromBalance;
        }
        baseToken.setBurnMode(0);
        vm.chainId(1);
    }

    /// @dev Anyone may burn everything the receiver holds: donations and credited-but-uncomposed batches.
    function burnSurplus(uint8 actorSeed) public {
        vm.chainId(8453);
        uint256 held = credited + donated[2] - realBaseBurned;
        vm.prank(actors[actorSeed % 3]);
        if (held == 0) {
            vm.expectRevert(BaseBurnReceiver.InexactBurn.selector);
            receiver.burnSurplus();
        } else {
            assertEq(receiver.burnSurplus(), held);
            surplus += held;
            realBaseBurned += held;
        }
        vm.chainId(1);
    }

    function sendAck(uint256 seed, bool fail) public {
        if (shipments.length == 0) return;
        uint256 i = seed % shipments.length;
        Shipment storage s = shipments[i];
        vm.chainId(8453);
        MockEndpoint endpoint = MockEndpoint(receiver.endpoint());
        endpoint.setFail(fail);
        if (!s.burned) vm.expectRevert(BaseBurnReceiver.UnknownBatch.selector);
        else if (fail) vm.expectRevert(bytes("mock failed ack"));
        receiver.sendAcknowledgement{value: 0.001 ether}(i + 1);
        if (s.burned && !fail) {
            assertEq(endpoint.lastMessage(), _ackMessage(i));
            s.ackSent = true;
        }
        endpoint.setFail(false);
        vm.chainId(1);
    }

    function deliverAck(uint256 seed) public {
        if (shipments.length == 0) return;
        uint256 i = seed % shipments.length;
        Shipment storage s = shipments[i];
        if (!s.ackSent) return;
        vm.chainId(1);
        vm.prank(treasury.endpoint());
        treasury.lzReceive(_origin(), keccak256(abi.encode(i)), _ackMessage(i), address(this), "");
        if (!s.confirmed) {
            s.confirmed = true;
            confirmed += s.amount;
        }
    }

    function rejectForgedReceipt(uint256 seed, uint8 attackSeed) public {
        if (shipments.length == 0) return;
        uint256 i = seed % shipments.length;
        Origin memory origin = _origin();
        address caller = treasury.endpoint();
        if (attackSeed % 3 == 0) caller = currentOwner;
        else if (attackSeed % 3 == 1) origin.srcEid = treasury.ETHEREUM_EID();
        else origin.sender = bytes32(uint256(uint160(currentOwner)));
        vm.chainId(1);
        vm.expectRevert(IMDBurnQueue.UnauthenticatedMessage.selector);
        vm.prank(caller);
        treasury.lzReceive(origin, shipments[i].guid, _ackMessage(i), address(this), "");
    }

    function elapse(uint32 secondsSeed) public {
        vm.warp(block.timestamp + uint256(secondsSeed) % 365 days);
    }

    function assertModel() external view {
        assertEq(treasury.owner(), currentOwner);
        assertEq(garden.totalCandles(), candles);
        assertEq(garden.paidCandles(), candles);
        assertEq(treasury.totalPayments(), candles * 1e18);
        assertEq(treasury.totalBurnAllocated(), candles * 0.3e18);
        assertEq(treasury.pendingBurn(), candles * 0.3e18 - sent);
        assertEq(treasury.inTransitBurn(), sent - confirmed);
        assertEq(treasury.confirmedBurn(), confirmed);
        assertEq(treasury.totalSupplyBurned(), confirmed);
        assertEq(treasury.ecosystemBalance(), candles * 0.5e18 - withdrawn[0]);
        assertEq(treasury.operationsBalance(), candles * 0.1e18 - withdrawn[1]);
        assertEq(treasury.founderBalance(), candles * 0.1e18 - withdrawn[2]);
        assertEq(treasury.totalEcosystemWithdrawn(), withdrawn[0]);
        assertEq(treasury.totalOperationsWithdrawn(), withdrawn[1]);
        assertEq(treasury.totalFounderWithdrawn(), withdrawn[2]);
        assertEq(token.balanceOf(address(garden)), donated[0]);
        assertEq(
            token.balanceOf(address(treasury)),
            candles * 1e18 + donated[1] - sent - withdrawn[0] - withdrawn[1] - withdrawn[2]
        );
        assertEq(treasury.unallocatedBalance(), donated[1]);
        assertEq(token.totalSupply(), initialSupply + minted - sent);
        assertEq(receiver.totalBurned(), burned);
        assertEq(receiver.surplusBurned(), surplus);
        assertEq(realBaseBurned, burned + surplus, "real Base burns = attributed batches + surplus");
        assertEq(baseToken.balanceOf(address(receiver)), credited + donated[2] - realBaseBurned);
        assertEq(baseToken.totalSupply(), credited + donated[2] - realBaseBurned);
        assertLe(surplus, donated[2] + credited - burned, "surplus never exceeds unattributed custody");
        assertLe(confirmed, burned);
        assertLe(burned, credited);
        assertLe(credited, sent);
        assertEq(token.allowance(address(treasury), address(token)), 0);
        assertEq(baseToken.allowance(address(receiver), receiver.baseOFT()), 0);
        assertEq(address(garden).balance + address(treasury).balance + address(receiver).balance, 0);
        assertEq(treasury.batchCount(), shipments.length);
        for (uint256 i; i < shipments.length; ++i) {
            Shipment storage s = shipments[i];
            (bytes32 guid, uint256 amount, bool isConfirmed) = treasury.batches(i + 1);
            assertEq(guid, s.guid);
            assertEq(amount, s.amount);
            assertEq(isConfirmed, s.confirmed);
            assertEq(receiver.consumedGuid(s.guid), s.burned);
            (bytes32 burnGuid, uint256 burnAmount) = receiver.burns(i + 1);
            assertEq(burnGuid, s.burned ? s.guid : bytes32(0));
            assertEq(burnAmount, s.burned ? s.amount : 0);
        }
        for (uint256 i; i < purchases.length; ++i) {
            Purchase storage p = purchases[i];
            _assertCandle(p, p.first);
            _assertCandle(p, p.first + p.count - 1);
        }
    }

    function _assertCandle(Purchase storage p, uint256 id) private view {
        WishGarden.Candle memory c = garden.getCandle(id);
        assertEq(c.purchaser, p.author);
        assertEq(c.createdAt, p.createdAt);
        assertEq(c.style, p.style);
        assertEq(c.position, id - 1);
        assertFalse(c.freeClaim);
        assertEq(c.nftTokenId, 0);
        (address author, string memory text) = garden.wishOf(id);
        assertEq(author, p.author);
        assertEq(text, p.text);
        assertEq(garden.wishBatch(id), bytes(p.text).length == 0 ? 0 : p.first);
    }

    function _composeMessage(uint256 i) private view returns (bytes memory) {
        return abi.encodePacked(
            uint64(i + 1),
            uint32(30101),
            shipments[i].amount,
            bytes32(uint256(uint160(address(treasury)))),
            abi.encode(uint256(1), i + 1, shipments[i].amount)
        );
    }

    function _ackMessage(uint256 i) private view returns (bytes memory) {
        return abi.encode(uint8(2), i + 1, shipments[i].guid, shipments[i].amount);
    }

    function _origin() private view returns (Origin memory) {
        return Origin(30184, bytes32(uint256(uint160(address(receiver)))), 1);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
contract BridgeLifecycleInvariantTest is ReplacementTestBase {
    GardenLifecycleHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new GardenLifecycleHandler(garden, treasury, receiver, alice, bob);
        vm.deal(address(handler), 1000 ether);
        // Start with paid records, retained pending funds, and credited-but-unburned Base custody.
        handler.buy(9, 6, 0, true);
        handler.dispatch(uint96(1e18), 0);
        handler.credit(0, 0, true);
        bytes4[] memory selectors = new bytes4[](12);
        selectors[11] = handler.burnSurplus.selector;
        selectors[0] = handler.buy.selector;
        selectors[1] = handler.donate.selector;
        selectors[2] = handler.withdraw.selector;
        selectors[3] = handler.transferOwner.selector;
        selectors[4] = handler.dispatch.selector;
        selectors[5] = handler.credit.selector;
        selectors[6] = handler.compose.selector;
        selectors[7] = handler.sendAck.selector;
        selectors[8] = handler.deliverAck.selector;
        selectors[9] = handler.rejectForgedReceipt.selector;
        selectors[10] = handler.elapse.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_custodySupplyRecordsAndReceiptsMatchIndependentActions() public view {
        handler.assertModel();
    }

    function test_partialCreditFailedBurnDelayedAckAndReplayConserveCustody() public {
        handler.donate(0, 123);
        handler.donate(1, 456);
        handler.donate(2, 789);
        handler.dispatch(uint96(0.7e18), 1); // failure must leave the next ID available
        handler.dispatch(uint96(0.7e18), 0);
        handler.credit(1, uint96(0.1e18), false);
        handler.assertModel();
        handler.credit(1, 0, true);
        handler.compose(1, 3); // supply-neutral counterfeit burn rolls back
        handler.assertModel();
        handler.burnSurplus(2); // front-runs nothing pending; burns the receiver donation
        handler.credit(0, 0, true);
        handler.burnSurplus(0); // burns batch 1's credit before its compose
        handler.compose(0, 0); // completes from surplus, exactly once
        handler.assertModel();
        handler.compose(1, 0);
        handler.sendAck(1, true);
        handler.sendAck(1, false);
        handler.elapse(30 days);
        handler.assertModel();
        handler.deliverAck(1);
        handler.deliverAck(1);
        handler.compose(1, 0); // replay must revert, never reburn
        handler.transferOwner(1);
        handler.withdraw(0, 1e18, true);
        handler.withdraw(1, 1e18, false);
        handler.assertModel();
    }
}
