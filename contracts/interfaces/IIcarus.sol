// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice The Icarus (Aerodrome-style) pool factory surface Curveball uses on RISE.
/// @dev Integration compatibility is exercised by the pinned-block fork tests.
interface IIcarusFactory {
    function isPaused() external view returns (bool);
    function getPool(address tokenA, address tokenB, bool stable) external view returns (address);
    function createPool(address tokenA, address tokenB, bool stable) external returns (address pool);
    function getFee(address pool, bool stable) external view returns (uint256);
    function getUnstakedFee(address pool) external view returns (uint256);
}

/// @notice The Icarus pool surface Curveball uses on RISE.
/// @dev Only `swap` is expected to check the factory pause; fork tests exercise that assumption.
interface IIcarusPool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function getReserves() external view returns (uint256 reserve0, uint256 reserve1, uint256 blockTimestampLast);
    function mint(address to) external returns (uint256 liquidity);
    function skim(address to) external;
    function sync() external;
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function claimFees() external returns (uint256 claimed0, uint256 claimed1);
    /// @notice Output after the pool fee at current reserves.
    function getAmountOut(uint256 amountIn, address tokenIn) external view returns (uint256);
    /// @notice Fee-free output averaged over the last `granularity` 30-minute observation windows.
    /// @dev Panics (underflow) unless `observationLength() > granularity`.
    function quote(address tokenIn, uint256 amountIn, uint256 granularity) external view returns (uint256);
    function observationLength() external view returns (uint256);
}
