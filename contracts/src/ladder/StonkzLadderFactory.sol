// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {StonkzLadderAuction} from "./StonkzLadderAuction.sol";
import {LadderConstants} from "./LadderConstants.sol";
import {DeployControls} from "../DeployControls.sol";

/// @title StonkzLadderFactory — filing gate for ladder auctions (modularity)
/// @notice Owner-settable vault + carve default. HoldbackPct > 0 reverts while vault unset.
///         carveBps stamped immutably per auction at filing (FEECHAIN stamp pattern).
///         DeployControls: deploysEnabled + allowlist gate every `file` (docs/03 switch 4).
contract StonkzLadderFactory is DeployControls {
    address public vaultRef;
    /// @notice Mutable default carve for new filings. Bounds [0, CARVE_BPS_MAX]. Unit: bps of raised.
    uint16 public defaultCarveBps = LadderConstants.DEFAULT_CARVE_BPS; // bps of raised

    event VaultRefSet(address indexed vault);
    event DefaultCarveBpsSet(uint16 bps);
    event AuctionFiled(address indexed auction, address indexed creator, uint16 holdbackBps, uint16 carveBps);

    error VaultRequiredForHoldback();
    error VaultRefNotContract();
    error HoldbackCeiling();
    error CarveBounds();

    constructor() DeployControls() {}

    /// @notice Set the Management Vault ref. Target MUST have code (EOA/empty reverts).
    function setVaultRef(address vault) external onlyOwner {
        if (vault != address(0) && vault.code.length == 0) revert VaultRefNotContract();
        vaultRef = vault;
        emit VaultRefSet(vault);
    }

    function setDefaultCarveBps(uint16 bps) external onlyOwner {
        if (bps > LadderConstants.CARVE_BPS_MAX) revert CarveBounds();
        defaultCarveBps = bps;
        emit DefaultCarveBpsSet(bps);
    }

    /// @notice File a ladder auction. Stamps current defaultCarveBps (or explicit p.carveBps if set).
    /// @dev Pass carveBps=type(uint16).max to mean "use factory default".
    function file(StonkzLadderAuction.Params memory p) external returns (StonkzLadderAuction auction) {
        _requireDeployAllowed(msg.sender);

        if (p.carveBps == type(uint16).max) {
            p.carveBps = defaultCarveBps;
        }
        if (p.carveBps > LadderConstants.CARVE_BPS_MAX) revert CarveBounds();

        if (p.holdbackBps > 0) {
            if (vaultRef == address(0)) revert VaultRequiredForHoldback();
            if (p.holdbackDelivery != LadderConstants.HoldbackDelivery.Vault) revert VaultRequiredForHoldback();
            if (p.holdbackBps > LadderConstants.holdbackCeilingBps(uint8(p.tier))) revert HoldbackCeiling();
        } else {
            p.holdbackDelivery = LadderConstants.HoldbackDelivery.None;
        }

        p.vaultRef = vaultRef;
        auction = new StonkzLadderAuction(p);
        emit AuctionFiled(address(auction), p.creator, p.holdbackBps, p.carveBps);
    }
}
