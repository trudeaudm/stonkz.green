// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IPoolManager} from "./v4/IPoolManager.sol";
import {PoolKey, PoolId, PoolIdLibrary} from "./v4/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "./v4/types/Currency.sol";
import {BuybackAccumulator} from "./BuybackAccumulator.sol";

/// @title FeeLocker — immutable custody for positions we create (spec §8.6)
/// @notice Main-pool fee crank RETIRED (FEECHAIN Phase 4 / docs/06). Ongoing main fees are
///         handled by StonkzFeeHook accrue-and-flush. Side: fees compound back into the same
///         position via permissionless crank — UNCHANGED.
/// @dev Constructor still takes BuybackAccumulator for ABI/deploy compatibility with launched
///      wiring; it is no longer invoked by any automatic fee path.
contract FeeLocker {
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
        address pairCurrency; // currency that is pair (USDG); other is user token
        address userToken;
        bool currency0IsPair;
        bool active;
    }

    IPoolManager public immutable poolManager;
    /// @dev Retained for deploy ABI compatibility; unused by fee cranks after Phase 4.
    BuybackAccumulator public immutable accumulator;
    address public immutable burnSink;

    uint256 public nextLockId;
    mapping(uint256 => LockedPosition) public locks;

    event PositionLocked(uint256 indexed lockId, PoolId indexed poolId, PoolKind kind, bytes32 positionId);
    event SideFeesCompounded(uint256 indexed lockId, uint256 fee0, uint256 fee1);

    error MainFeeCrankRetired();

    constructor(IPoolManager poolManager_, BuybackAccumulator accumulator_, address burnSink_) {
        poolManager = poolManager_;
        accumulator = accumulator_;
        burnSink = burnSink_ == address(0) ? address(0x000000000000000000000000000000000000dEaD) : burnSink_;
    }

    /// @notice Custody a newly created position (called by LiquidityStrategy).
    function lockPosition(
        PoolKey memory key,
        bytes32 positionId,
        PoolKind kind,
        address pairCurrency,
        address userToken
    ) external returns (uint256 lockId) {
        lockId = ++nextLockId;
        bool c0Pair = key.currency0.toAddress() == pairCurrency
            || (pairCurrency == address(0) && key.currency0.toAddress() == address(0));
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

    /// @notice RETIRED (FEECHAIN Phase 4). Main fees via StonkzFeeHook; no pair→BuybackAccumulator route.
    function crankMainFees(uint256) external pure returns (uint256, uint256) {
        revert MainFeeCrankRetired();
    }

    /// @notice Permissionless: collect side-pool fees and compound into same position (spec §8.6).
    /// @dev UNCHANGED — side-pool compounding is out of Phase 4 scope.
    function crankSideCompound(uint256 lockId) external {
        LockedPosition storage lp = locks[lockId];
        require(lp.active && lp.kind == PoolKind.Side, "side");
        PoolId id = lp.key.toId();
        (uint256 fee0, uint256 fee1) = poolManager.collectFees(id, lp.positionId);
        if (fee0 == 0 && fee1 == 0) return;

        // Re-deposit as liquidity delta proportional to fees (simplified: +fee1 as liquidity units).
        int256 liqDelta = int256(fee0 + fee1);
        if (liqDelta > 0) {
            // Read position bounds from mock via salt recreation not available — use zero-range compound marker.
            // Strategy stores salt = positionId; recreate modify with salt only if liquidity tracked.
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
