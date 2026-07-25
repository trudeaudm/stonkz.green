// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IPoolManager} from "./v4/IPoolManager.sol";
import {PoolKey, PoolId, PoolIdLibrary} from "./v4/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "./v4/types/Currency.sol";
import {StonkzFeeHook} from "./StonkzFeeHook.sol";

/// @title FeeLockerV2 — immutable custody + hook-integrated main-pool fee accounting
/// @notice fees-and-governance.md §1.5 / spec §8.6. New launches use v2: the primary pool's
///         ongoing fees are handled by StonkzFeeHook (per-swap take + best-effort convert +
///         80/20 split). Side-pool compounding is UNCHANGED from FeeLocker v1 (fees compound
///         back into the same position via a permissionless crank).
/// @dev Per-token immutability: tokens already launched under v1 keep v1 (no migration).
///      No admin, no upgradeability.
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
    }

    IPoolManager public immutable poolManager;
    StonkzFeeHook public immutable hook;

    uint256 public nextLockId;
    mapping(uint256 => LockedPosition) public locks;

    event PositionLocked(uint256 indexed lockId, PoolId indexed poolId, PoolKind kind, bytes32 positionId);
    event MainFeesCranked(uint256 indexed lockId, address indexed token, uint256 tokenIn, uint256 pairOut);
    event SideFeesCompounded(uint256 indexed lockId, uint256 fee0, uint256 fee1);

    error NotMain();
    error NotSide();
    error Inactive();

    constructor(IPoolManager poolManager_, StonkzFeeHook hook_) {
        poolManager = poolManager_;
        hook = hook_;
    }

    /// @notice Custody a newly created position (called by the listing/strategy).
    function lockPosition(
        PoolKey memory key,
        bytes32 positionId,
        PoolKind kind,
        address pairCurrency,
        address userToken
    ) external returns (uint256 lockId) {
        lockId = ++nextLockId;
        bool c0Pair = key.currency0.toAddress() == pairCurrency;
        locks[lockId] = LockedPosition({
            key: key,
            positionId: positionId,
            kind: kind,
            pairCurrency: pairCurrency,
            userToken: userToken,
            currency0IsPair: c0Pair,
            active: true
        });
        emit PositionLocked(lockId, key.toId(), kind, positionId);
    }

    /// @notice Permissionless: route main-pool fees via the hook's bounded conversion + 80/20
    ///         split (§1). Ongoing per-swap fees are already taken by the hook; this cranks the
    ///         accrual fallback for any conversions that were deferred.
    function crankMainFees(uint256 lockId) external returns (uint256 tokenIn, uint256 pairOut) {
        LockedPosition storage lp = locks[lockId];
        if (!lp.active) revert Inactive();
        if (lp.kind != PoolKind.Main) revert NotMain();
        (tokenIn, pairOut) = hook.crankConvert(lp.userToken);
        emit MainFeesCranked(lockId, lp.userToken, tokenIn, pairOut);
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
