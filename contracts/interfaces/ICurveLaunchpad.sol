// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Launchpad views the fee escrow, LP locker and holder reserve rely on.
interface ICurveLaunchpad {
    /// @notice Receives the protocol share of every fee.
    function treasury() external view returns (address);

    /// @notice The LP locker allowed to distribute pool fees through the escrow.
    function locker() external view returns (address);

    /// @notice Tokens sold on every curve; the denominator for holder-reserve claims.
    function curveSupply() external view returns (uint256);

    /// @notice The fee split snapshotted when `token` launched.
    function feePolicy(address token)
        external
        view
        returns (address creator, uint16 creatorShareBps, uint16 buybackShareBps);

    /// @notice The graduated Icarus pool, or address(0) while `token` is still on its curve.
    function poolOf(address token) external view returns (address);

    /// @notice Curve tokens `account` bought and still holds; frozen at graduation.
    function held(address token, address account) external view returns (uint256);
}
