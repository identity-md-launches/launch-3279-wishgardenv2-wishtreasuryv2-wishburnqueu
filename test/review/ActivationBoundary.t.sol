// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReplacementTestBase} from "../replacement/ReplacementTestBase.sol";
import {WishGardenTreasury} from "src/WishGardenTreasury.sol";
import {WishGarden} from "src/WishGarden.sol";
import {IMDBurnQueue} from "src/bridge/IMDBurnQueue.sol";
import {BaseBurnReceiver} from "../../base/src/BaseBurnReceiver.sol";
import {Origin} from "src/bridge/IMDBridgeInterfaces.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MockEndpoint} from "../replacement/Mocks.sol";

contract ActivationBoundaryReviewTest is ReplacementTestBase {
    function testFuzz_failedFreezeIsAtomicAndCorrectedConfigurationCanRetry(uint8 fieldSeed) public {
        WishGardenTreasury fresh = new WishGardenTreasury(OWNER);
        address ep = address(ethEndpoint);
        address remoteEp = address(baseEndpoint);
        address peer = address(adapter);
        uint128 receiveGas = 300_000;
        uint128 composeGas = 300_000;
        uint128 ackGas = 300_000;
        bytes32 evidence = EVIDENCE;
        uint8 field = fieldSeed % 14;
        if (field == 0) ep = alice;
        else if (field == 1) remoteEp = address(0);
        else if (field == 2) peer = address(0);
        else if (field == 3) peer = IMD;
        else if (field == 4) remoteEp = peer;
        else if (field == 5) evidence = bytes32(0);
        else if (field == 6) receiveGas = 99_999;
        else if (field == 7) receiveGas = 5_000_001;
        else if (field == 8) composeGas = 99_999;
        else if (field == 9) composeGas = 5_000_001;
        else if (field == 10) ackGas = 99_999;
        else if (field == 11) ackGas = 5_000_001;
        else if (field == 12) ep = address(new MockEndpoint(30102)); // not the token's endpoint / wrong eid
        else peer = bob; // not the token's configured Base peer
        vm.prank(OWNER);
        vm.expectRevert(IMDBurnQueue.InvalidBridgeConfiguration.selector);
        fresh.freezeBridge(ep, remoteEp, peer, receiveGas, composeGas, ackGas, SALT, evidence);
        assertFalse(fresh.bridgeFrozen());
        assertFalse(fresh.purchasesEnabled());
        assertEq(fresh.endpoint(), address(0));
        assertEq(fresh.baseEndpoint(), address(0));
        assertEq(fresh.baseOFT(), address(0));
        assertEq(fresh.baseReceiver(), address(0));
        assertEq(fresh.acknowledgementGas(), 0);
        assertEq(fresh.receiverSalt(), bytes32(0));
        assertEq(fresh.verificationEvidence(), bytes32(0));
        assertEq(fresh.configurationHash(), bytes32(0));
        assertEq(fresh.bridgeTokenCodeHash(), bytes32(0));
        assertEq(fresh.endpointCodeHash(), bytes32(0));
        assertEq(fresh.bridgeOptions().length, 0);
        vm.prank(OWNER);
        fresh.freezeBridge(
            address(ethEndpoint),
            address(baseEndpoint),
            address(adapter),
            100_000,
            5_000_000,
            100_000,
            SALT,
            EVIDENCE
        );
        assertTrue(fresh.bridgeFrozen());
        assertFalse(fresh.receiverReady());
        assertFalse(fresh.purchasesEnabled());
        assertEq(
            fresh.baseReceiver(),
            fresh.predictReceiver(address(baseEndpoint), address(adapter), 100_000, SALT)
        );
    }

    /// @notice The frozen destination is exactly the CREATE2 address of the compiled receiver bound to this
    ///         treasury; the prediction agrees with a real deployment through the deterministic deployer.
    function testFuzz_derivedReceiverMatchesDeterministicDeployment(bytes32 salt, uint128 gasSeed) public {
        uint128 ackGas = uint128(bound(gasSeed, 100_000, 5_000_000));
        WishGardenTreasury fresh = new WishGardenTreasury(OWNER);
        address predicted = fresh.predictReceiver(address(baseEndpoint), address(adapter), ackGas, salt);
        assertEq(_create2Receiver(address(fresh), ackGas, salt), predicted);
        BaseBurnReceiver deployed = BaseBurnReceiver(predicted);
        assertEq(deployed.ethereumQueue(), address(fresh));
        assertEq(deployed.acknowledgementGas(), ackGas);
        assertEq(fresh.receiverCreationCodeHash(), keccak256(type(BaseBurnReceiver).creationCode));
        // Any change of queue, gas, salt or endpoints moves the address.
        assertTrue(
            treasury.predictReceiver(address(baseEndpoint), address(adapter), ackGas, salt) != predicted
        );
        assertTrue(fresh.predictReceiver(address(baseEndpoint), address(adapter), ackGas, ~salt) != predicted);
        assertTrue(fresh.predictReceiver(address(ethEndpoint), address(adapter), ackGas, salt) != predicted);
        uint128 otherGas = ackGas == 5_000_000 ? ackGas - 1 : ackGas + 1;
        assertTrue(
            fresh.predictReceiver(address(baseEndpoint), address(adapter), otherGas, salt) != predicted
        );
        vm.prank(OWNER);
        fresh.freezeBridge(
            address(ethEndpoint), address(baseEndpoint), address(adapter), GAS, GAS, ackGas, salt, EVIDENCE
        );
        assertEq(fresh.baseReceiver(), predicted);
        assertTrue(fresh.allowInitializePath(Origin(30184, bytes32(uint256(uint160(predicted))), 1)));
    }

    /// @notice Receivers with identical code that are NOT at the derived address (plain CREATE, another
    ///         salt, another queue) can never signal readiness for this treasury.
    function testFuzz_nonDerivedReceiverCannotSignalReadiness(uint8 variantSeed) public {
        (WishGardenTreasury fresh,,) = _freshFrozen();
        BaseBurnReceiver impostor;
        uint8 variant = variantSeed % 3;
        if (variant == 0) {
            impostor = new BaseBurnReceiver(
                address(baseEndpoint), address(adapter), address(fresh), 30101, 30184, GAS
            );
        } else if (variant == 1) {
            impostor = _deployReceiver(address(fresh), keccak256("another salt"));
        } else {
            impostor = receiver; // bound to the main treasury
        }
        assertTrue(address(impostor) != fresh.baseReceiver());
        vm.chainId(8453);
        impostor.sendAcknowledgement{value: 0.001 ether}(0);
        bytes memory ready = baseEndpoint.lastMessage();
        vm.chainId(1);
        vm.prank(address(ethEndpoint));
        vm.expectRevert(IMDBurnQueue.UnauthenticatedMessage.selector);
        fresh.lzReceive(
            Origin(30184, bytes32(uint256(uint160(address(impostor)))), 1), keccak256(ready), ready, alice, ""
        );
        assertFalse(fresh.receiverReady());
        vm.prank(OWNER);
        vm.expectRevert(IMDBurnQueue.BridgeNotReady.selector);
        fresh.activatePurchases();
    }

    function testFuzz_readinessMustAuthenticateExactRouteBeforeActivation(uint8 attackSeed) public {
        (WishGardenTreasury fresh, WishGarden newGarden, BaseBurnReceiver remote) = _freshFrozen();
        Origin memory origin = Origin(30184, bytes32(uint256(uint160(address(remote)))), 1);
        assertTrue(fresh.allowInitializePath(origin));
        bytes memory message =
            abi.encode(uint8(1), uint256(0), bytes32(uint256(uint160(address(adapter)))), uint256(8453));
        address caller = address(ethEndpoint);
        uint8 attack = attackSeed % 8;
        if (attack == 0) {
            caller = OWNER;
        } else if (attack == 1) {
            origin.srcEid = 30101;
        } else if (attack == 2) {
            origin.sender = bytes32(uint256(uint160(address(remote))) | (uint256(1) << 200));
        } else if (attack == 3) {
            message =
                abi.encode(uint8(1), uint256(1), bytes32(uint256(uint160(address(adapter)))), uint256(8453));
        } else if (attack == 4) {
            message = abi.encode(uint8(1), uint256(0), bytes32(uint256(uint160(alice))), uint256(8453));
        } else if (attack == 5) {
            message =
                abi.encode(uint8(1), uint256(0), bytes32(uint256(uint160(address(adapter)))), uint256(1));
        } else if (attack == 6) {
            message = bytes.concat(message, hex"00");
        } else {
            message =
                abi.encode(uint8(2), uint256(0), bytes32(uint256(uint160(address(adapter)))), uint256(8453));
        }
        vm.prank(caller);
        vm.expectRevert();
        fresh.lzReceive(origin, keccak256(message), message, alice, "");
        assertFalse(fresh.receiverReady());
        vm.prank(OWNER);
        vm.expectRevert(IMDBurnQueue.BridgeNotReady.selector);
        fresh.activatePurchases();
        vm.prank(alice);
        token.approve(address(newGarden), 1e18);
        vm.prank(alice);
        vm.expectRevert(WishGarden.PurchasesDisabled.selector);
        newGarden.buyCandlesWithWish(1, 0, "too early", true);
        assertEq(token.allowance(alice, address(newGarden)), 1e18);
        assertEq(newGarden.totalCandles(), 0);
        // Generate the legitimate payload through the matching remote receiver, then deliver it.
        vm.chainId(8453);
        remote.sendAcknowledgement{value: 0.001 ether}(0);
        bytes memory ready = baseEndpoint.lastMessage();
        vm.chainId(1);
        vm.prank(address(ethEndpoint));
        fresh.lzReceive(
            Origin(30184, bytes32(uint256(uint160(address(remote)))), 2), keccak256(ready), ready, alice, ""
        );
        assertTrue(fresh.receiverReady());
        assertFalse(fresh.purchasesEnabled());
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        fresh.activatePurchases();
        vm.prank(OWNER);
        fresh.activatePurchases();
        vm.prank(alice);
        newGarden.buyCandlesWithWish(1, 0, "after activation", true);
        assertEq(fresh.pendingBurn(), 0.3e18);
        assertEq(fresh.totalPayments(), 1e18);
    }

    function test_ownerSuccessionCannotChangeFrozenDestinationOrGrantPendingOwnerPowers() public {
        (WishGardenTreasury fresh,,) = _freshFrozen();
        bytes32 config = fresh.configurationHash();
        address destination = fresh.baseReceiver();
        vm.prank(OWNER);
        fresh.transferOwnership(bob);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        fresh.freezeBridge(
            address(ethEndpoint),
            address(baseEndpoint),
            address(adapter),
            GAS,
            GAS,
            GAS,
            keccak256("x"),
            EVIDENCE
        );
        vm.prank(bob);
        fresh.acceptOwnership();
        vm.prank(bob);
        vm.expectRevert(IMDBurnQueue.ConfigurationFrozen.selector);
        fresh.freezeBridge(
            address(ethEndpoint),
            address(baseEndpoint),
            address(adapter),
            GAS,
            GAS,
            GAS,
            keccak256("x"),
            EVIDENCE
        );
        assertEq(fresh.configurationHash(), config);
        assertEq(fresh.baseReceiver(), destination);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, OWNER));
        fresh.activatePurchases();
    }

    function _freshFrozen()
        private
        returns (WishGardenTreasury fresh, WishGarden newGarden, BaseBurnReceiver remote)
    {
        fresh = new WishGardenTreasury(OWNER);
        newGarden = new WishGarden(OWNER, address(fresh));
        remote = _deployReceiver(address(fresh), SALT);
        assertFalse(fresh.allowInitializePath(Origin(30184, bytes32(uint256(uint160(address(remote)))), 1)));
        vm.startPrank(OWNER);
        fresh.bindGarden(address(newGarden));
        fresh.freezeBridge(
            address(ethEndpoint), address(baseEndpoint), address(adapter), GAS, GAS, GAS, SALT, EVIDENCE
        );
        vm.stopPrank();
        assertEq(fresh.baseReceiver(), address(remote));
    }

    function _create2Receiver(address queue, uint128 ackGas, bytes32 salt) private returns (address) {
        bytes memory initCode = bytes.concat(
            type(BaseBurnReceiver).creationCode,
            abi.encode(address(baseEndpoint), address(adapter), queue, uint32(30101), uint32(30184), ackGas)
        );
        (bool ok, bytes memory returned) = CREATE2_DEPLOYER.call(bytes.concat(salt, initCode));
        assertTrue(ok);
        return address(bytes20(returned));
    }
}
