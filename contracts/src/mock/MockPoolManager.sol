// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IPoolManager, ISwapHook} from "../v4/IPoolManager.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "../v4/types/BalanceDelta.sol";
import {PoolKey, PoolId, PoolIdLibrary} from "../v4/types/PoolKey.sol";
import {Currency} from "../v4/types/Currency.sol";
import {TickMath} from "../v4/TickMath.sol";

/// @title MockPoolManager — enough v4 semantics for settle / side-pool / FeeLocker (spec §8, M3)
/// @dev Dual-backend: C1/C2 harness injects IPoolManager; swap this for real v4 in M3.5 unchanged.
contract MockPoolManager is IPoolManager {
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;

    struct Slot0 {
        uint160 sqrtPriceX96;
        int24 tick;
        uint24 protocolFee;
        uint24 lpFee;
        bool initialized;
    }

    struct Position {
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 feesOwed0;
        uint256 feesOwed1;
    }

    mapping(PoolId => Slot0) public slots;
    mapping(PoolId => mapping(bytes32 => Position)) public positions;
    /// @dev Forced sync spend override for seam-attack tests (0 = free sync).
    mapping(PoolId => uint256) public syncCostOverride;

    // ─── M4/M3.5 hook seam ───────────────────────────────────────────────────
    mapping(PoolId => address) public hooks; // pool => StonkzFeeHook
    /// @dev Mock swap-fee rate in ppm applied to |amountSpecified| (default from key.fee).
    ///      Used only when key.fee != 0 (LP-fee path / legacy tests).
    mapping(PoolId => uint24) public feePpmOverride;
    /// @dev Explicit hook fee in bps when key.fee == 0 (docs/06 main pools). Default 100.
    ///      Vacuity guard: fee=0 must NOT imply feeAmount=0 when a hook is attached.
    mapping(PoolId => uint16) public hookFeeBps;
    mapping(PoolId => bool) public hookFeeBpsConfigured;
    uint16 public defaultHookFeeBps = 100; // Gate 1: factory default 100 bps (1%)

    event HookSet(PoolId indexed id, address hook);

    function setSyncCost(PoolId id, uint256 cost) external {
        syncCostOverride[id] = cost;
    }

    function setFeePpm(PoolId id, uint24 ppm) external {
        feePpmOverride[id] = ppm;
    }

    /// @notice Set per-pool hook fee in bps (Phase 1 / docs/06). Bounds enforced in Phase 3 factory.
    function setHookFeeBps(PoolId id, uint16 bps) external {
        hookFeeBps[id] = bps;
        hookFeeBpsConfigured[id] = true;
    }

    /// @notice Test helper: jump spot without a swap (front-run seam setup).
    function forcePrice(PoolId id, uint160 sqrtPriceX96) external {
        Slot0 storage s = slots[id];
        require(s.initialized, "init");
        s.sqrtPriceX96 = sqrtPriceX96;
        s.tick = TickMath.getTickAtSqrtRatio(sqrtPriceX96);
    }

    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external returns (int24 tick) {
        PoolId id = key.toId();
        Slot0 storage s = slots[id];
        if (s.initialized) revert PoolAlreadyInitialized();
        tick = TickMath.getTickAtSqrtRatio(sqrtPriceX96);
        s.sqrtPriceX96 = sqrtPriceX96;
        s.tick = tick;
        s.lpFee = key.fee;
        s.initialized = true;
        emit Initialize(id, sqrtPriceX96, tick);
    }

    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes calldata)
        external
        returns (BalanceDelta callerDelta, BalanceDelta feesAccrued)
    {
        PoolId id = key.toId();
        Slot0 storage s = slots[id];
        if (!s.initialized) revert PoolNotInitialized();

        bytes32 posId = keccak256(abi.encode(msg.sender, params.tickLower, params.tickUpper, params.salt));
        Position storage pos = positions[id][posId];

        if (params.liquidityDelta > 0) {
            pos.tickLower = params.tickLower;
            pos.tickUpper = params.tickUpper;
            pos.liquidity += uint128(uint256(params.liquidityDelta));
        } else if (params.liquidityDelta < 0) {
            uint128 remove = uint128(uint256(-params.liquidityDelta));
            require(pos.liquidity >= remove, "liq");
            pos.liquidity -= remove;
        }

        // Simplified delta: report zero cash flows (strategy tracks conservation off-chain of mock).
        callerDelta = BalanceDeltaLibrary.zero();
        feesAccrued = BalanceDeltaLibrary.zero();
        emit ModifyLiquidity(id, msg.sender, params.tickLower, params.tickUpper, params.liquidityDelta);
    }

    function setPoolHook(PoolId id, address hook) external {
        hooks[id] = hook;
        if (hook != address(0) && !hookFeeBpsConfigured[id]) {
            hookFeeBps[id] = defaultHookFeeBps;
            hookFeeBpsConfigured[id] = true;
        }
        emit HookSet(id, hook);
    }

    function poolHook(PoolId id) external view returns (address) {
        return hooks[id];
    }

    function swap(PoolKey memory key, SwapParams memory params, bytes calldata)
        external
        returns (BalanceDelta swapDelta)
    {
        PoolId id = key.toId();
        Slot0 storage s = slots[id];
        if (!s.initialized) revert PoolNotInitialized();

        // Move price to limit (or leave if already there). Exact accounting is not modeled.
        uint160 limit = params.sqrtPriceLimitX96;
        if (params.zeroForOne) {
            if (limit < s.sqrtPriceX96) {
                s.sqrtPriceX96 = limit < TickMath.MIN_SQRT_RATIO + 1 ? TickMath.MIN_SQRT_RATIO + 1 : limit;
                s.tick = TickMath.getTickAtSqrtRatio(s.sqrtPriceX96);
            }
        } else {
            if (limit > s.sqrtPriceX96) {
                s.sqrtPriceX96 = limit >= TickMath.MAX_SQRT_RATIO ? TickMath.MAX_SQRT_RATIO - 1 : limit;
                s.tick = TickMath.getTickAtSqrtRatio(s.sqrtPriceX96);
            }
        }

        int256 a0 = params.zeroForOne ? params.amountSpecified : int256(0);
        int256 a1 = params.zeroForOne ? int256(0) : params.amountSpecified;
        swapDelta = BalanceDeltaLibrary.from(int128(a0), int128(a1));
        emit Swap(id, msg.sender, a0, a1, s.sqrtPriceX96, s.tick);

        // Fee-take + hook callback (FEECHAIN Phase 1):
        //   key.fee == 0 (main) → feeAmount from explicit hookFeeBps (not key.fee).
        //   key.fee != 0 (side / legacy) → feeAmount from key.fee ppm (or override).
        address hook = hooks[id];
        if (hook != address(0)) {
            uint256 absAmt = params.amountSpecified < 0
                ? uint256(-params.amountSpecified)
                : uint256(params.amountSpecified);
            uint256 feeAmount;
            if (key.fee == 0) {
                feeAmount = (absAmt * uint256(hookFeeBps[id])) / 10_000;
            } else {
                uint24 ppm = feePpmOverride[id] != 0 ? feePpmOverride[id] : key.fee;
                feeAmount = (absAmt * ppm) / 1_000_000;
            }
            address tokenIn = params.zeroForOne
                ? Currency.unwrap(key.currency0)
                : Currency.unwrap(key.currency1);
            ISwapHook(hook).afterSwap(key, tokenIn, feeAmount);
        }
    }

    // convertTokenToPair REMOVED — FEECHAIN Phase 0 / docs/06.

    function syncToPrice(PoolKey memory key, uint160 targetSqrtPriceX96, uint256 maxBudget)
        external
        returns (uint256 spent)
    {
        PoolId id = key.toId();
        Slot0 storage s = slots[id];
        if (!s.initialized) {
            // Auto-init at target if never created (settle path).
            this.initialize(key, targetSqrtPriceX96);
            return 0;
        }
        spent = syncCostOverride[id];
        if (spent > maxBudget) revert SyncBudgetExceeded(spent, maxBudget);
        s.sqrtPriceX96 = targetSqrtPriceX96;
        s.tick = TickMath.getTickAtSqrtRatio(targetSqrtPriceX96);
    }

    function getSlot0(PoolId id)
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)
    {
        Slot0 storage s = slots[id];
        return (s.sqrtPriceX96, s.tick, s.protocolFee, s.lpFee);
    }

    function isInitialized(PoolId id) external view returns (bool) {
        return slots[id].initialized;
    }

    function accrueFees(PoolId id, bytes32 positionId, uint256 fee0, uint256 fee1) external {
        Position storage pos = positions[id][positionId];
        pos.feesOwed0 += fee0;
        pos.feesOwed1 += fee1;
    }

    function pendingFees(PoolId id, bytes32 positionId) external view returns (uint256 fee0, uint256 fee1) {
        Position storage pos = positions[id][positionId];
        return (pos.feesOwed0, pos.feesOwed1);
    }

    function collectFees(PoolId id, bytes32 positionId) external returns (uint256 fee0, uint256 fee1) {
        Position storage pos = positions[id][positionId];
        fee0 = pos.feesOwed0;
        fee1 = pos.feesOwed1;
        pos.feesOwed0 = 0;
        pos.feesOwed1 = 0;
    }

    function positionLiquidity(PoolId id, bytes32 positionId) external view returns (uint128) {
        return positions[id][positionId].liquidity;
    }
}
