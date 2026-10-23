// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "solady/tokens/ERC20.sol";

/// @dev Plain 18-decimal quote token with an open mint for tests.
contract MockWETH is ERC20 {
    function name() public pure override returns (string memory) {
        return "Wrapped Ether";
    }

    function symbol() public pure override returns (string memory) {
        return "WETH";
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
