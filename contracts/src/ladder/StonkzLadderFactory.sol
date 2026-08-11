// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {StonkzLadderAuction} from "./StonkzLadderAuction.sol";
import {LadderConstants} from "./LadderConstants.sol";
import {DeployControls} from "../DeployControls.sol";
import {Vanity} from "../Vanity.sol";

/// @title StonkzLadderFactory — filing gate for ladder auctions (modularity)
/// @notice Owner-settable vault + settlement + sideTokenRef + carve default.
///         HoldbackPct > 0 reverts while vault unset. carveBps stamped immutably per auction
///         at filing (FEECHAIN stamp pattern). DeployControls gate every `file` (docs/03).
///         CREATE2 + 0x4663 vanity (docs/03 VANITY PREFIX): salt = keccak256(deployer, userSalt).
contract StonkzLadderFactory is DeployControls {
    address public vaultRef;
    /// @notice Optional settlement stamped into new filings (may be address(0); auction can wire later).
    address public settlementRef;
    /// @notice Protocol-token ref for side-pool price lookup. address(0) until stand-in/genesis set.
    address public sideTokenRef;
    /// @notice Mutable default carve for new filings. Bounds [0, CARVE_BPS_MAX]. Unit: bps of raised.
    uint16 public defaultCarveBps = LadderConstants.DEFAULT_CARVE_BPS; // bps of raised

    event VaultRefSet(address indexed vault);
    event SettlementRefSet(address indexed settlement);
    event SideTokenRefSet(address indexed sideToken);
    event DefaultCarveBpsSet(uint16 bps);
    event AuctionFiled(
        address indexed auction, address indexed creator, uint16 holdbackBps, uint16 carveBps, bytes32 userSalt, bytes32 salt
    );

    error VaultRequiredForHoldback();
    error VaultRefNotContract();
    error SettlementRefNotContract();
    error SideTokenRefNotContract();
    /// @dev createSidePool=true requires factory.sideTokenRef set (no silent park).
    error SideTokenRefUnset();
    error HoldbackCeiling();
    error CarveBounds();

    constructor() DeployControls() {}

    /// @notice Set the Management Vault ref. Target MUST have code (EOA/empty reverts).
    function setVaultRef(address vault) external onlyOwner {
        if (vault != address(0) && vault.code.length == 0) revert VaultRefNotContract();
        vaultRef = vault;
        emit VaultRefSet(vault);
    }

    /// @notice Set settlement stamped into new `file`s. Target MUST have code if non-zero.
    function setSettlementRef(address settlement) external onlyOwner {
        if (settlement != address(0) && settlement.code.length == 0) revert SettlementRefNotContract();
        settlementRef = settlement;
        emit SettlementRefSet(settlement);
    }

    /// @notice Set side-token ref for ref-price lookup. Seeds ETH default when non-zero.
    function setSideTokenRef(address sideToken) external onlyOwner {
        if (sideToken != address(0) && sideToken.code.length == 0) revert SideTokenRefNotContract();
        sideTokenRef = sideToken;
        emit SideTokenRefSet(sideToken);
        if (sideToken != address(0)) _seedDefaultRefPrices(sideToken, address(0));
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

    /// @notice File a ladder auction without CREATE2 vanity (compat / unit tests).
    /// @dev Production path is `file(p, userSalt)` with 0x4663 prefix. Same stamps either way.
    function file(StonkzLadderAuction.Params memory p) external returns (StonkzLadderAuction auction) {
        _requireDeployAllowed(msg.sender);
        _stampAuctionParams(p);
        auction = new StonkzLadderAuction(p);
        emit AuctionFiled(address(auction), p.creator, p.holdbackBps, p.carveBps, bytes32(0), bytes32(0));
    }

    /// @notice File a ladder auction. Stamps current defaultCarveBps (or explicit p.carveBps if set).
    /// @dev Pass carveBps=type(uint16).max to mean "use factory default".
    ///      Side-pool switches (createSidePool, sidePoolBps) are ALWAYS stamped from factory defaults.
    ///      vaultRef / settlementRef stamped from factory; prior auctions keep their stamps.
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
        // Loud unset: createSidePool=true requires sideTokenRef (mirror Express SideTokenRefUnset).
        if (p.createSidePool && sideTokenRef == address(0)) revert SideTokenRefUnset();
        // Switch 1 stamped via auction constructor reading DeployControls(msg.sender).
        // Ref price: pair-wei per side-token, WAD — required iff createSidePool.
        p.refPriceWad = p.createSidePool ? _requireRefPrice(sideTokenRef, p.pairToken) : 0;

        if (p.holdbackBps > 0) {
            if (vaultRef == address(0)) revert VaultRequiredForHoldback();
            if (p.holdbackDelivery != LadderConstants.HoldbackDelivery.Vault) revert VaultRequiredForHoldback();
            if (p.holdbackBps > LadderConstants.holdbackCeilingBps(uint8(p.tier))) revert HoldbackCeiling();
        } else {
            p.holdbackDelivery = LadderConstants.HoldbackDelivery.None;
        }

        p.vaultRef = vaultRef;
        // Stamp settlement when factory ref is set; else keep Params (direct / test wire).
        if (settlementRef != address(0)) {
            p.settlement = settlementRef;
        }
    }
}
