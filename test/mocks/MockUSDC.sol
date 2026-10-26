// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "solady/tokens/ERC20.sol";

/// @dev 6-decimal quote token used to prove deployment rejects non-18-decimal quote tokens.
contract MockUSDC is ERC20 {
    constructor() {
        _mint(msg.sender, 1_000_000e6);
    }

    function name() public pure override returns (string memory) {
        return "Mock USDC";
    }

    function symbol() public pure override returns (string memory) {
        return "mUSDC";
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}
