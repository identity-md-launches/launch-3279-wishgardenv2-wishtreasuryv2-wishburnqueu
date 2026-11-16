// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {GardenEconomy} from "../../src/GardenEconomy.sol";
import {LegacyWishGarden as WishGarden} from "../legacy-src/LegacyWishGarden.sol";
import {LegacyWishGardenTreasury as WishGardenTreasury} from "../legacy-src/LegacyWishGardenTreasury.sol";
import {LegacyWishGardenBurnSink as WishGardenBurnSink} from "../legacy-src/LegacyWishGardenBurnSink.sol";
import {IMDRuntime} from "../fixtures/IMDRuntime.sol";
import {IdentityNFTRuntime} from "../fixtures/IdentityNFTRuntime.sol";

interface IIdentityNFT is IERC721 {
    function mint(uint256 id) external;
}

abstract contract GardenTestBase is Test {
    address internal constant OWNER = 0x48E4E74fE1d0c14404cEB57B9fec5b21329C6ec9;
    address internal constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address internal constant NFT = 0x0000eC93127BAA929E58E97dd0095A2BFb38ec1D;
    bytes32 internal constant EVIDENCE =
        keccak256("local test owner attestation; not a production attestation");
    IERC20 internal token = IERC20(IMD);
    IIdentityNFT internal nft = IIdentityNFT(NFT);
    WishGarden internal garden;
    WishGardenTreasury internal treasury;
    WishGardenBurnSink internal sink;
    address internal alice;
    address internal bob;
    address internal operations;
    address internal founder;

    function setUp() public virtual {
        vm.chainId(1);
        vm.warp(1_800_000_000);
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        operations = makeAddr("operations test beneficiary");
        founder = makeAddr("founder test beneficiary");
        // Actual verified runtimes, with independent local storage. No RPC or environment dependency.
        vm.etch(IMD, IMDRuntime.code());
        vm.etch(NFT, IdentityNFTRuntime.code());
        sink = new WishGardenBurnSink();
        treasury = new WishGardenTreasury(OWNER, address(sink), operations, founder);
        garden = new WishGarden(OWNER, address(treasury));
        vm.prank(OWNER);
        treasury.bindGarden(address(garden));
        deal(IMD, alice, 1_000_000e18, true);
        deal(IMD, bob, 1_000_000e18, true);
    }

    function _buy(address purchaser, uint256 quantity, uint8 style) internal returns (uint256 firstId) {
        vm.startPrank(purchaser);
        token.approve(address(garden), quantity * 1e18);
        firstId = garden.buyCandles(quantity, style);
        vm.stopPrank();
    }

    function _confirmCollection() internal {
        vm.prank(OWNER);
        garden.confirmOfficialCollection(EVIDENCE);
    }

    function _mintNFT(address recipient, uint256 id) internal {
        // The real collection permits one mint per wallet; transfer fixtures to the intended holder.
        address minter = address(uint160(100_000 + id));
        vm.startPrank(minter);
        nft.mint(id);
        nft.transferFrom(minter, recipient, id);
        vm.stopPrank();
    }

    function _assertAccounting(uint256 paid) internal view {
        assertEq(treasury.totalPayments(), paid * 1e18);
        assertEq(treasury.totalIMDLocked(), paid * 0.3e18);
        assertEq(token.balanceOf(address(sink)), paid * 0.3e18);
        assertEq(treasury.ecosystemBalance() + treasury.totalEcosystemWithdrawn(), paid * 0.5e18);
        assertEq(treasury.operationsBalance() + treasury.totalOperationsClaimed(), paid * 0.1e18);
        assertEq(treasury.founderBalance() + treasury.totalFounderClaimed(), paid * 0.1e18);
        assertEq(token.balanceOf(address(treasury)), treasury.accountedBalance());
        assertEq(token.balanceOf(address(garden)), 0);
        assertEq(treasury.totalSupplyBurned(), 0);
    }
}
