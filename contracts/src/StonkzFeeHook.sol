// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IPoolManager, ISwapHook} from "./v4/IPoolManager.sol";
import {PoolKey, PoolId, PoolIdLibrary} from "./v4/types/PoolKey.sol";
import {ICTOGovernor, IFeeReceiverRegistry} from "./interfaces/IStonkzGovernance.sol";

/// @title StonkzFeeHook — main-pool fee take + accrue-and-flush (docs/06 / FEECHAIN Phase 3)
/// @notice Pair-currency-side fee take (no conversion). Per-pool `hookFeeBps` and
///         `protocolFeeBps` stamped at register. Swap path only accrues; `flush` pushes.
/// @dev Hook discipline: fee-take and split accounting — NOTHING else. `afterSwap` MUST NOT
///      revert a trade (try/catch around accrue). Units: hookFeeBps / protocolFeeBps are BPS.
contract StonkzFeeHook is ISwapHook, IFeeReceiverRegistry {
    using PoolIdLibrary for PoolKey;

    uint16 public constant HOOK_FEE_BPS_MAX = 1000; // bps = 10%
    uint16 public constant PROTOCOL_FEE_BPS_MAX = 4000; // bps = 40% of hook fee
    uint16 public constant DEFAULT_HOOK_FEE_BPS = 100; // bps = 1%
    uint16 public constant DEFAULT_PROTOCOL_FEE_BPS = 2500; // bps = 25% of hook fee

    IPoolManager public immutable poolManager;
    address public immutable protocolTreasury;
    ICTOGovernor public immutable ctoGovernor;
    address public owner;

    /// @notice Mutable factory default for newly stamped pools. Bounds [0, HOOK_FEE_BPS_MAX].
    uint16 public defaultHookFeeBps = DEFAULT_HOOK_FEE_BPS; // bps = 1%
    /// @notice Mutable factory default protocol share of the hook fee. Bounds [0, PROTOCOL_FEE_BPS_MAX].
    uint16 public defaultProtocolFeeBps = DEFAULT_PROTOCOL_FEE_BPS; // bps = 25% of fee

    mapping(address => address) public feeReceiver;
    mapping(address => address) public pageAdmin;
    mapping(address => bool) public registered;
    mapping(address => address) public pairOf;
    mapping(address => PoolKey) internal _poolKeyOf;
    mapping(PoolId => address) public tokenOfPool;

    /// @notice Per-token stamped hook fee. Immutable after register. Unit: bps.
    mapping(address => uint16) public hookFeeBps;
    /// @notice Per-token stamped protocol share of hook fee. Immutable after register. Unit: bps.
    mapping(address => uint16) public protocolFeeBps;

    /// @notice Accrued pair-currency balances awaiting flush (docs/06 ### Distribution).
    mapping(address => uint256) public receiverPairProceeds;
    mapping(address => uint256) public tokenPairProceeds;
    uint256 public treasuryPairProceeds;

    /// @dev Test / fuzz lever: next accrue via external self-call reverts (swap must still complete).
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

    error AlreadyRegistered();
    error NotFeeReceiver();
    error CTOActiveBlocked();
    error OnlyGovernor();
    error OnlyOwner();
    error HookFeeBpsOutOfBounds(uint16 bps);
    error ProtocolFeeBpsOutOfBounds(uint16 bps);
    error ForcedAccrueFail();
    error OnlySelf();

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    constructor(IPoolManager poolManager_, address protocolTreasury_, ICTOGovernor ctoGovernor_) {
        require(protocolTreasury_ != address(0), "treasury");
        poolManager = poolManager_;
        protocolTreasury = protocolTreasury_;
        ctoGovernor = ctoGovernor_;
        owner = msg.sender;
    }

    receive() external payable {}

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

    /// @notice Standard path: stamp factory defaults (docs/06).
    function registerPool(address token, address pairCurrency, address creator, PoolKey memory key) external {
        _register(token, pairCurrency, creator, key, defaultHookFeeBps, defaultProtocolFeeBps, false);
    }

    /// @notice Owner-only custom-fee deploy (docs/06 ### Custom deploys). Same hookFeeBps bounds.
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
        registered[token] = true;
        feeReceiver[token] = creator;
        pageAdmin[token] = creator;
        pairOf[token] = pairCurrency;
        _poolKeyOf[token] = key;
        hookFeeBps[token] = hookFeeBps_;
        protocolFeeBps[token] = protocolFeeBps_;
        PoolId id = key.toId();
        tokenOfPool[id] = token;
        poolManager.setPoolHook(id, address(this));
        if (custom) {
            emit CustomFeeDeploy(token, pairCurrency, creator, id, hookFeeBps_);
        } else {
            emit PoolRegistered(token, pairCurrency, creator, id, hookFeeBps_);
        }
    }

    function poolKeyOf(address token) external view returns (PoolKey memory) {
        return _poolKeyOf[token];
    }

    /// @inheritdoc ISwapHook
    /// @dev Pair-currency feeAmount only (docs/06). Accrue-and-flush — no transfers here.
    ///      Never reverts the swap: accrue is behind try/catch. Force-fail flag is cleared
    ///      HERE (not inside the reverting call) so the clear survives the caught revert.
    function afterSwap(PoolKey calldata key, address feeCurrency, uint256 feeAmount) external {
        if (msg.sender != address(poolManager)) return;
        if (feeAmount == 0) return;
        bool fail = forceFailNextAccrue;
        if (fail) forceFailNextAccrue = false;
        try this.accrueFromSwap(key, feeCurrency, feeAmount, fail) {} catch {}
    }

    /// @notice External self-call target for try/catch (Solidity restriction). Only this contract.
    function accrueFromSwap(PoolKey calldata key, address feeCurrency, uint256 feeAmount, bool shouldFail)
        external
    {
        if (msg.sender != address(this)) revert OnlySelf();
        if (shouldFail) revert ForcedAccrueFail();
        address token = tokenOfPool[key.toId()];
        if (token == address(0)) return;
        address pair = pairOf[token];
        if (feeCurrency != pair) return; // pair-currency-side only
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

    /// @notice Permissionless flush of accrued balances for `token` (docs/06 ### Distribution).
    /// @dev Each recipient is independent — a reverting receiver cannot block treasury (or vice versa).
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
            // Keep global treasury total consistent with per-token bucket.
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

    /// @inheritdoc IFeeReceiverRegistry
    function governorTransfer(address token, address newReceiver, address newAdmin) external {
        if (msg.sender != address(ctoGovernor)) revert OnlyGovernor();
        feeReceiver[token] = newReceiver;
        pageAdmin[token] = newAdmin;
        emit GovernorTransfer(token, newReceiver, newAdmin);
    }

    /// @notice Test helper — arm one forced accrue revert for trade-never-reverts fuzz.
    function setForceFailNextAccrue(bool v) external onlyOwner {
        forceFailNextAccrue = v;
    }
}
