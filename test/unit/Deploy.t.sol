// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Fixture} from "../Fixture.sol";
import {CurveDeploy} from "../../scripts/CurveDeploy.sol";
import {CurveLaunchpad} from "../../contracts/CurveLaunchpad.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";

contract DeployTest is Fixture {
    /// @dev External so a revert inside the deployment can be caught by `expectRevert`.
    function deployAs(address deployer) external returns (Deployment memory) {
        return _deployCurve(deployer, _params());
    }

    /// @dev External so a revert inside the deployment can be caught by `expectRevert`.
    function deployWithQuoteToken(address quoteToken) external returns (Deployment memory) {
        Params memory p = _params();
        p.quoteToken = quoteToken;
        return _deployCurve(address(this), p);
    }

    /// @dev Audit finding (Low): a non-18-decimal quote token must fail fast at deploy instead of
    ///      silently deploying a curve whose fixed quote bounds are off by orders of magnitude.
    function test_deploy_rejectsNon18DecimalQuoteToken() public {
        MockUSDC usdc = new MockUSDC();
        assertEq(usdc.decimals(), 6);
        vm.expectRevert(CurveLaunchpad.InvalidConfig.selector);
        this.deployWithQuoteToken(address(usdc));
        assertEq(launchpad.quoteToken(), address(weth), "the original fixture deployment is unaffected");
    }

    function test_fixture_isWiredThroughCurveDeploy() public view {
        _checkWiring(Deployment(launchpad, escrow, locker, reserve), _params());
        assertEq(launchpad.owner(), owner);
        assertEq(escrow.owner(), owner);
        assertEq(launchpad.graduationTarget(), TARGET);
    }

    function test_deploy_isRepeatableFromTheSameDeployer() public {
        Deployment memory d = this.deployAs(address(this));
        assertTrue(address(d.launchpad) != address(launchpad));
        assertEq(d.escrow.launchpad(), address(d.launchpad));
    }

    function test_deploy_abortsWhenThePredictionIsWrong() public {
        // Predicting from the wrong account's nonce stands in for a retried transaction shifting it.
        vm.expectPartialRevert(CurveDeploy.AddressPredictionMismatch.selector);
        this.deployAs(alice);
    }
}
