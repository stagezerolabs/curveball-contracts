// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {CurveHolderReserve} from "../../contracts/CurveHolderReserve.sol";
import {CurveToken} from "../../contracts/CurveToken.sol";
import {MockLaunchpad} from "../mocks/MockLaunchpad.sol";

contract HolderReserveTest is Test {
    uint256 constant SUPPLY = 1_000_000 ether;
    uint256 constant CURVE = 800_000 ether;
    uint256 constant RESERVE = 40_000 ether;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    MockLaunchpad launchpad = new MockLaunchpad(makeAddr("treasury"));
    CurveHolderReserve reserve;
    CurveToken token;

    function setUp() public {
        reserve = new CurveHolderReserve(address(launchpad));
        token = launchpad.createToken(SUPPLY, address(reserve), RESERVE);
        vm.prank(address(launchpad));
        reserve.register(address(token), RESERVE);
    }

    function _graduate() internal {
        launchpad.unlock(token);
        launchpad.setPool(address(token), makeAddr("pool"));
    }

    function test_register_onlyLaunchpad_once_andBacked() public {
        assertEq(reserve.reserveOf(address(token)), RESERVE);

        vm.expectRevert(CurveHolderReserve.NotLaunchpad.selector);
        reserve.register(address(token), RESERVE);

        vm.startPrank(address(launchpad));
        vm.expectRevert(CurveHolderReserve.AlreadyRegistered.selector);
        reserve.register(address(token), RESERVE);

        CurveToken unbacked = launchpad.createToken(SUPPLY, address(reserve), RESERVE - 1);
        vm.expectRevert(CurveHolderReserve.Unbacked.selector);
        reserve.register(address(unbacked), RESERVE);

        vm.expectRevert(CurveHolderReserve.InvalidAmount.selector);
        reserve.register(address(unbacked), 0);
        vm.stopPrank();
    }

    function test_claim_revertsBeforeGraduation() public {
        launchpad.setHeld(address(token), alice, CURVE);
        assertEq(reserve.claimable(address(token), alice), 0);
        vm.prank(alice);
        vm.expectRevert(CurveHolderReserve.NotGraduated.selector);
        reserve.claim(address(token));
    }

    function test_claim_paysProRataOnce() public {
        launchpad.setHeld(address(token), alice, CURVE / 4);
        _graduate();
        assertEq(reserve.claimable(address(token), alice), RESERVE / 4);

        vm.prank(alice);
        assertEq(reserve.claim(address(token)), RESERVE / 4);
        assertEq(token.balanceOf(alice), RESERVE / 4);
        assertEq(reserve.claimable(address(token), alice), 0);

        vm.prank(alice);
        vm.expectRevert(CurveHolderReserve.AlreadyClaimed.selector);
        reserve.claim(address(token));
    }

    function test_claim_zeroHeldGetsNothing() public {
        _graduate();
        assertEq(reserve.claimable(address(token), bob), 0);
        vm.prank(bob);
        vm.expectRevert(CurveHolderReserve.NothingToClaim.selector);
        reserve.claim(address(token));
    }

    function testFuzz_claims_neverExceedReserve(uint256 seed, uint8 holders) public {
        holders = uint8(bound(holders, 1, 20));
        uint256 left = CURVE;
        address[] memory accounts = new address[](holders);
        for (uint256 i = 0; i < holders; i++) {
            accounts[i] = address(uint160(0x1000 + i));
            uint256 amount = i == holders - 1 ? left : bound(uint256(keccak256(abi.encode(seed, i))), 0, left);
            launchpad.setHeld(address(token), accounts[i], amount);
            left -= amount;
        }
        _graduate();

        uint256 paid;
        for (uint256 i = 0; i < holders; i++) {
            if (reserve.claimable(address(token), accounts[i]) == 0) continue;
            vm.prank(accounts[i]);
            paid += reserve.claim(address(token));
        }
        assertLe(paid, RESERVE);
        assertGe(paid + holders, RESERVE, "rounding loses at most 1 wei per holder");
        assertEq(token.balanceOf(address(reserve)), RESERVE - paid);
    }
}
