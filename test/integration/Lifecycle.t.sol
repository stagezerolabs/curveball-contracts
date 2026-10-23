// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Fixture} from "../Fixture.sol";
import {CurveFeeEscrow} from "../../contracts/CurveFeeEscrow.sol";
import {CurveHolderReserve} from "../../contracts/CurveHolderReserve.sol";
import {CurveLaunchpad} from "../../contracts/CurveLaunchpad.sol";
import {MockIcarusPool} from "../mocks/MockIcarus.sol";

/// @dev One market from launch to its last claim, asserting where every wei went at each step.
contract LifecycleTest is Fixture {
    uint256 constant S = 1_000_000 ether;
    uint256 constant C = 800_000 ether;
    uint16 constant RESERVE_BPS = 400;
    uint256 constant RESERVE_TOKENS = S * RESERVE_BPS / 10_000;

    address carol = makeAddr("carol");
    address token;
    MockIcarusPool pool;
    uint256 creatorTokens;
    uint256 aliceTokens;
    uint256 bobTokens;

    /// @dev Every WETH ever minted is held by an actor or a contract this test knows about. Pool fees sit in the pool's fee holders.
    function _assertWethConserved() internal view {
        uint256 accounted = weth.balanceOf(creator) + weth.balanceOf(alice) + weth.balanceOf(bob)
            + weth.balanceOf(carol) + weth.balanceOf(treasury) + weth.balanceOf(address(launchpad))
            + weth.balanceOf(address(escrow)) + weth.balanceOf(address(locker));
        if (address(pool) != address(0)) {
            accounted += weth.balanceOf(address(pool)) + weth.balanceOf(pool.poolFees())
            + weth.balanceOf(pool.gaugeFees());
        }
        assertEq(accounted, weth.totalSupply(), "WETH conserved");
    }

    /// @dev The quote side's `totalOwed` already counts the buyback balance.
    function _assertEscrowBacked() internal view {
        assertGe(weth.balanceOf(address(escrow)), escrow.totalOwed(address(weth)));
        assertLe(escrow.buybackBalance(token), escrow.totalOwed(address(weth)));
        assertGe(IERC20(token).balanceOf(address(escrow)), escrow.totalOwed(token));
    }

    function _swap(address who, address tokenIn, uint256 amountIn) internal returns (uint256 out) {
        out = pool.getAmountOut(amountIn, tokenIn);
        vm.prank(who);
        IERC20(tokenIn).transfer(address(pool), amountIn);
        bool outIsToken0 = pool.token0() != tokenIn;
        pool.swap(outIsToken0 ? out : 0, outIsToken0 ? 0 : out, who, "");
    }

    function test_lifecycle_launchToLastClaim() public {
        _launchWithReserveAndFirstBuy();
        _tradeBothWays();
        _sellOutTheCurve();
        _graduate();
        _tradeInThePool();
        _claimLpFees();
        _claimFees();
        _buybackAndBurn();
        _claimReserve();
    }

    function _launchWithReserveAndFirstBuy() internal {
        _fund(creator, LAUNCH_FEE + 0.2 ether);
        vm.prank(creator);
        (token, creatorTokens) = launchpad.launch(_meta(), 50, RESERVE_BPS, 0.2 ether, 0);

        assertEq(weth.balanceOf(treasury), LAUNCH_FEE);
        assertEq(IERC20(token).totalSupply(), S);
        assertEq(IERC20(token).balanceOf(address(reserve)), RESERVE_TOKENS);
        assertEq(reserve.reserveOf(token), RESERVE_TOKENS);
        assertEq(IERC20(token).balanceOf(creator), creatorTokens);
        assertEq(launchpad.held(token, creator), creatorTokens);
        assertEq(IERC20(token).balanceOf(address(launchpad)), S - RESERVE_TOKENS - creatorTokens);
        _assertWethConserved();
        _assertEscrowBacked();
    }

    function _tradeBothWays() internal {
        aliceTokens = _buy(alice, token, 1.5 ether);
        bobTokens = _buy(bob, token, 0.7 ether);
        uint256 wethBefore = weth.balanceOf(alice);
        uint256 proceeds = _sell(alice, token, aliceTokens / 4);
        aliceTokens -= aliceTokens / 4;

        assertEq(weth.balanceOf(alice), wethBefore + proceeds);
        assertEq(IERC20(token).balanceOf(alice), aliceTokens);
        assertEq(launchpad.held(token, alice), aliceTokens);
        assertEq(weth.balanceOf(address(launchpad)), launchpad.totalRealQuote());
        _assertWethConserved();
        _assertEscrowBacked();
    }

    function _sellOutTheCurve() internal {
        bobTokens += _buy(bob, token, 100 ether);

        CurveLaunchpad.Market memory m = launchpad.market(token);
        assertEq(uint8(m.state), uint8(CurveLaunchpad.State.Ready));
        assertEq(S - m.virtualToken, C);
        assertEq(creatorTokens + aliceTokens + bobTokens, C, "every curve token has a holder");
        assertEq(launchpad.held(token, bob), bobTokens);
        assertGe(m.realQuote, TARGET);
        assertEq(weth.balanceOf(address(launchpad)), m.realQuote);
        _assertWethConserved();
    }

    function _graduate() internal {
        uint256 realQuote = launchpad.market(token).realQuote;
        pool = MockIcarusPool(launchpad.graduate(token));

        (uint256 poolTokens, uint256 poolQuote) = _reserves();
        assertEq(poolQuote, realQuote);
        assertEq(launchpad.totalRealQuote(), 0);
        assertEq(weth.balanceOf(address(launchpad)), 0);
        assertEq(IERC20(token).balanceOf(address(launchpad)), 0);
        assertEq(IERC20(token).totalSupply(), C + RESERVE_TOKENS + poolTokens, "the rest is burned");
        assertEq(pool.balanceOf(address(locker)) + pool.balanceOf(address(1)), pool.totalSupply());
        _assertWethConserved();
    }

    function _tradeInThePool() internal {
        _fund(carol, 5 ether);
        // Each swap lands in a new 30-minute window, so the TWAP has observations by the buyback.
        for (uint256 i = 0; i < 4; i++) {
            vm.warp(block.timestamp + 1801);
            _swap(carol, address(weth), 0.5 ether);
            vm.warp(block.timestamp + 1801);
            _swap(carol, token, IERC20(token).balanceOf(carol) / 3);
        }
        vm.prank(alice);
        IERC20(token).transfer(carol, 1 ether);
        assertEq(launchpad.held(token, alice), aliceTokens, "post-graduation transfers leave the ledger frozen");
        _assertWethConserved();
    }

    function _claimLpFees() internal {
        uint256 supplyBefore = IERC20(token).totalSupply();
        uint256 wethOwedBefore = escrow.totalOwed(address(weth));
        (uint256 tokenFees, uint256 quoteFees) = locker.claim(address(pool));

        assertGt(tokenFees, 0);
        assertGt(quoteFees, 0);
        uint256 burned = supplyBefore - IERC20(token).totalSupply();
        assertEq(burned, tokenFees * 2_500 / 10_000, "the buyback share of token fees burns at once");
        assertEq(escrow.totalOwed(token), tokenFees - burned);
        assertEq(escrow.totalOwed(address(weth)), wethOwedBefore + quoteFees);
        assertEq(weth.balanceOf(address(locker)), 0);
        assertEq(IERC20(token).balanceOf(address(locker)), 0);
        _assertEscrowBacked();
        _assertWethConserved();
    }

    function _claimFees() internal {
        uint256 creatorOwed = escrow.claimable(creator, address(weth));
        uint256 treasuryOwed = escrow.claimable(treasury, address(weth));
        uint256 creatorTokenFees = escrow.claimable(creator, token);
        uint256 creatorWethBefore = weth.balanceOf(creator);
        uint256 treasuryWethBefore = weth.balanceOf(treasury);
        assertGt(creatorOwed, 0);
        assertGt(creatorTokenFees, 0);

        vm.startPrank(creator);
        assertEq(escrow.claim(address(weth)), creatorOwed);
        escrow.claim(token);
        vm.stopPrank();
        vm.startPrank(treasury);
        assertEq(escrow.claim(address(weth)), treasuryOwed);
        escrow.claim(token);
        vm.stopPrank();

        assertEq(weth.balanceOf(creator), creatorWethBefore + creatorOwed);
        assertEq(weth.balanceOf(treasury), treasuryWethBefore + treasuryOwed);
        assertEq(IERC20(token).balanceOf(creator), creatorTokens + creatorTokenFees);
        assertEq(escrow.totalOwed(address(weth)), escrow.buybackBalance(token));
        assertEq(escrow.totalOwed(token), 0);
        assertEq(weth.balanceOf(address(escrow)), escrow.buybackBalance(token), "only the buyback balance is left");
        _assertWethConserved();
    }

    function _buybackAndBurn() internal {
        for (uint256 i = 0; i < 3; i++) {
            uint256 balance = escrow.buybackBalance(token);
            uint256 supplyBefore = IERC20(token).totalSupply();
            uint256 burned = escrow.buyback(token);
            assertGt(burned, 0);
            assertLt(escrow.buybackBalance(token), balance);
            assertEq(supplyBefore - IERC20(token).totalSupply(), burned);
            vm.expectRevert(CurveFeeEscrow.TooSoon.selector);
            escrow.buyback(token);
            vm.warp(block.timestamp + 1 hours);
        }
        assertEq(weth.balanceOf(address(escrow)), escrow.buybackBalance(token));
        assertEq(IERC20(token).balanceOf(address(escrow)), 0, "every bought token is burned");
        _assertWethConserved();
    }

    function _claimReserve() internal {
        uint256 paid;
        address[3] memory holders = [creator, alice, bob];
        for (uint256 i = 0; i < holders.length; i++) {
            uint256 expected = RESERVE_TOKENS * launchpad.held(token, holders[i]) / C;
            uint256 balanceBefore = IERC20(token).balanceOf(holders[i]);
            vm.prank(holders[i]);
            assertEq(reserve.claim(token), expected);
            assertEq(IERC20(token).balanceOf(holders[i]), balanceBefore + expected);
            paid += expected;
        }
        vm.prank(carol);
        vm.expectRevert(CurveHolderReserve.NothingToClaim.selector);
        reserve.claim(token);
        vm.prank(alice);
        vm.expectRevert(CurveHolderReserve.AlreadyClaimed.selector);
        reserve.claim(token);

        assertLe(RESERVE_TOKENS - paid, holders.length, "only round-down dust stays behind");
        assertEq(IERC20(token).balanceOf(address(reserve)), RESERVE_TOKENS - paid);
    }

    function _reserves() internal view returns (uint256 tokens, uint256 quote) {
        (uint256 r0, uint256 r1,) = pool.getReserves();
        (tokens, quote) = pool.token0() == token ? (r0, r1) : (r1, r0);
    }
}
