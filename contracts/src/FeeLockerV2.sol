// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IPoolManager} from "./v4/IPoolManager.sol";
import {PoolKey, PoolId, PoolIdLibrary} from "./v4/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "./v4/types/Currency.sol";
import {StonkzFeeHook} from "./StonkzFeeHook.sol";

/// @title FeeLockerV2 — immutable custody; side-pool compounding
/// @notice Main-pool fee conversion crank REMOVED (FEECHAIN Phase 0 / docs/06).
///         Ongoing main fees are handled by StonkzFeeHook. Side-pool compounding is
///         UNCHANGED from FeeLocker v1.
/// @dev Per-token immutability: tokens already launched under v1 keep v1 (no migration).
///      No admin, no upgradeability. crankMainFees retired — Phase 4 severs FeeLocker main route.
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
    event SideFeesCompounded(uint256 indexed lockId, uint256 fee0, uint256 fee1);

    error NotSide();
    error Inactive();
    error MainFeeCrankRetired(); // Phase 0: conversion crank deleted

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
