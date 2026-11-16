// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Permanent custody of the 30% burn allocation. IMD totalSupply does NOT decrease.
/// @dev No owner, withdrawal, approval, arbitrary call, upgrade, or destruction path exists.
///      Ethereum IMD exposes no public supply-reducing burn. See docs/verification.md.
contract LegacyWishGardenBurnSink {
    address public constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    bool public constant SUPPLY_REDUCING = false;

    /// @notice Includes any direct donations as well as the garden's 30% allocations.
    function lockedBalance() external view returns (uint256) {
        return IERC20(IMD).balanceOf(address(this));
    }
}
