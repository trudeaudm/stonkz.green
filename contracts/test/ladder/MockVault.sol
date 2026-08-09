// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IStonkzVault} from "../../src/vault/IStonkzVault.sol";

/// @dev Minimal vault stub for ladder tests — satisfies setVaultRef code check + deposit pull.
contract MockVault is IStonkzVault {
    mapping(address => uint256) public custody;
    mapping(address => mapping(address => uint256)) public balanceOf;

    function lockedBalance(address token) external view returns (uint256) {
        return custody[token];
    }

    function deposit(address token, uint256 amount, address beneficiary) external {
        (bool ok, bytes memory data) =
            token.call(abi.encodeWithSignature("transferFrom(address,address,uint256)", msg.sender, address(this), amount));
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "TRANSFER_FROM");
        custody[token] += amount;
        balanceOf[token][beneficiary] += amount;
    }
}
