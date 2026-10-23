// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {CurveLaunchpad} from "../../contracts/CurveLaunchpad.sol";
import {CurveToken} from "../../contracts/CurveToken.sol";
import {CurveMath} from "../../contracts/libraries/CurveMath.sol";

contract LaunchpadAdminTest is Test {
    address owner = makeAddr("owner");
    address guardian = makeAddr("guardian");
    address stranger = makeAddr("stranger");

    CurveLaunchpad launchpad;

    function _config() internal returns (CurveLaunchpad.Config memory c) {
        c.owner = owner;
        c.guardian = guardian;
        c.treasury = makeAddr("treasury");
        c.quoteToken = makeAddr("weth");
        c.icarusFactory = makeAddr("icarus");
        c.escrow = makeAddr("escrow");
        c.locker = makeAddr("locker");
        c.reserve = makeAddr("reserve");
        c.launchFee = 0.001 ether;
        c.graduationTarget = 4 ether;
        c.fees = CurveLaunchpad.FeeDefaults(75, 5_000, 2_500, 50);
    }

    function setUp() public {
        launchpad = new CurveLaunchpad(_config());
    }

    function test_constructor_setsImmutablesAndSealedImplementation() public {
        assertEq(launchpad.owner(), owner);
        assertEq(launchpad.guardian(), guardian);
        assertEq(launchpad.locker(), makeAddr("locker"));
        assertEq(launchpad.graduationTarget(), 4 ether);
        assertEq(launchpad.curveSupply(), 800_000 ether);
        assertEq(launchpad.MAX_RESERVE_TOKENS(), 40_000 ether);
        assertEq(launchpad.MAX_RESERVE_BPS(), 400);
        CurveToken implementation = CurveToken(launchpad.tokenImplementation());
        assertEq(implementation.launchpad(), address(launchpad));
        vm.prank(address(launchpad));
        vm.expectRevert(CurveToken.AlreadyInitialized.selector);
        implementation.initialize("x", "x", 1, address(0), 0);
    }

    function test_constructor_rejectsBadConfig() public {
        CurveLaunchpad.Config memory c = _config();
        c.escrow = address(0);
        vm.expectRevert(CurveLaunchpad.InvalidConfig.selector);
        new CurveLaunchpad(c);

        c = _config();
        c.guardian = address(0);
        vm.expectRevert(CurveLaunchpad.InvalidConfig.selector);
        new CurveLaunchpad(c);

        c = _config();
        c.launchFee = 0.01 ether + 1;
        vm.expectRevert(CurveLaunchpad.InvalidConfig.selector);
        new CurveLaunchpad(c);

        c = _config();
        c.fees.feeBps = 201;
        vm.expectRevert(CurveLaunchpad.InvalidConfig.selector);
        new CurveLaunchpad(c);
    }

    function test_setFeeDefaults_bounds() public {
        vm.startPrank(owner);
        launchpad.setFeeDefaults(CurveLaunchpad.FeeDefaults(200, 6_000, 4_000, 50));
        (uint16 fee, uint16 creatorShare, uint16 buybackShare, uint16 taxCap) = launchpad.feeDefaults();
        assertEq(abi.encode(fee, creatorShare, buybackShare, taxCap), abi.encode(200, 6_000, 4_000, 50));

        vm.expectRevert(CurveLaunchpad.InvalidConfig.selector);
        launchpad.setFeeDefaults(CurveLaunchpad.FeeDefaults(201, 5_000, 2_500, 50));
        vm.expectRevert(CurveLaunchpad.InvalidConfig.selector);
        launchpad.setFeeDefaults(CurveLaunchpad.FeeDefaults(75, 5_000, 2_500, 51));
        // The escrow's split underflows when the creator and buyback shares exceed the whole fee.
        vm.expectRevert(CurveLaunchpad.InvalidConfig.selector);
        launchpad.setFeeDefaults(CurveLaunchpad.FeeDefaults(75, 6_000, 4_001, 50));
        vm.stopPrank();
    }

    function test_setGraduationTarget_bounds() public {
        vm.startPrank(owner);
        launchpad.setGraduationTarget(0.01 ether);
        assertEq(launchpad.graduationTarget(), 0.01 ether);

        vm.expectRevert(CurveLaunchpad.InvalidConfig.selector);
        launchpad.setGraduationTarget(0.01 ether - 4);
        vm.expectRevert(CurveMath.InvalidTarget.selector);
        launchpad.setGraduationTarget(4 ether + 1);
        vm.expectRevert(CurveMath.InvalidTarget.selector);
        launchpad.setGraduationTarget(type(uint128).max);
        vm.stopPrank();
    }

    function test_ownerFunctions_revertForOthers() public {
        bytes memory unauthorized = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger);
        vm.startPrank(stranger);
        vm.expectRevert(unauthorized);
        launchpad.setFeeDefaults(CurveLaunchpad.FeeDefaults(75, 5_000, 2_500, 50));
        vm.expectRevert(unauthorized);
        launchpad.setGraduationTarget(8 ether);
        vm.expectRevert(unauthorized);
        launchpad.setGuardian(stranger);
        vm.expectRevert(unauthorized);
        launchpad.unpause();
        vm.stopPrank();
    }

    function test_guardian_canPauseButNotUnpause() public {
        vm.prank(stranger);
        vm.expectRevert(CurveLaunchpad.NotGuardian.selector);
        launchpad.pause();

        vm.prank(guardian);
        launchpad.pause();
        assertTrue(launchpad.paused());

        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        launchpad.unpause();

        vm.prank(owner);
        launchpad.unpause();
        assertFalse(launchpad.paused());
    }

    function test_setGuardian_rotates() public {
        address next = makeAddr("next");
        vm.prank(owner);
        launchpad.setGuardian(next);
        vm.prank(guardian);
        vm.expectRevert(CurveLaunchpad.NotGuardian.selector);
        launchpad.pause();
        vm.prank(next);
        launchpad.pause();

        vm.prank(owner);
        vm.expectRevert(CurveLaunchpad.InvalidConfig.selector);
        launchpad.setGuardian(address(0));
    }

    function test_ownership_isTwoStep_andCannotBeRenounced() public {
        address next = makeAddr("next");
        vm.prank(owner);
        launchpad.transferOwnership(next);
        assertEq(launchpad.owner(), owner);
        vm.prank(next);
        launchpad.acceptOwnership();
        assertEq(launchpad.owner(), next);

        vm.prank(next);
        vm.expectRevert(CurveLaunchpad.RenounceDisabled.selector);
        launchpad.renounceOwnership();
    }
}
