// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Fixture} from "../Fixture.sol";
import {CurveLaunchpad} from "../../contracts/CurveLaunchpad.sol";
import {CurveToken} from "../../contracts/CurveToken.sol";
import {IIcarusPool} from "../../contracts/interfaces/IIcarus.sol";
import {MockIcarusPool} from "../mocks/MockIcarus.sol";

contract LaunchpadGraduateTest is Fixture {
    uint256 constant S = 1_000_000 ether;
    uint256 constant C = 800_000 ether;

    /// @dev Launches with `reserveBps`, trades a little both ways, and sells out.
    function _readyMarket(uint16 reserveBps) internal returns (address token) {
        token = _launch(creator, reserveBps, 0.05 ether);
        uint256 bought = _buy(alice, token, 1.3 ether);
        _sell(alice, token, bought / 3);
        _sellOut(bob, token);
    }

    /// @dev The curve-end price in tokens per quote, widened before multiplying the uint128 fields.
    function _tokensFor(uint256 quote, CurveLaunchpad.Market memory m) internal pure returns (uint256) {
        return quote * uint256(m.virtualToken) / uint256(m.virtualQuote);
    }

    function _reserves(address pool, address token) internal view returns (uint256 tokens, uint256 quote) {
        (uint256 r0, uint256 r1,) = IIcarusPool(pool).getReserves();
        (tokens, quote) = IIcarusPool(pool).token0() == token ? (r0, r1) : (r1, r0);
    }

    /// @dev Asserts a clean graduation: reserves as computed, nothing left behind, every pointer set.
    function _assertGraduated(address token, address pool, uint256 quoteInPool, uint256 tokensToPool) internal view {
        (uint256 tokens, uint256 quote) = _reserves(pool, token);
        assertEq(tokens, tokensToPool);
        assertEq(quote, quoteInPool);
        CurveLaunchpad.Market memory m = launchpad.market(token);
        assertEq(uint8(m.state), uint8(CurveLaunchpad.State.Graduated));
        assertEq(m.realQuote, 0);
        assertEq(launchpad.poolOf(token), pool);
        assertEq(locker.tokenOf(pool), token);
        assertGt(IIcarusPool(pool).balanceOf(address(locker)), 0);
        assertEq(CurveToken(token).balanceOf(address(launchpad)), 0);
        assertTrue(CurveToken(token).unlocked());
        assertEq(CurveToken(token).totalSupply(), C + m.reserveTokens + tokensToPool);
        assertEq(launchpad.held(token, creator) + launchpad.held(token, alice) + launchpad.held(token, bob), C);
    }

    function _assertOpensAtCurveEndPrice(address token, address pool, uint256 vT, uint256 vQ) internal view {
        (uint256 tokens, uint256 quote) = _reserves(pool, token);
        // tokens = floor(quote * vT / vQ), so the pool's price is the curve-end spot to within one token-wei.
        assertApproxEqAbs(tokens, quote * vT / vQ, 1);
    }

    function test_graduate_opensAtTheCurveEndPrice_forEveryReserve() public {
        uint16[3] memory reserves = [uint16(0), 100, 400];
        for (uint256 i = 0; i < reserves.length; i++) {
            address token = _readyMarket(reserves[i]);
            CurveLaunchpad.Market memory m = launchpad.market(token);
            uint256 expectedTokens = _tokensFor(m.realQuote, m);
            if (reserves[i] == 400) assertGe(expectedTokens, S - C - m.reserveTokens, "R = MAX sits on the clamp");
            uint256 cap = S - C - m.reserveTokens;
            uint256 tokensToPool = expectedTokens < cap ? expectedTokens : cap;

            address pool = launchpad.graduate(token);

            _assertGraduated(token, pool, m.realQuote, tokensToPool);
            if (reserves[i] != 400) _assertOpensAtCurveEndPrice(token, pool, m.virtualToken, m.virtualQuote);
            assertEq(launchpad.totalRealQuote(), 0);
            assertEq(weth.balanceOf(address(launchpad)), 0);
        }
    }

    function test_graduate_atMaxReserve_driftStaysWithinTheClamp() public {
        address token = _readyMarket(400);
        CurveLaunchpad.Market memory m = launchpad.market(token);
        address pool = launchpad.graduate(token);
        (uint256 tokens, uint256 quote) = _reserves(pool, token);
        assertEq(tokens, S - C - m.reserveTokens);
        // Clamping can only lift the opening price, and only by the sellout drift.
        assertGe(quote * uint256(m.virtualToken), tokens * uint256(m.virtualQuote));
        assertApproxEqRel(quote * uint256(m.virtualToken), tokens * uint256(m.virtualQuote), 1e6);
    }

    function test_graduate_emitsGraduated() public {
        address token = _readyMarket(0);
        CurveLaunchpad.Market memory m = launchpad.market(token);
        uint256 tokensToPool = _tokensFor(m.realQuote, m);
        vm.expectEmit(true, false, false, true, address(launchpad));
        emit CurveLaunchpad.Graduated(token, address(0), m.realQuote, tokensToPool, S - C - tokensToPool);
        launchpad.graduate(token);
    }

    function test_graduate_revertsUnlessReady() public {
        address token = _launch(creator, 0, 0.05 ether);
        vm.expectRevert(CurveLaunchpad.NotReady.selector);
        launchpad.graduate(token);

        _sellOut(bob, token);
        launchpad.graduate(token);
        vm.expectRevert(CurveLaunchpad.NotReady.selector);
        launchpad.graduate(token);
    }

    function test_graduate_stillWorksWhileIcarusIsPausedOrTheLaunchpadIs() public {
        address token = _readyMarket(400);
        icarus.setPauseState(true);
        vm.prank(guardian);
        launchpad.pause();
        launchpad.graduate(token);
        assertTrue(launchpad.poolOf(token) != address(0));
    }

    // ---------------------------------------------------------------- pre-created pools

    function test_graduate_reusesACleanPreCreatedPool() public {
        address token = _readyMarket(0);
        address precreated = icarus.createPool(address(weth), token, false);
        CurveLaunchpad.Market memory m = launchpad.market(token);
        assertEq(launchpad.graduate(token), precreated);
        _assertGraduated(token, precreated, m.realQuote, _tokensFor(m.realQuote, m));
    }

    function test_graduate_skimsAnUnsyncedDonation() public {
        address token = _readyMarket(400);
        address pool = icarus.createPool(token, address(weth), false);
        weth.mint(pool, 3 ether);
        CurveLaunchpad.Market memory m = launchpad.market(token);

        launchpad.graduate(token);

        (, uint256 quote) = _reserves(pool, token);
        assertEq(quote, m.realQuote, "the donation is skimmed, not priced");
        assertEq(weth.balanceOf(address(launchpad)), 3 ether, "and left to rescue");
    }

    function test_graduate_matchesASyncedDonationInsideTheBuffer() public {
        address token = _readyMarket(0);
        address pool = icarus.createPool(token, address(weth), false);
        weth.mint(pool, 0.5 ether);
        MockIcarusPool(pool).sync();
        CurveLaunchpad.Market memory m = launchpad.market(token);
        uint256 quoteInPool = m.realQuote + 0.5 ether;
        uint256 tokensToPool = _tokensFor(quoteInPool, m);
        assertLt(tokensToPool, S - C, "inside the buffer");

        launchpad.graduate(token);

        _assertGraduated(token, pool, quoteInPool, tokensToPool);
        _assertOpensAtCurveEndPrice(token, pool, m.virtualToken, m.virtualQuote);
    }

    function test_graduate_neverRevertsOnASyncedDonationBeyondTheBuffer() public {
        address token = _readyMarket(0);
        address pool = icarus.createPool(token, address(weth), false);
        weth.mint(pool, 1_000 ether);
        MockIcarusPool(pool).sync();
        CurveLaunchpad.Market memory m = launchpad.market(token);

        launchpad.graduate(token);

        // Clamped to every token outside the curve: the donor pays the whole premium.
        _assertGraduated(token, pool, m.realQuote + 1_000 ether, S - C);
        assertEq(CurveToken(token).totalSupply(), S, "nothing left to burn");
    }

    function test_graduate_revertsForAPoolThatAlreadyHasLp() public {
        address token = _readyMarket(0);
        address pool = icarus.createPool(token, address(weth), false);
        // Unreachable with the transfer lock (minting LP needs both tokens), so simulate it.
        vm.mockCall(pool, abi.encodeWithSelector(IIcarusPool.totalSupply.selector), abi.encode(uint256(1)));
        vm.expectRevert(CurveLaunchpad.PoolUsed.selector);
        launchpad.graduate(token);
    }

    function test_graduate_revertsIfThePoolHoldsTokensBeforeTheTransfer() public {
        address token = _readyMarket(0);
        address pool = icarus.createPool(token, address(weth), false);
        (bool tokenIsToken0) = IIcarusPool(pool).token0() == token;
        bytes memory reserves = tokenIsToken0 ? abi.encode(1, 0, 0) : abi.encode(0, 1, 0);
        vm.mockCall(pool, abi.encodeWithSelector(IIcarusPool.getReserves.selector), reserves);
        vm.expectRevert(CurveLaunchpad.PoolUsed.selector);
        launchpad.graduate(token);
    }

    // ---------------------------------------------------------------- size gate

    function test_launchpad_keepsTwoKilobytesUnderTheCodeSizeLimit() public view {
        assertLe(address(launchpad).code.length, 24_576 - 2_048);
    }
}
