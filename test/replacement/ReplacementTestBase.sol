// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {WishGarden} from "../../src/WishGarden.sol";
import {WishGardenTreasury} from "../../src/WishGardenTreasury.sol";
import {LegacyWishRegistry} from "../../src/LegacyWishRegistry.sol";
import {BaseBurnReceiver} from "../../base/src/BaseBurnReceiver.sol";
import {Origin} from "../../src/bridge/IMDBridgeInterfaces.sol";
import {MockEndpoint, MockIMDOFT, MockBaseIMD, MockBaseAdapter} from "./Mocks.sol";

abstract contract ReplacementTestBase is Test {
    address internal constant OWNER = 0x48E4E74fE1d0c14404cEB57B9fec5b21329C6ec9;
    address internal constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address internal constant BASE_IMD = 0xFF0C532FDB8Cd566Ae169C1CB157ff2Bdc83E105;
    /// @dev Arachnid deterministic deployment proxy: live runtime observed on chains 1 and 8453 (69 bytes).
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes internal constant CREATE2_DEPLOYER_CODE =
        hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";
    uint256 internal constant PREFIX = 1 << 255;
    bytes32 internal constant EVIDENCE = keccak256("TEST ONLY verified setup");
    bytes32 internal constant SALT = keccak256("TEST ONLY receiver salt");
    uint128 internal constant GAS = 300_000;
    WishGarden internal garden;
    WishGardenTreasury internal treasury;
    LegacyWishRegistry internal registry;
    BaseBurnReceiver internal receiver;
    MockIMDOFT internal token;
    MockBaseIMD internal baseToken;
    MockEndpoint internal ethEndpoint;
    MockEndpoint internal baseEndpoint;
    MockBaseAdapter internal adapter;
    address internal alice;
    address internal bob;

    function setUp() public virtual {
        vm.chainId(1);
        alice = makeAddr("replacement alice");
        bob = makeAddr("replacement bob");
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(address(this), 100 ether);
        ethEndpoint = new MockEndpoint(30101);
        baseEndpoint = new MockEndpoint(30184);
        vm.etch(IMD, address(new MockIMDOFT()).code);
        token = MockIMDOFT(IMD);
        vm.etch(BASE_IMD, address(new MockBaseIMD()).code);
        baseToken = MockBaseIMD(BASE_IMD);
        vm.etch(CREATE2_DEPLOYER, CREATE2_DEPLOYER_CODE);
        adapter = new MockBaseAdapter(address(baseEndpoint), BASE_IMD, IMD);
        token.setup(address(ethEndpoint), address(adapter));
        token.mint(alice, 1_000_000e18);
        token.mint(bob, 1_000_000e18);
        treasury = new WishGardenTreasury(OWNER);
        garden = new WishGarden(OWNER, address(treasury));
        registry = new LegacyWishRegistry();
        receiver = _deployReceiver(address(treasury), SALT);
        vm.prank(OWNER);
        treasury.bindGarden(address(garden));
        _freeze();
        _ready();
        vm.prank(OWNER);
        treasury.activatePurchases();
    }

    /// @dev Deploys the receiver exactly as the owner script does: through the deterministic deployer.
    function _deployReceiver(address queue, bytes32 salt) internal returns (BaseBurnReceiver deployed) {
        bytes memory initCode = bytes.concat(
            type(BaseBurnReceiver).creationCode,
            abi.encode(address(baseEndpoint), address(adapter), queue, uint32(30101), uint32(30184), GAS)
        );
        (bool ok, bytes memory returned) = CREATE2_DEPLOYER.call(bytes.concat(salt, initCode));
        require(ok && returned.length == 20, "deterministic deployment failed");
        deployed = BaseBurnReceiver(address(bytes20(returned)));
    }

    function _freeze() internal {
        vm.prank(OWNER);
        treasury.freezeBridge(
            address(ethEndpoint), address(baseEndpoint), address(adapter), GAS, GAS, GAS, SALT, EVIDENCE
        );
        assertEq(treasury.baseReceiver(), address(receiver), "derived receiver must match deployment");
    }

    function _ready() internal {
        vm.chainId(8453);
        receiver.sendAcknowledgement{value: 0.001 ether}(0);
        _deliverAck(baseEndpoint.lastMessage());
    }

    function _deliverAck(bytes memory payload) internal {
        _deliverFrom(address(receiver), payload);
    }

    function _deliverFrom(address sender, bytes memory payload) internal {
        vm.chainId(1);
        vm.prank(address(ethEndpoint));
        treasury.lzReceive(
            Origin(30184, bytes32(uint256(uint160(sender))), 1),
            keccak256(payload),
            payload,
            address(this),
            ""
        );
    }

    function _buy(uint256 quantity, uint8 style, string memory wish) internal returns (uint256) {
        vm.startPrank(alice);
        token.approve(address(garden), quantity * 1e18);
        uint256 id = garden.buyCandlesWithWish(quantity, style, wish, true);
        vm.stopPrank();
        return id;
    }

    function _dispatch(uint256 amount) internal returns (uint256 id, bytes32 guid) {
        id = treasury.dispatch{value: 0.001 ether}(amount, treasury.batchCount() + 1);
        (guid,,) = treasury.batches(id);
    }

    function _composeMessage(uint256 id, uint256 amount) internal view returns (bytes memory) {
        return abi.encodePacked(
            uint64(1),
            uint32(30101),
            amount,
            bytes32(uint256(uint160(address(treasury)))),
            abi.encode(uint256(1), id, amount)
        );
    }

    function _burn(uint256 id, bytes32 guid, uint256 amount) internal {
        vm.chainId(8453);
        baseToken.mint(address(receiver), amount); // mocked destination credit, NEVER represented as live bridging
        vm.prank(address(baseEndpoint));
        receiver.lzCompose(address(adapter), guid, _composeMessage(id, amount), address(this), "");
    }

    function _assertAccounting(uint256 count) internal view {
        assertEq(garden.paidCandles(), count);
        assertEq(garden.totalCandles(), count);
        assertEq(treasury.totalPayments(), count * 1e18);
        assertEq(treasury.totalBurnAllocated(), count * 0.3e18);
        assertEq(treasury.pendingBurn() + treasury.inTransitBurn() + treasury.confirmedBurn(), count * 0.3e18);
        assertEq(treasury.ecosystemBalance() + treasury.totalEcosystemWithdrawn(), count * 0.5e18);
        assertEq(treasury.operationsBalance() + treasury.totalOperationsWithdrawn(), count * 0.1e18);
        assertEq(treasury.founderBalance() + treasury.totalFounderWithdrawn(), count * 0.1e18);
        assertGe(token.balanceOf(address(treasury)), treasury.accountedBalance());
    }
}
