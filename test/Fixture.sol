// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CurveDeploy} from "../scripts/CurveDeploy.sol";
import {CurveFeeEscrow} from "../contracts/CurveFeeEscrow.sol";
import {CurveHolderReserve} from "../contracts/CurveHolderReserve.sol";
import {CurveLaunchpad} from "../contracts/CurveLaunchpad.sol";
import {CurveLpLocker} from "../contracts/CurveLpLocker.sol";
import {MockIcarusFactory} from "./mocks/MockIcarus.sol";
import {MockWETH} from "./mocks/MockWETH.sol";

/// @dev The full system on mocks, deployed through the same `CurveDeploy` path as production.
abstract contract Fixture is Test, CurveDeploy {
    uint256 constant TARGET = 4 ether;
    uint256 constant LAUNCH_FEE = 0.001 ether;

    address owner = makeAddr("owner");
    address guardian = makeAddr("guardian");
    address treasury = makeAddr("treasury");
    address creator = makeAddr("creator");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    MockWETH weth;
    MockIcarusFactory icarus;
    CurveLaunchpad launchpad;
    CurveFeeEscrow escrow;
    CurveLpLocker locker;
    CurveHolderReserve reserve;

    function setUp() public virtual {
        weth = new MockWETH();
        icarus = new MockIcarusFactory();
        Deployment memory d = _deployCurve(address(this), _params());
        (launchpad, escrow, locker, reserve) = (d.launchpad, d.escrow, d.locker, d.reserve);
    }

    function _params() internal view returns (Params memory) {
        return Params({
            owner: owner,
            guardian: guardian,
            treasury: treasury,
            quoteToken: address(weth),
            icarusFactory: address(icarus),
            launchFee: LAUNCH_FEE,
            graduationTarget: TARGET,
            fees: CurveLaunchpad.FeeDefaults(75, 5_000, 2_500, 50)
        });
    }

    function _meta() internal pure returns (CurveLaunchpad.Metadata memory) {
        return CurveLaunchpad.Metadata("Curve Meme", "MEME", "ipfs://meme");
    }

    /// @dev Launches from `who` with a `reserveBps` holder reserve and a `firstBuy` quote first buy.
    function _launch(address who, uint16 reserveBps, uint256 firstBuy) internal returns (address token) {
        _fund(who, LAUNCH_FEE + firstBuy);
        vm.prank(who);
        (token,) = launchpad.launch(_meta(), 0, reserveBps, firstBuy, 0);
    }

    /// @dev Buys with exactly `spend` freshly minted WETH and returns the tokens received.
    function _buy(address who, address token, uint256 spend) internal returns (uint256) {
        _fund(who, spend);
        vm.prank(who);
        return launchpad.buy(token, spend, 0, block.timestamp);
    }

    function _sell(address who, address token, uint256 amount) internal returns (uint256) {
        vm.startPrank(who);
        IERC20(token).approve(address(launchpad), amount);
        uint256 net = launchpad.sell(token, amount, 0, block.timestamp);
        vm.stopPrank();
        return net;
    }

    /// @dev Buys the rest of the curve from `who`, leaving the market Ready.
    function _sellOut(address who, address token) internal {
        _buy(who, token, 100 ether);
    }

    /// @dev Mints `amount` WETH to `account` and approves the launchpad for all of it.
    function _fund(address account, uint256 amount) internal {
        weth.mint(account, amount);
        vm.prank(account);
        weth.approve(address(launchpad), type(uint256).max);
    }
}
