// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Fixture} from "../Fixture.sol";
import {CurveLaunchpad} from "../../contracts/CurveLaunchpad.sol";
import {CurveToken} from "../../contracts/CurveToken.sol";
import {MockWETH} from "../mocks/MockWETH.sol";

contract LaunchpadRescueTest is Fixture {
    address token;

    function setUp() public override {
        super.setUp();
        token = _launch(creator, 400, 0);
        _buy(alice, token, 2 ether);
    }

    function test_rescue_wethIsLimitedToTheSurplus() public {
        weth.mint(address(launchpad), 1 ether);
        vm.startPrank(owner);
        vm.expectRevert(CurveLaunchpad.NotRescuable.selector);
        launchpad.rescue(address(weth), owner, 1 ether + 1);
        launchpad.rescue(address(weth), owner, 1 ether);
        vm.stopPrank();
        assertEq(weth.balanceOf(owner), 1 ether);
        assertEq(weth.balanceOf(address(launchpad)), launchpad.totalRealQuote());
    }

    function test_rescue_aTokenOnItsCurveReverts_evenAfterAnAbort() public {
        vm.prank(owner);
        vm.expectRevert(CurveLaunchpad.NotRescuable.selector);
        launchpad.rescue(token, owner, 1);

        _sellOut(bob, token);
        vm.warp(block.timestamp + launchpad.GRADUATION_TIMEOUT());
        launchpad.abortGraduation(token);
        vm.prank(owner);
        vm.expectRevert(CurveLaunchpad.NotRescuable.selector);
        launchpad.rescue(token, owner, 1);
    }

    function test_rescue_aGraduatedTokenDonatedLater() public {
        _sellOut(bob, token);
        launchpad.graduate(token);
        vm.prank(bob);
        CurveToken(token).transfer(address(launchpad), 5 ether);
        vm.prank(owner);
        launchpad.rescue(token, owner, 5 ether);
        assertEq(CurveToken(token).balanceOf(owner), 5 ether);
    }

    function test_rescue_aStrayToken() public {
        MockWETH stray = new MockWETH();
        stray.mint(address(launchpad), 7 ether);
        vm.prank(owner);
        launchpad.rescue(address(stray), owner, 7 ether);
        assertEq(stray.balanceOf(owner), 7 ether);
    }

    function test_rescue_skimmedPoolWeth() public {
        _sellOut(bob, token);
        address pool = icarus.createPool(token, address(weth), false);
        weth.mint(pool, 3 ether);
        launchpad.graduate(token);
        vm.prank(owner);
        launchpad.rescue(address(weth), treasury, 3 ether);
        assertEq(weth.balanceOf(treasury), LAUNCH_FEE + 3 ether);
        assertEq(weth.balanceOf(address(launchpad)), 0);
    }

    function test_rescue_onlyOwner() public {
        weth.mint(address(launchpad), 1 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        launchpad.rescue(address(weth), alice, 1 ether);
    }
}
