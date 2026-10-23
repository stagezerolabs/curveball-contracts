// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, stdError} from "forge-std/Test.sol";
import {MockIcarusFactory, MockIcarusPool} from "../mocks/MockIcarus.sol";
import {MockWETH} from "../mocks/MockWETH.sol";

/// @dev Pins the mock to the verified Icarus behaviour later suites depend on.
contract MockIcarusTest is Test {
    MockIcarusFactory factory = new MockIcarusFactory();
    MockWETH weth = new MockWETH();
    MockWETH meme = new MockWETH();
    MockIcarusPool pool;
    address lp = makeAddr("lp");
    address trader = makeAddr("trader");

    function setUp() public {
        pool = MockIcarusPool(factory.createPool(address(meme), address(weth), false));
    }

    function _seed(uint256 memeAmount, uint256 wethAmount) internal returns (uint256 liquidity) {
        meme.mint(address(pool), memeAmount);
        weth.mint(address(pool), wethAmount);
        liquidity = pool.mint(lp);
    }

    function _reserves() internal view returns (uint256 memeReserve, uint256 wethReserve) {
        (uint256 r0, uint256 r1,) = pool.getReserves();
        (memeReserve, wethReserve) = pool.token0() == address(meme) ? (r0, r1) : (r1, r0);
    }

    function _swapWethIn(uint256 amountIn) internal returns (uint256 out) {
        out = pool.getAmountOut(amountIn, address(weth));
        weth.mint(address(pool), amountIn);
        (uint256 out0, uint256 out1) = pool.token0() == address(meme) ? (out, uint256(0)) : (uint256(0), out);
        pool.swap(out0, out1, trader, "");
    }

    function test_createPool_isDeterministicAndUnique() public {
        (address t0, address t1) =
            address(meme) < address(weth) ? (address(meme), address(weth)) : (address(weth), address(meme));
        address predicted = vm.computeCreate2Address(
            keccak256(abi.encodePacked(t0, t1, false)),
            keccak256(abi.encodePacked(type(MockIcarusPool).creationCode, abi.encode(t0, t1))),
            address(factory)
        );
        assertEq(address(pool), predicted);
        assertEq(factory.getPool(address(weth), address(meme), false), address(pool));
        vm.expectRevert(MockIcarusFactory.PoolAlreadyExists.selector);
        factory.createPool(address(weth), address(meme), false);
    }

    function test_firstMint_locksMinimumLiquidityAndSetsReserves() public {
        uint256 liquidity = _seed(160_000 ether, 10 ether);
        assertEq(liquidity, _sqrt(160_000 ether * 10 ether) - 1000);
        assertEq(pool.balanceOf(address(1)), 1000);
        (uint256 memeReserve, uint256 wethReserve) = _reserves();
        assertEq(memeReserve, 160_000 ether);
        assertEq(wethReserve, 10 ether);
    }

    function test_skim_removesOnlyUnsyncedBalances() public {
        weth.mint(address(pool), 1 ether);
        pool.skim(trader);
        assertEq(weth.balanceOf(trader), 1 ether);
        (, uint256 wethReserve) = _reserves();
        assertEq(wethReserve, 0);
    }

    function test_sync_foldsDonationIntoReserves_soSkimCannotRemoveIt() public {
        weth.mint(address(pool), 1 ether);
        pool.sync();
        pool.skim(trader);
        assertEq(weth.balanceOf(trader), 0);
        (, uint256 wethReserve) = _reserves();
        assertEq(wethReserve, 1 ether);
        assertEq(pool.totalSupply(), 0);
    }

    function test_swap_takesFeeOnInput_andSplitsGaugeShare() public {
        _seed(160_000 ether, 10 ether);
        uint256 out = _swapWethIn(1 ether);
        assertEq(meme.balanceOf(trader), out);
        uint256 fee = 1 ether * 30 / 10_000;
        uint256 gauge = fee * 1000 / 10_000;
        assertEq(weth.balanceOf(pool.gaugeFees()), gauge);
        assertEq(weth.balanceOf(pool.poolFees()), fee - gauge);
        (, uint256 wethReserve) = _reserves();
        assertEq(wethReserve, 11 ether - fee, "fees must leave the pool");
    }

    function test_swap_revertsWhilePaused_butMintAndSyncDoNot() public {
        factory.setPauseState(true);
        _seed(160_000 ether, 10 ether);
        pool.sync();
        weth.mint(address(pool), 1 ether);
        vm.expectRevert(MockIcarusPool.IsPaused.selector);
        pool.swap(1 ether, 0, trader, "");
    }

    function test_claimFees_paysLpItsShare() public {
        _seed(160_000 ether, 10 ether);
        _swapWethIn(1 ether);
        vm.prank(lp);
        (uint256 claimed0, uint256 claimed1) = pool.claimFees();
        uint256 wethClaimed = pool.token0() == address(weth) ? claimed0 : claimed1;
        uint256 lpFee = 1 ether * 30 / 10_000 * 9000 / 10_000;
        // LP owns everything except MINIMUM_LIQUIDITY, so it claims the LP fee minus index rounding dust.
        assertApproxEqAbs(wethClaimed, lpFee, 1e6);
        assertLe(wethClaimed, lpFee);
        assertEq(weth.balanceOf(lp), wethClaimed);
    }

    function test_quote_underflowsUntilEnoughObservations_thenAveragesFeeFree() public {
        _seed(160_000 ether, 10 ether);
        assertEq(pool.observationLength(), 1);
        vm.expectRevert(stdError.arithmeticError);
        pool.quote(address(weth), 1 ether, 2);
        for (uint256 i = 0; i < 2; i++) {
            vm.warp(block.timestamp + 1801);
            pool.sync();
        }
        assertEq(pool.observationLength(), 3);
        uint256 twapOut = pool.quote(address(weth), 1 ether, 2);
        assertEq(twapOut, uint256(1 ether) * 160_000 ether / (10 ether + 1 ether));
        assertGt(twapOut, pool.getAmountOut(1 ether, address(weth)), "quote is fee-free");
    }

    function test_observations_onlyPushAfterPeriod() public {
        _seed(160_000 ether, 10 ether);
        vm.warp(block.timestamp + 1800);
        pool.sync();
        assertEq(pool.observationLength(), 1);
        vm.warp(block.timestamp + 1);
        pool.sync();
        assertEq(pool.observationLength(), 2);
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        y = x;
        uint256 z = (x + 1) / 2;
        while (z < y) (y, z) = (z, (x / z + z) / 2);
    }
}
