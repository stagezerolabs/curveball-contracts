// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Fixture} from "../Fixture.sol";
import {CurveToken} from "../../contracts/CurveToken.sol";
import {CurveLaunchpad} from "../../contracts/CurveLaunchpad.sol";

/// @dev Regression for audit finding (Low): "Token transfers to the launchpad while the market is
///      trading or aborted can strand tokens that graduation later burns and the owner cannot
///      rescue." Fix: while locked, the launchpad must be the caller for a transfer to its own
///      address; a holder calling transfer/transferFrom directly reverts `Locked`, while protocol
///      flows (buy, sell settlement, graduation burn) keep `msg.sender == launchpad`.
contract CurveTokenTransferLockTest is Fixture {
    address token;

    function _launchedToken() internal returns (address t) {
        _fund(creator, LAUNCH_FEE + 0.2 ether);
        vm.prank(creator);
        (t,) = launchpad.launch(_meta(), 0, 0, 0.2 ether, 0);
    }

    function test_manualTransferToLaunchpad_revertsWhileLocked() public {
        token = _launchedToken();
        uint256 bought = _buy(bob, token, 1 ether);
        uint256 launchpadBefore = CurveToken(token).balanceOf(address(launchpad));

        vm.prank(bob);
        vm.expectRevert(CurveToken.Locked.selector);
        CurveToken(token).transfer(address(launchpad), 1 ether);

        // approve + transferFrom by the holder is blocked too.
        vm.startPrank(bob);
        CurveToken(token).approve(address(launchpad), type(uint256).max);
        vm.expectRevert(CurveToken.Locked.selector);
        CurveToken(token).transferFrom(bob, address(launchpad), 1 ether);
        vm.stopPrank();
        assertEq(CurveToken(token).balanceOf(bob), bought, "all of bob's tokens stayed with bob");
        assertEq(CurveToken(token).balanceOf(address(launchpad)), launchpadBefore, "nothing reached the launchpad");
    }

    function test_manualTransferToLaunchpad_stillBlockedWhenAborted() public {
        token = _launchedToken();
        _sellOut(bob, token);
        vm.warp(block.timestamp + launchpad.GRADUATION_TIMEOUT());
        vm.prank(bob);
        launchpad.abortGraduation(token);
        assertEq(uint8(launchpad.market(token).state), uint8(CurveLaunchpad.State.Aborted));

        vm.prank(bob);
        vm.expectRevert(CurveToken.Locked.selector);
        CurveToken(token).transfer(address(launchpad), 1 ether);
    }

    function test_protocolFlows_sellAndBuy_stillWork() public {
        token = _launchedToken();
        uint256 bought = _buy(bob, token, 1 ether);
        assertGt(_sell(bob, token, bought / 2), 0, "sell settlement has msg.sender == launchpad");
        assertGt(_buy(alice, token, 1 ether), 0, "buys still work");
    }

    function test_manualTransferToLaunchpad_isFreeAfterGraduation() public {
        token = _launchedToken();
        _sellOut(bob, token);
        launchpad.graduate(token);
        vm.prank(bob);
        CurveToken(token).transfer(address(launchpad), 1 ether);
        assertEq(CurveToken(token).balanceOf(address(launchpad)), 1 ether, "post-graduation transfers are free");
    }
}
