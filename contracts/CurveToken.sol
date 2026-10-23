// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "solady/tokens/ERC20.sol";

/// @notice Fixed-supply launch token, deployed as an EIP-1167 clone by the launchpad.
/// @dev Until graduation only mints and transfers to or from the launchpad can move tokens, so no
///      curve token can reach the graduation pool early. Solady derives the permit domain from
///      `address(this)` and `name()` on every call, which keeps permit correct for each clone.
contract CurveToken is ERC20 {
    uint256 private constant MAX_NAME_LENGTH = 64;
    uint256 private constant MAX_SYMBOL_LENGTH = 12;

    address public immutable launchpad;

    string private _name;
    string private _symbol;
    bool private _initialized;
    bool public unlocked;

    event Unlocked();

    error NotLaunchpad();
    error AlreadyInitialized();
    error InvalidMetadata();
    error Locked();

    modifier onlyLaunchpad() {
        if (msg.sender != launchpad) revert NotLaunchpad();
        _;
    }

    constructor() {
        launchpad = msg.sender;
        // Seal the implementation; clones start with fresh storage.
        _initialized = true;
    }

    /// @notice Sets metadata and mints the whole supply: the reserve to `reserveRecipient`, the rest to the launchpad.
    function initialize(
        string calldata name_,
        string calldata symbol_,
        uint256 supply,
        address reserveRecipient,
        uint256 reserveAmount
    ) external onlyLaunchpad {
        if (_initialized) revert AlreadyInitialized();
        uint256 nameLength = bytes(name_).length;
        uint256 symbolLength = bytes(symbol_).length;
        if (nameLength == 0 || nameLength > MAX_NAME_LENGTH || symbolLength == 0 || symbolLength > MAX_SYMBOL_LENGTH) {
            revert InvalidMetadata();
        }
        _initialized = true;
        _name = name_;
        _symbol = symbol_;
        _mint(launchpad, supply - reserveAmount);
        if (reserveAmount != 0) _mint(reserveRecipient, reserveAmount);
    }

    function unlock() external onlyLaunchpad {
        unlocked = true;
        emit Unlocked();
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    function _beforeTokenTransfer(address from, address to, uint256) internal view override {
        if (unlocked || from == address(0) || from == launchpad || to == launchpad) return;
        revert Locked();
    }

    function _givePermit2InfiniteAllowance() internal pure override returns (bool) {
        return false;
    }
}
