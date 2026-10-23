// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ICurveFeeEscrow, ICurveLpLocker} from "./interfaces/ICurveSingletons.sol";
import {IIcarusPool} from "./interfaces/IIcarus.sol";

/// @notice Holds every graduated pool's LP forever and forwards its trading fees to the fee escrow.
/// @dev There is no function that moves LP. Fees are attributed from the amounts `claimFees`
///      returns, never from balances, so a stray transfer can't be credited to any market.
contract CurveLpLocker is ICurveLpLocker {
    using SafeERC20 for IERC20;

    address public immutable launchpad;
    ICurveFeeEscrow public immutable escrow;

    mapping(address pool => address token) public tokenOf;

    event PoolRegistered(address indexed token, address indexed pool);
    event LpFeesClaimed(address indexed token, address indexed pool, uint256 tokenAmount, uint256 quoteAmount);

    error NotLaunchpad();
    error AlreadyRegistered();
    error UnregisteredPool();

    constructor(address launchpad_, address escrow_) {
        launchpad = launchpad_;
        escrow = ICurveFeeEscrow(escrow_);
    }

    /// @inheritdoc ICurveLpLocker
    function register(address token, address pool) external {
        if (msg.sender != launchpad) revert NotLaunchpad();
        if (tokenOf[pool] != address(0)) revert AlreadyRegistered();
        tokenOf[pool] = token;
        emit PoolRegistered(token, pool);
    }

    /// @notice Claims `pool`'s LP fees and hands both sides to the escrow for the market's split.
    function claim(address pool) external returns (uint256 tokenAmount, uint256 quoteAmount) {
        address token = tokenOf[pool];
        if (token == address(0)) revert UnregisteredPool();
        (uint256 claimed0, uint256 claimed1) = IIcarusPool(pool).claimFees();
        address token0 = IIcarusPool(pool).token0();
        address quote = token0 == token ? IIcarusPool(pool).token1() : token0;
        (tokenAmount, quoteAmount) = token0 == token ? (claimed0, claimed1) : (claimed1, claimed0);
        _forward(token, token, tokenAmount);
        _forward(token, quote, quoteAmount);
        emit LpFeesClaimed(token, pool, tokenAmount, quoteAmount);
    }

    function _forward(address token, address asset, uint256 amount) internal {
        if (amount == 0) return;
        IERC20(asset).safeTransfer(address(escrow), amount);
        escrow.distribute(token, asset, amount, 0);
    }
}
