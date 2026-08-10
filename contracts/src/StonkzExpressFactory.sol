// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IPoolManager} from "./v4/IPoolManager.sol";
import {BuybackAccumulator} from "./BuybackAccumulator.sol";
import {FeeLockerV2} from "./FeeLockerV2.sol";
import {StonkzFeeHook} from "./StonkzFeeHook.sol";
import {CTOGovernor} from "./CTOGovernor.sol";
import {StonkzDirectListing} from "./StonkzDirectListing.sol";
import {DeployControls} from "./DeployControls.sol";
import {Vanity} from "./Vanity.sol";

/// @title StonkzExpressFactory — gated Express (direct listing) deploy path
/// @notice Sole production entry for Express launches. CREATE2 salt =
///         keccak256(deployer, userSalt). Vanity: predicted address top bytes == 0x4663
///         (docs/03 VANITY PREFIX; docs/04).
contract StonkzExpressFactory is DeployControls {
    IPoolManager public immutable poolManager;
    FeeLockerV2 public immutable feeLocker;
    StonkzFeeHook public immutable hook;
    BuybackAccumulator public immutable accumulator;
    CTOGovernor public immutable ctoGovernor;
    address public immutable pairToken;
    /// @notice Protocol-token ref for side pools. address(0) until genesis.
    address public immutable stonkzRef;

    event ExpressListed(
        address indexed listing, address indexed token, address indexed creator, bytes32 userSalt, bytes32 salt
    );

    constructor(
        IPoolManager poolManager_,
        FeeLockerV2 feeLocker_,
        StonkzFeeHook hook_,
        BuybackAccumulator accumulator_,
        CTOGovernor ctoGovernor_,
        address pairToken_,
        address stonkzRef_
    ) DeployControls() {
        poolManager = poolManager_;
        feeLocker = feeLocker_;
        hook = hook_;
        accumulator = accumulator_;
        ctoGovernor = ctoGovernor_;
        pairToken = pairToken_;
        stonkzRef = stonkzRef_;
        // USDG (or other non-ETH quote): seed mid-band default. ETH already set in DeployControls.
        _seedUsdgRefDefault(pairToken_);
    }

    /// @notice CREATE2 salt binding deployer → prevents salt grief across allowlisted callers.
    function listingSalt(address deployer, bytes32 userSalt) public pure returns (bytes32) {
        return keccak256(abi.encode(deployer, userSalt));
    }

    /// @notice Init-code hash for a listing AFTER factory stamps (vanity miner input).
    /// @dev Must match the bytecode `list` deploys — stamps applied here identically.
    function listingInitCodeHash(StonkzDirectListing.ListingParams memory p) public view returns (bytes32) {
        _stampListingParams(p);
        return keccak256(
            abi.encodePacked(
                type(StonkzDirectListing).creationCode,
                abi.encode(poolManager, feeLocker, hook, accumulator, ctoGovernor, pairToken, stonkzRef, p)
            )
        );
    }

    /// @notice Predict CREATE2 address for a listing given init-code hash (vanity miner input).
    function predictListingAddress(address deployer, bytes32 userSalt, bytes32 initCodeHash)
        public
        view
        returns (address predicted)
    {
        bytes32 salt = listingSalt(deployer, userSalt);
        predicted = Vanity.predict(address(this), salt, initCodeHash);
    }

    /// @notice Deploy an Express listing. Gated by DeployControls (RIDER A birth = deployer-only).
    /// @dev Stamps side-pool + lock + ref-price factory defaults (docs/03; ruling B).
    ///      Reverts VanityPrefixMismatch if predicted address top bytes != 0x4663.
    /// @param userSalt Caller-chosen salt half; effective salt = listingSalt(msg.sender, userSalt).
    function list(StonkzDirectListing.ListingParams memory p, bytes32 userSalt)
        external
        returns (StonkzDirectListing listing)
    {
        _requireDeployAllowed(msg.sender);
        _stampListingParams(p);
        bytes32 salt = listingSalt(msg.sender, userSalt);
        bytes32 initHash = keccak256(
            abi.encodePacked(
                type(StonkzDirectListing).creationCode,
                abi.encode(poolManager, feeLocker, hook, accumulator, ctoGovernor, pairToken, stonkzRef, p)
            )
        );
        address predicted = Vanity.predict(address(this), salt, initHash);
        Vanity.requirePrefix(predicted);

        listing = new StonkzDirectListing{salt: salt}(
            poolManager, feeLocker, hook, accumulator, ctoGovernor, pairToken, stonkzRef, p
        );
        assert(address(listing) == predicted);
        emit ExpressListed(address(listing), address(listing.token()), p.creator, userSalt, salt);
    }

    function _stampListingParams(StonkzDirectListing.ListingParams memory p) internal view {
        p.createSidePool = defaultCreateSidePool;
        p.sidePoolBps = defaultSidePoolBps;
        p.liquidityLocked = defaultLiquidityLocked;
        p.stonkzRefPriceWad = p.createSidePool ? _requireRefPrice(pairToken) : 0;
    }
}
