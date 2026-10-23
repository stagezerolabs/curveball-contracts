// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ICurveLaunchpad} from "../../contracts/interfaces/ICurveLaunchpad.sol";
import {CurveToken} from "../../contracts/CurveToken.sol";

/// @dev Settable `ICurveLaunchpad` for the singleton unit tests. It owns a real `CurveToken`
///      implementation, so tokens it creates keep the transfer lock until `unlock`.
contract MockLaunchpad is ICurveLaunchpad {
    struct Policy {
        address creator;
        uint16 creatorShareBps;
        uint16 buybackShareBps;
    }

    CurveToken public immutable tokenImplementation = new CurveToken();

    address public treasury;
    address public locker;
    uint256 public curveSupply = 800_000 ether;

    mapping(address token => Policy) internal _policy;
    mapping(address token => address) public poolOf;
    mapping(address token => mapping(address account => uint256)) public held;

    constructor(address treasury_) {
        treasury = treasury_;
    }

    function createToken(uint256 supply, address reserveRecipient, uint256 reserveAmount)
        external
        returns (CurveToken token)
    {
        token = CurveToken(Clones.clone(address(tokenImplementation)));
        token.initialize("Mock", "MOCK", supply, reserveRecipient, reserveAmount);
    }

    function unlock(CurveToken token) external {
        token.unlock();
    }

    function send(CurveToken token, address to, uint256 amount) external {
        token.transfer(to, amount);
    }

    function setTreasury(address treasury_) external {
        treasury = treasury_;
    }

    function setLocker(address locker_) external {
        locker = locker_;
    }

    function setCurveSupply(uint256 curveSupply_) external {
        curveSupply = curveSupply_;
    }

    function setFeePolicy(address token, address creator, uint16 creatorShareBps, uint16 buybackShareBps) external {
        _policy[token] = Policy(creator, creatorShareBps, buybackShareBps);
    }

    function setPool(address token, address pool) external {
        poolOf[token] = pool;
    }

    function setHeld(address token, address account, uint256 amount) external {
        held[token][account] = amount;
    }

    function feePolicy(address token) external view returns (address, uint16, uint16) {
        Policy memory p = _policy[token];
        return (p.creator, p.creatorShareBps, p.buybackShareBps);
    }
}
