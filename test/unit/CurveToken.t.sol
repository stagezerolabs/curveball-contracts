// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {CurveToken} from "../../contracts/CurveToken.sol";

/// @dev The test contract plays the launchpad: it deploys the implementation, so it is `launchpad`.
contract CurveTokenTest is Test {
    uint256 constant SUPPLY = 1_000_000 ether;
    uint256 constant RESERVE = 40_000 ether;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    CurveToken implementation;
    CurveToken token;
    address reserve = makeAddr("reserve");
    address alice;
    uint256 aliceKey;
    address bob = makeAddr("bob");

    function setUp() public {
        (alice, aliceKey) = makeAddrAndKey("alice");
        implementation = new CurveToken();
        token = _clone("Curve Meme", "MEME", bytes32("one"));
        token.transfer(alice, 100 ether);
    }

    function _clone(string memory name_, string memory symbol_, bytes32 salt) internal returns (CurveToken t) {
        t = CurveToken(Clones.cloneDeterministic(address(implementation), salt));
        t.initialize(name_, symbol_, SUPPLY, reserve, RESERVE);
    }

    function _permit(CurveToken t, address spender, uint256 value) internal {
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                t.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                        alice,
                        spender,
                        value,
                        t.nonces(alice),
                        deadline
                    )
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(aliceKey, digest);
        t.permit(alice, spender, value, deadline, v, r, s);
    }

    // ---------------------------------------------------------------- initialize

    function test_initialize_mintsSupplyAndReserve() public view {
        assertEq(token.name(), "Curve Meme");
        assertEq(token.symbol(), "MEME");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(reserve), RESERVE);
        assertEq(token.balanceOf(address(this)), SUPPLY - RESERVE - 100 ether);
        assertEq(token.launchpad(), address(this));
        assertFalse(token.unlocked());
    }

    function test_initialize_onlyOnce() public {
        vm.expectRevert(CurveToken.AlreadyInitialized.selector);
        token.initialize("Again", "AGN", SUPPLY, reserve, 0);
    }

    function test_initialize_onlyLaunchpad() public {
        CurveToken t = CurveToken(Clones.clone(address(implementation)));
        vm.prank(bob);
        vm.expectRevert(CurveToken.NotLaunchpad.selector);
        t.initialize("Meme", "MEME", SUPPLY, reserve, 0);
    }

    function test_initialize_implementationIsSealed() public {
        vm.expectRevert(CurveToken.AlreadyInitialized.selector);
        implementation.initialize("Impl", "IMPL", SUPPLY, reserve, 0);
    }

    function test_initialize_rejectsBadMetadata() public {
        address t = Clones.clone(address(implementation));
        vm.expectRevert(CurveToken.InvalidMetadata.selector);
        CurveToken(t).initialize("", "MEME", SUPPLY, reserve, 0);
        vm.expectRevert(CurveToken.InvalidMetadata.selector);
        CurveToken(t).initialize("Meme", "", SUPPLY, reserve, 0);
        vm.expectRevert(CurveToken.InvalidMetadata.selector);
        CurveToken(t).initialize(string(new bytes(65)), "MEME", SUPPLY, reserve, 0);
        vm.expectRevert(CurveToken.InvalidMetadata.selector);
        CurveToken(t).initialize("Meme", string(new bytes(13)), SUPPLY, reserve, 0);
    }

    // ---------------------------------------------------------------- transfer lock

    function test_lock_blocksTransfersBetweenHolders() public {
        vm.prank(alice);
        vm.expectRevert(CurveToken.Locked.selector);
        token.transfer(bob, 1 ether);
    }

    function test_lock_blocksReserveUntilUnlock() public {
        vm.prank(reserve);
        vm.expectRevert(CurveToken.Locked.selector);
        token.transfer(alice, 1 ether);
    }

    function test_lock_blocksApproveThenTransferFrom() public {
        vm.prank(alice);
        token.approve(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert(CurveToken.Locked.selector);
        token.transferFrom(alice, bob, 1 ether);
    }

    function test_lock_blocksPermitThenTransferFrom() public {
        _permit(token, bob, 1 ether);
        assertEq(token.allowance(alice, bob), 1 ether);
        vm.prank(bob);
        vm.expectRevert(CurveToken.Locked.selector);
        token.transferFrom(alice, bob, 1 ether);
    }

    function test_lock_blocksBurnByHolder() public {
        vm.prank(alice);
        vm.expectRevert(CurveToken.Locked.selector);
        token.burn(1 ether);
    }

    function test_lock_allowsTransfersToAndFromLaunchpad() public {
        vm.prank(alice);
        token.approve(address(this), 10 ether);
        token.transferFrom(alice, address(this), 10 ether);
        assertEq(token.balanceOf(alice), 90 ether);
        token.transfer(bob, 5 ether);
        assertEq(token.balanceOf(bob), 5 ether);
    }

    // ---------------------------------------------------------------- unlock and burn

    function test_unlock_onlyLaunchpad() public {
        vm.prank(alice);
        vm.expectRevert(CurveToken.NotLaunchpad.selector);
        token.unlock();
    }

    function test_unlock_freesTransfersAndBurns() public {
        vm.expectEmit(address(token));
        emit CurveToken.Unlocked();
        token.unlock();
        assertTrue(token.unlocked());
        vm.startPrank(alice);
        token.transfer(bob, 1 ether);
        token.burn(9 ether);
        vm.stopPrank();
        assertEq(token.balanceOf(bob), 1 ether);
        assertEq(token.totalSupply(), SUPPLY - 9 ether);
    }

    // ---------------------------------------------------------------- permit and Permit2

    function test_permit_domainIsPerClone() public {
        CurveToken other = _clone("Curve Meme", "MEME", bytes32("two"));
        assertTrue(token.DOMAIN_SEPARATOR() != other.DOMAIN_SEPARATOR());
        _permit(other, bob, 3 ether);
        assertEq(other.allowance(alice, bob), 3 ether);
        assertEq(token.allowance(alice, bob), 0);
    }

    function test_permit2_hasNoInfiniteAllowance() public view {
        assertEq(token.allowance(alice, PERMIT2), 0);
    }
}
