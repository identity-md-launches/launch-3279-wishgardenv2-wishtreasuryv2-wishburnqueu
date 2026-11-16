// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {GardenTestBase, IIdentityNFT} from "./helpers/GardenTestBase.sol";
import {LegacyWishGarden as WishGarden} from "./legacy-src/LegacyWishGarden.sol";
import {LegacyWishGardenTreasury as WishGardenTreasury} from "./legacy-src/LegacyWishGardenTreasury.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract GardenHandler is Test {
    WishGarden public immutable garden;
    WishGardenTreasury public immutable treasury;
    IERC20 public immutable token;
    IIdentityNFT public immutable nft;
    address public immutable alice;
    address public immutable bob;
    address public immutable sink;
    uint256 public paid;
    uint256 public free;
    uint256 public donatedGarden;
    uint256 public donatedTreasury;
    uint256 public donatedSink;
    bytes32 public firstRecordHash;

    constructor(WishGarden garden_, address alice_, address bob_) {
        garden = garden_;
        treasury = garden_.treasury();
        token = IERC20(garden_.IMD());
        nft = IIdentityNFT(garden_.OFFICIAL_COLLECTION());
        sink = treasury.burnSink();
        alice = alice_;
        bob = bob_;
    }

    function buy(uint8 who, uint8 quantitySeed, uint8 styleSeed) external {
        address purchaser = who % 2 == 0 ? alice : bob;
        uint256 quantity = uint256(quantitySeed) % 50 + 1;
        vm.startPrank(purchaser);
        token.approve(address(garden), quantity * 1e18);
        garden.buyCandles(quantity, styleSeed % 7);
        vm.stopPrank();
        paid += quantity;
        _rememberFirstRecord();
    }

    function claim(uint8 tokenSeed, uint8 styleSeed) external {
        uint256 id = tokenSeed % 32;
        if (garden.nftClaimedCandle(id) != 0) return;
        address currentOwner = nft.ownerOf(id);
        vm.prank(currentOwner);
        garden.claimFreeCandle(id, styleSeed % 7);
        ++free;
        _rememberFirstRecord();
    }

    function transferNFT(uint8 tokenSeed) external {
        uint256 id = tokenSeed % 32;
        address currentOwner = nft.ownerOf(id);
        uint256 previousClaim = garden.nftClaimedCandle(id);
        vm.prank(currentOwner);
        nft.transferFrom(currentOwner, currentOwner == alice ? bob : alice, id);
        assertEq(garden.nftClaimedCandle(id), previousClaim);
    }

    function withdraw(uint8 bucketSeed, uint96 amountSeed) external {
        uint8 bucket = bucketSeed % 3;
        uint256 available = bucket == 0
            ? treasury.ecosystemBalance()
            : bucket == 1 ? treasury.operationsBalance() : treasury.founderBalance();
        if (available == 0) return;
        uint256 amount = uint256(amountSeed) % available + 1;
        if (bucket == 0) {
            vm.prank(treasury.owner());
            treasury.withdrawEcosystem(alice, amount);
        } else if (bucket == 1) {
            vm.prank(treasury.operationsRecipient());
            treasury.claimOperations(amount);
        } else {
            vm.prank(treasury.founderRecipient());
            treasury.claimFounder(amount);
        }
    }

    function donate(uint8 destinationSeed, uint96 amountSeed) external {
        uint8 destination = destinationSeed % 3;
        uint256 amount = uint256(amountSeed) % 1e18 + 1;
        if (destination == 0) {
            donatedGarden += amount;
            vm.prank(alice);
            token.transfer(address(garden), amount);
        } else if (destination == 1) {
            donatedTreasury += amount;
            vm.prank(alice);
            token.transfer(address(treasury), amount);
        } else {
            donatedSink += amount;
            vm.prank(alice);
            token.transfer(sink, amount);
        }
    }

    function _rememberFirstRecord() private {
        if (firstRecordHash == bytes32(0)) firstRecordHash = keccak256(abi.encode(garden.getCandle(1)));
    }
}

contract WishGardenInvariantTest is GardenTestBase {
    GardenHandler internal handler;
    uint256 internal initialSupply;

    function setUp() public override {
        super.setUp();
        _confirmCollection();
        for (uint256 i; i < 32; ++i) {
            _mintNFT(i % 2 == 0 ? alice : bob, i);
        }
        handler = new GardenHandler(garden, alice, bob);
        initialSupply = token.totalSupply();
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = GardenHandler.buy.selector;
        selectors[1] = GardenHandler.claim.selector;
        selectors[2] = GardenHandler.transferNFT.selector;
        selectors[3] = GardenHandler.withdraw.selector;
        selectors[4] = GardenHandler.donate.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_exactAllocationSolvencyAndSupplyConservation() public view {
        uint256 paid = handler.paid();
        assertEq(treasury.totalPayments(), paid * 1e18);
        assertEq(treasury.totalIMDLocked(), paid * 0.3e18);
        assertEq(token.balanceOf(address(sink)), paid * 0.3e18 + handler.donatedSink());
        assertEq(treasury.ecosystemBalance() + treasury.totalEcosystemWithdrawn(), paid * 0.5e18);
        assertEq(treasury.operationsBalance() + treasury.totalOperationsClaimed(), paid * 0.1e18);
        assertEq(treasury.founderBalance() + treasury.totalFounderClaimed(), paid * 0.1e18);
        assertEq(token.balanceOf(address(treasury)), treasury.accountedBalance() + handler.donatedTreasury());
        assertEq(token.balanceOf(address(garden)), handler.donatedGarden());
        assertEq(treasury.unallocatedBalance(), handler.donatedTreasury());
        assertEq(token.totalSupply(), initialSupply);
        assertEq(treasury.totalSupplyBurned(), 0);
        uint256 held = token.balanceOf(alice) + token.balanceOf(bob) + token.balanceOf(operations)
            + token.balanceOf(founder) + token.balanceOf(address(garden)) + token.balanceOf(address(treasury))
            + token.balanceOf(address(sink));
        assertEq(held, initialSupply);
    }

    function invariant_persistentRecordsAndSingleLifetimeClaim() public view {
        assertEq(garden.paidCandles(), handler.paid());
        assertEq(garden.freeCandles(), handler.free());
        assertEq(garden.totalCandles(), handler.paid() + handler.free());
        assertEq(garden.candleCountOf(alice) + garden.candleCountOf(bob), garden.totalCandles());
        if (garden.totalCandles() != 0) {
            assertEq(keccak256(abi.encode(garden.getCandle(1))), handler.firstRecordHash());
            assertEq(garden.getCandle(garden.totalCandles()).position, garden.totalCandles() - 1);
        }
        uint256 consumed;
        for (uint256 id; id < 32; ++id) {
            uint256 candleId = garden.nftClaimedCandle(id);
            if (candleId == 0) continue;
            ++consumed;
            WishGarden.Candle memory candle = garden.getCandle(candleId);
            assertTrue(candle.freeClaim);
            assertEq(candle.nftTokenId, id);
            assertEq(candle.position, candleId - 1);
        }
        assertEq(consumed, handler.free());
    }
}
