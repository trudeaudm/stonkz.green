// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IPoolManager, ISwapHook} from "./v4/IPoolManager.sol";
import {PoolKey, PoolId, PoolIdLibrary} from "./v4/types/PoolKey.sol";
import {Currency} from "./v4/types/Currency.sol";
import {ICTOGovernor, IFeeReceiverRegistry} from "./interfaces/IStonkzGovernance.sol";

/// @title StonkzFeeHook — primary-pool per-swap fee take + best-effort conversion
/// @notice fees-and-governance.md §1 / spec §8.6. On each primary-pool swap the hook:
///         (1) takes the swap fee, (2) attempts ONE bounded conversion of the
///         token-denominated half → pair currency via the SAME pool, (3) splits all
///         pair-currency proceeds 80% feeReceiver / 20% protocolTreasury. Receivers never
///         hold token-denominated fees — there is nothing to dump (§0).
///
/// @dev **Hook discipline (§1.2):** the hook does fee-take, ONE bounded conversion, and
///      split accounting — NOTHING else. Conversion is BEST-EFFORT: any failure accrues the
///      fee for a later bounded permissionless crank and the user's trade ALWAYS succeeds.
///      This contract never reverts inside `afterSwap`.
///
/// @dev **Reentrancy posture (§1.2):** conversion re-enters the SAME pool
///      (`poolManager.convertTokenToPair`). We follow the v4-native pattern: the PoolManager
///      marks conversion swaps so they do not re-trigger `afterSwap` (no recursive fee loop),
///      and all hook state writes happen after the single external conversion returns
///      (checks-effects-interactions). Provisional on mock; re-run unmodified against real
///      v4-core in M3.5 (study Doppler's public hook as the reference implementation).
contract StonkzFeeHook is ISwapHook, IFeeReceiverRegistry {
    using PoolIdLibrary for PoolKey;

    uint16 internal constant RECEIVER_BPS = 8000; // 80% (§1.3)
    uint16 internal constant TREASURY_BPS = 2000; // 20% (§1.3)
    uint256 public constant CONVERT_CAP = 100 ether; // hardcoded per-conversion size cap
    uint256 public constant CRANK_COOLDOWN = 30; // seconds — hardcoded crank cooldown

    IPoolManager public immutable poolManager;
    address public immutable protocolTreasury; // hardened address, immutable (§1.3)
    ICTOGovernor public immutable ctoGovernor; // interlock for voluntary transfers (§1.4)

    // ─── receiver + page-admin registry (§1.4, §4.4) ─────────────────────────
    mapping(address => address) public feeReceiver; // token => receiver (initially creator)
    mapping(address => address) public pageAdmin; // token => token-page admin
    mapping(address => bool) public registered; // token => pool registered
    mapping(address => address) public pairOf; // token => pair currency
    mapping(address => PoolKey) internal _poolKeyOf; // token => primary pool key
    mapping(PoolId => address) public tokenOfPool; // poolId => token

    // ─── fee accounting (wei-exact, §1.3) ────────────────────────────────────
    mapping(address => uint256) public accruedTokenFees; // token-denominated fees awaiting conversion
    mapping(address => uint256) public receiverPairProceeds; // pair proceeds credited to feeReceiver
    mapping(address => uint256) public tokenPairProceeds; // pair proceeds credited to treasury (per token)
    uint256 public treasuryPairProceeds; // aggregate treasury pair proceeds
    mapping(address => uint256) public lastCrankTime; // token => last successful crank

    event PoolRegistered(address indexed token, address indexed pair, address indexed creator, PoolId poolId);
    event FeeSplit(address indexed token, address indexed receiver, uint256 receiverShare, uint256 treasuryShare);
    event FeeAccrued(address indexed token, uint256 tokenAmount, uint256 totalAccrued);
    event ConversionCranked(address indexed token, uint256 tokenIn, uint256 pairOut);
    event FeeReceiverTransferred(address indexed token, address indexed from, address indexed to);
    event GovernorTransfer(address indexed token, address indexed newReceiver, address indexed newAdmin);

    error AlreadyRegistered();
    error NotFeeReceiver();
    error CTOActiveBlocked(); // voluntary-transfer-blocked (§1.4)
    error OnlyGovernor();
    error CrankCooldown(uint256 nextAllowed);
    error NothingToCrank();
    error ConversionReverted();

    constructor(IPoolManager poolManager_, address protocolTreasury_, ICTOGovernor ctoGovernor_) {
        require(protocolTreasury_ != address(0), "treasury");
        poolManager = poolManager_;
        protocolTreasury = protocolTreasury_;
        ctoGovernor = ctoGovernor_;
    }

    // ─── registration ────────────────────────────────────────────────────────

    /// @notice Attach the hook to a token's primary pool and set the initial creator receiver.
    /// @dev Construction-time wiring by the listing/strategy; once-only per token.
    function registerPool(address token, address pairCurrency, address creator, PoolKey memory key) external {
        if (registered[token]) revert AlreadyRegistered();
        registered[token] = true;
        feeReceiver[token] = creator;
        pageAdmin[token] = creator;
        pairOf[token] = pairCurrency;
        _poolKeyOf[token] = key;
        PoolId id = key.toId();
        tokenOfPool[id] = token;
        poolManager.setPoolHook(id, address(this));
        emit PoolRegistered(token, pairCurrency, creator, id);
    }

    function poolKeyOf(address token) external view returns (PoolKey memory) {
        return _poolKeyOf[token];
    }

    // ─── swap hook (§1.1–§1.3) — MUST NOT REVERT ─────────────────────────────

    /// @inheritdoc ISwapHook
    function afterSwap(PoolKey calldata key, address tokenIn, uint256 feeAmount) external {
        // Only the PoolManager should call this; ignore anything else without reverting.
        if (msg.sender != address(poolManager)) return;
        if (feeAmount == 0) return;
        address token = tokenOfPool[key.toId()];
        if (token == address(0)) return;

        address pair = pairOf[token];
        if (tokenIn == pair) {
            // Fee already in pair currency — split directly, no conversion needed.
            _split(token, feeAmount);
            return;
        }

        // Token-denominated fee: attempt ONE bounded conversion via the same pool (§1.1).
        uint256 convertAmt = feeAmount > CONVERT_CAP ? CONVERT_CAP : feeAmount;
        uint256 remainder = feeAmount - convertAmt;
        try poolManager.convertTokenToPair(key, convertAmt) returns (uint256 pairOut) {
            _split(token, pairOut);
            if (remainder > 0) _accrue(token, remainder);
        } catch {
            // BEST-EFFORT: conversion failed → accrue the whole fee; trade still succeeds (§1.2).
            _accrue(token, feeAmount);
        }
    }

    // ─── permissionless conversion crank (fallback path, §1.2) ───────────────

    /// @notice Convert accrued token fees → pair (bounded size + cooldown), then split 80/20.
    /// @dev Reverts if the conversion fails so the caller can retry after the market moves;
    ///      cooldown is only consumed on success.
    function crankConvert(address token) external returns (uint256 tokenIn, uint256 pairOut) {
        uint256 accrued = accruedTokenFees[token];
        if (accrued == 0) revert NothingToCrank();
        uint256 last = lastCrankTime[token];
        if (last != 0 && block.timestamp < last + CRANK_COOLDOWN) {
            revert CrankCooldown(last + CRANK_COOLDOWN);
        }

        tokenIn = accrued > CONVERT_CAP ? CONVERT_CAP : accrued;
        try poolManager.convertTokenToPair(_poolKeyOf[token], tokenIn) returns (uint256 out) {
            pairOut = out;
        } catch {
            revert ConversionReverted();
        }

        accruedTokenFees[token] = accrued - tokenIn;
        lastCrankTime[token] = block.timestamp;
        _split(token, pairOut);
        emit ConversionCranked(token, tokenIn, pairOut);
    }

    // ─── receiver transfer (§1.4) ────────────────────────────────────────────

    /// @notice Voluntary feeReceiver transfer by the current holder. BLOCKED while a CTO
    ///         vote is active (§1.4) — the interlock queries the CTOGovernor.
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

    // ─── internal ──────────────────────────────────────────────────────────

    function _split(address token, uint256 pairAmount) internal {
        if (pairAmount == 0) return;
        uint256 rShare = (pairAmount * RECEIVER_BPS) / 10_000;
        uint256 tShare = pairAmount - rShare; // wei-exact remainder → treasury
        receiverPairProceeds[token] += rShare;
        tokenPairProceeds[token] += tShare;
        treasuryPairProceeds += tShare;
        emit FeeSplit(token, feeReceiver[token], rShare, tShare);
    }

    function _accrue(address token, uint256 amount) internal {
        accruedTokenFees[token] += amount;
        emit FeeAccrued(token, amount, accruedTokenFees[token]);
    }
}
