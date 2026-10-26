// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Fixture} from "../Fixture.sol";
import {CurveFeeEscrow} from "../../contracts/CurveFeeEscrow.sol";
import {MockIcarusPool} from "../mocks/MockIcarus.sol";

/// @dev Regression suite for audit finding "TWAP is not reliable (CurveFeeEscrow)".
///
/// Pre-fix: a pool pre-created without minting and stacked with zeroed observations by the public
/// `sync()` made the first buyback's two-window TWAP query return 0, voiding the slippage band
/// (the first 25% chunk could be bought at a manipulated price; later buybacks degraded until real
/// observations displaced the zeros). Fix: the escrow stores the pool's observation count at
/// graduation and skips until both sampled windows were recorded over seeded reserves, and skips
/// on a zero TWAP as defense in depth.
contract FeeEscrowTwapPoison is Fixture {
    uint256 constant WINDOW = 1801; // 30-minute Icarus observation period + 1s

    address attacker = makeAddr("attacker");
    address token;
    MockIcarusPool pool;

    // ------------------------------------------------------------- helpers

    function _sellOutAndAccrueFees() internal returns (address t) {
        _fund(creator, LAUNCH_FEE + 0.2 ether);
        vm.prank(creator);
        (t,) = launchpad.launch(_meta(), 50, 0, 0.2 ether, 0);
        _sellOut(bob, t); // market Ready; 25% of buy fees already credited to the buyback balance
    }

    /// @dev The audit scenario: anyone pre-creates the empty pool (mints nothing) and calls the
    ///      public `sync()` over several windows, stacking cumulative prices of zero.
    function _preCreateAndPoison(address t) internal returns (MockIcarusPool) {
        MockIcarusPool p = MockIcarusPool(icarus.createPool(t, address(weth), false));
        assertEq(p.totalSupply(), 0, "created without minting");
        for (uint256 i = 0; i < 4; i++) {
            vm.warp(block.timestamp + WINDOW);
            p.sync(); // permissionless; pushes an observation even though reserves are zero
        }
        return p;
    }

    /// @dev The exact chunk the escrow will spend on the next buyback.
    function _nextChunk() internal view returns (uint256 amountIn) {
        uint256 balance = escrow.buybackBalance(token);
        amountIn = balance * 2_500 / 10_000;
        if (amountIn == 0) amountIn = balance;
        (uint256 r0, uint256 r1,) = pool.getReserves();
        uint256 quoteReserve = pool.token0() == token ? r1 : r0;
        uint256 maxIn = quoteReserve * 25 / 10_000;
        if (amountIn > maxIn) amountIn = maxIn;
    }

    function _frontRun(uint256 wethIn) internal {
        uint256 out = pool.getAmountOut(wethIn, address(weth));
        _fund(attacker, wethIn);
        vm.prank(attacker);
        IERC20(address(weth)).transfer(address(pool), wethIn);
        bool outIsToken0 = pool.token0() != address(weth);
        pool.swap(outIsToken0 ? out : 0, outIsToken0 ? 0 : out, attacker, "");
    }

    function _quoteReserve() internal view returns (uint256) {
        (uint256 r0, uint256 r1,) = pool.getReserves();
        return pool.token0() == token ? r1 : r0;
    }

    function _expectSkip(CurveFeeEscrow.SkipReason reason) internal {
        uint256 balance = escrow.buybackBalance(token);
        vm.expectEmit(address(escrow));
        emit CurveFeeEscrow.BuybackSkipped(token, reason);
        assertEq(escrow.buyback(token), 0);
        assertEq(escrow.buybackBalance(token), balance, "a skip must preserve the credit");
        assertEq(escrow.lastBuyback(token), 0, "a skip must not start the interval");
    }

    // ------------------------------------------------------------- fix regressions

    /// @dev The first buyback on a pre-created poisoned pool no longer executes: the two sampled
    ///      windows would be zeroed, so it skips, preserving credit and the interval.
    function test_fix_preCreatedPool_firstBuybackSkips() public {
        token = _sellOutAndAccrueFees();
        pool = _preCreateAndPoison(token);
        assertEq(launchpad.graduate(token), address(pool), "graduation reuses the empty pre-created pool");

        assertEq(escrow.seedObservations(token), 5, "the graduation count includes the stacked zeros");
        assertGt(pool.observationLength(), 3, "the old guard alone would pass");
        _expectSkip(CurveFeeEscrow.SkipReason.FewObservations);

        // It must keep skipping until BOTH sample windows are post-graduation. With the graduation
        // count at 5, the earliest sampled index (observationLength - 3) must reach 5, i.e. three
        // live pushes. The escrow's own hourly syncs provide one per attempt.
        vm.warp(block.timestamp + 1 hours);
        _expectSkip(CurveFeeEscrow.SkipReason.FewObservations);
        vm.warp(block.timestamp + 1 hours);
        _expectSkip(CurveFeeEscrow.SkipReason.FewObservations);

        // Third retry: two live windows now fill the sample, the TWAP is real, and the buyback
        // runs without any price manipulation room (a front-run would skip, see below).
        vm.warp(block.timestamp + 1 hours);
        pool.sync(); // same observation push the failing buyback attempts performed
        uint256 amountIn = _nextChunk();
        uint256 twap = pool.quote(address(weth), amountIn, 2);
        uint256 spot = pool.getAmountOut(amountIn, address(weth));
        assertApproxEqRel(twap, spot, 0.02e18, "the reference price is now genuine");
        assertGt(escrow.buyback(token), 0, "a mature sample lets the buyback run");
    }

    /// @dev The exploit path is dead: the same 2%-of-pool front-run the clean pool already rejects
    ///      is now also rejected on the pre-created poisoned pool (the band exists again).
    function test_fix_poisonedPool_rejectsSameFrontRun() public {
        token = _sellOutAndAccrueFees();
        pool = _preCreateAndPoison(token);
        launchpad.graduate(token);

        // Mature the sample: two skipped retries push one live observation each, then a third
        // push (an eventual retry) opens the gate — the next attempt prices against a genuine TWAP.
        for (uint256 i = 0; i < 2; i++) {
            vm.warp(block.timestamp + 1 hours);
            escrow.buyback(token); // skips; each sync pushes one live observation
        }
        vm.warp(block.timestamp + 1 hours);
        pool.sync();
        assertGt(pool.observationLength(), 3);
        _frontRun(_quoteReserve() * 2 / 100); // ~4% spot move, far outside the 1% band
        _expectSkip(CurveFeeEscrow.SkipReason.Slippage);
    }

    /// @dev Control: with a pool created and seeded by graduation (normal flow), the same gate does
    ///      not delay anything — the first buyback works as before, and the band still rejects a
    ///      >1% move.
    function test_control_cleanPool_rejectsSameFrontRun() public {
        token = _sellOutAndAccrueFees();
        launchpad.graduate(token); // pool created and seeded at graduation (normal flow)
        pool = MockIcarusPool(launchpad.poolOf(token));
        assertEq(escrow.seedObservations(token), 1);
        for (uint256 i = 0; i < 3; i++) {
            vm.warp(block.timestamp + WINDOW);
            pool.sync();
        }
        assertGt(pool.observationLength(), 3);

        _frontRun(_quoteReserve() * 2 / 100); // ~4% spot move
        _expectSkip(CurveFeeEscrow.SkipReason.Slippage);
    }

    /// @dev Pool mechanics documentation: with the zeros stacked pre-seed, quote() (the external
    ///      pool oracle, unchanged by the fix) is 0 then ~50% then full. This is exactly why the
    ///      gate above refuses the first two buybacks.
    function test_pool_quoteIsDegradedUntilLiveWindows() public {
        token = _sellOutAndAccrueFees();
        pool = _preCreateAndPoison(token);
        launchpad.graduate(token);

        uint256 amountIn = _nextChunk();
        uint256 fairOut = pool.getAmountOut(amountIn, address(weth));

        uint256 twap1 = pool.quote(address(weth), amountIn, 2);
        assertApproxEqRel(twap1, 0, 0, "both sampled windows are zeroed");

        vm.warp(block.timestamp + 1 hours);
        pool.sync();
        uint256 twap2 = pool.quote(address(weth), amountIn, 2);
        assertApproxEqRel(twap2 * 2, fairOut, 0.02e18, "one live window: TWAP ~ half of spot");

        vm.warp(block.timestamp + 1 hours);
        pool.sync();
        uint256 twap3 = pool.quote(address(weth), amountIn, 2);
        assertApproxEqRel(twap3, fairOut, 0.02e18, "two live windows: TWAP recovers");
    }
}
