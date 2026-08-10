// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IPoolManager} from "./v4/IPoolManager.sol";
import {BuybackAccumulator} from "./BuybackAccumulator.sol";
import {FeeLockerV2} from "./FeeLockerV2.sol";
import {StonkzFeeHook} from "./StonkzFeeHook.sol";
import {CTOGovernor} from "./CTOGovernor.sol";
import {StonkzDirectListing} from "./StonkzDirectListing.sol";
import {DeployControls} from "./DeployControls.sol";

/// @title StonkzExpressFactory — gated Express (direct listing) deploy path
/// @notice Sole production entry for Express launches. CREATE2-ready (RIDER C): salt =
///         keccak256(deployer, userSalt) so a later 0x4663 vanity check can attach without
///         restructuring. No vanity mining in this chain.
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
    /// @dev Vanity (docs/04): later require predicted address top bytes == 0x4663; salt formula stays.
    function listingSalt(address deployer, bytes32 userSalt) public pure returns (bytes32) {
        return keccak256(abi.encode(deployer, userSalt));
    }

    /// @notice Predict CREATE2 address for a listing given init-code hash (vanity miner input).
    function predictListingAddress(address deployer, bytes32 userSalt, bytes32 initCodeHash)
        public
        view
        returns (address predicted)
    {
        bytes32 salt = listingSalt(deployer, userSalt);
        predicted = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash))))
        );
    }

    /// @notice Deploy an Express listing. Gated by DeployControls (RIDER A birth = deployer-only).
    /// @dev Stamps side-pool + lock + ref-price factory defaults (docs/03; ruling B).
    /// @param userSalt Caller-chosen salt half; effective salt = listingSalt(msg.sender, userSalt).
    /// @dev Native pair: pass msg.value as ETH settle buffer for real PM (adapter refunds dust).
    function list(StonkzDirectListing.ListingParams memory p, bytes32 userSalt)
        external
        payable
        returns (StonkzDirectListing listing)
    {
        _requireDeployAllowed(msg.sender);
        p.createSidePool = defaultCreateSidePool;
        p.sidePoolBps = defaultSidePoolBps;
        p.liquidityLocked = defaultLiquidityLocked;
        // Ref: required when createSidePool; never a silent fallback (RefPriceUnset).
        p.stonkzRefPriceWad = p.createSidePool ? _requireRefPrice(pairToken) : 0;
        bytes32 salt = listingSalt(msg.sender, userSalt);
        listing = new StonkzDirectListing{salt: salt, value: msg.value}(
            poolManager, feeLocker, hook, accumulator, ctoGovernor, pairToken, stonkzRef, p
        );
        emit ExpressListed(address(listing), address(listing.token()), p.creator, userSalt, salt);
    }
}
