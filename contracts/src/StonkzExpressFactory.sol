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
/// @dev Child refs are owner-settable (stamp pattern): new lists copy current refs; prior
///      listings keep their immutable stamps (PREDEPLOY-REFIT Phase 1).
contract StonkzExpressFactory is DeployControls {
    IPoolManager public poolManager; // V4 adapter / PM
    FeeLockerV2 public feeLocker;
    StonkzFeeHook public hook;
    BuybackAccumulator public accumulator;
    CTOGovernor public ctoGovernor;
    address public pairToken;
    /// @notice Protocol-token ref for side pools. address(0) until genesis stand-in is set.
    address public sideTokenRef;

    event ExpressListed(
        address indexed listing, address indexed token, address indexed creator, bytes32 userSalt, bytes32 salt
    );
    event PoolManagerSet(address indexed poolManager);
    event FeeLockerSet(address indexed feeLocker);
    event HookSet(address indexed hook);
    event AccumulatorSet(address indexed accumulator);
    event GovernorSet(address indexed governor);
    event PairTokenSet(address indexed pairToken);
    event SideTokenRefSet(address indexed sideToken);

    error PoolManagerNotContract();
    error FeeLockerNotContract();
    error HookNotContract();
    error AccumulatorNotContract();
    error GovernorNotContract();
    error SideTokenRefNotContract();

    constructor(
        IPoolManager poolManager_,
        FeeLockerV2 feeLocker_,
        StonkzFeeHook hook_,
        BuybackAccumulator accumulator_,
        CTOGovernor ctoGovernor_,
        address pairToken_,
        address sideTokenRef_
    ) DeployControls() {
        _setPoolManager(address(poolManager_));
        _setFeeLocker(address(feeLocker_));
        _setHook(address(hook_));
        _setAccumulator(address(accumulator_));
        _setGovernor(address(ctoGovernor_));
        pairToken = pairToken_;
        emit PairTokenSet(pairToken_);
        _setSideTokenRef(sideTokenRef_);
    }

    function setPoolManager(address pm) external onlyOwner {
        _setPoolManager(pm);
    }

    function setFeeLocker(address locker) external onlyOwner {
        _setFeeLocker(locker);
    }

    function setHook(address hook_) external onlyOwner {
        _setHook(hook_);
    }

    function setAccumulator(address acc) external onlyOwner {
        _setAccumulator(acc);
    }

    function setGovernor(address gov) external onlyOwner {
        _setGovernor(gov);
    }

    /// @notice Pair currency for new lists (address(0)=ETH). Re-seeds USDG-style default for sideTokenRef.
    function setPairToken(address pair) external onlyOwner {
        pairToken = pair;
        emit PairTokenSet(pair);
        if (sideTokenRef != address(0)) _seedDefaultRefPrices(sideTokenRef, pair);
    }

    function setSideTokenRef(address sideToken) external onlyOwner {
        _setSideTokenRef(sideToken);
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
    /// @dev Stamps side-pool + lock + ref-price + child refs current at list (docs/03; ruling B).
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
        p.refPriceWad = p.createSidePool ? _requireRefPrice(sideTokenRef, pairToken) : 0;
        bytes32 salt = listingSalt(msg.sender, userSalt);
        listing = new StonkzDirectListing{salt: salt, value: msg.value}(
            poolManager, feeLocker, hook, accumulator, ctoGovernor, pairToken, sideTokenRef, p
        );
        emit ExpressListed(address(listing), address(listing.token()), p.creator, userSalt, salt);
    }

    function _setPoolManager(address pm) internal {
        if (pm == address(0) || pm.code.length == 0) revert PoolManagerNotContract();
        poolManager = IPoolManager(pm);
        emit PoolManagerSet(pm);
    }

    function _setFeeLocker(address locker) internal {
        if (locker == address(0) || locker.code.length == 0) revert FeeLockerNotContract();
        feeLocker = FeeLockerV2(locker);
        emit FeeLockerSet(locker);
    }

    function _setHook(address hook_) internal {
        if (hook_ == address(0) || hook_.code.length == 0) revert HookNotContract();
        hook = StonkzFeeHook(payable(hook_));
        emit HookSet(hook_);
    }

    function _setAccumulator(address acc) internal {
        if (acc == address(0) || acc.code.length == 0) revert AccumulatorNotContract();
        accumulator = BuybackAccumulator(payable(acc));
        emit AccumulatorSet(acc);
    }

    function _setGovernor(address gov) internal {
        if (gov == address(0) || gov.code.length == 0) revert GovernorNotContract();
        ctoGovernor = CTOGovernor(gov);
        emit GovernorSet(gov);
    }

    function _setSideTokenRef(address sideToken) internal {
        if (sideToken != address(0) && sideToken.code.length == 0) revert SideTokenRefNotContract();
        sideTokenRef = sideToken;
        emit SideTokenRefSet(sideToken);
        if (sideToken != address(0)) _seedDefaultRefPrices(sideToken, pairToken);
    }
}
