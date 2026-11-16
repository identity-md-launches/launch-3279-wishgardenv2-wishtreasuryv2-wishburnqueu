// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {GardenTestBase} from "./helpers/GardenTestBase.sol";
import {LegacyWishGardenBurnSink as WishGardenBurnSink} from "./legacy-src/LegacyWishGardenBurnSink.sol";
import {LegacyWishGardenTreasury as WishGardenTreasury} from "./legacy-src/LegacyWishGardenTreasury.sol";
import {LegacyWishGarden as WishGarden} from "./legacy-src/LegacyWishGarden.sol";
import {GardenEconomy} from "../src/GardenEconomy.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @dev Local rehearsal only; the service, not this test contract, performs the real factory deployment.
contract LaunchFactoryRehearsal {
    function deploy(address owner, address operations, address founder)
        external
        returns (WishGardenBurnSink sink, WishGardenTreasury treasury, WishGarden garden)
    {
        sink = new WishGardenBurnSink();
        treasury = new WishGardenTreasury(owner, address(sink), operations, founder);
        garden = new WishGarden(owner, address(treasury));
    }
}

contract DeploymentAndDependenciesTest is GardenTestBase {
    function test_allConstructorsWorkOnEmptyChainAndKeepExplicitLaunchOwner() public {
        vm.etch(IMD, "");
        vm.etch(NFT, "");
        LaunchFactoryRehearsal factory = new LaunchFactoryRehearsal();
        (WishGardenBurnSink deployedSink, WishGardenTreasury deployedTreasury, WishGarden deployedGarden) =
            factory.deploy(OWNER, OWNER, OWNER);
        assertEq(deployedGarden.owner(), OWNER);
        assertEq(deployedTreasury.owner(), OWNER);
        assertEq(deployedTreasury.operationsRecipient(), OWNER);
        assertEq(deployedTreasury.founderRecipient(), OWNER);
        assertEq(deployedTreasury.burnSink(), address(deployedSink));
        assertEq(address(deployedGarden.treasury()), address(deployedTreasury));
        assertEq(
            deployedTreasury.garden(), address(0), "explicitly unconfigured, not a deployment placeholder"
        );
        assertFalse(deployedGarden.collectionConfirmed());
        assertTrue(deployedGarden.owner() != address(factory));
        assertTrue(deployedTreasury.owner() != address(factory));
    }

    function test_zeroOwnerAndZeroDependenciesAreRejected() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new WishGarden(address(0), address(treasury));
        vm.expectRevert(GardenEconomy.InvalidAddress.selector);
        new WishGarden(OWNER, address(0));
        vm.expectRevert(GardenEconomy.InvalidAddress.selector);
        new WishGardenTreasury(OWNER, address(0), operations, founder);
        vm.expectRevert(GardenEconomy.InvalidAddress.selector);
        new WishGardenTreasury(OWNER, address(sink), address(0), founder);
        vm.expectRevert(GardenEconomy.InvalidAddress.selector);
        new WishGardenTreasury(OWNER, address(sink), operations, address(0));
    }

    function test_verifiedIMDRuntimeHas18DecimalsAndNoPublicBurn() public {
        assertEq(IMD.codehash, 0x79a1ae149d27d4aae006d4dd75cb834222c9623799bbf34359428aaf66fec3bf);
        assertEq(IERC20Metadata(IMD).decimals(), 18);
        uint256 supply = token.totalSupply();
        vm.startPrank(alice);
        (bool burnSuccess,) = IMD.call(abi.encodeWithSignature("burn(uint256)", 1e18));
        (bool burnFromSuccess,) = IMD.call(abi.encodeWithSignature("burnFrom(address,uint256)", alice, 1e18));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1e18);
        vm.stopPrank();
        assertFalse(burnSuccess);
        assertFalse(burnFromSuccess);
        assertEq(token.totalSupply(), supply);
        _buy(alice, 10, 0);
        assertEq(token.totalSupply(), supply);
        assertEq(sink.lockedBalance(), 3e18);
        assertFalse(sink.SUPPLY_REDUCING());
        assertEq(treasury.totalSupplyBurned(), 0);
    }

    function test_applicationRuntimeSizeAndForbiddenReachableOpcodes() public view {
        address[3] memory applications = [address(sink), address(treasury), address(garden)];
        for (uint256 i; i < applications.length; ++i) {
            bytes memory code = applications[i].code;
            assertGt(code.length, 0);
            assertLe(code.length, 24_576);
            bool reachable = true;
            for (uint256 j; j < code.length; ++j) {
                uint8 op = uint8(code[j]);
                if (op == 0x5b) reachable = true;
                if (op >= 0x60 && op <= 0x7f) {
                    j += op - 0x5f;
                    continue;
                }
                if (reachable) assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff);
                if (op == 0x00 || op == 0x56 || op == 0xf3 || op == 0xfd || op == 0xfe || op == 0xff) {
                    reachable = false;
                }
            }
        }
    }
}
