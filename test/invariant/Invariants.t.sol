// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Fixture} from "../Fixture.sol";
import {CurveLaunchpad} from "../../contracts/CurveLaunchpad.sol";
import {MockIcarusPool} from "../mocks/MockIcarus.sol";
import {Handler} from "./Handler.sol";

/// @dev System-wide accounting and lifecycle invariants over every market launched by the handler.
///      Call-level safety properties are checked by the handler and surface here as its violation count.
contract InvariantsTest is Fixture {
    uint256 constant S = 1_000_000 ether;
    uint256 constant C = 800_000 ether;
    /// @dev At least this share of a run's calls must do their action rather than return early.
    ///      The worst runs observed reach about 35%; a broken action drops whole categories to 0.
    uint256 constant MIN_REACHED_BPS = 2_000;

    Handler handler;

    function setUp() public override {
        super.setUp();
        handler = new Handler(launchpad, escrow, locker, reserve, weth, icarus, owner, guardian);

        bytes4[] memory selectors = new bytes4[](20);
        selectors[0] = Handler.launch.selector;
        selectors[1] = Handler.buy.selector;
        selectors[2] = Handler.sell.selector;
        selectors[3] = Handler.oversell.selector;
        selectors[4] = Handler.donateWeth.selector;
        selectors[5] = Handler.donatePool.selector;
        selectors[6] = Handler.donateToken.selector;
        selectors[7] = Handler.transfer.selector;
        selectors[8] = Handler.warp.selector;
        selectors[9] = Handler.graduate.selector;
        selectors[10] = Handler.abort.selector;
        selectors[11] = Handler.swap.selector;
        selectors[12] = Handler.lpClaim.selector;
        selectors[13] = Handler.feeClaim.selector;
        selectors[14] = Handler.buyback.selector;
        selectors[15] = Handler.reserveClaim.selector;
        selectors[16] = Handler.rescue.selector;
        selectors[17] = Handler.admin.selector;
        selectors[18] = Handler.pause.selector;
        selectors[19] = Handler.icarusPause.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function _tokens() internal view returns (address[] memory tokens) {
        tokens = new address[](handler.tokenCount());
        for (uint256 i = 0; i < tokens.length; i++) {
            tokens[i] = handler.tokens(i);
        }
    }

    function _accounts() internal view returns (address[] memory accounts) {
        accounts = new address[](handler.actorCount() + 1);
        for (uint256 i = 0; i + 1 < accounts.length; i++) {
            accounts[i] = handler.actors(i);
        }
        accounts[accounts.length - 1] = treasury;
    }

    /// @dev 1. The launchpad owes exactly Σ realQuote and holds exactly that plus the WETH it owes
    ///      nobody (donations and skimmed pool balances, less rescues).
    function invariant_launchpadBacksEveryCurve() public view {
        address[] memory tokens = _tokens();
        uint256 sum;
        for (uint256 i = 0; i < tokens.length; i++) {
            sum += launchpad.market(tokens[i]).realQuote;
        }
        assertEq(launchpad.totalRealQuote(), sum);
        assertEq(weth.balanceOf(address(launchpad)), sum + handler.launchpadSurplus());
    }

    /// @dev Every WETH ever minted is held by an actor, the treasury, the rescue sink, a singleton,
    ///      or a pool and its fee holders: no fee is routed anywhere else.
    function invariant_wethConserved() public view {
        address[] memory accounts = _accounts();
        uint256 sum = weth.balanceOf(handler.sink()) + weth.balanceOf(address(launchpad))
            + weth.balanceOf(address(escrow)) + weth.balanceOf(address(locker)) + weth.balanceOf(address(reserve));
        for (uint256 i = 0; i < accounts.length; i++) {
            sum += weth.balanceOf(accounts[i]);
        }
        for (uint256 i = 0; i < handler.poolCount(); i++) {
            MockIcarusPool pool = MockIcarusPool(handler.pools(i));
            sum += weth.balanceOf(address(pool)) + weth.balanceOf(pool.poolFees()) + weth.balanceOf(pool.gaugeFees());
        }
        assertEq(sum, weth.totalSupply());
    }

    /// @dev 2 and 3. Curve reserves stay consistent; the launchpad holds every unsold curve token.
    function invariant_curveAccounting() public view {
        address[] memory tokens = _tokens();
        for (uint256 i = 0; i < tokens.length; i++) {
            CurveLaunchpad.Market memory m = launchpad.market(tokens[i]);
            uint256 sold = S - m.virtualToken;
            assertLe(sold, C);
            if (m.state == CurveLaunchpad.State.Graduated) {
                assertEq(m.realQuote, 0);
                // Graduation burns everything it didn't seed, and the locker holds the pool's LP.
                assertEq(IERC20(tokens[i]).balanceOf(address(launchpad)), handler.donatedAfterGraduation(tokens[i]));
                assertGt(IERC20(m.pool).balanceOf(address(locker)), 0);
            } else {
                assertEq(m.realQuote, m.virtualQuote - m.initialVirtualQuote);
                assertEq(m.pool, address(0));
                assertGe(IERC20(tokens[i]).balanceOf(address(launchpad)), S - m.reserveTokens - sold);
            }
        }
    }

    /// @dev 4. Every escrow credit is backed, and the ledger adds up to `totalOwed` per asset.
    function invariant_escrowBacksEveryClaim() public view {
        address[] memory tokens = _tokens();
        address[] memory accounts = _accounts();
        uint256 owedQuote = _sumClaimable(accounts, address(weth));
        for (uint256 i = 0; i < tokens.length; i++) {
            owedQuote += escrow.buybackBalance(tokens[i]);
            uint256 owedToken = _sumClaimable(accounts, tokens[i]);
            assertEq(escrow.totalOwed(tokens[i]), owedToken);
            assertGe(IERC20(tokens[i]).balanceOf(address(escrow)), owedToken);
        }
        assertEq(escrow.totalOwed(address(weth)), owedQuote);
        assertGe(weth.balanceOf(address(escrow)), owedQuote);
    }

    /// @dev 5. The held ledger is the curve's sales; before graduation it bounds every balance.
    function invariant_heldLedgerMatchesSales() public view {
        address[] memory tokens = _tokens();
        for (uint256 i = 0; i < tokens.length; i++) {
            CurveLaunchpad.Market memory m = launchpad.market(tokens[i]);
            uint256 sum;
            for (uint256 j = 0; j < handler.actorCount(); j++) {
                address actor = handler.actors(j);
                uint256 held = launchpad.held(tokens[i], actor);
                sum += held;
                if (m.state != CurveLaunchpad.State.Graduated) {
                    assertGe(held, IERC20(tokens[i]).balanceOf(actor));
                }
            }
            assertEq(sum, S - m.virtualToken);
            if (m.state != CurveLaunchpad.State.Graduated) {
                address pool = icarus.getPool(tokens[i], address(weth), false);
                if (pool != address(0)) assertEq(IERC20(tokens[i]).balanceOf(pool), 0);
            }
        }
    }

    /// @dev 6. Reserve claims never exceed the reserve, and the rest is still held.
    function invariant_reserveClaimsBounded() public view {
        address[] memory tokens = _tokens();
        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 reserved = launchpad.market(tokens[i]).reserveTokens;
            uint256 claimed = handler.reserveClaimed(tokens[i]);
            assertEq(reserve.reserveOf(tokens[i]), reserved);
            assertLe(claimed, reserved);
            assertEq(IERC20(tokens[i]).balanceOf(address(reserve)), reserved - claimed);
        }
    }

    /// @dev 7, 8 and 9: locker LP, the state machine, pause scope and token supply.
    function invariant_handlerSawNoViolation() public view {
        assertEq(handler.violations(), 0, handler.lastViolation());
    }

    /// @dev 10. A run where most calls returned early proves nothing.
    function afterInvariant() external view {
        uint256 reached;
        for (uint256 i = 0; i < handler.ACTIONS(); i++) {
            reached += handler.reached(Handler.Action(i));
        }
        assertGe(reached * 10_000, handler.calls() * MIN_REACHED_BPS, "handler mostly returned early");
    }

    /// @dev 10, deterministically: every action category can do its work, so none is vacuous.
    ///      A 64-call run can't be required to hit all 20 categories without failing by chance.
    function test_handler_reachesEveryAction() public {
        handler.buy(1, 0, 1 ether);
        handler.sell(1, 0, 5_000);
        handler.oversell(2, 0);
        handler.donateWeth(1 ether, false);
        handler.donatePool(0, 0.1 ether, true);
        handler.donateToken(1, 0, 1_000);
        handler.transfer(1, 0, true, 1_000);
        handler.warp(1 hours);
        handler.admin(true, 100, 4_000, 3_000, 25);
        handler.admin(false, 0, 0, 0, 2 ether);
        handler.launch(2, 0, 100, 0);
        handler.graduate(3, 0);
        for (uint256 i = 0; i < 4; i++) {
            handler.warp(1801);
            handler.swap(2, 0, true, 0.2 ether);
            handler.warp(1801);
            handler.swap(3, 0, false, 3_000);
        }
        handler.lpClaim(0);
        handler.feeClaim(0, 0, true);
        handler.buyback(0);
        handler.reserveClaim(0, 0);
        handler.rescue(0, 0, 0.5 ether);
        handler.abort(2, 1, 0);
        handler.pause(true);
        handler.icarusPause();

        for (uint256 i = 0; i < handler.ACTIONS(); i++) {
            assertGt(handler.reached(Handler.Action(i)), 0, vm.toString(i));
        }
        assertGt(handler.earlyAbortsRejected(), 0);
        assertEq(handler.violations(), 0, handler.lastViolation());
    }

    /// @dev The paths the fuzzer reaches least: an early abort, the inline abort inside a sell, a buy
    ///      on an Aborted market, its re-sellout, and graduation from Aborted.
    function test_handler_reachesTheRarePaths() public {
        handler.abort(0, 1, 1); // sells out, rejects the early abort, does not wait
        handler.warp(7 days);
        handler.sell(0, 1, 5_000); // aborts inline
        handler.buy(2, 1, 0.5 ether);
        handler.graduate(3, 1); // re-sells out, graduates from Aborted

        assertGt(handler.earlyAbortsRejected(), 0);
        assertEq(handler.inlineAborts(), 1);
        assertEq(handler.regraduations(), 1);
        assertEq(uint8(launchpad.market(handler.tokens(1)).state), uint8(CurveLaunchpad.State.Graduated));
        assertEq(handler.violations(), 0, handler.lastViolation());
    }

    function _sumClaimable(address[] memory accounts, address asset) internal view returns (uint256 sum) {
        for (uint256 i = 0; i < accounts.length; i++) {
            sum += escrow.claimable(accounts[i], asset);
        }
    }
}
