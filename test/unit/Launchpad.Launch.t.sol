// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Fixture} from "../Fixture.sol";
import {CurveLaunchpad} from "../../contracts/CurveLaunchpad.sol";
import {CurveToken} from "../../contracts/CurveToken.sol";

contract LaunchpadLaunchTest is Fixture {
    uint256 constant S = 1_000_000 ether;

    function _market(address token) internal view returns (CurveLaunchpad.Market memory) {
        return launchpad.market(token);
    }

    function test_launch_deploysAtThePredictedAddress_andSnapshotsTheMarket() public {
        address predicted = launchpad.predictToken(creator);
        _fund(creator, LAUNCH_FEE);
        vm.expectEmit(address(launchpad));
        emit CurveLaunchpad.LaunchCreated(
            predicted, creator, "Curve Meme", "MEME", "ipfs://meme", 75, 5_000, 2_500, 50, 40_000 ether
        );
        vm.prank(creator);
        (address token, uint256 tokensOut) = launchpad.launch(_meta(), 50, 400, 0, 0);

        assertEq(token, predicted);
        assertEq(tokensOut, 0);
        assertEq(launchpad.launchNonce(creator), 1);
        assertTrue(launchpad.predictToken(creator) != token);

        CurveLaunchpad.Market memory m = _market(token);
        assertEq(m.creator, creator);
        assertEq(abi.encode(m.feeBps, m.creatorShareBps, m.buybackShareBps, m.taxBps), abi.encode(75, 5_000, 2_500, 50));
        assertEq(uint8(m.state), uint8(CurveLaunchpad.State.Trading));
        assertEq(m.virtualToken, S);
        assertEq(m.initialVirtualQuote, 1 ether, "vQ0 = target * (S - C) / C");
        assertEq(m.virtualQuote, m.initialVirtualQuote);
        assertEq(m.reserveTokens, 40_000 ether);

        assertEq(CurveToken(token).name(), "Curve Meme");
        assertEq(CurveToken(token).totalSupply(), S);
        assertEq(CurveToken(token).balanceOf(address(launchpad)), S - 40_000 ether);
        assertEq(CurveToken(token).balanceOf(address(reserve)), 40_000 ether);
        assertEq(reserve.reserveOf(token), 40_000 ether);
        assertEq(weth.balanceOf(treasury), LAUNCH_FEE);
    }

    function test_launch_withoutReserve_registersNothing() public {
        address token = _launch(creator, 0, 0);
        assertEq(reserve.reserveOf(token), 0);
        assertEq(CurveToken(token).balanceOf(address(launchpad)), S);
    }

    function test_launch_rejectsReserveAboveTheMaximum() public {
        _fund(creator, LAUNCH_FEE);
        vm.prank(creator);
        vm.expectRevert(CurveLaunchpad.InvalidLaunch.selector);
        launchpad.launch(_meta(), 0, 401, 0, 0);
    }

    function test_launch_rejectsTaxAboveTheCap() public {
        _fund(creator, LAUNCH_FEE);
        vm.prank(creator);
        vm.expectRevert(CurveLaunchpad.InvalidLaunch.selector);
        launchpad.launch(_meta(), 51, 0, 0, 0);
    }

    function test_launch_enforcesMetadataBounds() public {
        _fund(creator, LAUNCH_FEE);
        vm.startPrank(creator);
        vm.expectRevert(CurveLaunchpad.InvalidLaunch.selector);
        launchpad.launch(CurveLaunchpad.Metadata("Curve Meme", "MEME", ""), 0, 0, 0, 0);
        vm.expectRevert(CurveLaunchpad.InvalidLaunch.selector);
        launchpad.launch(CurveLaunchpad.Metadata("Curve Meme", "MEME", string(new bytes(2049))), 0, 0, 0, 0);
        vm.expectRevert(CurveToken.InvalidMetadata.selector);
        launchpad.launch(CurveLaunchpad.Metadata("", "MEME", "ipfs://meme"), 0, 0, 0, 0);
        vm.expectRevert(CurveToken.InvalidMetadata.selector);
        launchpad.launch(CurveLaunchpad.Metadata("Curve Meme", "THIRTEENCHARS", "ipfs://meme"), 0, 0, 0, 0);
        launchpad.launch(CurveLaunchpad.Metadata("Curve Meme", "MEME", string(new bytes(2048))), 0, 0, 0, 0);
        vm.stopPrank();
    }

    function test_launch_requiresTheLaunchFee() public {
        vm.prank(creator);
        vm.expectRevert();
        launchpad.launch(_meta(), 0, 0, 0, 0);
    }

    function test_launch_firstBuyGoesToTheCreator() public {
        address token = _launch(creator, 400, 0.1 ether);
        uint256 bought = CurveToken(token).balanceOf(creator);
        assertGt(bought, 0);
        assertEq(launchpad.held(token, creator), bought);
        assertLe(weth.balanceOf(creator), 2, "spends the first-buy budget up to rounding dust");
        assertEq(_market(token).realQuote, launchpad.totalRealQuote());
    }

    function test_launch_firstBuyRespectsMinOut() public {
        _fund(creator, LAUNCH_FEE + 0.1 ether);
        vm.prank(creator);
        vm.expectRevert(CurveLaunchpad.Slippage.selector);
        launchpad.launch(_meta(), 0, 0, 0.1 ether, 1_000_000 ether);
    }

    function test_launch_rejectsMinOutWithoutAFirstBuy() public {
        _fund(creator, LAUNCH_FEE);
        vm.prank(creator);
        vm.expectRevert(CurveLaunchpad.InvalidLaunch.selector);
        launchpad.launch(_meta(), 0, 0, 0, 1);
    }

    function test_launch_revertsWhilePaused() public {
        vm.prank(guardian);
        launchpad.pause();
        _fund(creator, LAUNCH_FEE);
        vm.prank(creator);
        vm.expectRevert(CurveLaunchpad.EnforcedPause.selector);
        launchpad.launch(_meta(), 0, 0, 0, 0);
    }

    function test_adminChangesAfterLaunch_dontReachExistingMarkets() public {
        address token = _launch(creator, 0, 0);
        CurveLaunchpad.Market memory before = _market(token);

        vm.startPrank(owner);
        launchpad.setFeeDefaults(CurveLaunchpad.FeeDefaults(200, 1_000, 1_000, 10));
        launchpad.setGraduationTarget(8 ether);
        vm.stopPrank();

        CurveLaunchpad.Market memory afterwards = _market(token);
        assertEq(abi.encode(afterwards), abi.encode(before));
        (address policyCreator, uint16 creatorShare, uint16 buybackShare) = launchpad.feePolicy(token);
        assertEq(abi.encode(policyCreator, creatorShare, buybackShare), abi.encode(creator, 5_000, 2_500));

        address next = _launch(creator, 0, 0);
        assertEq(_market(next).initialVirtualQuote, 2 ether);
        assertEq(_market(next).feeBps, 200);
    }
}
