// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {StonkzLadderAuction} from "./StonkzLadderAuction.sol";
import {LadderConstants} from "./LadderConstants.sol";
import {DeployControls} from "../DeployControls.sol";
import {Vanity} from "../Vanity.sol";

/// @title StonkzLadderFactory — filing gate for ladder auctions (modularity)
/// @notice Owner-settable vault + carve default. HoldbackPct > 0 reverts while vault unset.
///         carveBps stamped immutably per auction at filing (FEECHAIN stamp pattern).
///         DeployControls: deploysEnabled + allowlist gate every `file` (docs/03 switch 4).
///         CREATE2 + 0x4663 vanity (docs/03 VANITY PREFIX): salt = keccak256(deployer, userSalt).
contract StonkzLadderFactory is DeployControls {
    address public vaultRef;
    /// @notice Mutable default carve for new filings. Bounds [0, CARVE_BPS_MAX]. Unit: bps of raised.
    uint16 public defaultCarveBps = LadderConstants.DEFAULT_CARVE_BPS; // bps of raised

    event VaultRefSet(address indexed vault);
    event DefaultCarveBpsSet(uint16 bps);
    event AuctionFiled(
        address indexed auction, address indexed creator, uint16 holdbackBps, uint16 carveBps, bytes32 userSalt, bytes32 salt
    );

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

    /// @notice CREATE2 salt binding deployer (docs/03 vanity — same formula as Express).
    function auctionSalt(address deployer, bytes32 userSalt) public pure returns (bytes32) {
        return keccak256(abi.encode(deployer, userSalt));
    }

    /// @notice Init-code hash AFTER factory stamps (vanity miner input).
    function auctionInitCodeHash(StonkzLadderAuction.Params memory p) public view returns (bytes32) {
        _stampAuctionParams(p);
        return keccak256(abi.encodePacked(type(StonkzLadderAuction).creationCode, abi.encode(p)));
    }

    /// @notice Predict CREATE2 address for a filed auction.
    function predictAuctionAddress(address deployer, bytes32 userSalt, bytes32 initCodeHash)
        public
        view
        returns (address predicted)
    {
        bytes32 salt = auctionSalt(deployer, userSalt);
        predicted = Vanity.predict(address(this), salt, initCodeHash);
    }

    /// @notice File a ladder auction. Stamps current defaultCarveBps (or explicit p.carveBps if set).
    /// @dev Pass carveBps=type(uint16).max to mean "use factory default".
    ///      Side-pool switches (createSidePool, sidePoolBps) are ALWAYS stamped from factory defaults.
    ///      Reverts VanityPrefixMismatch if predicted address top bytes != 0x4663.
    /// @param userSalt Caller-chosen salt half; effective salt = auctionSalt(msg.sender, userSalt).
    function file(StonkzLadderAuction.Params memory p, bytes32 userSalt) external returns (StonkzLadderAuction auction) {
        _requireDeployAllowed(msg.sender);
        _stampAuctionParams(p);

        bytes32 salt = auctionSalt(msg.sender, userSalt);
        bytes32 initHash = keccak256(abi.encodePacked(type(StonkzLadderAuction).creationCode, abi.encode(p)));
        address predicted = Vanity.predict(address(this), salt, initHash);
        Vanity.requirePrefix(predicted);

        auction = new StonkzLadderAuction{salt: salt}(p);
        assert(address(auction) == predicted);
        emit AuctionFiled(address(auction), p.creator, p.holdbackBps, p.carveBps, userSalt, salt);
    }

    function _stampAuctionParams(StonkzLadderAuction.Params memory p) internal view {
        if (p.carveBps == type(uint16).max) {
            p.carveBps = defaultCarveBps;
        }
        if (p.carveBps > LadderConstants.CARVE_BPS_MAX) revert CarveBounds();

        // docs/03 switches 2–3 — stamp factory defaults (mutable → immutable per auction).
        p.createSidePool = defaultCreateSidePool;
        p.sidePoolBps = defaultSidePoolBps;
        // Switch 1 stamped via auction constructor reading DeployControls(msg.sender).
        // Ref price (ruling B): pair-wei per STONKZ token, WAD — required iff createSidePool.
        p.stonkzRefPriceWad = p.createSidePool ? _requireRefPrice(p.pairToken) : 0;

        if (p.holdbackBps > 0) {
            if (vaultRef == address(0)) revert VaultRequiredForHoldback();
            if (p.holdbackDelivery != LadderConstants.HoldbackDelivery.Vault) revert VaultRequiredForHoldback();
            if (p.holdbackBps > LadderConstants.holdbackCeilingBps(uint8(p.tier))) revert HoldbackCeiling();
        } else {
            p.holdbackDelivery = LadderConstants.HoldbackDelivery.None;
        }

        p.vaultRef = vaultRef;
    }
}
