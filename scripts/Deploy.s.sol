// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {CurveDeploy} from "./CurveDeploy.sol";
import {CurveLaunchpad} from "../contracts/CurveLaunchpad.sol";
import {IIcarusFactory} from "../contracts/interfaces/IIcarus.sol";

interface ITimelock {
    function getMinDelay() external view returns (uint256);
    function hasRole(bytes32 role, address account) external view returns (bool);
}

/// @notice Deploys and wires the four singletons on RISE through `CurveDeploy`.
/// @dev Run with `--account`; the broadcasting account is the deployer whose nonce predicts the
///      launchpad address. On testnet 11155931 the owner, guardian and treasury use the configured
///      testnet operator. On mainnet 4153 they come from the environment and must pass the preflight: the
///      owner is a `TimelockController` with a non-zero delay and a contract (multisig) proposer, and
///      the guardian and treasury are contracts.
contract Deploy is Script, CurveDeploy {
    uint256 internal constant MAINNET = 4_153;
    uint256 internal constant TESTNET = 11_155_931;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant MAINNET_ICARUS = 0xEe10C6a0f158bFEeef3d48Dc0D26130Cf6115615;
    address internal constant TESTNET_ICARUS = 0x8221dfB70c9A2dE60253dcfC58231FD529bbF4F9;
    address internal constant TESTNET_OPERATOR = 0xd07988eCBCf446b9650dC93Ed9c61Bf97F02a8d3;
    bytes32 internal constant PROPOSER_ROLE = keccak256("PROPOSER_ROLE");

    uint256 internal constant LAUNCH_FEE = 0.001 ether;
    uint256 internal constant TESTNET_TARGET = 0.01 ether;

    error UnsupportedChain(uint256 chainId);
    error Preflight(string check);

    function run() external returns (Deployment memory d) {
        Params memory p = params();
        preflight(p);
        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        d = _deployCurve(deployer, p);
        vm.stopBroadcast();
    }

    function params() public view returns (Params memory p) {
        p.quoteToken = WETH;
        p.launchFee = LAUNCH_FEE;
        p.fees = CurveLaunchpad.FeeDefaults({feeBps: 75, creatorShareBps: 5_000, buybackShareBps: 2_500, taxCapBps: 50});
        if (block.chainid == TESTNET) {
            (p.owner, p.guardian, p.treasury) = (TESTNET_OPERATOR, TESTNET_OPERATOR, TESTNET_OPERATOR);
            p.icarusFactory = TESTNET_ICARUS;
            p.graduationTarget = TESTNET_TARGET;
        } else if (block.chainid == MAINNET) {
            p.owner = vm.envAddress("CURVE_OWNER");
            p.guardian = vm.envAddress("CURVE_GUARDIAN");
            p.treasury = vm.envAddress("CURVE_TREASURY");
            p.icarusFactory = MAINNET_ICARUS;
            p.graduationTarget = vm.envUint("CURVE_GRADUATION_TARGET");
        } else {
            revert UnsupportedChain(block.chainid);
        }
    }

    /// @notice Every check that can fail before anything is broadcast.
    function preflight(Params memory p) public view {
        _require(WETH.code.length != 0, "WETH has no code");
        _require(p.icarusFactory.code.length != 0, "Icarus factory has no code");
        // Graduation needs neither, but a paused venue on deploy day means something is wrong.
        _require(!IIcarusFactory(p.icarusFactory).isPaused(), "Icarus is paused");
        _require(p.graduationTarget >= 0.01 ether, "graduation target below MIN_TARGET");
        if (block.chainid != MAINNET) return;

        _require(p.owner.code.length != 0, "owner is not a contract");
        _require(ITimelock(p.owner).getMinDelay() != 0, "owner timelock has no delay");
        address proposer = vm.envAddress("CURVE_TIMELOCK_PROPOSER");
        _require(proposer.code.length != 0, "timelock proposer is not a contract");
        _require(ITimelock(p.owner).hasRole(PROPOSER_ROLE, proposer), "proposer lacks PROPOSER_ROLE");
        _require(p.guardian.code.length != 0, "guardian is not a contract");
        _require(p.treasury.code.length != 0, "treasury is not a contract");
    }

    function _require(bool ok, string memory check) internal pure {
        if (!ok) revert Preflight(check);
    }
}
