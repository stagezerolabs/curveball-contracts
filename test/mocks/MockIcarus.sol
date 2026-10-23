// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20, IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @dev Test double for the volatile-pool factory behavior Curveball relies on. Pools are CREATE2-deployed
///      with the same (token0, token1, stable) salt as the live integration, so their addresses are predictable.
contract MockIcarusFactory {
    uint256 public constant MAX_FEE = 300;
    uint256 public constant MAX_UNSTAKED_FEE = 5000;

    bool public isPaused;
    uint256 public volatileFee = 30;
    uint256 public unstakedFee = 1000;
    mapping(address => uint256) public customFee;
    mapping(address => uint256) public customUnstakedFee;
    mapping(address => mapping(address => mapping(bool => address))) private _getPool;

    error PoolAlreadyExists();
    error StableUnsupported();

    function setPauseState(bool state) external {
        isPaused = state;
    }

    function setFees(uint256 volatileFee_, uint256 unstakedFee_) external {
        require(volatileFee_ <= MAX_FEE && unstakedFee_ <= MAX_UNSTAKED_FEE);
        volatileFee = volatileFee_;
        unstakedFee = unstakedFee_;
    }

    function setCustomFees(address pool, uint256 fee, uint256 unstaked) external {
        customFee[pool] = fee;
        customUnstakedFee[pool] = unstaked;
    }

    function getPool(address tokenA, address tokenB, bool stable) external view returns (address) {
        return _getPool[tokenA][tokenB][stable];
    }

    function getFee(address pool, bool) public view returns (uint256) {
        uint256 fee = customFee[pool];
        return fee != 0 ? fee : volatileFee;
    }

    function getUnstakedFee(address pool) external view returns (uint256) {
        uint256 fee = customUnstakedFee[pool];
        return fee != 0 ? fee : unstakedFee;
    }

    function createPool(address tokenA, address tokenB, bool stable) external returns (address pool) {
        if (stable) revert StableUnsupported();
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        if (_getPool[token0][token1][stable] != address(0)) revert PoolAlreadyExists();
        pool = address(new MockIcarusPool{salt: keccak256(abi.encodePacked(token0, token1, stable))}(token0, token1));
        _getPool[token0][token1][stable] = pool;
        _getPool[token1][token0][stable] = pool;
    }
}

/// @dev Holds a pool's segregated fees, as the real PoolFees does, so skim can never take them.
contract MockPoolFees {
    using SafeERC20 for IERC20;

    address internal immutable pool;
    address internal immutable token0;
    address internal immutable token1;

    constructor(address token0_, address token1_) {
        pool = msg.sender;
        (token0, token1) = (token0_, token1_);
    }

    function claimFeesFor(address recipient, uint256 amount0, uint256 amount1) external {
        require(msg.sender == pool);
        if (amount0 > 0) IERC20(token0).safeTransfer(recipient, amount0);
        if (amount1 > 0) IERC20(token1).safeTransfer(recipient, amount1);
    }
}

