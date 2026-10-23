// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CurveFeeEscrow} from "../../contracts/CurveFeeEscrow.sol";
import {CurveHolderReserve} from "../../contracts/CurveHolderReserve.sol";
import {CurveLaunchpad} from "../../contracts/CurveLaunchpad.sol";
import {CurveLpLocker} from "../../contracts/CurveLpLocker.sol";
import {CurveMath} from "../../contracts/libraries/CurveMath.sol";
import {MockIcarusFactory, MockIcarusPool} from "../mocks/MockIcarus.sol";
import {MockWETH} from "../mocks/MockWETH.sol";

/// @dev Drives the whole system through every action a user, keeper, donor or admin can take.
///      The handler keeps its own ghost of each market's state machine, updated only from its own
///      successful calls, and derives every "must succeed / must revert" rule from that ghost rather
///      than from the contract. Broken rules, ghost divergence and non-monotonic quantities are
///      recorded as violations after each call.
contract Handler is Test {
    enum Action {
        Launch,
        Buy,
        Sell,
        Oversell,
        DonateWeth,
        DonatePool,
        DonateToken,
        Transfer,
        Warp,
        Graduate,
        Abort,
        Swap,
        LpClaim,
        FeeClaim,
        Buyback,
        ReserveClaim,
        Rescue,
        Admin,
        Pause,
        IcarusPause
    }

    struct Ghost {
        CurveLaunchpad.State state;
        uint40 readyAt;
        CurveLaunchpad.FeeDefaults fees;
        uint16 taxBps;
        uint256 initialVirtualQuote;
    }

    uint256 public constant ACTIONS = uint256(type(Action).max) + 1;
    uint256 internal constant S = 1_000_000 ether;
    uint256 internal constant C = 800_000 ether;
    uint256 internal constant MAX_MARKETS = 4;

    CurveLaunchpad public immutable launchpad;
    CurveFeeEscrow public immutable escrow;
    CurveLpLocker public immutable locker;
    CurveHolderReserve public immutable reserve;
    MockWETH public immutable weth;
    MockIcarusFactory public immutable icarus;
    address public immutable owner;
    address public immutable guardian;
    address public immutable treasury;
    /// @notice Where rescues send funds, so WETH conservation still sees them.
    address public immutable sink = makeAddr("sink");

    address[] public actors;
    address[] public tokens;
    /// @notice Every pool the handler or a graduation created.
    address[] public pools;
    mapping(address pool => bool) internal tracked;
    mapping(address token => Ghost) internal ghosts;

    /// @notice How often each action did its work instead of returning early.
    mapping(Action => uint256) public reached;
    uint256 public calls;
    uint256 public inlineAborts;
    uint256 public earlyAbortsRejected;
    uint256 public regraduations;
    uint256 public violations;
    string public lastViolation;

    /// @notice WETH the launchpad holds beyond `totalRealQuote`: donations and skims, less rescues.
    uint256 public launchpadSurplus;
    mapping(address token => uint256) public lastSupply;
    mapping(address pool => uint256) public lastLockerLp;
    mapping(address token => uint256) public reserveClaimed;
    /// @notice Tokens holders sent the launchpad after graduation, less what was rescued.
    mapping(address token => uint256) public donatedAfterGraduation;

    modifier step() {
        calls++;
        _;
        _checkAfterStep();
    }

    constructor(
        CurveLaunchpad launchpad_,
        CurveFeeEscrow escrow_,
        CurveLpLocker locker_,
        CurveHolderReserve reserve_,
        MockWETH weth_,
        MockIcarusFactory icarus_,
        address owner_,
        address guardian_
    ) {
        (launchpad, escrow, locker, reserve, weth, icarus) = (launchpad_, escrow_, locker_, reserve_, weth_, icarus_);
        (owner, guardian, treasury) = (owner_, guardian_, launchpad_.treasury());
        actors.push(makeAddr("actor0"));
        actors.push(makeAddr("actor1"));
        actors.push(makeAddr("actor2"));
        actors.push(makeAddr("actor3"));
        // Two markets from the start, so trading actions have something to act on in every run.
        launch(0, 0, 400, 0.1 ether);
        launch(1, 50, 0, 0);
    }

    // ---------------------------------------------------------------- curve

    function launch(uint256 actorSeed, uint16 taxBps, uint16 reserveBps, uint256 firstBuy) public step {
        if (tokens.length >= MAX_MARKETS) return;
        address actor = _actor(actorSeed);
        CurveLaunchpad.FeeDefaults memory fees = _feeDefaults();
        taxBps = uint16(bound(taxBps, 0, fees.taxCapBps));
        reserveBps = uint16(bound(reserveBps, 0, 400));
        firstBuy = firstBuy % 3 == 0 ? 0 : bound(firstBuy, 0.001 ether, 2 ether);
        _fund(actor, launchpad.launchFee() + firstBuy);
        uint256 vQ0 = launchpad.graduationTarget() * (S - C) / C;

        bool paused = launchpad.paused();
        vm.prank(actor);
        try launchpad.launch(_meta(), taxBps, reserveBps, firstBuy, 0) returns (address token, uint256) {
            if (paused) _violate("launch while paused");
            tokens.push(token);
            ghosts[token] = Ghost(CurveLaunchpad.State.Trading, 0, fees, taxBps, vQ0);
            lastSupply[token] = S;
            _afterBuy(token);
            reached[Action.Launch]++;
        } catch {
            if (!paused) _violate("launch reverted");
        }
    }

    function buy(uint256 actorSeed, uint256 marketSeed, uint256 spend) external step {
        address actor = _actor(actorSeed);
        address token = _token(marketSeed);
        spend = bound(spend, 0.0001 ether, 3 ether);
        _fund(actor, spend);
        bool mustRevert = !_open(token) || _soldOut(token) || launchpad.paused();
        bool mustSucceed = !mustRevert && _buyQuotable(token, spend);

        vm.prank(actor);
        try launchpad.buy(token, spend, 0, block.timestamp) {
            if (mustRevert) _violate("buy on a closed curve or while paused");
            _afterBuy(token);
            reached[Action.Buy]++;
        } catch {
            if (mustSucceed) _violate("open buy reverted");
        }
    }

    function sell(uint256 actorSeed, uint256 marketSeed, uint256 bps) external step {
        address token = _token(marketSeed);
        (address actor, uint256 sellable) = _seller(actorSeed, token);
        uint256 amount = sellable * bound(bps, 1, 10_000) / 10_000;
        if (amount == 0) return;

        Ghost storage g = ghosts[token];
        bool expiredReady = g.state == CurveLaunchpad.State.Ready && _expired(token);
        bool mustRevert = !_open(token) && !expiredReady;
        // Pause never matters here: whenever the curve can quote it, an open sell must go through.
        bool mustSucceed = !mustRevert && _sellQuotable(token, amount);

        vm.startPrank(actor);
        IERC20(token).approve(address(launchpad), amount);
        try launchpad.sell(token, amount, 0, block.timestamp) {
            if (mustRevert) _violate("sell on a graduated or unexpired ready market");
            if (expiredReady) {
                g.state = CurveLaunchpad.State.Aborted;
                inlineAborts++;
            }
            reached[Action.Sell]++;
        } catch {
            if (mustSucceed) _violate("open sell reverted");
        }
        vm.stopPrank();
    }

    /// @dev Selling one more than the ledger holds, from a holder or from someone who holds nothing.
    function oversell(uint256 actorSeed, uint256 marketSeed) external step {
        address actor = _actor(actorSeed);
        address token = _token(marketSeed);
        uint256 amount = launchpad.held(token, actor) + 1;
        vm.startPrank(actor);
        IERC20(token).approve(address(launchpad), amount);
        try launchpad.sell(token, amount, 0, block.timestamp) {
            _violate("sold more than held");
        } catch {
            reached[Action.Oversell]++;
        }
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- donations and transfers

    function donateWeth(uint256 amount, bool toEscrow) external step {
        amount = bound(amount, 1, 5 ether);
        if (toEscrow) {
            weth.mint(address(escrow), amount);
        } else {
            weth.mint(address(launchpad), amount);
            launchpadSurplus += amount;
        }
        reached[Action.DonateWeth]++;
    }

    /// @dev Pre-creating and funding the graduation pool, optionally synced: the griefing route.
    function donatePool(uint256 marketSeed, uint256 amount, bool sync) external step {
        MockIcarusPool pool = _poolFor(_token(marketSeed));
        weth.mint(address(pool), bound(amount, 1, 2 ether));
        if (sync) pool.sync();
        reached[Action.DonatePool]++;
    }

    /// @dev A holder sending curve tokens to the launchpad, the only place they can go before graduation.
    function donateToken(uint256 actorSeed, uint256 marketSeed, uint256 bps) external step {
        address token = _token(marketSeed);
        address actor = _holder(actorSeed, token);
        uint256 amount = IERC20(token).balanceOf(actor) * bound(bps, 1, 2_000) / 10_000;
        if (amount == 0) return;
        vm.prank(actor);
        IERC20(token).transfer(address(launchpad), amount);
        if (ghosts[token].state == CurveLaunchpad.State.Graduated) donatedAfterGraduation[token] += amount;
        reached[Action.DonateToken]++;
    }

    /// @dev A holder moving tokens to another actor or into the pool: locked until graduation.
    function transfer(uint256 actorSeed, uint256 marketSeed, bool toPool, uint256 bps) external step {
        address token = _token(marketSeed);
        address actor = _holder(actorSeed, token);
        uint256 amount = IERC20(token).balanceOf(actor) * bound(bps, 1, 5_000) / 10_000;
        if (amount == 0) return;
        address to = toPool ? address(_poolFor(token)) : _actor(actorSeed % actors.length + 1);
        bool graduated = ghosts[token].state == CurveLaunchpad.State.Graduated;

        vm.prank(actor);
        try IERC20(token).transfer(to, amount) {
            if (!graduated) _violate("curve token moved before graduation");
        } catch {
            if (graduated) _violate("graduated token transfer reverted");
        }
        reached[Action.Transfer]++;
    }

    // ---------------------------------------------------------------- time, graduation and abort

    function warp(uint256 seconds_) external step {
        vm.warp(block.timestamp + bound(seconds_, 1, 8 days));
        reached[Action.Warp]++;
    }

    /// @dev Sells the market out first when it can, so graduation is exercised in most runs.
    function graduate(uint256 actorSeed, uint256 marketSeed) external step {
        address token = _token(marketSeed);
        if (_open(token) && !_soldOut(token) && !launchpad.paused()) _sellOut(_actor(actorSeed), token);
        CurveLaunchpad.State state = ghosts[token].state;
        bool mustSucceed =
            state == CurveLaunchpad.State.Ready || (state == CurveLaunchpad.State.Aborted && _soldOut(token));

        CurveLaunchpad.Market memory m = launchpad.market(token);
        address existing = icarus.getPool(token, address(weth), false);
        (uint256 syncedQuote, uint256 unsyncedQuote) = existing == address(0) ? (0, 0) : _quoteSides(existing, token);

        try launchpad.graduate(token) returns (address pool) {
            if (!mustSucceed) _violate("graduated an unready market");
            ghosts[token].state = CurveLaunchpad.State.Graduated;
            if (state == CurveLaunchpad.State.Aborted) regraduations++;
            launchpadSurplus += unsyncedQuote;
            _track(pool);
            _checkOpeningPrice(token, pool, m, m.realQuote + syncedQuote);
            reached[Action.Graduate]++;
        } catch {
            if (mustSucceed) _violate("ready market failed to graduate");
        }
    }

    /// @dev Tries an abort before the timeout (which must fail), then sometimes waits it out and aborts.
    function abort(uint256 actorSeed, uint256 marketSeed, uint256 waitSeed) external step {
        address token = _token(marketSeed);
        Ghost storage g = ghosts[token];
        if (g.state == CurveLaunchpad.State.Trading && !launchpad.paused()) _sellOut(_actor(actorSeed), token);
        if (g.state == CurveLaunchpad.State.Ready && !_expired(token)) {
            uint256 deadline = uint256(g.readyAt) + launchpad.GRADUATION_TIMEOUT();
            if (waitSeed % 3 == 0) vm.warp(deadline - 1);
            try launchpad.abortGraduation(token) {
                _violate("aborted before the timeout");
            } catch {
                earlyAbortsRejected++;
                reached[Action.Abort]++;
            }
            if (waitSeed % 2 == 0) vm.warp(deadline);
        }
        bool mustSucceed = g.state == CurveLaunchpad.State.Ready && _expired(token);

        try launchpad.abortGraduation(token) {
            if (!mustSucceed) _violate("aborted a market that was not expired and ready");
            g.state = CurveLaunchpad.State.Aborted;
            reached[Action.Abort]++;
        } catch {
            if (mustSucceed) _violate("expired ready market failed to abort");
        }
    }

    // ---------------------------------------------------------------- after graduation

    function swap(uint256 actorSeed, uint256 marketSeed, bool buyToken, uint256 amount) external step {
        (address token, MockIcarusPool pool) = _graduated(marketSeed);
        if (address(pool) == address(0)) return;
        address actor = _holder(actorSeed, token);
        // Holders sell into the pool; when nobody holds any, someone buys.
        buyToken = buyToken || IERC20(token).balanceOf(actor) == 0;
        address tokenIn = buyToken ? address(weth) : token;
        if (buyToken) {
            amount = bound(amount, 0.0001 ether, 1 ether);
            weth.mint(actor, amount);
        } else {
            amount = IERC20(token).balanceOf(actor) * bound(amount, 1, 5_000) / 10_000;
        }
        if (amount == 0) return;
        uint256 out = pool.getAmountOut(amount, tokenIn);
        if (out == 0) return;

        vm.prank(actor);
        IERC20(tokenIn).transfer(address(pool), amount);
        bool outIsToken0 = pool.token0() != tokenIn;
        try pool.swap(outIsToken0 ? out : 0, outIsToken0 ? 0 : out, actor, "") {
            reached[Action.Swap]++;
        } catch {
            // Only Icarus's pause stops a correctly quoted swap; the input stays in the pool as a donation.
            if (!icarus.isPaused()) _violate("pool swap reverted");
        }
    }

    function lpClaim(uint256 marketSeed) external step {
        (, MockIcarusPool pool) = _graduated(marketSeed);
        if (address(pool) == address(0)) return;
        try locker.claim(address(pool)) {
            reached[Action.LpClaim]++;
        } catch {
            _violate("locker claim reverted");
        }
    }

    function feeClaim(uint256 accountSeed, uint256 marketSeed, bool quote) external step {
        address asset = quote ? address(weth) : _token(marketSeed);
        address account = _account(accountSeed);
        for (uint256 i = 1; i <= actors.length && escrow.claimable(account, asset) == 0; i++) {
            account = _account(accountSeed % (actors.length + 1) + i);
        }
        uint256 owed = escrow.claimable(account, asset);
        uint256 balanceBefore = IERC20(asset).balanceOf(account);
        vm.prank(account);
        try escrow.claim(asset) returns (uint256 paid) {
            if (paid != owed || IERC20(asset).balanceOf(account) != balanceBefore + owed) _violate("claim paid wrong");
            if (owed != 0) reached[Action.FeeClaim]++;
        } catch {
            _violate("fee claim reverted");
        }
    }

    function buyback(uint256 marketSeed) external step {
        (address token,) = _graduated(marketSeed);
        if (token == address(0)) return;
        uint256 last = escrow.lastBuyback(token);
        bool due =
            escrow.buybackBalance(token) != 0 && (last == 0 || block.timestamp >= last + escrow.BUYBACK_INTERVAL());
        try escrow.buyback(token) returns (uint256 burned) {
            if (!due) _violate("buyback ran early or with nothing to buy");
            if (burned != 0) reached[Action.Buyback]++;
        } catch {
            if (due) _violate("due buyback reverted instead of skipping");
        }
    }

    function reserveClaim(uint256 actorSeed, uint256 marketSeed) external step {
        address token = _token(marketSeed);
        address actor = _actor(actorSeed);
        for (uint256 i = 0; i < actors.length && reserve.claimable(token, actor) == 0; i++) {
            actor = _actor(actorSeed % actors.length + i + 1);
        }
        uint256 claimable = reserve.claimable(token, actor);
        bool graduated = ghosts[token].state == CurveLaunchpad.State.Graduated;
        if (!graduated && claimable != 0) _violate("reserve claimable before graduation");
        vm.prank(actor);
        try reserve.claim(token) returns (uint256 amount) {
            if (!graduated) _violate("reserve claimed before graduation");
            if (amount != claimable) _violate("reserve paid other than claimable");
            reserveClaimed[token] += amount;
            reached[Action.ReserveClaim]++;
        } catch {
            if (claimable != 0) _violate("claimable reserve reverted");
        }
    }

    // ---------------------------------------------------------------- admin

    /// @dev Each choice first tries one wei past what may leave, which must revert, then a random amount
    ///      within it. 0: launchpad WETH, which must succeed up to the surplus. 1: a curve token,
    ///      which must revert until graduation and then releases post-graduation donations. 2 and 3: escrow
    ///      WETH or token, which must succeed up to the escrow's surplus once the token is unlocked.
    function rescue(uint256 choice, uint256 marketSeed, uint256 amount) external step {
        choice %= 4;
        address token = _token(marketSeed);
        if (choice == 0) {
            _rescue(address(launchpad), address(weth), launchpadSurplus + 1, false);
            amount = bound(amount, 0, launchpadSurplus);
            if (_rescue(address(launchpad), address(weth), amount, true)) launchpadSurplus -= amount;
        } else if (choice == 1) {
            bool graduated = ghosts[token].state == CurveLaunchpad.State.Graduated;
            if (graduated) _rescue(address(launchpad), token, donatedAfterGraduation[token] + 1, false);
            amount = graduated ? bound(amount, 0, donatedAfterGraduation[token]) : bound(amount, 0, 1 ether);
            if (_rescue(address(launchpad), token, amount, graduated)) donatedAfterGraduation[token] -= amount;
        } else {
            address asset = choice == 2 ? address(weth) : token;
            uint256 surplus = IERC20(asset).balanceOf(address(escrow)) - escrow.totalOwed(asset);
            // A curve token can't leave the escrow at all while it is still locked.
            bool movable = asset == address(weth) || ghosts[token].state == CurveLaunchpad.State.Graduated;
            _rescue(address(escrow), asset, surplus + 1, false);
            _rescue(address(escrow), asset, bound(amount, 0, surplus), movable);
        }
        reached[Action.Rescue]++;
    }

    /// @dev New fee defaults or a new graduation target; existing markets must keep their snapshots.
    function admin(bool setFees, uint16 feeBps, uint16 creatorShareBps, uint16 buybackShareBps, uint256 value)
        external
        step
    {
        vm.startPrank(owner);
        if (setFees) {
            creatorShareBps = uint16(bound(creatorShareBps, 0, 10_000));
            CurveLaunchpad.FeeDefaults memory fees = CurveLaunchpad.FeeDefaults(
                uint16(bound(feeBps, 0, 200)),
                creatorShareBps,
                uint16(bound(buybackShareBps, 0, 10_000 - creatorShareBps)),
                uint16(bound(value, 0, 50))
            );
            try launchpad.setFeeDefaults(fees) {}
            catch {
                _violate("valid fee defaults rejected");
            }
        } else {
            // The starting virtual quote must divide exactly: target * (S - C) / C needs a multiple of 4.
            uint256 target = bound(value, 0.01 ether, 10 ether) / 4 * 4;
            try launchpad.setGraduationTarget(target) {}
            catch {
                _violate("valid graduation target rejected");
            }
        }
        vm.stopPrank();
        reached[Action.Admin]++;
    }

    function pause(bool on) external step {
        if (on) {
            vm.prank(guardian);
            launchpad.pause();
        } else {
            vm.prank(owner);
            launchpad.unpause();
        }
        reached[Action.Pause]++;
    }

    function icarusPause() external step {
        icarus.setPauseState(!icarus.isPaused());
        reached[Action.IcarusPause]++;
    }

    // ---------------------------------------------------------------- views for the invariants

    function tokenCount() external view returns (uint256) {
        return tokens.length;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function poolCount() external view returns (uint256) {
        return pools.length;
    }

    // ---------------------------------------------------------------- internal: ghosts and rules

    function _open(address token) internal view returns (bool) {
        CurveLaunchpad.State state = ghosts[token].state;
        return state == CurveLaunchpad.State.Trading || state == CurveLaunchpad.State.Aborted;
    }

    function _expired(address token) internal view returns (bool) {
        return block.timestamp >= uint256(ghosts[token].readyAt) + launchpad.GRADUATION_TIMEOUT();
    }

    /// @dev A sellout moves a Trading market to Ready; an Aborted one stays Aborted.
    function _afterBuy(address token) internal {
        Ghost storage g = ghosts[token];
        if (g.state == CurveLaunchpad.State.Trading && _soldOut(token)) {
            g.state = CurveLaunchpad.State.Ready;
            g.readyAt = uint40(block.timestamp);
        }
    }

    function _sellOut(address actor, address token) internal {
        _fund(actor, 100 ether);
        vm.prank(actor);
        try launchpad.buy(token, 100 ether, 0, block.timestamp) {
            _afterBuy(token);
        } catch {
            _violate("sellout buy reverted");
        }
    }

    /// @dev The pool must hold realQuote plus any synced donation, priced at the curve-end spot while
    ///      the burn buffer covers it, and otherwise clamped to every token outside the curve.
    function _checkOpeningPrice(address token, address pool, CurveLaunchpad.Market memory m, uint256 quoteInPool)
        internal
    {
        (uint256 r0, uint256 r1,) = MockIcarusPool(pool).getReserves();
        (uint256 poolTokens, uint256 quote) = MockIcarusPool(pool).token0() == token ? (r0, r1) : (r1, r0);
        if (quote != quoteInPool) _violate("pool quote is not realQuote plus the synced donation");
        uint256 cap = S - C - m.reserveTokens;
        uint256 ideal = quoteInPool * uint256(m.virtualToken) / uint256(m.virtualQuote);
        if (poolTokens != (ideal < cap ? ideal : cap)) _violate("pool opened off the curve-end price");
    }

    function _checkAfterStep() internal {
        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            Ghost storage g = ghosts[token];
            CurveLaunchpad.Market memory m = launchpad.market(token);
            if (m.state != g.state || m.readyAt != g.readyAt) _violate("market state diverged from the ghost");
            if (
                m.feeBps != g.fees.feeBps || m.creatorShareBps != g.fees.creatorShareBps
                    || m.buybackShareBps != g.fees.buybackShareBps || m.taxBps != g.taxBps
                    || m.initialVirtualQuote != g.initialVirtualQuote
            ) _violate("market snapshot changed");
            // The escrow splits by this view, so it must serve the snapshot too, not the live defaults.
            (address creator, uint16 creatorShareBps, uint16 buybackShareBps) = launchpad.feePolicy(token);
            if (
                creator != m.creator || creatorShareBps != g.fees.creatorShareBps
                    || buybackShareBps != g.fees.buybackShareBps
            ) _violate("fee policy is not the snapshot");

            // Invariant 9: token supply never increases after launch.
            uint256 supply = IERC20(token).totalSupply();
            if (supply > lastSupply[token]) _violate("token supply increased");
            lastSupply[token] = supply;

            // Invariant 7: locker LP never decreases.
            if (m.pool == address(0)) continue;
            uint256 lp = MockIcarusPool(m.pool).balanceOf(address(locker));
            if (lp < lastLockerLp[m.pool]) _violate("locker LP decreased");
            lastLockerLp[m.pool] = lp;
        }
    }

    function _rescue(address from, address asset, uint256 amount, bool mustSucceed) internal returns (bool ok) {
        vm.prank(owner);
        if (from == address(launchpad)) {
            try launchpad.rescue(asset, sink, amount) {
                ok = true;
            } catch {}
        } else {
            try escrow.rescue(asset, sink, amount) {
                ok = true;
            } catch {}
        }
        if (ok != mustSucceed) _violate(ok ? "rescue took owed funds" : "surplus rescue reverted");
    }

    function _violate(string memory why) internal {
        violations++;
        lastViolation = why;
    }

    // ---------------------------------------------------------------- internal: selection and helpers

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    /// @dev An actor or the treasury: everyone the escrow can owe.
    function _account(uint256 seed) internal view returns (address) {
        return seed % (actors.length + 1) == actors.length ? treasury : actors[seed % (actors.length + 1)];
    }

    function _token(uint256 seed) internal view returns (address) {
        return tokens[seed % tokens.length];
    }

    function _graduated(uint256 seed) internal view returns (address token, MockIcarusPool pool) {
        for (uint256 i = 0; i < tokens.length; i++) {
            address candidate = tokens[(seed % tokens.length + i) % tokens.length];
            if (ghosts[candidate].state == CurveLaunchpad.State.Graduated) {
                return (candidate, MockIcarusPool(launchpad.poolOf(candidate)));
            }
        }
    }

    /// @dev The first actor from `seed` on holding `token`, or the seed's actor if none does.
    function _holder(uint256 seed, address token) internal view returns (address) {
        for (uint256 i = 0; i < actors.length; i++) {
            address actor = _actor(seed % actors.length + i);
            if (IERC20(token).balanceOf(actor) != 0) return actor;
        }
        return _actor(seed);
    }

    /// @dev The first actor from `seed` on who can sell `token` to its curve, and how much.
    function _seller(uint256 seed, address token) internal view returns (address actor, uint256 amount) {
        for (uint256 i = 0; i < actors.length; i++) {
            actor = _actor(seed % actors.length + i);
            uint256 balance = IERC20(token).balanceOf(actor);
            uint256 held = launchpad.held(token, actor);
            amount = held < balance ? held : balance;
            if (amount != 0) return (actor, amount);
        }
    }

    /// @dev The token's pool, created (and tracked) if nobody has created it yet.
    function _poolFor(address token) internal returns (MockIcarusPool pool) {
        pool = MockIcarusPool(icarus.getPool(token, address(weth), false));
        if (address(pool) == address(0)) pool = MockIcarusPool(icarus.createPool(token, address(weth), false));
        _track(address(pool));
    }

    function _track(address pool) internal {
        if (tracked[pool]) return;
        tracked[pool] = true;
        pools.push(pool);
    }

    function _quoteSides(address pool, address token) internal view returns (uint256 synced, uint256 unsynced) {
        (uint256 r0, uint256 r1,) = MockIcarusPool(pool).getReserves();
        synced = MockIcarusPool(pool).token0() == token ? r1 : r0;
        unsynced = weth.balanceOf(pool) - synced;
    }

    function _soldOut(address token) internal view returns (bool) {
        return launchpad.market(token).virtualToken == S - C;
    }

    function _buyQuotable(address token, uint256 spend) internal view returns (bool) {
        try launchpad.previewBuy(token, spend) returns (CurveMath.Buy memory b) {
            return b.tokensOut != 0;
        } catch {
            return false;
        }
    }

    function _sellQuotable(address token, uint256 amount) internal view returns (bool) {
        try launchpad.previewSell(token, amount) {
            return true;
        } catch {
            return false;
        }
    }

    function _feeDefaults() internal view returns (CurveLaunchpad.FeeDefaults memory fees) {
        (fees.feeBps, fees.creatorShareBps, fees.buybackShareBps, fees.taxCapBps) = launchpad.feeDefaults();
    }

    function _meta() internal pure returns (CurveLaunchpad.Metadata memory) {
        return CurveLaunchpad.Metadata("Invariant", "INV", "ipfs://inv");
    }

    function _fund(address account, uint256 amount) internal {
        weth.mint(account, amount);
        vm.prank(account);
        weth.approve(address(launchpad), type(uint256).max);
    }
}
