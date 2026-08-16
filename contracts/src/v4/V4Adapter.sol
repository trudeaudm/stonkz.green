// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IUnlockCallback} from "@v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IPoolManager as ICanonPM} from "@v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@v4-core/src/interfaces/IHooks.sol";
import {PoolKey as CanonPoolKey} from "@v4-core/src/types/PoolKey.sol";
import {PoolId as CanonPoolId} from "@v4-core/src/types/PoolId.sol";
import {Currency as CanonCurrency} from "@v4-core/src/types/Currency.sol";
import {BalanceDelta as CanonDelta} from "@v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams as CanonModParams, SwapParams as CanonSwapParams} from "@v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@v4-core/src/libraries/StateLibrary.sol";
import {CurrencySettler} from "@v4-core/test/utils/CurrencySettler.sol";
import {PoolIdLibrary as CanonPoolIdLibrary} from "@v4-core/src/types/PoolId.sol";

import {IPoolManager} from "./IPoolManager.sol";
import {PoolKey, PoolId, PoolIdLibrary} from "./types/PoolKey.sol";
import {Currency} from "./types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "./types/BalanceDelta.sol";

/// @title V4Adapter - unlock-callback bridge to canonical Uniswap v4 PoolManager
/// @notice Implements our minimal `IPoolManager` surface against a real PM (docs/03
///         real-v4-is-a-launch-gate; V4-GAP-ANALYSIS). Owns ALL PM interaction:
///         initialize passthrough, modifyLiquidity with settle/take netting (ERC20 + ETH),
///         poke-collect (0-delta → feesAccrued), swap-toward-target replacing syncToPrice
///         (budget semantics preserved - ours), StateLibrary reads for slot0/initialized.
/// @dev `setPoolHook` / `accrueFees` are mock-era seams: revert on this adapter (Phase 1
///      binds hooks via PoolKey.hooks at initialize).
contract V4Adapter is IPoolManager, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;
    using StateLibrary for ICanonPM;
    using CurrencySettler for CanonCurrency;
    using CanonPoolIdLibrary for CanonPoolKey;

    /// @dev Canonical singleton (or in-test Deployers manager).
    ICanonPM public immutable manager;

    /// @dev Owner (deployer); transfer to Safe for prod. Matches DeployControls / FeeHook pattern.
    address public owner;

    /// @dev When true, unlockCallback deliberately skips settle - canary vacuity guard.
    bool public breakNetting;

    error OnlyManager();
    error NotOwner();
    error MockSeamRetired(string which);
    error UnknownAction();
    error ZeroAddress();

    enum Action {
        ModifyLiquidity,
        Swap,
        SyncToPrice,
        CollectFees
    }

    struct ModCallback {
        Action action;
        address payer; // settles debts / receives credits
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        int256 liquidityDelta;
        bytes32 salt;
        bytes hookData;
        bool zeroForOne;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
        uint256 maxBudget; // syncToPrice pair-currency budget (ours)
        bytes32 positionId; // collectFees poke salt encoding
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(ICanonPM manager_) {
        manager = manager_;
        owner = msg.sender;
    }

    function transferOwnership(address next) external onlyOwner {
        if (next == address(0)) revert ZeroAddress();
        owner = next;
    }

    /// @notice Test/ops canary: next unlock skips currency settle → CurrencyNotSettled.
    /// @dev Was: `function setBreakNetting(bool broken) external` (unauthed — anyone could DoS).
    function setBreakNetting(bool broken) external onlyOwner {
        breakNetting = broken;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // IPoolManager - reads (StateLibrary / extsload)
    // ═══════════════════════════════════════════════════════════════════════

    /// @inheritdoc IPoolManager
    /// @dev Convention: initialized iff sqrtPriceX96 != 0 (StateLibrary.getSlot0).
    function isInitialized(PoolId id) external view returns (bool) {
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(CanonPoolId.wrap(PoolId.unwrap(id)));
        return sqrtPriceX96 != 0;
    }

    /// @inheritdoc IPoolManager
    function getSlot0(PoolId id)
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)
    {
        return manager.getSlot0(CanonPoolId.wrap(PoolId.unwrap(id)));
    }

    function poolHook(PoolId) external pure returns (address) {
        return address(0); // hooks live in PoolKey; no mutable registry on canonical PM
    }

    // ═══════════════════════════════════════════════════════════════════════
    // IPoolManager - initialize (no unlock required)
    // ═══════════════════════════════════════════════════════════════════════

    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external returns (int24 tick) {
        return manager.initialize(_toCanonKey(key), sqrtPriceX96);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // IPoolManager - unlock-gated ops
    // ═══════════════════════════════════════════════════════════════════════

    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes calldata hookData)
        external
        payable
        returns (BalanceDelta callerDelta, BalanceDelta feesAccrued)
    {
        bytes memory raw = manager.unlock(
            abi.encode(
                ModCallback({
                    action: Action.ModifyLiquidity,
                    payer: msg.sender,
                    key: key,
                    tickLower: params.tickLower,
                    tickUpper: params.tickUpper,
                    liquidityDelta: params.liquidityDelta,
                    salt: params.salt,
                    hookData: hookData,
                    zeroForOne: false,
                    amountSpecified: 0,
                    sqrtPriceLimitX96: 0,
                    maxBudget: 0,
                    positionId: bytes32(0)
                })
            )
        );
        (CanonDelta d, CanonDelta fees) = abi.decode(raw, (CanonDelta, CanonDelta));
        callerDelta = BalanceDelta.wrap(CanonDelta.unwrap(d));
        feesAccrued = BalanceDelta.wrap(CanonDelta.unwrap(fees));
        _refundDustEth(msg.sender);
    }

    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData)
        external
        payable
        returns (BalanceDelta swapDelta)
    {
        bytes memory raw = manager.unlock(
            abi.encode(
                ModCallback({
                    action: Action.Swap,
                    payer: msg.sender,
                    key: key,
                    tickLower: 0,
                    tickUpper: 0,
                    liquidityDelta: 0,
                    salt: bytes32(0),
                    hookData: hookData,
                    zeroForOne: params.zeroForOne,
                    amountSpecified: params.amountSpecified,
                    sqrtPriceLimitX96: params.sqrtPriceLimitX96,
                    maxBudget: 0,
                    positionId: bytes32(0)
                })
            )
        );
        CanonDelta d = abi.decode(raw, (CanonDelta));
        swapDelta = BalanceDelta.wrap(CanonDelta.unwrap(d));
        _refundDustEth(msg.sender);
    }

    /// @inheritdoc IPoolManager
    /// @dev Budget semantics (ours): spend at most `maxBudget` of pair currency (currency that
    ///      decreases when moving toward target). Exact-in swaps until sqrtPrice reaches target
    ///      or budget exhausted → SyncBudgetExceeded. Replaces mock syncToPrice.
    function syncToPrice(PoolKey memory key, uint160 targetSqrtPriceX96, uint256 maxBudget)
        external
        payable
        returns (uint256 spent)
    {
        bytes memory raw = manager.unlock(
            abi.encode(
                ModCallback({
                    action: Action.SyncToPrice,
                    payer: msg.sender,
                    key: key,
                    tickLower: 0,
                    tickUpper: 0,
                    liquidityDelta: 0,
                    salt: bytes32(0),
                    hookData: "",
                    zeroForOne: false,
                    amountSpecified: 0,
                    sqrtPriceLimitX96: targetSqrtPriceX96,
                    maxBudget: maxBudget,
                    positionId: bytes32(0)
                })
            )
        );
        spent = abi.decode(raw, (uint256));
        _refundDustEth(msg.sender);
    }

    /// @inheritdoc IPoolManager
    /// @dev Use pokeCollect for canonical fee collection. Kept to satisfy IPoolManager.
    function collectFees(PoolId, bytes32) external pure returns (uint256, uint256) {
        revert MockSeamRetired("collectFees: use pokeCollect(key,ticks,salt)");
    }

    /// @notice Canonical fee collect: 0-delta modifyLiquidity, take positive fee deltas to `msg.sender`.
    function pokeCollect(PoolKey memory key, int24 tickLower, int24 tickUpper, bytes32 salt)
        external
        payable
        returns (uint256 fee0, uint256 fee1)
    {
        bytes memory raw = manager.unlock(
            abi.encode(
                ModCallback({
                    action: Action.CollectFees,
                    payer: msg.sender,
                    key: key,
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    liquidityDelta: 0,
                    salt: salt,
                    hookData: "",
                    zeroForOne: false,
                    amountSpecified: 0,
                    sqrtPriceLimitX96: 0,
                    maxBudget: 0,
                    positionId: salt
                })
            )
        );
        (fee0, fee1) = abi.decode(raw, (uint256, uint256));
        _refundDustEth(msg.sender);
    }

    function accrueFees(PoolId, bytes32, uint256, uint256) external pure {
        revert MockSeamRetired("accrueFees");
    }

    function pendingFees(PoolId, bytes32) external pure returns (uint256, uint256) {
        revert MockSeamRetired("pendingFees");
    }

    function setPoolHook(PoolId, address) external pure {
        revert MockSeamRetired("setPoolHook - hooks bind via PoolKey.hooks at initialize");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // unlock callback
    // ═══════════════════════════════════════════════════════════════════════

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert OnlyManager();
        ModCallback memory data = abi.decode(rawData, (ModCallback));

        if (data.action == Action.ModifyLiquidity) {
            return _modLiq(data);
        }
        if (data.action == Action.Swap) {
            return _swap(data);
        }
        if (data.action == Action.SyncToPrice) {
            return _syncToPrice(data);
        }
        if (data.action == Action.CollectFees) {
            return _pokeCollect(data);
        }
        revert UnknownAction();
    }

    function _modLiq(ModCallback memory data) internal returns (bytes memory) {
        CanonPoolKey memory ckey = _toCanonKey(data.key);
        (CanonDelta delta, CanonDelta fees) = manager.modifyLiquidity(
            ckey,
            CanonModParams({
                tickLower: data.tickLower,
                tickUpper: data.tickUpper,
                liquidityDelta: data.liquidityDelta,
                salt: data.salt
            }),
            data.hookData
        );
        if (!breakNetting) {
            _settleDelta(ckey, delta, data.payer);
        }
        // feesAccrued informational; principal path settles `delta` only (fees in delta when removing)
        return abi.encode(delta, fees);
    }

    function _swap(ModCallback memory data) internal returns (bytes memory) {
        CanonPoolKey memory ckey = _toCanonKey(data.key);
        CanonDelta delta = manager.swap(
            ckey,
            CanonSwapParams({
                zeroForOne: data.zeroForOne,
                amountSpecified: data.amountSpecified,
                sqrtPriceLimitX96: data.sqrtPriceLimitX96
            }),
            data.hookData
        );
        if (!breakNetting) {
            _settleDelta(ckey, delta, data.payer);
        }
        return abi.encode(delta);
    }

    function _syncToPrice(ModCallback memory data) internal returns (bytes memory) {
        CanonPoolKey memory ckey = _toCanonKey(data.key);
        CanonPoolId id = ckey.toId();
        (uint160 curSqrt,,,) = manager.getSlot0(id);

        if (curSqrt == 0) {
            // Auto-init at target (mock parity).
            manager.initialize(ckey, data.sqrtPriceLimitX96);
            return abi.encode(uint256(0));
        }
        if (curSqrt == data.sqrtPriceLimitX96) {
            return abi.encode(uint256(0));
        }

        bool zeroForOne = data.sqrtPriceLimitX96 < curSqrt;
        // Exact-in of up to maxBudget in the input currency.
        int256 amountSpecified = -int256(data.maxBudget);
        if (amountSpecified == 0) revert IPoolManager.SyncBudgetExceeded(0, data.maxBudget);

        CanonDelta delta = manager.swap(
            ckey,
            CanonSwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: data.sqrtPriceLimitX96
            }),
            ""
        );

        // Spent = abs of input currency delta (negative means we paid).
        int128 d0 = delta.amount0();
        int128 d1 = delta.amount1();
        uint256 spent;
        if (zeroForOne) {
            spent = d0 < 0 ? uint256(uint128(-d0)) : 0;
        } else {
            spent = d1 < 0 ? uint256(uint128(-d1)) : 0;
        }

        if (!breakNetting) {
            _settleDelta(ckey, delta, data.payer);
        }

        (uint160 afterSqrt,,,) = manager.getSlot0(id);
        if (afterSqrt != data.sqrtPriceLimitX96 && spent >= data.maxBudget) {
            revert IPoolManager.SyncBudgetExceeded(spent, data.maxBudget);
        }
        return abi.encode(spent);
    }

    function _pokeCollect(ModCallback memory data) internal returns (bytes memory) {
        CanonPoolKey memory ckey = _toCanonKey(data.key);
        (CanonDelta delta, CanonDelta fees) = manager.modifyLiquidity(
            ckey,
            CanonModParams({
                tickLower: data.tickLower,
                tickUpper: data.tickUpper,
                liquidityDelta: 0,
                salt: data.salt
            }),
            ""
        );
        // Prefer feesAccrued; fall back to delta if fees packed there.
        int128 f0 = fees.amount0();
        int128 f1 = fees.amount1();
        if (f0 == 0 && f1 == 0) {
            f0 = delta.amount0();
            f1 = delta.amount1();
        }
        if (!breakNetting) {
            if (f0 > 0) ckey.currency0.take(manager, data.payer, uint256(uint128(f0)), false);
            if (f1 > 0) ckey.currency1.take(manager, data.payer, uint256(uint128(f1)), false);
            // Settle any unexpected debts from poke.
            if (f0 < 0) ckey.currency0.settle(manager, data.payer, uint256(uint128(-f0)), false);
            if (f1 < 0) ckey.currency1.settle(manager, data.payer, uint256(uint128(-f1)), false);
        }
        uint256 fee0 = f0 > 0 ? uint256(uint128(f0)) : 0;
        uint256 fee1 = f1 > 0 ? uint256(uint128(f1)) : 0;
        return abi.encode(fee0, fee1);
    }

    function _settleDelta(CanonPoolKey memory ckey, CanonDelta delta, address payer) internal {
        int128 d0 = delta.amount0();
        int128 d1 = delta.amount1();
        if (d0 < 0) ckey.currency0.settle(manager, payer, uint256(uint128(-d0)), false);
        if (d1 < 0) ckey.currency1.settle(manager, payer, uint256(uint128(-d1)), false);
        if (d0 > 0) ckey.currency0.take(manager, payer, uint256(uint128(d0)), false);
        if (d1 > 0) ckey.currency1.take(manager, payer, uint256(uint128(d1)), false);
    }

    function _toCanonKey(PoolKey memory key) internal pure returns (CanonPoolKey memory ckey) {
        ckey = CanonPoolKey({
            currency0: CanonCurrency.wrap(Currency.unwrap(key.currency0)),
            currency1: CanonCurrency.wrap(Currency.unwrap(key.currency1)),
            fee: key.fee,
            tickSpacing: key.tickSpacing,
            hooks: IHooks(key.hooks)
        });
    }

    function _refundDustEth(address to) internal {
        uint256 bal = address(this).balance;
        if (bal > 0) {
            (bool ok,) = to.call{value: bal}("");
            require(ok, "eth refund");
        }
    }

    receive() external payable {}
}
