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
/// @notice Production PM surface: initialize / modifyLiquidity / pokeCollect are allowlisted
///         (adapter-owned positions; public salts). swap and syncToPrice stay permissionless;
///         sync never auto-inits. Ownable administers the allowlist (Safe after deploy).
/// @dev Reentrancy: unlockCallback is onlyManager; settle/take target the canonical PM; ETH
///      refund is a plain value-send after unlock. No extra guard — PM unlock serializes.
///      `setPoolHook` / `accrueFees` are mock-era seams: revert. breakNetting removed —
///      CurrencyNotSettled canary lives in test/harness/SkipSettleCanary only.
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

    /// @notice Addresses allowed for initialize / modifyLiquidity / pokeCollect / authorizeChild.
    mapping(address => bool) public authorized;

    error OnlyManager();
    error NotOwner();
    error NotAuthorized();
    error MockSeamRetired(string which);
    error UnknownAction();
    error ZeroAddress();

    event Authorized(address indexed account, bool allowed);

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

    modifier onlyAuthorized() {
        if (!authorized[msg.sender]) revert NotAuthorized();
        _;
    }

    constructor(ICanonPM manager_) {
        if (address(manager_) == address(0)) revert ZeroAddress();
        manager = manager_;
        owner = msg.sender;
    }

    function transferOwnership(address next) external onlyOwner {
        if (next == address(0)) revert ZeroAddress();
        owner = next;
    }

    function setAuthorized(address account, bool allowed) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        authorized[account] = allowed;
        emit Authorized(account, allowed);
    }

    /// @inheritdoc IPoolManager
    /// @notice Allowlist a CREATE2-predicted child so its constructor can mint/initialize.
    /// @dev Caller must already be authorized (factory). Called by `list` before CREATE2.
    function authorizeChild(address child) external {
        if (!authorized[msg.sender]) revert NotAuthorized();
        if (child == address(0)) revert ZeroAddress();
        authorized[child] = true;
        emit Authorized(child, true);
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

    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external onlyAuthorized returns (int24 tick) {
        return manager.initialize(_toCanonKey(key), sqrtPriceX96);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // IPoolManager - unlock-gated ops
    // ═══════════════════════════════════════════════════════════════════════

    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes calldata hookData)
        external
        payable
        onlyAuthorized
        returns (BalanceDelta callerDelta, BalanceDelta feesAccrued)
    {
        uint256 priorEth = address(this).balance - msg.value;
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
        _refundDustEth(msg.sender, priorEth);
    }

    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData)
        external
        payable
        returns (BalanceDelta swapDelta)
    {
        uint256 priorEth = address(this).balance - msg.value;
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
        _refundDustEth(msg.sender, priorEth);
    }

    /// @inheritdoc IPoolManager
    /// @dev Budget semantics (ours): spend at most `maxBudget` of pair currency (currency that
    ///      decreases when moving toward target). Exact-in swaps until sqrtPrice reaches target
    ///      or budget exhausted → SyncBudgetExceeded. Reverts if pool uninitialized (no auto-init).
    function syncToPrice(PoolKey memory key, uint160 targetSqrtPriceX96, uint256 maxBudget)
        external
        payable
        returns (uint256 spent)
    {
        uint256 priorEth = address(this).balance - msg.value;
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
        _refundDustEth(msg.sender, priorEth);
    }

    /// @inheritdoc IPoolManager
    /// @dev Use pokeCollect for canonical fee collection. Kept to satisfy IPoolManager.
    function collectFees(PoolId, bytes32) external pure returns (uint256, uint256) {
        revert MockSeamRetired("collectFees: use pokeCollect(key,ticks,salt)");
    }

    /// @notice Canonical fee collect: 0-delta modifyLiquidity, take positive fee deltas to `msg.sender`.
    /// @dev Allowlisted — fees take to caller is a theft surface if ungated (Phase 0 ruling).
    function pokeCollect(PoolKey memory key, int24 tickLower, int24 tickUpper, bytes32 salt)
        external
        payable
        onlyAuthorized
        returns (uint256 fee0, uint256 fee1)
    {
        uint256 priorEth = address(this).balance - msg.value;
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
        _refundDustEth(msg.sender, priorEth);
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
        _settleDelta(ckey, delta, data.payer);
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
        _settleDelta(ckey, delta, data.payer);
        return abi.encode(delta);
    }

    function _syncToPrice(ModCallback memory data) internal returns (bytes memory) {
        CanonPoolKey memory ckey = _toCanonKey(data.key);
        CanonPoolId id = ckey.toId();
        (uint160 curSqrt,,,) = manager.getSlot0(id);

        if (curSqrt == 0) {
            revert PoolNotInitialized();
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

        _settleDelta(ckey, delta, data.payer);

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
        if (f0 > 0) ckey.currency0.take(manager, data.payer, uint256(uint128(f0)), false);
        if (f1 > 0) ckey.currency1.take(manager, data.payer, uint256(uint128(f1)), false);
        // Settle any unexpected debts from poke.
        if (f0 < 0) ckey.currency0.settle(manager, data.payer, uint256(uint128(-f0)), false);
        if (f1 < 0) ckey.currency1.settle(manager, data.payer, uint256(uint128(-f1)), false);
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

    /// @dev Refund only unused ETH from this call; never prior stuck balance.
    function _refundDustEth(address to, uint256 priorEth) internal {
        uint256 bal = address(this).balance;
        if (bal > priorEth) {
            uint256 refund = bal - priorEth;
            (bool ok,) = to.call{value: refund}("");
            require(ok, "eth refund");
        }
    }

    receive() external payable {}
}
