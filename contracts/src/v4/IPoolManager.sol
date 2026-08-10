// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BalanceDelta} from "./types/BalanceDelta.sol";
import {PoolKey, PoolId} from "./types/PoolKey.sol";

/// @title ISwapHook — provisional fee seam (mock / pre-real-BeforeSwapDelta).
/// @dev StonkzFeeHook (docs/06): `feeCurrency` is the pair currency; `feeAmount` is the
///      pair-side take. Production target is BeforeSwapDelta; mock invokes this after
///      computing fee from stamped hookFeeBps. The hook MUST NOT revert the trade.
interface ISwapHook {
    function afterSwap(PoolKey calldata key, address feeCurrency, uint256 feeAmount) external;
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
        payable
        returns (BalanceDelta callerDelta, BalanceDelta feesAccrued);

    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData)
        external
        payable
        returns (BalanceDelta swapDelta);

    /// @notice Sync spot toward targetSqrt with a bounded pair-currency budget. Overrun → SyncBudgetExceeded.
    function syncToPrice(PoolKey memory key, uint160 targetSqrtPriceX96, uint256 maxBudget)
        external
        payable
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

    /// @notice Canonical fee collect: 0-delta modifyLiquidity → feesAccrued (V4-CANON).
    /// @dev Mock maps this onto collectFees using the registry positionId convention.
    function pokeCollect(PoolKey memory key, int24 tickLower, int24 tickUpper, bytes32 salt)
        external
        payable
        returns (uint256 fee0, uint256 fee1);

    // ─── M4 hook seam (fees-and-governance.md §1) ────────────────────────────

    /// @notice Attach a swap hook to a pool (called at pool creation by the listing/strategy).
    function setPoolHook(PoolId id, address hook) external;

    function poolHook(PoolId id) external view returns (address hook);

    // convertTokenToPair REMOVED (FEECHAIN Phase 0 / docs/06): not in canonical Uniswap v4;
    // M4 best-effort conversion path deleted. See docs/stop-task-feechain-phase0.md.
}
