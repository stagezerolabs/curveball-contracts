// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {CurveMath} from "../../contracts/libraries/CurveMath.sol";

/// @dev Exposes the internal library so reverts can be asserted with vm.expectRevert.
contract CurveMathHarness {
    function initialVirtualQuote(uint256 target, uint256 supply, uint256 curveSupply) external pure returns (uint256) {
        return CurveMath.initialVirtualQuote(target, supply, curveSupply);
    }

    function quoteBuy(uint256 vT, uint256 vQ, uint256 remaining, uint256 maxSpend, uint256 feeBps, uint256 taxBps)
        external
        pure
        returns (CurveMath.Buy memory)
    {
        return CurveMath.quoteBuy(vT, vQ, remaining, maxSpend, feeBps, taxBps);
    }

    function quoteSell(uint256 vT, uint256 vQ, uint256 realQuote, uint256 amount, uint256 feeBps, uint256 taxBps)
        external
        pure
        returns (CurveMath.Sell memory)
    {
        return CurveMath.quoteSell(vT, vQ, realQuote, amount, feeBps, taxBps);
    }
}

contract CurveMathTest is Test {
    uint256 constant S = 1_000_000 ether;
    uint256 constant C = 800_000 ether;
    uint256 constant FEE = 75;
    uint256 constant TAX = 50;

    CurveMathHarness h = new CurveMathHarness();

    /// @dev Mirrors the launchpad's per-market state for multi-trade simulations.
    struct Market {
        uint256 vT;
        uint256 vQ;
        uint256 realQuote;
        uint256 sold;
    }

    function _target(uint256 seed) internal pure returns (uint256) {
        // Valid targets are multiples of C / gcd(S - C, C) = 4 wei, from 0.001 to 1,000 WETH.
        return bound(seed, 0.001 ether / 4, 1_000 ether / 4) * 4;
    }

    function _open(uint256 target) internal pure returns (Market memory m) {
        m.vT = S;
        m.vQ = CurveMath.initialVirtualQuote(target, S, C);
    }

    function _buy(Market memory m, uint256 maxSpend) internal pure returns (CurveMath.Buy memory b) {
        b = CurveMath.quoteBuy(m.vT, m.vQ, C - m.sold, maxSpend, FEE, TAX);
        m.vT -= b.tokensOut;
        m.vQ += b.curveQuote;
        m.realQuote += b.curveQuote;
        m.sold += b.tokensOut;
    }

    function _sell(Market memory m, uint256 amount) internal pure returns (CurveMath.Sell memory s) {
        s = CurveMath.quoteSell(m.vT, m.vQ, m.realQuote, amount, FEE, TAX);
        m.vT += amount;
        m.vQ -= s.gross;
        m.realQuote -= s.gross;
        m.sold -= amount;
    }

    // ---------------------------------------------------------------- initialVirtualQuote

    function test_initialVirtualQuote_matchesClosedForm() public pure {
        assertEq(CurveMath.initialVirtualQuote(10 ether, S, C), 2.5 ether);
    }

    function test_initialVirtualQuote_rejectsInexactTarget() public {
        vm.expectRevert(CurveMath.InvalidTarget.selector);
        h.initialVirtualQuote(10 ether + 1, S, C);
    }

    function test_initialVirtualQuote_rejectsZeroAndOversized() public {
        vm.expectRevert(CurveMath.InvalidTarget.selector);
        h.initialVirtualQuote(0, S, C);
        vm.expectRevert(CurveMath.InvalidTarget.selector);
        h.initialVirtualQuote(uint256(type(uint128).max) * 4, S, C);
    }

    // ---------------------------------------------------------------- buy / sell

    function testFuzz_buy_neverDecreasesK_andChargesExactly(uint256 targetSeed, uint256 spend) public pure {
        Market memory m = _open(_target(targetSeed));
        spend = bound(spend, 1e6, 10_000 ether);
        uint256 k = m.vT * m.vQ;
        CurveMath.Buy memory b = _buy(m, spend);
        assertGe(m.vT * m.vQ, k, "k decreased");
        assertLe(b.spent, spend, "overspent");
        assertEq(b.spent, b.curveQuote + b.fee + b.tax, "spent != parts");
        assertEq(b.fee, b.curveQuote * FEE / 10_000);
        assertEq(b.tax, b.curveQuote * TAX / 10_000);
        assertLe(m.sold, C, "oversold");
    }

    function testFuzz_roundTrip_neverProfits(uint256 targetSeed, uint256 preSpend, uint256 spend) public pure {
        Market memory m = _open(_target(targetSeed));
        preSpend = bound(preSpend, 0, 500 ether);
        if (preSpend >= 1e6 && m.sold < C) _buy(m, preSpend);
        if (m.sold == C) return;
        spend = bound(spend, 1e6, 500 ether);
        CurveMath.Buy memory b = _buy(m, spend);
        uint256 k = m.vT * m.vQ;
        CurveMath.Sell memory s = _sell(m, b.tokensOut);
        assertGe(m.vT * m.vQ, k, "k decreased on sell");
        assertLe(s.gross, b.curveQuote, "curve round trip profit");
        assertLt(s.net, b.spent, "net round trip profit");
    }

    function testFuzz_sell_neverExceedsReserve(uint256 targetSeed, uint256 spend, uint256 amount) public pure {
        Market memory m = _open(_target(targetSeed));
        _buy(m, bound(spend, 1e6, 2_000 ether));
        // Below ~1 token a sell can be dust (fee rounds to zero), which reverts by design.
        amount = bound(amount, m.sold < 1 ether ? m.sold : 1 ether, m.sold);
        uint256 vT = m.vT;
        uint256 vQ = m.vQ;
        uint256 newVq = vT * vQ / (vT + amount);
        // Payout uses ceil(newVq), so it is at most the exact-division payout.
        CurveMath.Sell memory s = CurveMath.quoteSell(vT, vQ, m.realQuote, amount, FEE, TAX);
        assertLe(s.gross, vQ - newVq);
        assertLe(s.gross, m.realQuote);
        assertEq(s.net + s.fee + s.tax, s.gross);
    }

    function test_buy_clampsAtSellout() public pure {
        Market memory m = _open(10 ether);
        CurveMath.Buy memory b = _buy(m, 1_000 ether);
        assertEq(m.sold, C);
        assertEq(b.tokensOut, C);
        assertGe(m.realQuote, 10 ether);
        assertLe(m.realQuote, 10 ether + 1);
        assertEq(b.spent, b.curveQuote + b.fee + b.tax);
        assertLt(b.spent, 1_000 ether);
    }

    function test_buy_revertsWhenSoldOut() public {
        vm.expectRevert(CurveMath.SoldOut.selector);
        h.quoteBuy(S - C, 12.5 ether, 0, 1 ether, FEE, TAX);
    }

    function test_buy_revertsOnZeroOutput() public {
        // One wei of budget against a huge quote reserve buys nothing.
        vm.expectRevert(CurveMath.ZeroOutput.selector);
        h.quoteBuy(S, type(uint128).max, C, 1, 0, 0);
    }

    function test_buy_revertsOnDustFee() public {
        // Budget too small for a nonzero fee while fees are on.
        vm.expectRevert(CurveMath.DustTrade.selector);
        h.quoteBuy(S, 2.5 ether, C, 100, FEE, 0);
    }

    function test_buy_finalDustFillIsExempt() public view {
        // About 100 wei of curve quote for the last 4e6 token-wei: the fee rounds to 0 but it must fill.
        CurveMath.Buy memory b = h.quoteBuy(S - C + 4e6, 5 ether, 4e6, 100 ether, FEE, 0);
        assertEq(b.tokensOut, 4e6);
        assertEq(b.fee, 0);
        assertGt(b.curveQuote, 0);
        assertEq(b.spent, b.curveQuote);
    }

    function test_buy_rejectsOversizedSpend() public {
        vm.expectRevert(CurveMath.InvalidAmount.selector);
        h.quoteBuy(S, 2.5 ether, C, uint256(type(uint128).max) + 1, FEE, TAX);
    }

    function test_sell_revertsOnZeroAmountZeroOutputAndDust() public {
        vm.expectRevert(CurveMath.InvalidAmount.selector);
        h.quoteSell(S, 2.5 ether, 1 ether, 0, FEE, TAX);
        vm.expectRevert(CurveMath.ZeroOutput.selector);
        h.quoteSell(S - 1 ether, 2.5 ether, 1 ether, 1e4, FEE, TAX);
        // About 100 wei gross: nonzero output, but the fee rounds to zero.
        vm.expectRevert(CurveMath.DustTrade.selector);
        h.quoteSell(S - 1 ether, 2.5 ether, 1 ether, 4e7, FEE, TAX);
    }

    function test_sell_revertsBeyondReserve() public {
        vm.expectRevert(CurveMath.InsufficientReserve.selector);
        h.quoteSell(S - 1 ether, 2.5 ether, 0, 1 ether, FEE, TAX);
    }

    // ---------------------------------------------------------------- sellout drift and pool seeding

    /// @dev Drift comes from ceil rounding: under 1 wei per buy, at most S / (S - C) wei per sell.
    function testFuzz_selloutDrift_isBounded(uint256 targetSeed, uint256[12] memory moves) public pure {
        uint256 target = _target(targetSeed);
        Market memory m = _open(target);
        uint256 buys;
        uint256 sells;
        for (uint256 i = 0; i < moves.length && m.sold < C; i++) {
            if (moves[i] % 3 == 0 && m.sold > 1 ether) {
                _sell(m, bound(moves[i], 1 ether, m.sold));
                sells++;
            } else {
                _buy(m, bound(moves[i], 1e9, target / 4 + 1e9));
                buys++;
            }
        }
        if (m.sold < C) {
            _buy(m, target * 2);
            buys++;
        }
        assertEq(m.sold, C);
        assertGe(m.realQuote, target, "undershoot");
        assertLe(m.realQuote - target, buys + sells * (S / (S - C)) + 1, "drift too large");
    }

    function testFuzz_tokensFor_atSellout_staysNearIdealPoolSeed(uint256 targetSeed, uint256 split) public pure {
        uint256 target = _target(targetSeed);
        Market memory m = _open(target);
        uint256 vQ0 = m.vQ;
        _buy(m, bound(split, 1e9, target));
        if (m.sold < C) _buy(m, target * 2);
        uint256 idealSeed = (S - C) * C / S;
        uint256 maxReserve = (S - C) * (S - C) / S;
        assertEq(idealSeed + maxReserve, S - C, "reserve cap must be the seed remainder");
        uint256 tokens = CurveMath.tokensFor(m.realQuote, m.vT, m.vQ);
        uint256 drift = m.realQuote - target;
        // Drift may overshoot the ideal seed by at most drift * (S-C) / vQ0, which the launchpad clamps.
        assertLe(tokens, idealSeed + drift * (S - C) / vQ0 + 1, "seed overshoot");
        assertGe(tokens + 1, idealSeed, "seed undershoot");
    }

    // ---------------------------------------------------------------- fee split

    function testFuzz_splitFee_sumsExactly(uint256 fee, uint256 tax, uint256 creatorShare, uint256 buybackShare)
        public
        pure
    {
        fee = bound(fee, 0, type(uint128).max);
        tax = bound(tax, 0, type(uint128).max);
        creatorShare = bound(creatorShare, 0, 10_000);
        buybackShare = bound(buybackShare, 0, 10_000 - creatorShare);
        (uint256 creator, uint256 buyback, uint256 protocol) = CurveMath.splitFee(fee, tax, creatorShare, buybackShare);
        assertEq(creator + buyback + protocol, fee + tax);
        assertGe(creator, tax, "tax not routed to creator");
    }
}
