// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Splits fees already transferred to the escrow and records the resulting claims.
interface ICurveFeeEscrow {
    /// @param fee Trading or pool fee in `asset`, split by the market's fee policy.
    /// @param tax Creator tax in `asset`, owed to the creator in full.
    function distribute(address token, address asset, uint256 fee, uint256 tax) external;
}

/// @notice Holds graduated LP permanently and forwards its trading fees to the escrow.
interface ICurveLpLocker {
    function register(address token, address pool) external;
}

/// @notice Pays a launch's reserve pro rata to its curve holders after graduation.
interface ICurveHolderReserve {
    function register(address token, uint256 amount) external;
}
