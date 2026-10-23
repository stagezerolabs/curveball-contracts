// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {CurveFeeEscrow} from "../../contracts/CurveFeeEscrow.sol";
import {CurveToken} from "../../contracts/CurveToken.sol";
import {IIcarusPool} from "../../contracts/interfaces/IIcarus.sol";
import {MockIcarusFactory, MockIcarusPool} from "../mocks/MockIcarus.sol";
import {MockLaunchpad} from "../mocks/MockLaunchpad.sol";
import {MockWETH} from "../mocks/MockWETH.sol";

contract FeeEscrowTest is Test {
    uint256 constant SUPPLY = 1_000_000 ether;
    uint16 constant CREATOR_SHARE = 5_000;
    uint16 constant BUYBACK_SHARE = 2_000;

    address treasury = makeAddr("treasury");
    address creator = makeAddr("creator");
    address locker = makeAddr("locker");
    address owner = makeAddr("owner");
    address attacker = makeAddr("attacker");

    MockWETH weth = new MockWETH();
    MockIcarusFactory factory = new MockIcarusFactory();
    MockLaunchpad launchpad = new MockLaunchpad(treasury);
    CurveFeeEscrow escrow;
    CurveToken token;
    MockIcarusPool pool;

    function setUp() public {
        escrow = new CurveFeeEscrow(address(launchpad), address(weth), address(factory), owner);
        launchpad.setLocker(locker);
        token = launchpad.createToken(SUPPLY, address(0), 0);
        launchpad.setFeePolicy(address(token), creator, CREATOR_SHARE, BUYBACK_SHARE);
    }

    // ---------------------------------------------------------------- distribute

    function _distribute(uint256 fee, uint256 tax) internal {
        weth.mint(address(escrow), fee + tax);
        vm.prank(address(launchpad));
        escrow.distribute(address(token), address(weth), fee, tax);
    }

    function testFuzz_distribute_splitsExactly(uint128 fee, uint128 tax, uint16 creatorShare, uint16 buybackShare)
        public
    {
        creatorShare = uint16(bound(creatorShare, 0, 10_000));
        buybackShare = uint16(bound(buybackShare, 0, 10_000 - creatorShare));
        launchpad.setFeePolicy(address(token), creator, creatorShare, buybackShare);
        _distribute(fee, tax);

        uint256 toCreator = escrow.claimable(creator, address(weth));
        uint256 toTreasury = escrow.claimable(treasury, address(weth));
        uint256 toBuyback = escrow.buybackBalance(address(token));
        assertEq(toCreator + toTreasury + toBuyback, uint256(fee) + tax);
        assertEq(toCreator, uint256(fee) * creatorShare / 10_000 + tax);
        assertEq(toBuyback, uint256(fee) * buybackShare / 10_000);
        assertEq(escrow.totalOwed(address(weth)), uint256(fee) + tax);
    }

    function test_distribute_revertsWhenUnbacked() public {
        vm.prank(address(launchpad));
        vm.expectRevert(CurveFeeEscrow.Unbacked.selector);
        escrow.distribute(address(token), address(weth), 1 ether, 0);

        // A balance that already backs earlier credits can't back a new one.
        _distribute(1 ether, 0);
        vm.prank(address(launchpad));
        vm.expectRevert(CurveFeeEscrow.Unbacked.selector);
        escrow.distribute(address(token), address(weth), 1, 0);
    }

    function test_distribute_onlyLaunchpadOrItsLocker() public {
        weth.mint(address(escrow), 2 ether);
        vm.prank(attacker);
        vm.expectRevert(CurveFeeEscrow.Unauthorized.selector);
        escrow.distribute(address(token), address(weth), 1 ether, 0);

        vm.prank(locker);
        escrow.distribute(address(token), address(weth), 1 ether, 0);
        vm.prank(address(launchpad));
        escrow.distribute(address(token), address(weth), 1 ether, 0);
        assertEq(escrow.totalOwed(address(weth)), 2 ether);
    }

    function test_distribute_revertsForForeignAsset() public {
        MockWETH other = new MockWETH();
        other.mint(address(escrow), 1 ether);
        vm.prank(address(launchpad));
        vm.expectRevert(CurveFeeEscrow.InvalidAsset.selector);
        escrow.distribute(address(token), address(other), 1 ether, 0);
    }

    function test_distribute_memeAsset_burnsBuybackShare() public {
        launchpad.unlock(token);
        launchpad.send(token, address(escrow), 100 ether);
        vm.prank(locker);
        escrow.distribute(address(token), address(token), 100 ether, 0);

        assertEq(token.totalSupply(), SUPPLY - 20 ether);
        assertEq(token.balanceOf(address(escrow)), 80 ether);
        assertEq(escrow.claimable(creator, address(token)), 50 ether);
        assertEq(escrow.claimable(treasury, address(token)), 30 ether);
        assertEq(escrow.totalOwed(address(token)), 80 ether);
        assertEq(escrow.buybackBalance(address(token)), 0);
    }

    // ---------------------------------------------------------------- claim

    function test_claim_paysOnceThenZero() public {
        _distribute(10 ether, 1 ether);
        vm.prank(creator);
        assertEq(escrow.claim(address(weth)), 6 ether);
        assertEq(weth.balanceOf(creator), 6 ether);
        vm.prank(creator);
        assertEq(escrow.claim(address(weth)), 0);
        assertEq(weth.balanceOf(creator), 6 ether);

        vm.prank(treasury);
        escrow.claim(address(weth));
        assertEq(weth.balanceOf(treasury), 3 ether);
        assertEq(escrow.totalOwed(address(weth)), 2 ether, "only the buyback balance remains");
    }

    // ---------------------------------------------------------------- buyback

    /// @dev Graduates `token` into a pool at 160k tokens / 10 WETH, records `observationWindows` TWAP
    ///      windows, and accrues `buybackFee` of which 20% goes to the buyback balance.
    function _graduate(uint256 observationWindows, uint256 buybackFee) internal {
        launchpad.unlock(token);
        pool = MockIcarusPool(factory.createPool(address(token), address(weth), false));
        launchpad.send(token, address(pool), 160_000 ether);
        weth.mint(address(pool), 10 ether);
        pool.mint(address(this));
        launchpad.setPool(address(token), address(pool));
        for (uint256 i = 0; i < observationWindows; i++) {
            vm.warp(block.timestamp + 1801);
            pool.sync();
        }
        _distribute(buybackFee, 0);
    }

    function _frontRun(uint256 wethIn) internal {
        uint256 out = pool.getAmountOut(wethIn, address(weth));
        weth.mint(address(pool), wethIn);
        (uint256 out0, uint256 out1) = pool.token0() == address(token) ? (out, uint256(0)) : (uint256(0), out);
        pool.swap(out0, out1, attacker, "");
    }

    function _expectSkip(CurveFeeEscrow.SkipReason reason) internal {
        uint256 balance = escrow.buybackBalance(address(token));
        vm.expectEmit(address(escrow));
        emit CurveFeeEscrow.BuybackSkipped(address(token), reason);
        assertEq(escrow.buyback(address(token)), 0);
        assertEq(escrow.buybackBalance(address(token)), balance);
        assertEq(escrow.lastBuyback(address(token)), 0, "a skip must not start the interval");
    }

    function test_buyback_revertsBeforeGraduation() public {
        _distribute(4 ether, 0);
        vm.expectRevert(CurveFeeEscrow.NotGraduated.selector);
        escrow.buyback(address(token));
    }

    function test_buyback_spendsAChunk_andBurnsTheOutput() public {
        _graduate(3, 0.2 ether);
        uint256 expectedOut = pool.getAmountOut(0.01 ether, address(weth));
        uint256 supplyBefore = token.totalSupply();

        uint256 burned = escrow.buyback(address(token));

        assertEq(burned, expectedOut);
        assertEq(token.totalSupply(), supplyBefore - burned);
        assertEq(token.balanceOf(address(escrow)), 0);
        assertEq(escrow.buybackBalance(address(token)), 0.03 ether);
        assertEq(escrow.totalOwed(address(weth)), 0.19 ether);
        assertEq(weth.balanceOf(address(escrow)), 0.19 ether);
        assertEq(escrow.lastBuyback(address(token)), block.timestamp);
    }

    function test_buyback_capsTheChunkAtMaxPoolImpact() public {
        _graduate(3, 4 ether);
        escrow.buyback(address(token));
        assertEq(escrow.buybackBalance(address(token)), 0.8 ether - 10 ether * 25 / 10_000);
    }

    function test_buyback_spendsADustBalanceWhole() public {
        _graduate(3, 15);
        assertEq(escrow.buybackBalance(address(token)), 3);
        assertGt(escrow.buyback(address(token)), 0);
        assertEq(escrow.buybackBalance(address(token)), 0);
    }

    function test_buyback_worksForEitherPoolOrientation() public {
        bool firstIsToken0 = address(token) < address(weth);
        while ((address(token) < address(weth)) == firstIsToken0) {
            token = launchpad.createToken(SUPPLY, address(0), 0);
        }
        launchpad.setFeePolicy(address(token), creator, CREATOR_SHARE, BUYBACK_SHARE);
        _graduate(3, 0.2 ether);
        uint256 expectedOut = pool.getAmountOut(0.01 ether, address(weth));
        assertEq(escrow.buyback(address(token)), expectedOut);
    }

    function test_buyback_revertsInsideInterval_andKeepsWorkingOnAnIdlePool() public {
        _graduate(3, 40 ether);
        escrow.buyback(address(token));
        vm.warp(block.timestamp + 1 hours - 1);
        vm.expectRevert(CurveFeeEscrow.TooSoon.selector);
        escrow.buyback(address(token));

        // Nobody else touches the pool: each buyback's own price move must not wedge the next one.
        vm.warp(block.timestamp + 1);
        for (uint256 i = 0; i < 6; i++) {
            uint256 balance = escrow.buybackBalance(address(token));
            assertGt(escrow.buyback(address(token)), 0);
            assertLt(escrow.buybackBalance(address(token)), balance);
            vm.warp(block.timestamp + 1 hours);
        }
    }

    function test_buyback_recoversOnAnIdlePoolAfterAMarketMove() public {
        _graduate(3, 4 ether);
        vm.warp(block.timestamp + 1801);
        // A trader moves spot about 4% and the pool then goes quiet; without a sync the TWAP would
        // stay at the old price forever and every buyback would skip.
        _frontRun(0.2 ether);
        uint256 burned;
        for (uint256 i = 0; i < 2 && burned == 0; i++) {
            vm.warp(block.timestamp + 1 hours);
            burned = escrow.buyback(address(token));
        }
        assertGt(burned, 0);
    }

    function test_buyback_revertsWithNothingToBuy() public {
        _graduate(3, 4 ether);
        CurveToken other = launchpad.createToken(SUPPLY, address(0), 0);
        launchpad.setPool(address(other), address(pool));
        vm.expectRevert(CurveFeeEscrow.NothingToBuy.selector);
        escrow.buyback(address(other));
    }

    function test_buyback_skipsWithTooFewObservations() public {
        _graduate(2, 4 ether);
        _expectSkip(CurveFeeEscrow.SkipReason.FewObservations);
    }

    function test_buyback_skipsWhenQuoteReverts() public {
        _graduate(3, 4 ether);
        vm.mockCallRevert(address(pool), abi.encodeWithSelector(IIcarusPool.quote.selector), "");
        _expectSkip(CurveFeeEscrow.SkipReason.QuoteFailed);
    }

    function test_buyback_skipsWhileIcarusIsPaused() public {
        _graduate(3, 4 ether);
        factory.setPauseState(true);
        _expectSkip(CurveFeeEscrow.SkipReason.PoolPaused);
        assertEq(weth.balanceOf(address(pool)), 10 ether, "no quote left stranded in the pool");

        factory.setPauseState(false);
        assertGt(escrow.buyback(address(token)), 0);
    }

    function test_buyback_toleratesASmallFrontRun() public {
        _graduate(3, 4 ether);
        _frontRun(0.01 ether);
        assertGt(escrow.buyback(address(token)), 0);
    }

    function test_buyback_skipsWhenSandwichedBeyondTheBand() public {
        _graduate(3, 4 ether);
        _frontRun(0.1 ether);
        _expectSkip(CurveFeeEscrow.SkipReason.Slippage);
    }

    // ---------------------------------------------------------------- admin

    function test_rescue_cannotTouchLiabilities() public {
        _distribute(4 ether, 0);
        weth.mint(address(escrow), 1 ether);
        vm.startPrank(owner);
        vm.expectRevert(CurveFeeEscrow.ExceedsSurplus.selector);
        escrow.rescue(address(weth), owner, 1 ether + 1);
        escrow.rescue(address(weth), owner, 1 ether);
        vm.stopPrank();
        assertEq(weth.balanceOf(owner), 1 ether);
        assertEq(weth.balanceOf(address(escrow)), escrow.totalOwed(address(weth)));
    }

    function test_rescue_onlyOwner_andOwnershipCannotBeRenounced() public {
        weth.mint(address(escrow), 1 ether);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        escrow.rescue(address(weth), attacker, 1 ether);

        vm.prank(owner);
        vm.expectRevert(CurveFeeEscrow.RenounceDisabled.selector);
        escrow.renounceOwnership();
    }
}
