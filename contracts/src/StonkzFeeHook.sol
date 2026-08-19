// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IHooks} from "@v4-core/src/interfaces/IHooks.sol";
import {IPoolManager as ICanonPM} from "@v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@v4-core/src/libraries/Hooks.sol";
import {PoolKey as CanonPoolKey} from "@v4-core/src/types/PoolKey.sol";
import {BalanceDelta as CanonDelta} from "@v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams as CanonModParams, SwapParams as CanonSwapParams} from "@v4-core/src/types/PoolOperation.sol";
import {Currency as CanonCurrency} from "@v4-core/src/types/Currency.sol";
import {CurrencySettler} from "@v4-core/test/utils/CurrencySettler.sol";

import {IPoolManager, ISwapHook} from "./v4/IPoolManager.sol";
import {PoolKey, PoolId, PoolIdLibrary} from "./v4/types/PoolKey.sol";
import {ICTOGovernor, IFeeReceiverRegistry} from "./interfaces/IStonkzGovernance.sol";

/// @title StonkzFeeHook — canonical IHooks fee take + accrue-and-flush (docs/06; V4-CANON)
/// @notice Pair-currency fee only (docs/06): never a percentage of a launch-token count, never
///         custodied in launch tokens. `fee = pairNotional * hookFeeBps / 10_000` where
///         `pairNotional` is the pair-currency amount actually moving:
///         - pair is SPECIFIED (exact-in BUY, exact-out SELL): take in `beforeSwap` from
///           `abs(amountSpecified)` — specified is already pair-denominated. Exact-in BUY is
///           the live-correct path and is preserved. Exact-out SELL stays in `beforeSwap`
///           deliberately (specified amount IS the pair notional; unifying it into `afterSwap`
///           would not change the number and would add a second take-site for a known amount).
///         - pair is UNSPECIFIED (exact-out BUY, exact-in SELL): take in `afterSwap` from
///           `abs(pairDelta)` — the swap's pair-currency leg. Output (sell) / input (buy)
///           is unknown until the pool swap runs.
/// @dev Address flags: BEFORE_SWAP | AFTER_SWAP | BEFORE_SWAP_RETURNS_DELTA |
///      AFTER_SWAP_RETURNS_DELTA (= 0x0CC). Production CREATE2 mine: top bytes 0x4663 +
///      low 0x0CC (~2^30, same search space as the previous 0x088 mine).
///      INVARIANT: a token-denominated fee is unrepresentable — `beforeSwap` returns without
///      taking unless the specified currency is the pair, and `afterSwap` computes the fee
///      solely from the pair currency's delta (never from the token leg).
contract StonkzFeeHook is IHooks, ISwapHook, IFeeReceiverRegistry {
    using PoolIdLibrary for PoolKey;
    using CurrencySettler for CanonCurrency;

    uint16 public constant HOOK_FEE_BPS_MAX = 1000; // bps = 10%
    uint16 public constant PROTOCOL_FEE_BPS_MAX = 4000; // bps = 40% of hook fee
    uint16 public constant DEFAULT_HOOK_FEE_BPS = 100; // bps = 1%
    uint16 public constant DEFAULT_PROTOCOL_FEE_BPS = 2500; // bps = 25% of hook fee

    /// @dev Required low-14-bit pattern (BEFORE_SWAP | AFTER_SWAP | both RETURNS_DELTA) = 0x0CC.
    uint160 public constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    /// @notice Canonical PoolManager (msg.sender for beforeSwap / afterSwap). Defaults to
    ///         `poolManager_` cast; call `bindCanonManager` when `poolManager` is a V4Adapter.
    ICanonPM public canonManager;
    /// @notice Our IPoolManager surface (Mock or V4Adapter) — msg.sender check for afterSwap mock path.
    IPoolManager public immutable poolManager;
    /// @notice Protocol share of flushed pair proceeds (25% of hook fee at default protocolFeeBps).
    address public immutable protocolTreasury;
    /// @notice CTO governor allowed to `governorTransfer`. May be address(0) in tests.
    ICTOGovernor public immutable ctoGovernor;
    /// @notice Owner of admin setters (`bindCanonManager`, defaults, custom register, ownership).
    address public owner;

    /// @notice Factory default stamped onto new `registerPool` calls. Existing stamps unchanged.
    uint16 public defaultHookFeeBps = DEFAULT_HOOK_FEE_BPS;
    /// @notice Factory default protocol share of the hook fee, stamped at register. Cap 4000.
    uint16 public defaultProtocolFeeBps = DEFAULT_PROTOCOL_FEE_BPS;

    /// @notice Creator (or CTO candidate) that receives the 75% receiver share on flush.
    mapping(address => address) public feeReceiver;
    /// @notice Token-page admin, transferred with feeReceiver on a passed CTO.
    mapping(address => address) public pageAdmin;
    /// @notice True once `_register` has stamped this token (write-once).
    mapping(address => bool) public registered;
    /// @notice Pair currency for a token (`address(0)` = ETH). Fees accrue and flush in this unit.
    mapping(address => address) public pairOf;
    mapping(address => PoolKey) internal _poolKeyOf;
    /// @notice Launch token keyed by canonical pool id (`keccak256(abi.encode(PoolKey))`).
    mapping(PoolId => address) public tokenOfPool;

    /// @notice Per-token hook fee in bps of pair notional. Write-once in `_register`.
    mapping(address => uint16) public hookFeeBps;
    /// @notice Per-token protocol share of the hook fee in bps (default 2500 = 25%). Write-once.
    mapping(address => uint16) public protocolFeeBps;

    /// @notice Accrued receiver share (pair wei) pending `flush`.
    mapping(address => uint256) public receiverPairProceeds;
    /// @notice Accrued protocol share (pair wei) pending `flush` for this token.
    mapping(address => uint256) public tokenPairProceeds;
    /// @notice Sum of protocol shares across tokens (pair wei) pending `flush`.
    uint256 public treasuryPairProceeds;

    /// @notice Test/ops switch: next accrue self-call reverts; swap itself must not revert.
    bool public forceFailNextAccrue;

    event PoolRegistered(
        address indexed token, address indexed pair, address indexed creator, PoolId poolId, uint16 hookFeeBps_
    );
    event CustomFeeDeploy(
        address indexed token, address indexed pair, address indexed creator, PoolId poolId, uint16 hookFeeBps_
    );
    event FeeSplit(address indexed token, address indexed receiver, uint256 receiverShare, uint256 treasuryShare);
    event FeeFlushed(address indexed token, address indexed to, uint256 amount, bool success);
    event FeeReceiverTransferred(address indexed token, address indexed from, address indexed to);
    event GovernorTransfer(address indexed token, address indexed newReceiver, address indexed newAdmin);
    event DefaultHookFeeBpsUpdated(uint16 oldBps, uint16 newBps);
    event DefaultProtocolFeeBpsUpdated(uint16 oldBps, uint16 newBps);
    event OwnerTransferred(address indexed previousOwner, address indexed newOwner);
    event CanonManagerBound(address indexed canonManager);

    error AlreadyRegistered();
    error NotFeeReceiver();
    error CTOActiveBlocked();
    error OnlyGovernor();
    error OnlyOwner();
    error HookFeeBpsOutOfBounds(uint16 bps);
    error ProtocolFeeBpsOutOfBounds(uint16 bps);
    error ForcedAccrueFail();
    error OnlySelf();
    error KeyHooksMismatch();

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    /// @notice Bind PM / adapter, treasury, optional CTO governor, and explicit owner.
    /// @param poolManager_ Mock or V4Adapter (or in-test canon PM when used directly).
    /// @param protocolTreasury_ Flush destination for the protocol share of pair proceeds.
    /// @param ctoGovernor_ Governor allowed to `governorTransfer`; address(0) disables the interlock.
    /// @param initialOwner_ Explicit owner — required when CREATE2 goes through Foundry's
    ///        CREATE2_FACTORY (Arachnid proxy): msg.sender there is the proxy, not the EOA.
    constructor(
        IPoolManager poolManager_,
        address protocolTreasury_,
        ICTOGovernor ctoGovernor_,
        address initialOwner_
    ) {
        require(protocolTreasury_ != address(0), "treasury");
        require(address(poolManager_) != address(0), "pm");
        require(initialOwner_ != address(0), "owner");
        poolManager = poolManager_;
        protocolTreasury = protocolTreasury_;
        ctoGovernor = ctoGovernor_;
        owner = initialOwner_;

        // Default: treat poolManager as beforeSwap/afterSwap authority (mock / in-test canon PM).
        // V4Adapter exposes immutable `manager()` — bind it here so Create2Deployer deploys
        // do not need a post-create onlyOwner call from the proxy.
        canonManager = ICanonPM(address(poolManager_));
        (bool ok, bytes memory ret) = address(poolManager_).staticcall(abi.encodeWithSignature("manager()"));
        if (ok && ret.length >= 32) {
            address m = abi.decode(ret, (address));
            if (m != address(0)) {
                canonManager = ICanonPM(m);
                emit CanonManagerBound(m);
            }
        }
    }

    /// @notice Point production take-auth at the singleton / Deployers manager when using V4Adapter.
    /// @dev `msg.sender != canonManager` is a soft no-op on both swap hooks (unblocks sells at 0 fee
    ///      if rebound away from the PM — global, owner-only).
    /// @param m Canonical PoolManager that will call `beforeSwap` / `afterSwap`.
    function bindCanonManager(ICanonPM m) external onlyOwner {
        require(address(m) != address(0), "canon");
        canonManager = m;
        emit CanonManagerBound(address(m));
    }

    /// @notice Accept native pair-currency fees on ETH-paired mains (`take` of address(0)).
    receive() external payable {}

    /// @notice Permissions this hook requires (miner / `validateHookPermissions` input).
    /// @return p beforeSwap + afterSwap and both RETURNS_DELTA flags (address bits 0x0CC).
    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeSwap = true;
        p.afterSwap = true;
        p.beforeSwapReturnDelta = true;
        p.afterSwapReturnDelta = true;
    }

    /// @notice Revert unless `hook` address low bits match `HOOK_FLAGS` (0x0CC) exactly.
    /// @param hook Address to validate (this contract, or a synthetic flag address in tests).
    function validateHookAddress(address hook) public pure {
        Hooks.Permissions memory p = getHookPermissions();
        Hooks.validateHookPermissions(IHooks(hook), p);
    }

    /// @notice Transfer owner of admin setters. Does not move accrued proceeds.
    /// @param newOwner Next owner; must be nonzero.
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "owner");
        emit OwnerTransferred(owner, newOwner);
        owner = newOwner;
    }

    /// @notice Set the factory default hook fee for *future* `registerPool` stamps. Write-once
    ///         per token — already-registered pools are unchanged (docs/06 adjustability).
    /// @param bps New default in bps of pair notional; cap `HOOK_FEE_BPS_MAX`.
    function setDefaultHookFeeBps(uint16 bps) external onlyOwner {
        if (bps > HOOK_FEE_BPS_MAX) revert HookFeeBpsOutOfBounds(bps);
        emit DefaultHookFeeBpsUpdated(defaultHookFeeBps, bps);
        defaultHookFeeBps = bps;
    }

    /// @notice Set the factory default protocol share of the hook fee for future stamps.
    /// @param bps New default in bps of the hook fee; cap `PROTOCOL_FEE_BPS_MAX`.
    function setDefaultProtocolFeeBps(uint16 bps) external onlyOwner {
        if (bps > PROTOCOL_FEE_BPS_MAX) revert ProtocolFeeBpsOutOfBounds(bps);
        emit DefaultProtocolFeeBpsUpdated(defaultProtocolFeeBps, bps);
        defaultProtocolFeeBps = bps;
    }

    /// @notice Stamp factory defaults. Does NOT call setPoolHook — key.hooks must be this contract
    ///         (or address(0) for mock-only legacy keys that still use Mock.setPoolHook).
    /// @param token Launch token (fee-receiver key).
    /// @param pairCurrency Pair currency (`address(0)` = ETH). All takes and flushes use this unit.
    /// @param creator Initial feeReceiver and pageAdmin.
    /// @param key Main pool key; `hooks` must be this contract or zero (mock).
    function registerPool(address token, address pairCurrency, address creator, PoolKey memory key) external {
        _register(token, pairCurrency, creator, key, defaultHookFeeBps, defaultProtocolFeeBps, false);
    }

    /// @notice Owner-only custom hook-fee stamp. Still write-once (`AlreadyRegistered` on a second call).
    /// @param token Launch token.
    /// @param pairCurrency Pair currency (`address(0)` = ETH).
    /// @param creator Initial feeReceiver and pageAdmin.
    /// @param key Main pool key.
    /// @param hookFeeBps_ Per-token bps of pair notional; cap `HOOK_FEE_BPS_MAX`.
    function registerPoolCustom(
        address token,
        address pairCurrency,
        address creator,
        PoolKey memory key,
        uint16 hookFeeBps_
    ) external onlyOwner {
        if (hookFeeBps_ > HOOK_FEE_BPS_MAX) revert HookFeeBpsOutOfBounds(hookFeeBps_);
        _register(token, pairCurrency, creator, key, hookFeeBps_, defaultProtocolFeeBps, true);
    }

    /// @dev Write-once stamp. `hookFeeBps[token]` has no setter — a holder verifies the rate
    ///      from the pool, never from current factory state (docs/06).
    function _register(
        address token,
        address pairCurrency,
        address creator,
        PoolKey memory key,
        uint16 hookFeeBps_,
        uint16 protocolFeeBps_,
        bool custom
    ) internal {
        if (registered[token]) revert AlreadyRegistered();
        // Real path: hooks immutable in key. Mock may pass hooks=this or hooks=0 + Mock seam.
        if (key.hooks != address(0) && key.hooks != address(this)) revert KeyHooksMismatch();
        registered[token] = true;
        feeReceiver[token] = creator;
        pageAdmin[token] = creator;
        pairOf[token] = pairCurrency;
        _poolKeyOf[token] = key;
        hookFeeBps[token] = hookFeeBps_;
        protocolFeeBps[token] = protocolFeeBps_;
        PoolId id = key.toId();
        tokenOfPool[id] = token;
        if (custom) {
            emit CustomFeeDeploy(token, pairCurrency, creator, id, hookFeeBps_);
        } else {
            emit PoolRegistered(token, pairCurrency, creator, id, hookFeeBps_);
        }
    }

    /// @notice Stored main-pool key for `token` (empty if unregistered).
    /// @param token Launch token.
    /// @return The PoolKey stamped at register.
    function poolKeyOf(address token) external view returns (PoolKey memory) {
        return _poolKeyOf[token];
    }

    // ═══════════════════════════════════════════════════════════════════════
    // IHooks — pair-currency take (production)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Take the hook fee from the pair INPUT when the pair is the specified currency.
    /// @dev Soft no-op when `msg.sender != canonManager`, unregistered, `bps == 0`, or the
    ///      specified currency is not the pair (those four go to `afterSwap`). Fee is
    ///      `abs(amountSpecified) * bps / 10_000` — amountSpecified is pair-denominated
    ///      iff we take here, so a token-count fee cannot be computed on this path.
    /// @param key Canonical pool key.
    /// @param params Swap params (`zeroForOne`, signed `amountSpecified`).
    /// @return selector `IHooks.beforeSwap.selector`.
    /// @return delta Specified BeforeSwapDelta equal to the pair fee; unspecified 0.
    /// @return lpFeeOverride 0 (main pools are not dynamic-fee).
    function beforeSwap(address, CanonPoolKey calldata key, CanonSwapParams calldata params, bytes calldata)
        external
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (msg.sender != address(canonManager)) {
            return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
        }

        (address token, uint16 bps, address pair) = _lookup(key);
        if (token == address(0) || bps == 0) {
            return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
        }

        // INVARIANT: take in beforeSwap only when specified == pair. Otherwise amountSpecified
        // is token-denominated and must not be used as the fee notional (the live 0x088 bug).
        if (!_pairIsSpecified(key, params, pair)) {
            return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
        }

        bool exactIn = params.amountSpecified < 0;
        uint256 absSpec = exactIn ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        uint256 fee = (absSpec * uint256(bps)) / 10_000;
        if (fee == 0) {
            return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
        }

        CanonCurrency specified =
            (params.zeroForOne == exactIn) ? key.currency0 : key.currency1;
        specified.take(canonManager, address(this), fee, false);
        _accrueSafe(token, fee);

        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(uint128(fee)), 0), 0);
    }

    /// @notice Take the hook fee from the pair INPUT (exact-out buy) or OUTPUT (exact-in sell)
    ///         after the swap, when the pair is the unspecified currency.
    /// @dev Soft no-op when not canonManager / unregistered / bps==0 / pair is specified
    ///      (already taken in `beforeSwap`). Fee = `abs(pairDelta) * bps / 10_000`.
    ///      `pairDelta` is the pair currency's leg of the pool swap — never the token leg.
    /// @param key Canonical pool key.
    /// @param params Swap params (used only to decide specified vs unspecified).
    /// @param delta Pool swap delta *before* hook unspecified accounting.
    /// @return selector `IHooks.afterSwap.selector`.
    /// @return hookDeltaUnspecified Pair fee, applied to the unspecified currency by v4.
    function afterSwap(
        address,
        CanonPoolKey calldata key,
        CanonSwapParams calldata params,
        CanonDelta delta,
        bytes calldata
    ) external returns (bytes4, int128) {
        if (msg.sender != address(canonManager)) {
            return (IHooks.afterSwap.selector, 0);
        }

        (address token, uint16 bps, address pair) = _lookup(key);
        if (token == address(0) || bps == 0) {
            return (IHooks.afterSwap.selector, 0);
        }

        // Specified-pair cases already took in beforeSwap (exact-in buy / exact-out sell).
        if (_pairIsSpecified(key, params, pair)) {
            return (IHooks.afterSwap.selector, 0);
        }

        CanonCurrency pairCurrency = _pairCurrency(key, pair);
        // INVARIANT: refuse to take unless this currency unwraps to `pair` — the token leg
        // is the other currency and is never a fee source.
        if (CanonCurrency.unwrap(pairCurrency) != pair) {
            return (IHooks.afterSwap.selector, 0);
        }

        uint256 pairNotional = _absPairDelta(delta, key, pair);
        uint256 fee = (pairNotional * uint256(bps)) / 10_000;
        if (fee == 0) {
            return (IHooks.afterSwap.selector, 0);
        }

        pairCurrency.take(canonManager, address(this), fee, false);
        _accrueSafe(token, fee);
        return (IHooks.afterSwap.selector, int128(uint128(fee)));
    }

    /// @notice Accrue a pair-wei fee via external self-call so a reverting receiver cannot brick the swap.
    /// @dev Production `beforeSwap` / IHooks `afterSwap` path. Not the mock `ISwapHook` seam.
    /// @param token Launch token whose proceeds buckets are credited.
    /// @param feeAmount Pair-wei fee taken this swap.
    /// @param shouldFail If true, revert `ForcedAccrueFail` (test switch).
    function accrueFromSwapOur(address token, uint256 feeAmount, bool shouldFail) external {
        if (msg.sender != address(this)) revert OnlySelf();
        if (shouldFail) revert ForcedAccrueFail();
        _accrue(token, feeAmount);
    }

    /// @inheritdoc IHooks
    function beforeInitialize(address, CanonPoolKey calldata, uint160) external pure returns (bytes4) {
        return IHooks.beforeInitialize.selector;
    }

    /// @inheritdoc IHooks
    function afterInitialize(address, CanonPoolKey calldata, uint160, int24) external pure returns (bytes4) {
        return IHooks.afterInitialize.selector;
    }

    /// @inheritdoc IHooks
    function beforeAddLiquidity(address, CanonPoolKey calldata, CanonModParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IHooks.beforeAddLiquidity.selector;
    }

    /// @inheritdoc IHooks
    function afterAddLiquidity(
        address,
        CanonPoolKey calldata,
        CanonModParams calldata,
        CanonDelta,
        CanonDelta,
        bytes calldata
    ) external pure returns (bytes4, CanonDelta) {
        return (IHooks.afterAddLiquidity.selector, CanonDelta.wrap(0));
    }

    /// @inheritdoc IHooks
    function beforeRemoveLiquidity(address, CanonPoolKey calldata, CanonModParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IHooks.beforeRemoveLiquidity.selector;
    }

    /// @inheritdoc IHooks
    function afterRemoveLiquidity(
        address,
        CanonPoolKey calldata,
        CanonModParams calldata,
        CanonDelta,
        CanonDelta,
        bytes calldata
    ) external pure returns (bytes4, CanonDelta) {
        return (IHooks.afterRemoveLiquidity.selector, CanonDelta.wrap(0));
    }

    /// @inheritdoc IHooks
    function beforeDonate(address, CanonPoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IHooks.beforeDonate.selector;
    }

    /// @inheritdoc IHooks
    function afterDonate(address, CanonPoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IHooks.afterDonate.selector;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Mock dual-backend — provisional afterSwap (ISwapHook)
    // ═══════════════════════════════════════════════════════════════════════

    /// @inheritdoc ISwapHook
    /// @notice Mock PM seam: accrue a pair-currency fee already forwarded by MockPoolManager.
    /// @dev Production takes happen in the IHooks `beforeSwap` / `afterSwap` pair-side paths.
    ///      Soft no-op when `msg.sender != poolManager` or `feeAmount == 0`.
    function afterSwap(PoolKey calldata key, address feeCurrency, uint256 feeAmount) external {
        if (msg.sender != address(poolManager)) return;
        if (feeAmount == 0) return;
        bool fail = forceFailNextAccrue;
        if (fail) forceFailNextAccrue = false;
        try this.accrueFromSwap(key, feeCurrency, feeAmount, fail) {} catch {}
    }

    /// @notice Accrue a mock-path fee if `feeCurrency` is this token's pair (pair-only invariant).
    /// @param key Mock pool key (id → token).
    /// @param feeCurrency Must equal `pairOf[token]`; otherwise ignored.
    /// @param feeAmount Pair-wei fee.
    /// @param shouldFail If true, revert `ForcedAccrueFail`.
    function accrueFromSwap(PoolKey calldata key, address feeCurrency, uint256 feeAmount, bool shouldFail) external {
        if (msg.sender != address(this)) revert OnlySelf();
        if (shouldFail) revert ForcedAccrueFail();
        address token = tokenOfPool[key.toId()];
        if (token == address(0)) return;
        address pair = pairOf[token];
        if (feeCurrency != pair) return;
        _accrue(token, feeAmount);
    }

    /// @notice Push accrued receiver + protocol pair proceeds. Permissionless; send failure rolls that bucket back.
    /// @param token Launch token whose pair-proceeds buckets are flushed.
    function flush(address token) external {
        address pair = pairOf[token];
        address receiver = feeReceiver[token];

        uint256 rAmt = receiverPairProceeds[token];
        if (rAmt > 0) {
            receiverPairProceeds[token] = 0;
            bool ok = _send(pair, receiver, rAmt);
            if (!ok) receiverPairProceeds[token] = rAmt;
            emit FeeFlushed(token, receiver, rAmt, ok);
        }

        uint256 tAmt = tokenPairProceeds[token];
        if (tAmt > 0) {
            tokenPairProceeds[token] = 0;
            if (treasuryPairProceeds >= tAmt) treasuryPairProceeds -= tAmt;
            bool ok = _send(pair, protocolTreasury, tAmt);
            if (!ok) {
                tokenPairProceeds[token] = tAmt;
                treasuryPairProceeds += tAmt;
            }
            emit FeeFlushed(token, protocolTreasury, tAmt, ok);
        }
    }

    /// @notice Voluntary fee-receiver transfer. Blocked while a CTO vote is active.
    /// @param token Launch token.
    /// @param newReceiver Next feeReceiver.
    function transferFeeReceiver(address token, address newReceiver) external {
        if (msg.sender != feeReceiver[token]) revert NotFeeReceiver();
        if (address(ctoGovernor) != address(0) && ctoGovernor.ctoActive(token)) revert CTOActiveBlocked();
        feeReceiver[token] = newReceiver;
        emit FeeReceiverTransferred(token, msg.sender, newReceiver);
    }

    /// @notice CTO-only: move feeReceiver + pageAdmin to the candidate on a passed vote.
    /// @param token Launch token.
    /// @param newReceiver Candidate (new feeReceiver).
    /// @param newAdmin Candidate (new pageAdmin).
    function governorTransfer(address token, address newReceiver, address newAdmin) external {
        if (msg.sender != address(ctoGovernor)) revert OnlyGovernor();
        feeReceiver[token] = newReceiver;
        pageAdmin[token] = newAdmin;
        emit GovernorTransfer(token, newReceiver, newAdmin);
    }

    /// @notice Arm the next accrue self-call to revert without reverting the swap (hostile-receiver tests).
    /// @param v True to force the next accrue to fail.
    function setForceFailNextAccrue(bool v) external onlyOwner {
        forceFailNextAccrue = v;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // internals — pair-only fee (the class of bug that abs(amountSpecified) caused)
    // ═══════════════════════════════════════════════════════════════════════

    function _lookup(CanonPoolKey calldata key)
        internal
        view
        returns (address token, uint16 bps, address pair)
    {
        PoolId id = PoolId.wrap(keccak256(abi.encode(key)));
        token = tokenOfPool[id];
        if (token == address(0)) return (address(0), 0, address(0));
        bps = hookFeeBps[token];
        pair = pairOf[token];
    }

    /// @dev v4 specified currency: `(zeroForOne == exactIn) ? c0 : c1`. Pair-is-specified
    ///      iff that address equals `pair` — the only case `beforeSwap` may take.
    function _pairIsSpecified(CanonPoolKey calldata key, CanonSwapParams calldata params, address pair)
        internal
        pure
        returns (bool)
    {
        bool exactIn = params.amountSpecified < 0;
        address specified =
            CanonCurrency.unwrap((params.zeroForOne == exactIn) ? key.currency0 : key.currency1);
        return specified == pair;
    }

    /// @dev Pair currency as it sits in the key. Returns `currency0` when it matches `pair`,
    ///      else `currency1` (caller must still check unwrap == pair).
    function _pairCurrency(CanonPoolKey calldata key, address pair) internal pure returns (CanonCurrency) {
        if (CanonCurrency.unwrap(key.currency0) == pair) return key.currency0;
        return key.currency1;
    }

    /// @dev Absolute pair-currency leg of `delta`. Never reads the token leg.
    function _absPairDelta(CanonDelta delta, CanonPoolKey calldata key, address pair)
        internal
        pure
        returns (uint256)
    {
        int128 d = CanonCurrency.unwrap(key.currency0) == pair ? delta.amount0() : delta.amount1();
        if (d < 0) return uint256(uint128(-d));
        return uint256(uint128(d));
    }

    function _accrueSafe(address token, uint256 fee) internal {
        bool fail = forceFailNextAccrue;
        if (fail) forceFailNextAccrue = false;
        try this.accrueFromSwapOur(token, fee, fail) {} catch {}
    }

    function _accrue(address token, uint256 feeAmount) internal {
        uint16 pBps = protocolFeeBps[token];
        uint256 protocolShare = (feeAmount * uint256(pBps)) / 10_000;
        uint256 receiverShare = feeAmount - protocolShare;
        receiverPairProceeds[token] += receiverShare;
        tokenPairProceeds[token] += protocolShare;
        treasuryPairProceeds += protocolShare;
        emit FeeSplit(token, feeReceiver[token], receiverShare, protocolShare);
    }

    function _send(address pair, address to, uint256 amount) internal returns (bool) {
        if (to == address(0) || amount == 0) return false;
        if (pair == address(0)) {
            (bool sent,) = to.call{value: amount}("");
            return sent;
        }
        (bool callOk, bytes memory data) =
            pair.call(abi.encodeWithSignature("transfer(address,uint256)", to, amount));
        return callOk && (data.length == 0 || abi.decode(data, (bool)));
    }
}
