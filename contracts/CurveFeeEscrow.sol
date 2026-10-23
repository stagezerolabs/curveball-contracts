// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {CurveToken} from "./CurveToken.sol";
import {ICurveLaunchpad} from "./interfaces/ICurveLaunchpad.sol";
import {ICurveFeeEscrow} from "./interfaces/ICurveSingletons.sol";
import {IIcarusFactory, IIcarusPool} from "./interfaces/IIcarus.sol";
import {CurveMath} from "./libraries/CurveMath.sol";

/// @notice The one fee split. Holds creator and treasury claims and each market's buyback balance,
///         which after graduation buys the token from its Icarus pool and burns it.
/// @dev Every credit must be backed by a balance the caller already transferred in. `totalOwed`
///      tracks all liabilities per asset, so `rescue` can only take the surplus.
contract CurveFeeEscrow is ICurveFeeEscrow, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 internal constant BPS = 10_000;
    uint256 public constant BUYBACK_INTERVAL = 1 hours;
    uint256 public constant BUYBACK_CHUNK_BPS = 2_500;
    uint256 public constant BUYBACK_SLIPPAGE_BPS = 100;
    /// @dev Keeps each buyback's own price move well inside the band once the TWAP half-absorbs it.
    uint256 public constant BUYBACK_MAX_IMPACT_BPS = 25;
    uint256 internal constant TWAP_WINDOWS = 2;

    enum SkipReason {
        FewObservations,
        QuoteFailed,
        PoolPaused,
        Slippage
    }

    address public immutable launchpad;
    address public immutable quoteToken;
    IIcarusFactory public immutable icarusFactory;

    mapping(address account => mapping(address asset => uint256)) public claimable;
    /// @notice Quote reserved for buying back `token`.
    mapping(address token => uint256) public buybackBalance;
    mapping(address token => uint256) public lastBuyback;
    mapping(address asset => uint256) public totalOwed;

    event FeeAccrued(
        address indexed token,
        address indexed asset,
        uint256 creatorAmount,
        uint256 buybackAmount,
        uint256 protocolAmount
    );
    event FeeClaimed(address indexed account, address indexed asset, uint256 amount);
    event BuybackBurned(address indexed token, uint256 quoteSpent, uint256 tokensBurned);
    event BuybackSkipped(address indexed token, SkipReason reason);
    event Rescued(address indexed asset, address indexed to, uint256 amount);

    error Unauthorized();
    error InvalidAsset();
    error Unbacked();
    error NotGraduated();
    error TooSoon();
    error NothingToBuy();
    error ExceedsSurplus();
    error RenounceDisabled();

    constructor(address launchpad_, address quoteToken_, address icarusFactory_, address owner_) Ownable(owner_) {
        launchpad = launchpad_;
        quoteToken = quoteToken_;
        icarusFactory = IIcarusFactory(icarusFactory_);
    }

    /// @inheritdoc ICurveFeeEscrow
    /// @dev `asset` is the quote token (curve fees, pool fees) or `token` itself (pool fees). The
    ///      buyback share of a `token` fee is burned at once instead of being bought back later.
    function distribute(address token, address asset, uint256 fee, uint256 tax) external nonReentrant {
        if (msg.sender != launchpad && msg.sender != ICurveLaunchpad(launchpad).locker()) revert Unauthorized();
        if (asset != quoteToken && asset != token) revert InvalidAsset();
        uint256 amount = fee + tax;
        if (IERC20(asset).balanceOf(address(this)) < totalOwed[asset] + amount) revert Unbacked();

        (address creator, uint16 creatorShareBps, uint16 buybackShareBps) = ICurveLaunchpad(launchpad).feePolicy(token);
        (uint256 toCreator, uint256 toBuyback, uint256 toProtocol) =
            CurveMath.splitFee(fee, tax, creatorShareBps, buybackShareBps);
        claimable[creator][asset] += toCreator;
        claimable[ICurveLaunchpad(launchpad).treasury()][asset] += toProtocol;
        if (asset == token) {
            totalOwed[asset] += toCreator + toProtocol;
            if (toBuyback != 0) CurveToken(token).burn(toBuyback);
        } else {
            totalOwed[asset] += amount;
            buybackBalance[token] += toBuyback;
        }
        emit FeeAccrued(token, asset, toCreator, toBuyback, toProtocol);
    }

    /// @notice Pays the caller everything they are owed in `asset`; returns 0 when nothing is owed.
    function claim(address asset) external nonReentrant returns (uint256 amount) {
        amount = claimable[msg.sender][asset];
        if (amount == 0) return 0;
        claimable[msg.sender][asset] = 0;
        totalOwed[asset] -= amount;
        IERC20(asset).safeTransfer(msg.sender, amount);
        emit FeeClaimed(msg.sender, asset, amount);
    }

    /// @notice Spends a chunk of `token`'s buyback balance in its pool and burns the output.
    /// @dev Permissionless and at most once per `BUYBACK_INTERVAL`. A chunk is `BUYBACK_CHUNK_BPS` of the
    ///      balance (all of it once that rounds to 0), capped at `BUYBACK_MAX_IMPACT_BPS` of the pool's
    ///      quote reserve. The spot output must stay within `BUYBACK_SLIPPAGE_BPS` of the pool's
    ///      fee-adjusted TWAP. Every condition outside the caller's control skips without starting the
    ///      interval instead of reverting, so keepers never retry a revert in a loop.
    function buyback(address token) external nonReentrant returns (uint256 burned) {
        IIcarusPool pool = IIcarusPool(ICurveLaunchpad(launchpad).poolOf(token));
        if (address(pool) == address(0)) revert NotGraduated();
        uint256 last = lastBuyback[token];
        if (last != 0 && block.timestamp < last + BUYBACK_INTERVAL) revert TooSoon();
        uint256 balance = buybackBalance[token];
        if (balance == 0) revert NothingToBuy();

        // Brings an idle pool's observations up to date, so the TWAP absorbs the previous buyback.
        pool.sync();
        // quote() underflows unless there are more observations than windows. One extra window keeps
        // observation 0 out: on a pool created before graduation it averages in empty reserves.
        if (pool.observationLength() <= TWAP_WINDOWS + 1) return _skip(token, SkipReason.FewObservations);
        bool tokenIsToken0 = pool.token0() == token;
        uint256 amountIn = _chunk(pool, tokenIsToken0, balance);
        uint256 twapOut;
        try pool.quote(quoteToken, amountIn, TWAP_WINDOWS) returns (uint256 out) {
            twapOut = out;
        } catch {
            return _skip(token, SkipReason.QuoteFailed);
        }
        // Checked before any transfer: a swap reverting after the quote is in the pool would leave it skimmable.
        if (icarusFactory.isPaused()) return _skip(token, SkipReason.PoolPaused);

        uint256 poolFeeBps = icarusFactory.getFee(address(pool), false);
        uint256 minOut = twapOut * (BPS - poolFeeBps) / BPS * (BPS - BUYBACK_SLIPPAGE_BPS) / BPS;
        uint256 amountOut = pool.getAmountOut(amountIn, quoteToken);
        if (amountOut == 0 || amountOut < minOut) return _skip(token, SkipReason.Slippage);

        lastBuyback[token] = block.timestamp;
        buybackBalance[token] = balance - amountIn;
        totalOwed[quoteToken] -= amountIn;

        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(quoteToken).safeTransfer(address(pool), amountIn);
        (uint256 out0, uint256 out1) = tokenIsToken0 ? (amountOut, uint256(0)) : (uint256(0), amountOut);
        pool.swap(out0, out1, address(this), "");
        burned = IERC20(token).balanceOf(address(this)) - balanceBefore;
        CurveToken(token).burn(burned);
        emit BuybackBurned(token, amountIn, burned);
    }

    /// @notice Sends `asset` the escrow holds beyond its liabilities.
    function rescue(address asset, address to, uint256 amount) external onlyOwner nonReentrant {
        if (amount > IERC20(asset).balanceOf(address(this)) - totalOwed[asset]) revert ExceedsSurplus();
        IERC20(asset).safeTransfer(to, amount);
        emit Rescued(asset, to, amount);
    }

    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    function _chunk(IIcarusPool pool, bool tokenIsToken0, uint256 balance) internal view returns (uint256 amountIn) {
        amountIn = balance * BUYBACK_CHUNK_BPS / BPS;
        if (amountIn == 0) amountIn = balance;
        (uint256 reserve0, uint256 reserve1,) = pool.getReserves();
        uint256 maxIn = (tokenIsToken0 ? reserve1 : reserve0) * BUYBACK_MAX_IMPACT_BPS / BPS;
        if (amountIn > maxIn) amountIn = maxIn;
    }

    function _skip(address token, SkipReason reason) internal returns (uint256) {
        emit BuybackSkipped(token, reason);
        return 0;
    }
}
