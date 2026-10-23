// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Fixture} from "../Fixture.sol";
import {CurveDeploy} from "../../scripts/CurveDeploy.sol";

contract DeployTest is Fixture {
    /// @dev External so a revert inside the deployment can be caught by `expectRevert`.
    function deployAs(address deployer) external returns (Deployment memory) {
        return _deployCurve(deployer, _params());
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
