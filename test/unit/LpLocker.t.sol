// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {CurveFeeEscrow} from "../../contracts/CurveFeeEscrow.sol";
import {CurveLpLocker} from "../../contracts/CurveLpLocker.sol";
import {CurveToken} from "../../contracts/CurveToken.sol";
import {MockIcarusFactory, MockIcarusPool} from "../mocks/MockIcarus.sol";
import {MockLaunchpad} from "../mocks/MockLaunchpad.sol";
import {MockWETH} from "../mocks/MockWETH.sol";

contract LpLockerTest is Test {
    uint256 constant SUPPLY = 1_000_000 ether;

    address treasury = makeAddr("treasury");
    address creator = makeAddr("creator");
    address trader = makeAddr("trader");

    MockWETH weth = new MockWETH();
    MockIcarusFactory factory = new MockIcarusFactory();
    MockLaunchpad launchpad = new MockLaunchpad(treasury);
    CurveFeeEscrow escrow;
    CurveLpLocker locker;

    function setUp() public {
        escrow = new CurveFeeEscrow(address(launchpad), address(weth), address(factory), address(this));
        locker = new CurveLpLocker(address(launchpad), address(escrow));
        launchpad.setLocker(address(locker));
    }

    /// @dev Graduates a fresh token into a pool whose LP sits in the locker.
    function _graduate() internal returns (CurveToken token, MockIcarusPool pool) {
        token = launchpad.createToken(SUPPLY, address(0), 0);
        launchpad.setFeePolicy(address(token), creator, 5_000, 2_000);
        launchpad.unlock(token);
        pool = MockIcarusPool(factory.createPool(address(token), address(weth), false));
        launchpad.send(token, address(pool), 160_000 ether);
        weth.mint(address(pool), 10 ether);
        pool.mint(address(locker));
        launchpad.setPool(address(token), address(pool));
        vm.prank(address(launchpad));
        locker.register(address(token), address(pool));
    }

    function _swap(MockIcarusPool pool, address tokenIn, uint256 amountIn) internal {
        uint256 out = pool.getAmountOut(amountIn, tokenIn);
        if (tokenIn == address(weth)) weth.mint(address(pool), amountIn);
        else launchpad.send(CurveToken(tokenIn), address(pool), amountIn);
        (uint256 out0, uint256 out1) = pool.token0() == tokenIn ? (uint256(0), out) : (out, uint256(0));
        pool.swap(out0, out1, trader, "");
    }

    function test_register_onlyLaunchpad_once() public {
        (CurveToken token, MockIcarusPool pool) = _graduate();
        assertEq(locker.tokenOf(address(pool)), address(token));

        vm.expectRevert(CurveLpLocker.NotLaunchpad.selector);
        locker.register(address(token), address(pool));

        vm.prank(address(launchpad));
        vm.expectRevert(CurveLpLocker.AlreadyRegistered.selector);
        locker.register(address(token), address(pool));
    }

    function test_claim_revertsForUnregisteredPool() public {
        vm.expectRevert(CurveLpLocker.UnregisteredPool.selector);
        locker.claim(makeAddr("pool"));
    }

    function test_claim_routesOnlyEachPoolsOwnFees_andKeepsTheLp() public {
        (CurveToken a, MockIcarusPool poolA) = _graduate();
        (CurveToken b, MockIcarusPool poolB) = _graduate();
        uint256 lpA = poolA.balanceOf(address(locker));
        uint256 lpB = poolB.balanceOf(address(locker));

        _swap(poolA, address(weth), 1 ether);
        _swap(poolA, address(a), 1_000 ether);
        _swap(poolB, address(weth), 2 ether);
        // A stray balance in the locker must never be attributed to either market.
        weth.mint(address(locker), 5 ether);
        launchpad.send(a, address(locker), 7 ether);

        uint256 supplyA = a.totalSupply();
        (uint256 tokenFeesA, uint256 quoteFeesA) = locker.claim(address(poolA));
        (uint256 tokenFeesB, uint256 quoteFeesB) = locker.claim(address(poolB));

        assertGt(tokenFeesA, 0);
        assertGt(quoteFeesA, 0);
        assertEq(tokenFeesB, 0);
        assertGt(quoteFeesB, quoteFeesA);
        assertEq(weth.balanceOf(address(escrow)), quoteFeesA + quoteFeesB);
        assertEq(escrow.buybackBalance(address(a)), quoteFeesA * 2_000 / 10_000);
        assertEq(escrow.buybackBalance(address(b)), quoteFeesB * 2_000 / 10_000);
        assertEq(escrow.claimable(creator, address(a)), tokenFeesA * 5_000 / 10_000);
        assertEq(a.totalSupply(), supplyA - tokenFeesA * 2_000 / 10_000, "meme-side buyback share is burned");
        assertEq(weth.balanceOf(address(locker)), 5 ether);
        assertEq(a.balanceOf(address(locker)), 7 ether);
        assertEq(poolA.balanceOf(address(locker)), lpA);
        assertEq(poolB.balanceOf(address(locker)), lpB);
    }

    function test_claim_withNoFeesIsANoOp() public {
        (, MockIcarusPool pool) = _graduate();
        (uint256 tokenFees, uint256 quoteFees) = locker.claim(address(pool));
        assertEq(tokenFees + quoteFees, 0);
        assertEq(weth.balanceOf(address(escrow)), 0);
    }
}