/// @dev Test double for the volatile-pool behavior Curveball relies on: reserves, 30-minute observations,
///      first-mint MINIMUM_LIQUIDITY, skim/sync, fee-on-input swaps with an unstaked (gauge) share,
///      LP fee indexes and claimFees. Stable math, burn and flash hooks are omitted.
contract MockIcarusPool is ERC20 {
    using SafeERC20 for IERC20;

    struct Observation {
        uint256 timestamp;
        uint256 reserve0Cumulative;
        uint256 reserve1Cumulative;
    }

    uint256 internal constant MINIMUM_LIQUIDITY = 10 ** 3;
    uint256 internal constant BPS = 10_000;
    uint256 public constant periodSize = 1800;

    MockIcarusFactory public immutable factory;
    address public immutable token0;
    address public immutable token1;
    address public immutable poolFees;
    address public immutable gaugeFees;

    Observation[] public observations;
    uint256 public reserve0;
    uint256 public reserve1;
    uint256 public blockTimestampLast;
    uint256 public reserve0CumulativeLast;
    uint256 public reserve1CumulativeLast;
    uint256 public index0;
    uint256 public index1;
    mapping(address => uint256) public supplyIndex0;
    mapping(address => uint256) public supplyIndex1;
    mapping(address => uint256) public claimable0;
    mapping(address => uint256) public claimable1;

    error IsPaused();
    error InsufficientLiquidityMinted();
    error InsufficientOutputAmount();
    error InsufficientInputAmount();
    error InsufficientLiquidity();
    error K();

    constructor(address token0_, address token1_) ERC20("Volatile AMM", "vAMM") {
        factory = MockIcarusFactory(msg.sender);
        (token0, token1) = (token0_, token1_);
        poolFees = address(new MockPoolFees(token0_, token1_));
        gaugeFees = address(new MockPoolFees(token0_, token1_));
        // The real initialize reads both symbols and decimals; keep that dependency on the tokens.
        IERC20Metadata(token0_).symbol();
        IERC20Metadata(token1_).decimals();
        observations.push(Observation(block.timestamp, 0, 0));
    }

    function observationLength() external view returns (uint256) {
        return observations.length;
    }

    function getReserves() public view returns (uint256, uint256, uint256) {
        return (reserve0, reserve1, blockTimestampLast);
    }

    function claimFees() external returns (uint256 claimed0, uint256 claimed1) {
        _updateFor(msg.sender);
        claimed0 = claimable0[msg.sender];
        claimed1 = claimable1[msg.sender];
        if (claimed0 > 0 || claimed1 > 0) {
            claimable0[msg.sender] = 0;
            claimable1[msg.sender] = 0;
            MockPoolFees(poolFees).claimFeesFor(msg.sender, claimed0, claimed1);
        }
    }

    function mint(address to) external returns (uint256 liquidity) {
        (uint256 _reserve0, uint256 _reserve1) = (reserve0, reserve1);
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        uint256 amount0 = balance0 - _reserve0;
        uint256 amount1 = balance1 - _reserve1;
        uint256 supply = totalSupply();
        if (supply == 0) {
            liquidity = Math.sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY;
            _mint(address(1), MINIMUM_LIQUIDITY);
        } else {
            liquidity = Math.min(amount0 * supply / _reserve0, amount1 * supply / _reserve1);
        }
        if (liquidity == 0) revert InsufficientLiquidityMinted();
        _mint(to, liquidity);
        _update(balance0, balance1, _reserve0, _reserve1);
    }

    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata) external {
        if (factory.isPaused()) revert IsPaused();
        if (amount0Out == 0 && amount1Out == 0) revert InsufficientOutputAmount();
        (uint256 _reserve0, uint256 _reserve1) = (reserve0, reserve1);
        if (amount0Out >= _reserve0 || amount1Out >= _reserve1) revert InsufficientLiquidity();
        if (amount0Out > 0) IERC20(token0).safeTransfer(to, amount0Out);
        if (amount1Out > 0) IERC20(token1).safeTransfer(to, amount1Out);
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        uint256 amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
        uint256 amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;
        if (amount0In == 0 && amount1In == 0) revert InsufficientInputAmount();
        uint256 fee = factory.getFee(address(this), false);
        uint256 gaugeFee = factory.getUnstakedFee(address(this));
        if (amount0In > 0) _takeFee(token0, amount0In * fee / BPS, gaugeFee, true);
        if (amount1In > 0) _takeFee(token1, amount1In * fee / BPS, gaugeFee, false);
        balance0 = IERC20(token0).balanceOf(address(this));
        balance1 = IERC20(token1).balanceOf(address(this));
        if (balance0 * balance1 < _reserve0 * _reserve1) revert K();
        _update(balance0, balance1, _reserve0, _reserve1);
    }

    function skim(address to) external {
        IERC20(token0).safeTransfer(to, IERC20(token0).balanceOf(address(this)) - reserve0);
        IERC20(token1).safeTransfer(to, IERC20(token1).balanceOf(address(this)) - reserve1);
    }

    function sync() external {
        _update(IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)), reserve0, reserve1);
    }

    function getAmountOut(uint256 amountIn, address tokenIn) external view returns (uint256) {
        amountIn -= amountIn * factory.getFee(address(this), false) / BPS;
        return _getAmountOut(amountIn, tokenIn, reserve0, reserve1);
    }

    function quote(address tokenIn, uint256 amountIn, uint256 granularity) external view returns (uint256) {
        uint256 length = observations.length - 1;
        uint256 total;
        for (uint256 i = length - granularity; i < length; i++) {
            Observation memory a = observations[i];
            Observation memory b = observations[i + 1];
            uint256 elapsed = b.timestamp - a.timestamp;
            total += _getAmountOut(
                amountIn,
                tokenIn,
                (b.reserve0Cumulative - a.reserve0Cumulative) / elapsed,
                (b.reserve1Cumulative - a.reserve1Cumulative) / elapsed
            );
        }
        return total / granularity;
    }

    function _getAmountOut(uint256 amountIn, address tokenIn, uint256 _reserve0, uint256 _reserve1)
        internal
        view
        returns (uint256)
    {
        (uint256 reserveA, uint256 reserveB) = tokenIn == token0 ? (_reserve0, _reserve1) : (_reserve1, _reserve0);
        return amountIn * reserveB / (reserveA + amountIn);
    }

    function _takeFee(address token, uint256 fee, uint256 gaugeFeeBps, bool isToken0) internal {
        uint256 gaugeFee = fee * gaugeFeeBps / BPS;
        if (gaugeFee > 0) IERC20(token).safeTransfer(gaugeFees, gaugeFee);
        uint256 lpFee = fee - gaugeFee;
        if (lpFee == 0) return;
        IERC20(token).safeTransfer(poolFees, lpFee);
        uint256 ratio = lpFee * 1e18 / totalSupply();
        if (isToken0) index0 += ratio;
        else index1 += ratio;
    }

    function _update(uint256 balance0, uint256 balance1, uint256 _reserve0, uint256 _reserve1) internal {
        uint256 elapsed = block.timestamp - blockTimestampLast;
        if (elapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            reserve0CumulativeLast += _reserve0 * elapsed;
            reserve1CumulativeLast += _reserve1 * elapsed;
        }
        if (block.timestamp - observations[observations.length - 1].timestamp > periodSize) {
            observations.push(Observation(block.timestamp, reserve0CumulativeLast, reserve1CumulativeLast));
        }
        reserve0 = balance0;
        reserve1 = balance1;
        blockTimestampLast = block.timestamp;
    }

    function _updateFor(address account) internal {
        uint256 supplied = balanceOf(account);
        uint256 delta0 = index0 - supplyIndex0[account];
        uint256 delta1 = index1 - supplyIndex1[account];
        supplyIndex0[account] = index0;
        supplyIndex1[account] = index1;
        if (supplied > 0) {
            if (delta0 > 0) claimable0[account] += supplied * delta0 / 1e18;
            if (delta1 > 0) claimable1[account] += supplied * delta1 / 1e18;
        }
    }

    /// @dev LP transfers settle both sides' fee indexes first, as in the real pool.
    function _update(address from, address to, uint256 value) internal override {
        _updateFor(from);
        _updateFor(to);
        super._update(from, to, value);
    }
}
