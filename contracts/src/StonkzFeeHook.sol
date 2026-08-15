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
/// @notice Production: `beforeSwap` + BeforeSwapDelta pair-side take (ExactInHookFeeHarness
///         semantics). Accrue-and-flush + per-pool stamps unchanged. Hook binds via
///         `PoolKey.hooks` at initialize (no setPoolHook). Mock path retains `ISwapHook.afterSwap`
///         for dual-backend vector speed until all suites are on Real.
/// @dev Address flags: BEFORE_SWAP | BEFORE_SWAP_RETURNS_DELTA (= 0x088). Production
///      CREATE2 mine: top bytes 0x4663 + low 0x088 (~2^30).
contract StonkzFeeHook is IHooks, ISwapHook, IFeeReceiverRegistry {
    using PoolIdLibrary for PoolKey;
    using CurrencySettler for CanonCurrency;

    uint16 public constant HOOK_FEE_BPS_MAX = 1000; // bps = 10%
    uint16 public constant PROTOCOL_FEE_BPS_MAX = 4000; // bps = 40% of hook fee
    uint16 public constant DEFAULT_HOOK_FEE_BPS = 100; // bps = 1%
    uint16 public constant DEFAULT_PROTOCOL_FEE_BPS = 2500; // bps = 25% of hook fee

    /// @dev Required low-14-bit pattern (BEFORE_SWAP | BEFORE_SWAP_RETURNS_DELTA).
    uint160 public constant HOOK_FLAGS = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);

    /// @notice Canonical PoolManager (msg.sender for beforeSwap). Defaults to `poolManager_`
    ///         cast; call `bindCanonManager` when `poolManager` is a V4Adapter.
    ICanonPM public canonManager;
    /// @notice Our IPoolManager surface (Mock or V4Adapter) — msg.sender check for afterSwap mock path.
    IPoolManager public immutable poolManager;
    address public immutable protocolTreasury;
    ICTOGovernor public immutable ctoGovernor;
    address public owner;

    uint16 public defaultHookFeeBps = DEFAULT_HOOK_FEE_BPS;
    uint16 public defaultProtocolFeeBps = DEFAULT_PROTOCOL_FEE_BPS;

    mapping(address => address) public feeReceiver;
    mapping(address => address) public pageAdmin;
    mapping(address => bool) public registered;
    mapping(address => address) public pairOf;
    mapping(address => PoolKey) internal _poolKeyOf;
    mapping(PoolId => address) public tokenOfPool;

    mapping(address => uint16) public hookFeeBps;
    mapping(address => uint16) public protocolFeeBps;

    mapping(address => uint256) public receiverPairProceeds;
    mapping(address => uint256) public tokenPairProceeds;
    uint256 public treasuryPairProceeds;

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

    /// @param poolManager_ Mock or V4Adapter (or in-test canon PM when used directly).
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

        // Default: treat poolManager as beforeSwap authority (mock / in-test canon PM).
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

    /// @notice Point beforeSwap auth at the singleton / Deployers manager when using V4Adapter.
    function bindCanonManager(ICanonPM m) external onlyOwner {
        require(address(m) != address(0), "canon");
        canonManager = m;
        emit CanonManagerBound(address(m));
    }

    receive() external payable {}

    /// @notice Permissions this hook requires (miner / validateHookPermissions input).
    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeSwap = true;
        p.beforeSwapReturnDelta = true;
    }

    /// @notice Revert unless `hook` address low bits match HOOK_FLAGS exactly.
    function validateHookAddress(address hook) public pure {
        Hooks.Permissions memory p = Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
        Hooks.validateHookPermissions(IHooks(hook), p);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "owner");
        emit OwnerTransferred(owner, newOwner);
        owner = newOwner;
    }

    function setDefaultHookFeeBps(uint16 bps) external onlyOwner {
        if (bps > HOOK_FEE_BPS_MAX) revert HookFeeBpsOutOfBounds(bps);
        emit DefaultHookFeeBpsUpdated(defaultHookFeeBps, bps);
        defaultHookFeeBps = bps;
    }

    function setDefaultProtocolFeeBps(uint16 bps) external onlyOwner {
        if (bps > PROTOCOL_FEE_BPS_MAX) revert ProtocolFeeBpsOutOfBounds(bps);
        emit DefaultProtocolFeeBpsUpdated(defaultProtocolFeeBps, bps);
        defaultProtocolFeeBps = bps;
    }

    /// @notice Stamp factory defaults. Does NOT call setPoolHook — key.hooks must be this contract
    ///         (or address(0) for mock-only legacy keys that still use Mock.setPoolHook).
    function registerPool(address token, address pairCurrency, address creator, PoolKey memory key) external {
        _register(token, pairCurrency, creator, key, defaultHookFeeBps, defaultProtocolFeeBps, false);
    }

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
        // setPoolHook DELETED — PoolKey.hooks binds at initialize.
        if (custom) {
            emit CustomFeeDeploy(token, pairCurrency, creator, id, hookFeeBps_);
        } else {
            emit PoolRegistered(token, pairCurrency, creator, id, hookFeeBps_);
        }
    }

    function poolKeyOf(address token) external view returns (PoolKey memory) {
        return _poolKeyOf[token];
    }

    // ═══════════════════════════════════════════════════════════════════════
    // IHooks — beforeSwap fee take (production)
    // ═══════════════════════════════════════════════════════════════════════

    function beforeSwap(address, CanonPoolKey calldata key, CanonSwapParams calldata params, bytes calldata)
        external
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (msg.sender != address(canonManager)) {
            return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
        }

        // Map canon pool id → our PoolId (same keccak encoding of 5-slot key).
        PoolId id = PoolId.wrap(keccak256(abi.encode(key)));
        address token = tokenOfPool[id];
        if (token == address(0)) {
            return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
        }

        uint16 bps = hookFeeBps[token];
        if (bps == 0) {
            return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
        }

        address pair = pairOf[token];
        bool exactIn = params.amountSpecified < 0;
        uint256 absSpec = exactIn ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        uint256 fee = (absSpec * uint256(bps)) / 10_000;
        if (fee == 0) {
            return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
        }

        // Specified/unspecified follow v4 BeforeSwapDelta sort (DeltaReturningHook):
        // (zeroForOne == exactIn) ? (c0, c1) : (c1, c0). Fee always in `pair` (docs/06 pair-side).
        (CanonCurrency specified, CanonCurrency unspecified) = (params.zeroForOne == exactIn)
            ? (key.currency0, key.currency1)
            : (key.currency1, key.currency0);
        bool pairIsSpecified = CanonCurrency.unwrap(specified) == pair;
        if (!pairIsSpecified && CanonCurrency.unwrap(unspecified) != pair) {
            return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
        }
        CanonCurrency feeCurrency = pairIsSpecified ? specified : unspecified;
        feeCurrency.take(canonManager, address(this), fee, false);

        bool fail = forceFailNextAccrue;
        if (fail) forceFailNextAccrue = false;
        try this.accrueFromSwapOur(token, fee, fail) {} catch {}

        BeforeSwapDelta delta = pairIsSpecified
            ? toBeforeSwapDelta(int128(uint128(fee)), 0)
            : toBeforeSwapDelta(0, int128(uint128(fee)));
        return (IHooks.beforeSwap.selector, delta, 0);
    }

    /// @dev External self-call for try/catch accrue (production beforeSwap path).
    function accrueFromSwapOur(address token, uint256 feeAmount, bool shouldFail) external {
        if (msg.sender != address(this)) revert OnlySelf();
        if (shouldFail) revert ForcedAccrueFail();
        _accrue(token, feeAmount);
    }

    function beforeInitialize(address, CanonPoolKey calldata, uint160) external pure returns (bytes4) {
        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(address, CanonPoolKey calldata, uint160, int24) external pure returns (bytes4) {
        return IHooks.afterInitialize.selector;
    }

    function beforeAddLiquidity(address, CanonPoolKey calldata, CanonModParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IHooks.beforeAddLiquidity.selector;
    }

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

    function beforeRemoveLiquidity(address, CanonPoolKey calldata, CanonModParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IHooks.beforeRemoveLiquidity.selector;
    }

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

    function afterSwap(address, CanonPoolKey calldata, CanonSwapParams calldata, CanonDelta, bytes calldata)
        external
        pure
        returns (bytes4, int128)
    {
        return (IHooks.afterSwap.selector, 0);
    }

    function beforeDonate(address, CanonPoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IHooks.beforeDonate.selector;
    }

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
    function afterSwap(PoolKey calldata key, address feeCurrency, uint256 feeAmount) external {
        if (msg.sender != address(poolManager)) return;
        if (feeAmount == 0) return;
        bool fail = forceFailNextAccrue;
        if (fail) forceFailNextAccrue = false;
        try this.accrueFromSwap(key, feeCurrency, feeAmount, fail) {} catch {}
    }

    function accrueFromSwap(PoolKey calldata key, address feeCurrency, uint256 feeAmount, bool shouldFail) external {
        if (msg.sender != address(this)) revert OnlySelf();
        if (shouldFail) revert ForcedAccrueFail();
        address token = tokenOfPool[key.toId()];
        if (token == address(0)) return;
        address pair = pairOf[token];
        if (feeCurrency != pair) return;
        _accrue(token, feeAmount);
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

    function transferFeeReceiver(address token, address newReceiver) external {
        if (msg.sender != feeReceiver[token]) revert NotFeeReceiver();
        if (address(ctoGovernor) != address(0) && ctoGovernor.ctoActive(token)) revert CTOActiveBlocked();
        feeReceiver[token] = newReceiver;
        emit FeeReceiverTransferred(token, msg.sender, newReceiver);
    }

    function governorTransfer(address token, address newReceiver, address newAdmin) external {
        if (msg.sender != address(ctoGovernor)) revert OnlyGovernor();
        feeReceiver[token] = newReceiver;
        pageAdmin[token] = newAdmin;
        emit GovernorTransfer(token, newReceiver, newAdmin);
    }

    function setForceFailNextAccrue(bool v) external onlyOwner {
        forceFailNextAccrue = v;
    }
}
