// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IPoolManager} from "./v4/IPoolManager.sol";
import {PoolKey, PoolId, PoolIdLibrary} from "./v4/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "./v4/types/Currency.sol";
import {StonkzFeeHook} from "./StonkzFeeHook.sol";

/// @title FeeLockerV2 — custody registry + side-pool compounding (docs/03 lock stamp)
/// @notice Main-pool fee conversion crank REMOVED (FEECHAIN Phase 0 / docs/06).
///         Lock stamp (`liquidityLocked`, `unlockRecipient`) recorded per token at first
///         `lockPosition`. Withdraw of principal lives on Listing/Settlement (not here) —
///         this contract exposes gate views + `markWithdrawn` for registry integrity.
/// @dev Mint path unchanged: callers still `modifyLiquidity` themselves; FeeLocker only registers.
contract FeeLockerV2 {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    enum PoolKind {
        Main,
        Side
    }

    struct LockedPosition {
        PoolKey key;
        bytes32 positionId;
        PoolKind kind;
        address pairCurrency;
        address userToken;
        bool currency0IsPair;
        bool active;
        address registrar; // msg.sender at lockPosition (Listing/Settlement)
    }

    IPoolManager public immutable poolManager;
    StonkzFeeHook public immutable hook;

    uint256 public nextLockId;
    mapping(uint256 => LockedPosition) public locks;

    /// @notice Per-token lock stamp. Set once at first lockPosition for that token.
    mapping(address => bool) public liquidityLocked;
    /// @notice Per-token unlock recipient (creator), stamped immutable at first lock.
    mapping(address => address) public unlockRecipient;
    mapping(address => bool) public tokenStampSet;
    mapping(address => uint256[]) internal _lockIdsOf;

    event PositionLocked(
        uint256 indexed lockId,
        PoolId indexed poolId,
        PoolKind kind,
        bytes32 positionId,
        address indexed userToken,
        bool liquidityLocked_,
        address unlockRecipient_
    );
    event SideFeesCompounded(uint256 indexed lockId, uint256 fee0, uint256 fee1);
    event PositionWithdrawn(uint256 indexed lockId, address indexed userToken, address indexed by);

    error NotSide();
    error Inactive();
    error MainFeeCrankRetired();
    error LiquidityIsLocked();
    error NotUnlockRecipient();
    error NotRegistrar();
    error StampMismatch();
    error ZeroRecipient();

    constructor(IPoolManager poolManager_, StonkzFeeHook hook_) {
        poolManager = poolManager_;
        hook = hook_;
    }

    /// @notice Register a newly minted position and stamp lock terms on first lock for `userToken`.
    function lockPosition(
        PoolKey memory key,
        bytes32 positionId,
        PoolKind kind,
        address pairCurrency,
        address userToken,
        bool liquidityLocked_,
        address unlockRecipient_
    ) external returns (uint256 lockId) {
        if (unlockRecipient_ == address(0)) revert ZeroRecipient();
        if (tokenStampSet[userToken]) {
            if (liquidityLocked[userToken] != liquidityLocked_) revert StampMismatch();
            if (unlockRecipient[userToken] != unlockRecipient_) revert StampMismatch();
        } else {
            tokenStampSet[userToken] = true;
            liquidityLocked[userToken] = liquidityLocked_;
            unlockRecipient[userToken] = unlockRecipient_;
        }

        lockId = ++nextLockId;
        bool c0Pair = key.currency0.toAddress() == pairCurrency;
        locks[lockId] = LockedPosition({
            key: key,
            positionId: positionId,
            kind: kind,
            pairCurrency: pairCurrency,
            userToken: userToken,
            currency0IsPair: c0Pair,
            active: true,
            registrar: msg.sender
        });
        _lockIdsOf[userToken].push(lockId);
        emit PositionLocked(lockId, key.toId(), kind, positionId, userToken, liquidityLocked_, unlockRecipient_);
    }

    /// @notice Gate for Listing/Settlement withdraw. Reverts if locked or wrong caller.
    function requireCanWithdraw(address token, address caller) external view {
        if (!tokenStampSet[token]) revert Inactive();
        if (liquidityLocked[token]) revert LiquidityIsLocked();
        if (caller != unlockRecipient[token]) revert NotUnlockRecipient();
    }

    /// @notice Registrar marks a position inactive after successful principal withdraw.
    function markWithdrawn(uint256 lockId) external {
        LockedPosition storage lp = locks[lockId];
        if (!lp.active) revert Inactive();
        if (msg.sender != lp.registrar) revert NotRegistrar();
        if (liquidityLocked[lp.userToken]) revert LiquidityIsLocked();
        lp.active = false;
        emit PositionWithdrawn(lockId, lp.userToken, msg.sender);
    }

    function lockIdsOf(address token) external view returns (uint256[] memory) {
        return _lockIdsOf[token];
    }

    /// @notice RETIRED (FEECHAIN Phase 0). Conversion crank deleted per docs/06.
    function crankMainFees(uint256) external pure returns (uint256, uint256) {
        revert MainFeeCrankRetired();
    }

    /// @notice Permissionless: collect side-pool fees and compound into the same position.
    /// @dev UNCHANGED from FeeLocker v1 (§1.5 / spec §8.6 Side row).
    function crankSideCompound(uint256 lockId) external {
        LockedPosition storage lp = locks[lockId];
        if (!lp.active) revert Inactive();
        if (lp.kind != PoolKind.Side) revert NotSide();
        PoolId id = lp.key.toId();
        (uint256 fee0, uint256 fee1) = poolManager.collectFees(id, lp.positionId);
        if (fee0 == 0 && fee1 == 0) return;

        int256 liqDelta = int256(fee0 + fee1);
        if (liqDelta > 0) {
            poolManager.modifyLiquidity(
                lp.key,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: -887220,
                    tickUpper: 887220,
                    liquidityDelta: liqDelta,
                    salt: lp.positionId
                }),
                ""
            );
        }
        emit SideFeesCompounded(lockId, fee0, fee1);
    }
}
