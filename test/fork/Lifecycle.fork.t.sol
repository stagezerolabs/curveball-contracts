// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CurveDeploy} from "../../scripts/CurveDeploy.sol";
import {CurveLaunchpad} from "../../contracts/CurveLaunchpad.sol";
import {IIcarusFactory, IIcarusPool} from "../../contracts/interfaces/IIcarus.sol";

interface IWETH {
    function deposit() external payable;
}

interface IIcarusPausable {
    function pauser() external view returns (address);
    function setPauseState(bool state) external;
}

/// @dev The lifecycle against the real Icarus and WETH on a RISE fork. Skips without an RPC unless
///      CI_FORK=1, where a missing RPC or the wrong chain fails instead. Forks a pinned block for
///      reproducible runs; FORK_BLOCK overrides it if the RPC no longer serves that state.
abstract contract LifecycleFork is Test, CurveDeploy {
    address constant WETH = 0x4200000000000000000000000000000000000006;
    uint256 constant S = 1_000_000 ether;
    uint256 constant C = 800_000 ether;
    uint256 constant TARGET = 0.01 ether;

    address owner = makeAddr("owner");
    address guardian = makeAddr("guardian");
    address treasury = makeAddr("treasury");
    address creator = makeAddr("creator");
    address trader = makeAddr("trader");

    IIcarusFactory icarus;
    Deployment d;

    function _rpcVar() internal pure virtual returns (string memory);
    function _chainId() internal pure virtual returns (uint256);
    function _icarusFactory() internal pure virtual returns (address);
    function _forkBlock() internal pure virtual returns (uint256);

    function setUp() public {
        string memory rpc = vm.envOr(_rpcVar(), string(""));
        if (bytes(rpc).length == 0) {
            require(vm.envOr("CI_FORK", uint256(0)) != 1, string.concat(_rpcVar(), " is required when CI_FORK=1"));
            vm.skip(true);
        }
        vm.createSelectFork(rpc, vm.envOr("FORK_BLOCK", _forkBlock()));
        assertEq(block.chainid, _chainId(), "RPC points at the wrong chain");
        icarus = IIcarusFactory(_icarusFactory());
        d = _deployCurve(
            address(this),
            Params({
                owner: owner,
                guardian: guardian,
                treasury: treasury,
                quoteToken: WETH,
                icarusFactory: address(icarus),
                launchFee: 0,
                graduationTarget: TARGET,
                fees: CurveLaunchpad.FeeDefaults(75, 5_000, 2_500, 50)
            })
        );
    }

    function test_fork_graduatesIntoAFreshPool_andEarnsFees_andBuysBack() public {
        address token = _launchAndSellOut(100);
        CurveLaunchpad.Market memory m = d.launchpad.market(token);

        IIcarusPool pool = IIcarusPool(d.launchpad.graduate(token));
        assertEq(icarus.getPool(token, WETH, false), address(pool));
        (uint256 tokens, uint256 quote) = _reserves(pool, token);
        assertEq(quote, m.realQuote);
        assertApproxEqAbs(tokens, quote * uint256(m.virtualToken) / uint256(m.virtualQuote), 1, "curve-end price");
        // The real first mint locks MINIMUM_LIQUIDITY; the locker holds everything else.
        assertEq(pool.balanceOf(address(d.locker)) + 1_000, pool.totalSupply());
        assertEq(IERC20(token).balanceOf(address(d.launchpad)), 0);

        // Trade across 30-minute windows so the pool records TWAP observations.
        _wrap(trader, 0.01 ether);
        for (uint256 i = 0; i < 4; i++) {
            vm.warp(block.timestamp + 1801);
            _swap(pool, WETH, 0.001 ether);
            vm.warp(block.timestamp + 1801);
            _swap(pool, token, IERC20(token).balanceOf(trader) / 2);
        }
        assertGt(pool.observationLength(), 3);

        // claimFees pays the LP share only; the real unstaked fee goes to the gauge side.
        uint256 owedBefore = d.escrow.totalOwed(WETH);
        (uint256 tokenFees, uint256 quoteFees) = d.locker.claim(address(pool));
        assertGt(tokenFees, 0);
        assertGt(quoteFees, 0);
        assertEq(d.escrow.totalOwed(WETH), owedBefore + quoteFees);
        assertGe(IERC20(WETH).balanceOf(address(d.escrow)), d.escrow.totalOwed(WETH));

        // The real factory's pause stops swaps only: the buyback skips without starting its interval.
        _setIcarusPaused(true);
        assertEq(d.escrow.buyback(token), 0);
        assertEq(d.escrow.lastBuyback(token), 0);
        _setIcarusPaused(false);

        uint256 supply = IERC20(token).totalSupply();
        uint256 burned = d.escrow.buyback(token);
        assertGt(burned, 0, "buyback skipped on the real pool");
        assertEq(IERC20(token).totalSupply(), supply - burned);
        assertEq(IERC20(token).balanceOf(address(d.escrow)), d.escrow.totalOwed(token));
    }

    /// @dev A griefer pre-creates the pool and syncs a WETH donation; graduation matches it instead of reverting.
    ///      No reserve, so the burn buffer can absorb the 10% donation at the curve-end price.
    function test_fork_matchesASyncedDonationInAPreCreatedPool() public {
        address token = _launchAndSellOut(0);
        IIcarusPool pool = IIcarusPool(icarus.createPool(token, WETH, false));
        _wrap(address(this), 0.001 ether);
        IERC20(WETH).transfer(address(pool), 0.001 ether);
        pool.sync();
        CurveLaunchpad.Market memory m = d.launchpad.market(token);

        assertEq(d.launchpad.graduate(token), address(pool));

        (uint256 tokens, uint256 quote) = _reserves(pool, token);
        assertEq(quote, m.realQuote + 0.001 ether);
        assertApproxEqAbs(tokens, quote * uint256(m.virtualToken) / uint256(m.virtualQuote), 1, "curve-end price");
        assertEq(d.locker.tokenOf(address(pool)), token);
    }

    /// @dev Icarus's pauser can't force an abort: graduation never checks the pause.
    function test_fork_graduatesWhileIcarusIsPaused() public {
        address token = _launchAndSellOut(0);
        _setIcarusPaused(true);
        address pool = d.launchpad.graduate(token);
        assertEq(uint8(d.launchpad.market(token).state), uint8(CurveLaunchpad.State.Graduated));
        assertGt(IIcarusPool(pool).balanceOf(address(d.locker)), 0);
    }

    function _setIcarusPaused(bool state) internal {
        vm.prank(IIcarusPausable(address(icarus)).pauser());
        IIcarusPausable(address(icarus)).setPauseState(state);
        assertEq(icarus.isPaused(), state);
    }

    function _launchAndSellOut(uint16 reserveBps) internal returns (address token) {
        _wrap(creator, 1 ether);
        vm.startPrank(creator);
        IERC20(WETH).approve(address(d.launchpad), type(uint256).max);
        (token,) =
            d.launchpad.launch(CurveLaunchpad.Metadata("Fork launch", "FORK", "ipfs://fork"), 0, reserveBps, 0, 0);
        d.launchpad.buy(token, 1 ether, C, block.timestamp);
        vm.stopPrank();
        assertEq(uint8(d.launchpad.market(token).state), uint8(CurveLaunchpad.State.Ready));
    }

    function _swap(IIcarusPool pool, address tokenIn, uint256 amountIn) internal {
        uint256 out = pool.getAmountOut(amountIn, tokenIn);
        vm.prank(trader);
        IERC20(tokenIn).transfer(address(pool), amountIn);
        bool outIsToken0 = pool.token0() != tokenIn;
        pool.swap(outIsToken0 ? out : 0, outIsToken0 ? 0 : out, trader, "");
    }

    function _wrap(address account, uint256 amount) internal {
        vm.deal(account, amount);
        vm.prank(account);
        IWETH(WETH).deposit{value: amount}();
    }

    function _reserves(IIcarusPool pool, address token) internal view returns (uint256 tokens, uint256 quote) {
        (uint256 r0, uint256 r1,) = pool.getReserves();
        (tokens, quote) = pool.token0() == token ? (r0, r1) : (r1, r0);
    }
}

contract LifecycleMainnetForkTest is LifecycleFork {
    function _rpcVar() internal pure override returns (string memory) {
        return "RISE_MAINNET_RPC_URL";
    }

    function _chainId() internal pure override returns (uint256) {
        return 4153;
    }

    function _icarusFactory() internal pure override returns (address) {
        return 0xEe10C6a0f158bFEeef3d48Dc0D26130Cf6115615;
    }

    function _forkBlock() internal pure override returns (uint256) {
        return 24_722_082;
    }
}

contract LifecycleTestnetForkTest is LifecycleFork {
    function _rpcVar() internal pure override returns (string memory) {
        return "RISE_TESTNET_RPC_URL";
    }

    function _chainId() internal pure override returns (uint256) {
        return 11155931;
    }

    function _icarusFactory() internal pure override returns (address) {
        return 0x8221dfB70c9A2dE60253dcfC58231FD529bbF4F9;
    }

    function _forkBlock() internal pure override returns (uint256) {
        return 57_239_173;
    }
}
