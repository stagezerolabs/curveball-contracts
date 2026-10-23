// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Fixture} from "../Fixture.sol";
import {CurveLaunchpad} from "../../contracts/CurveLaunchpad.sol";
import {CurveToken} from "../../contracts/CurveToken.sol";
import {CurveMath} from "../../contracts/libraries/CurveMath.sol";
import {MockIcarusPool} from "../mocks/MockIcarus.sol";

contract LaunchpadTradeTest is Fixture {
    uint256 constant S = 1_000_000 ether;
    uint256 constant C = 800_000 ether;

    address token;

    function setUp() public override {
        super.setUp();
        token = _launch(creator, 400, 0);
    }

    function _market() internal view returns (CurveLaunchpad.Market memory) {
        return launchpad.market(token);
    }

    function _predictedPool(address meme) internal view returns (address) {
        (address t0, address t1) = meme < address(weth) ? (meme, address(weth)) : (address(weth), meme);
        return vm.computeCreate2Address(
            keccak256(abi.encodePacked(t0, t1, false)),
            keccak256(abi.encodePacked(type(MockIcarusPool).creationCode, abi.encode(t0, t1))),
            address(icarus)
        );
    }

    // ---------------------------------------------------------------- buy

    function test_buy_matchesThePreview_andAccountsEverything() public {
        CurveMath.Buy memory preview = launchpad.previewBuy(token, 1 ether);
        _fund(alice, 1 ether);
        vm.expectEmit(address(launchpad));
        emit CurveLaunchpad.Trade(
            token,
            alice,
            true,
            preview.spent,
            preview.tokensOut,
            preview.fee,
            preview.tax,
            S - preview.tokensOut,
            1 ether + preview.curveQuote
        );
        vm.prank(alice);
        uint256 out = launchpad.buy(token, 1 ether, preview.tokensOut, block.timestamp);

        assertEq(out, preview.tokensOut);
        assertEq(CurveToken(token).balanceOf(alice), out);
        assertEq(launchpad.held(token, alice), out);
        assertEq(weth.balanceOf(alice), 1 ether - preview.spent);
        assertEq(weth.balanceOf(address(launchpad)), preview.curveQuote);
        assertEq(launchpad.totalRealQuote(), preview.curveQuote);
        assertEq(_market().realQuote, _market().virtualQuote - _market().initialVirtualQuote);
        assertEq(weth.balanceOf(address(escrow)), preview.fee);
        assertEq(escrow.totalOwed(address(weth)), preview.fee);
        assertEq(escrow.claimable(creator, address(weth)), preview.fee * 5_000 / 10_000);
    }

    function test_buy_creatorTaxIsCreditedToTheCreator() public {
        _fund(creator, LAUNCH_FEE);
        vm.prank(creator);
        (address taxed,) = launchpad.launch(_meta(), 50, 0, 0, 0);
        CurveMath.Buy memory preview = launchpad.previewBuy(taxed, 1 ether);
        assertEq(preview.tax, preview.curveQuote * 50 / 10_000);
        _buy(alice, taxed, 1 ether);
        assertEq(escrow.claimable(creator, address(weth)), preview.fee * 5_000 / 10_000 + preview.tax);
    }

    function test_buy_revertsOnSlippageAndDeadline() public {
        uint256 expected = launchpad.previewBuy(token, 1 ether).tokensOut;
        _fund(alice, 1 ether);
        vm.startPrank(alice);
        vm.expectRevert(CurveLaunchpad.Slippage.selector);
        launchpad.buy(token, 1 ether, expected + 1, block.timestamp);
        vm.expectRevert(CurveLaunchpad.Expired.selector);
        launchpad.buy(token, 1 ether, 0, block.timestamp - 1);
        vm.stopPrank();
    }

    function test_buy_revertsForAnUnknownToken() public {
        _fund(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(CurveLaunchpad.NotTrading.selector);
        launchpad.buy(makeAddr("unknown"), 1 ether, 0, block.timestamp);
    }

    function test_buy_sellout_clampsAndChargesExactlySpent() public {
        CurveMath.Buy memory preview = launchpad.previewBuy(token, 100 ether);
        assertEq(preview.tokensOut, C);
        _fund(alice, 100 ether);
        vm.expectEmit(address(launchpad));
        emit CurveLaunchpad.GraduationReady(token);
        vm.prank(alice);
        launchpad.buy(token, 100 ether, C, block.timestamp);

        assertEq(weth.balanceOf(alice), 100 ether - preview.spent);
        CurveLaunchpad.Market memory m = _market();
        assertEq(uint8(m.state), uint8(CurveLaunchpad.State.Ready));
        assertEq(m.readyAt, block.timestamp);
        assertEq(m.virtualToken, S - C);
        assertEq(m.realQuote, TARGET, "a single sellout buy raises the target exactly");
    }

    function test_sellout_afterManyTrades_raisesTheTargetWithinDrift() public {
        for (uint256 i = 0; i < 20; i++) {
            _buy(i % 2 == 0 ? alice : bob, token, 0.13 ether);
            if (i % 3 == 0) _sell(alice, token, CurveToken(token).balanceOf(alice) / 3);
        }
        _sellOut(bob, token);
        uint256 realQuote = _market().realQuote;
        assertGe(realQuote, TARGET);
        assertLe(realQuote, TARGET + 64, "rounding drift stays within a few wei per trade");
        assertEq(launchpad.held(token, alice) + launchpad.held(token, bob), C);
    }

    /// @dev The largest spend whose fill still leaves part of the curve unsold.
    function _largestPartialSpend() internal view returns (uint256 lo) {
        uint256 remaining = launchpad.market(token).virtualToken - (S - C);
        uint256 hi = 100 ether;
        while (lo + 1 < hi) {
            uint256 mid = (lo + hi) / 2;
            try launchpad.previewBuy(token, mid) returns (CurveMath.Buy memory b) {
                if (b.tokensOut < remaining) lo = mid;
                else hi = mid;
            } catch {
                lo = mid; // too small to fill anything
            }
        }
    }

    function test_sellout_cantBeWedgedByLeavingADustRemainder() public {
        // Leave the smallest remainder a buy can: so little that any fill's fee rounds to 0.
        _buy(alice, token, _largestPartialSpend());
        uint256 remaining = launchpad.market(token).virtualToken - (S - C);
        assertGt(remaining, 0);
        assertLt(remaining * launchpad.market(token).virtualQuote / launchpad.market(token).virtualToken, 134);
        assertEq(uint8(_market().state), uint8(CurveLaunchpad.State.Trading));

        assertEq(launchpad.previewBuy(token, 100 ether).tokensOut, remaining);
        _sellOut(bob, token);
        assertEq(uint8(_market().state), uint8(CurveLaunchpad.State.Ready));
        assertEq(launchpad.held(token, bob), remaining);
    }

    function test_buy_inReady_reverts() public {
        _sellOut(alice, token);
        _fund(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert(CurveLaunchpad.NotTrading.selector);
        launchpad.buy(token, 1 ether, 0, block.timestamp);
    }

    function test_pause_blocksBuyButNotSell() public {
        uint256 bought = _buy(alice, token, 1 ether);
        vm.prank(guardian);
        launchpad.pause();

        _fund(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert(CurveLaunchpad.EnforcedPause.selector);
        launchpad.buy(token, 1 ether, 0, block.timestamp);

        assertGt(_sell(alice, token, bought), 0);
    }

    // ---------------------------------------------------------------- sell

    function test_sell_matchesThePreview_andAccountsEverything() public {
        uint256 bought = _buy(alice, token, 1 ether);
        uint256 balanceBefore = weth.balanceOf(alice);
        uint256 escrowBefore = weth.balanceOf(address(escrow));
        CurveMath.Sell memory preview = launchpad.previewSell(token, bought / 2);

        uint256 net = _sell(alice, token, bought / 2);

        assertEq(net, preview.net);
        assertEq(weth.balanceOf(alice), balanceBefore + net);
        assertEq(weth.balanceOf(address(escrow)), escrowBefore + preview.fee + preview.tax);
        assertEq(launchpad.held(token, alice), bought - bought / 2);
        assertEq(CurveToken(token).balanceOf(alice), bought - bought / 2);
        assertEq(weth.balanceOf(address(launchpad)), launchpad.totalRealQuote());
        assertEq(_market().realQuote, _market().virtualQuote - _market().initialVirtualQuote);
    }

    function test_sell_revertsOnSlippageDeadlineAndOverselling() public {
        uint256 bought = _buy(alice, token, 1 ether);
        uint256 expected = launchpad.previewSell(token, bought).net;
        vm.startPrank(alice);
        CurveToken(token).approve(address(launchpad), type(uint256).max);
        vm.expectRevert(CurveLaunchpad.Slippage.selector);
        launchpad.sell(token, bought, expected + 1, block.timestamp);
        vm.expectRevert(CurveLaunchpad.Expired.selector);
        launchpad.sell(token, bought, 0, block.timestamp - 1);
        vm.expectRevert();
        launchpad.sell(token, bought + 1, 0, block.timestamp);
        vm.stopPrank();
    }

    function test_sell_inReady_revertsBeforeTheTimeout() public {
        _sellOut(alice, token);
        vm.warp(block.timestamp + launchpad.GRADUATION_TIMEOUT() - 1);
        vm.startPrank(alice);
        CurveToken(token).approve(address(launchpad), 1 ether);
        vm.expectRevert(CurveLaunchpad.NotTrading.selector);
        launchpad.sell(token, 1 ether, 0, block.timestamp);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- isolation and routing

    function test_twoMarkets_areIsolated() public {
        address other = _launch(bob, 0, 0);
        _buy(alice, token, 2 ether);
        CurveLaunchpad.Market memory untouched = launchpad.market(other);
        uint256 boughtOther = _buy(bob, other, 0.5 ether);

        assertEq(launchpad.market(token).realQuote + launchpad.market(other).realQuote, launchpad.totalRealQuote());
        assertEq(untouched.virtualToken, S);
        assertEq(launchpad.held(other, alice), 0);
        assertEq(launchpad.held(token, bob), 0);

        // Bob's tokens on one market can't draw on WETH the launchpad holds for the other.
        vm.startPrank(bob);
        CurveToken(other).approve(address(launchpad), type(uint256).max);
        vm.expectRevert();
        launchpad.sell(other, boughtOther + 1, 0, block.timestamp);
        vm.stopPrank();
    }

    function test_noCurveTokensReachThePoolBeforeGraduation() public {
        address pool = _predictedPool(token);
        uint256 bought = _buy(alice, token, 3 ether);

        vm.prank(alice);
        vm.expectRevert(CurveToken.Locked.selector);
        CurveToken(token).transfer(pool, bought);

        _sellOut(bob, token);
        assertEq(CurveToken(token).balanceOf(pool), 0);
        assertEq(launchpad.held(token, pool), 0);
    }

    function testFuzz_held_equalsBalance_forEveryTrader(uint256 seed) public {
        address[3] memory traders = [alice, bob, creator];
        for (uint256 i = 0; i < 12 && _market().virtualToken > S - C; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            address trader = traders[r % 3];
            uint256 balance = CurveToken(token).balanceOf(trader);
            if (r % 2 == 0 || balance < 1 ether) {
                _buy(trader, token, bound(r >> 8, 0.001 ether, 1 ether));
            } else {
                _sell(trader, token, bound(r >> 8, 1 ether, balance));
            }
        }
        for (uint256 i = 0; i < 3; i++) {
            assertEq(launchpad.held(token, traders[i]), CurveToken(token).balanceOf(traders[i]));
        }
        assertEq(weth.balanceOf(address(launchpad)), launchpad.totalRealQuote());
    }
}
