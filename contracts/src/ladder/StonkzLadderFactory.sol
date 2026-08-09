// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {StonkzLadderAuction} from "./StonkzLadderAuction.sol";
import {LadderConstants} from "./LadderConstants.sol";
import {LadderTypes} from "./LadderTypes.sol";

/// @title StonkzLadderFactory — filing gate for ladder auctions (modularity)
/// @notice Owner-settable vault reference. HoldbackPct > 0 reverts while vault unset.
contract StonkzLadderFactory {
    address public owner;
    /// @notice Management vault. Unset (address(0)) ⇒ no holdback filings allowed.
    address public vaultRef;

    event OwnerTransferred(address indexed prev, address indexed next);
    event VaultRefSet(address indexed vault);
    event AuctionFiled(address indexed auction, address indexed creator, uint16 holdbackBps);

    error NotOwner();
    error VaultRequiredForHoldback();
    error HoldbackCeiling();
    error TakeRemoved();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    function transferOwnership(address next) external onlyOwner {
        emit OwnerTransferred(owner, next);
        owner = next;
    }

    function setVaultRef(address vault) external onlyOwner {
        vaultRef = vault;
        emit VaultRefSet(vault);
    }

    /// @notice File a ladder auction. Availability guard + per-tier holdback ceiling.
    function file(StonkzLadderAuction.Params memory p) external returns (StonkzLadderAuction auction) {
        // TAKE removed — enum admits only None|Vault; any other encoding rejected by auction ctor.
        if (p.holdbackBps > 0) {
            if (vaultRef == address(0)) revert VaultRequiredForHoldback();
            if (p.holdbackDelivery != LadderConstants.HoldbackDelivery.Vault) revert VaultRequiredForHoldback();
            if (p.holdbackBps > LadderConstants.holdbackCeilingBps(uint8(p.tier))) revert HoldbackCeiling();
        } else {
            p.holdbackDelivery = LadderConstants.HoldbackDelivery.None;
        }

        p.vaultRef = vaultRef; // stamp current factory vault (0 when holdback=0)
        auction = new StonkzLadderAuction(p);
        emit AuctionFiled(address(auction), p.creator, p.holdbackBps);
    }
}
