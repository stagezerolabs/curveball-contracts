// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ICurveLaunchpad} from "./interfaces/ICurveLaunchpad.sol";
import {ICurveHolderReserve} from "./interfaces/ICurveSingletons.sol";

/// @notice Holds each launch's reserve and pays it pro rata to curve holders once the token graduates.
/// @dev The share is `reserve * held / curveSupply`, where `held` is the launchpad's ledger frozen at
///      graduation. Round-down dust and unclaimed or never-graduated reserves stay here by design.
contract CurveHolderReserve is ICurveHolderReserve {
    using SafeERC20 for IERC20;

    ICurveLaunchpad public immutable launchpad;

    mapping(address token => uint256) public reserveOf;
    mapping(address token => mapping(address account => bool)) public claimed;

    event ReserveRegistered(address indexed token, uint256 amount);
    event ReserveClaimed(address indexed token, address indexed account, uint256 amount);

    error NotLaunchpad();
    error InvalidAmount();
    error AlreadyRegistered();
    error Unbacked();
    error NotGraduated();
    error AlreadyClaimed();
    error NothingToClaim();

    constructor(address launchpad_) {
        launchpad = ICurveLaunchpad(launchpad_);
    }

    /// @inheritdoc ICurveHolderReserve
    function register(address token, uint256 amount) external {
        if (msg.sender != address(launchpad)) revert NotLaunchpad();
        if (amount == 0) revert InvalidAmount();
        if (reserveOf[token] != 0) revert AlreadyRegistered();
        if (IERC20(token).balanceOf(address(this)) < amount) revert Unbacked();
        reserveOf[token] = amount;
        emit ReserveRegistered(token, amount);
    }

    /// @notice What `account` can claim now; 0 before graduation and after its claim.
    function claimable(address token, address account) public view returns (uint256) {
        if (claimed[token][account] || launchpad.poolOf(token) == address(0)) return 0;
        return reserveOf[token] * launchpad.held(token, account) / launchpad.curveSupply();
    }

    function claim(address token) external returns (uint256 amount) {
        if (launchpad.poolOf(token) == address(0)) revert NotGraduated();
        if (claimed[token][msg.sender]) revert AlreadyClaimed();
        amount = claimable(token, msg.sender);
        if (amount == 0) revert NothingToClaim();
        claimed[token][msg.sender] = true;
        IERC20(token).safeTransfer(msg.sender, amount);
        emit ReserveClaimed(token, msg.sender, amount);
    }
}
