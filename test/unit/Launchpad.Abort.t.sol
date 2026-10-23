// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Fixture} from "../Fixture.sol";
import {CurveLaunchpad} from "../../contracts/CurveLaunchpad.sol";
import {CurveToken} from "../../contracts/CurveToken.sol";

contract LaunchpadAbortTest is Fixture {
    uint256 constant S = 1_000_000 ether;
    uint256 constant C = 800_000 ether;

    address token;
    uint256 timeout;

    function setUp() public override {
        super.setUp();
        timeout = launchpad.GRADUATION_TIMEOUT();
        token = _launch(creator, 400, 0);
        _buy(alice, token, 1 ether);
        _sellOut(bob, token);
    }

    function _state() internal view returns (CurveLaunchpad.State) {
        return launchpad.market(token).state;
    }

    function _sold() internal view returns (uint256) {
        return S - launchpad.market(token).virtualToken;
    }

    function test_abort_revertsBeforeTheTimeout() public {
        vm.warp(block.timestamp + timeout - 1);
        vm.expectRevert(CurveLaunchpad.NotAbortable.selector);
        launchpad.abortGraduation(token);
    }

    function test_abort_afterTheTimeout_reopensSells() public {
        vm.warp(block.timestamp + timeout);
        vm.expectEmit(address(launchpad));
        emit CurveLaunchpad.GraduationAborted(token);
        launchpad.abortGraduation(token);
        assertEq(uint8(_state()), uint8(CurveLaunchpad.State.Aborted));
        assertGt(_sell(alice, token, 1 ether), 0);

        vm.expectRevert(CurveLaunchpad.NotAbortable.selector);
        launchpad.abortGraduation(token);
    }

    function test_sell_afterTheTimeout_abortsInline() public {
        vm.warp(block.timestamp + timeout);
        vm.startPrank(alice);
        CurveToken(token).approve(address(launchpad), 1 ether);
        vm.expectEmit(address(launchpad));
        emit CurveLaunchpad.GraduationAborted(token);
        assertGt(launchpad.sell(token, 1 ether, 0, block.timestamp), 0);
        vm.stopPrank();
        assertEq(uint8(_state()), uint8(CurveLaunchpad.State.Aborted));
    }

    function test_abort_isSticky_aResoldOutCurveStillSells() public {
        vm.warp(block.timestamp + timeout);
        _sell(alice, token, 1 ether);
        _fund(alice, 100 ether);
        vm.expectEmit(address(launchpad));
        emit CurveLaunchpad.GraduationReady(token);
        vm.prank(alice);
        launchpad.buy(token, 100 ether, 0, block.timestamp);
        assertEq(_sold(), C);
        assertEq(uint8(_state()), uint8(CurveLaunchpad.State.Aborted), "re-selling out doesn't re-block sells");
        assertGt(_sell(bob, token, 1 ether), 0);
    }

    function test_graduate_fromAborted_onlyWhenSoldOut() public {
        vm.warp(block.timestamp + timeout);
        _sell(alice, token, 1 ether);
        vm.expectRevert(CurveLaunchpad.NotReady.selector);
        launchpad.graduate(token);

        _sellOut(alice, token);
        address pool = launchpad.graduate(token);
        assertEq(launchpad.poolOf(token), pool);
        assertEq(uint8(_state()), uint8(CurveLaunchpad.State.Graduated));
    }

    function test_abort_revertsForTradingOrGraduatedMarkets() public {
        address trading = _launch(creator, 0, 0.05 ether);
        vm.warp(block.timestamp + timeout);
        vm.expectRevert(CurveLaunchpad.NotAbortable.selector);
        launchpad.abortGraduation(trading);

        launchpad.graduate(token);
        vm.expectRevert(CurveLaunchpad.NotAbortable.selector);
        launchpad.abortGraduation(token);
    }

    function test_abort_worksWhilePaused() public {
        vm.prank(guardian);
        launchpad.pause();
        vm.warp(block.timestamp + timeout);
        launchpad.abortGraduation(token);
        assertGt(_sell(alice, token, 1 ether), 0);
    }

    function test_held_staysConsistentAcrossTheAbort() public {
        vm.warp(block.timestamp + timeout);
        _sell(alice, token, CurveToken(token).balanceOf(alice));
        _sell(bob, token, 10_000 ether);
        assertEq(launchpad.held(token, alice), 0);
        assertEq(launchpad.held(token, alice) + launchpad.held(token, bob), _sold());
        assertEq(launchpad.held(token, bob), CurveToken(token).balanceOf(bob));
        assertEq(weth.balanceOf(address(launchpad)), launchpad.totalRealQuote());
    }
}
