// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BalanceDelta} from "./types/BalanceDelta.sol";
import {PoolKey, PoolId} from "./types/PoolKey.sol";

/// @title ISwapHook — v4-style hook callback invoked by the PoolManager after a swap.
/// @dev StonkzFeeHook implements this (fees-and-governance.md §1). `feeAmount` is denominated
///      in `tokenIn` (the currency the trader paid). The hook MUST NOT revert — a trade can
///      never fail because of hook fee logic (§1.2).
interface ISwapHook {
    function afterSwap(PoolKey calldata key, address tokenIn, uint256 feeAmount) external;
}

/// @title IPoolManager — minimal Uniswap v4 surface for STONKZ settlement (spec §8)
/// @dev Interface-first: MockPoolManager implements this for M3; M3.5 wraps real v4-core.
interface IPoolManager {
    struct ModifyLiquidityParams {
        int24 tickLower;
        int24 tickUpper;
        int256 liquidityDelta;
        bytes32 salt;
    }

    struct SwapParams {
        bool zeroForOne;
        int256 amountSpecified; // negative = exactIn
        uint160 sqrtPriceLimitX96;
    }

    error PoolAlreadyInitialized();
    error PoolNotInitialized();
    error SyncBudgetExceeded(uint256 spent, uint256 budget);
    error PriceNotSynced(uint160 current, uint160 target);

    event Initialize(PoolId indexed id, uint160 sqrtPriceX96, int24 tick);
    event ModifyLiquidity(PoolId indexed id, address indexed sender, int24 tickLower, int24 tickUpper, int256 liquidityDelta);
    event Swap(PoolId indexed id, address indexed sender, int256 amount0, int256 amount1, uint160 sqrtPriceX96, int24 tick);

    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external returns (int24 tick);

    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes calldata hookData)
        external
        returns (BalanceDelta callerDelta, BalanceDelta feesAccrued);

    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData)
        external
        returns (BalanceDelta swapDelta);

    /// @notice Sync spot toward targetSqrt with a bounded pair-currency budget. Overrun → SyncBudgetExceeded.
    function syncToPrice(PoolKey memory key, uint160 targetSqrtPriceX96, uint256 maxBudget)
        external
        returns (uint256 spent);

    function getSlot0(PoolId id)
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee);

    function isInitialized(PoolId id) external view returns (bool);

    /// @notice Accrue mock fees onto a position (test / FeeLocker crank).
    function accrueFees(PoolId id, bytes32 positionId, uint256 fee0, uint256 fee1) external;

    function pendingFees(PoolId id, bytes32 positionId) external view returns (uint256 fee0, uint256 fee1);

    function collectFees(PoolId id, bytes32 positionId)
        external
        returns (uint256 fee0, uint256 fee1);

    // ─── M4 hook seam (fees-and-governance.md §1) ────────────────────────────

    /// @notice Attach a swap hook to a pool (called at pool creation by the listing/strategy).
    function setPoolHook(PoolId id, address hook) external;

    function poolHook(PoolId id) external view returns (address hook);

    /// @notice Best-effort ONE-shot conversion of `tokenAmount` (user token) → pair currency,
    ///         re-entering the SAME pool (§1.1). Reverts on failure so the hook can accrue (§1.2).
    function convertTokenToPair(PoolKey memory key, uint256 tokenAmount) external returns (uint256 pairOut);
}
