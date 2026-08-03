// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IPoolManager, ISwapHook} from "./v4/IPoolManager.sol";
import {PoolKey, PoolId, PoolIdLibrary} from "./v4/types/PoolKey.sol";
import {Currency} from "./v4/types/Currency.sol";
import {ICTOGovernor, IFeeReceiverRegistry} from "./interfaces/IStonkzGovernance.sol";

/// @title StonkzFeeHook — primary-pool fee take + split (M3.5 / docs/06)
/// @notice PHASE 0 interim: conversion path REMOVED. Pair-currency fees split 80/20.
///         Token-denominated feeAmount is ignored (no convert). Phase 3 replaces this
///         with pair-currency-side BeforeSwapDelta take + accrue-and-flush.
///
/// @dev **Hook discipline:** fee-take and split accounting — NOTHING else.
///      This contract never reverts inside `afterSwap`.
contract StonkzFeeHook is ISwapHook, IFeeReceiverRegistry {
    using PoolIdLibrary for PoolKey;

    uint16 internal constant RECEIVER_BPS = 8000; // 80% — retired in Phase 3 for protocolFeeBps
    uint16 internal constant TREASURY_BPS = 2000; // 20% — retired in Phase 3

    IPoolManager public immutable poolManager;
    address public immutable protocolTreasury;
    ICTOGovernor public immutable ctoGovernor;

    mapping(address => address) public feeReceiver;
    mapping(address => address) public pageAdmin;
    mapping(address => bool) public registered;
    mapping(address => address) public pairOf;
    mapping(address => PoolKey) internal _poolKeyOf;
    mapping(PoolId => address) public tokenOfPool;

    mapping(address => uint256) public receiverPairProceeds;
    mapping(address => uint256) public tokenPairProceeds;
    uint256 public treasuryPairProceeds;

    event PoolRegistered(address indexed token, address indexed pair, address indexed creator, PoolId poolId);
    event FeeSplit(address indexed token, address indexed receiver, uint256 receiverShare, uint256 treasuryShare);
    event FeeReceiverTransferred(address indexed token, address indexed from, address indexed to);
    event GovernorTransfer(address indexed token, address indexed newReceiver, address indexed newAdmin);

    error AlreadyRegistered();
    error NotFeeReceiver();
    error CTOActiveBlocked();
    error OnlyGovernor();

    constructor(IPoolManager poolManager_, address protocolTreasury_, ICTOGovernor ctoGovernor_) {
        require(protocolTreasury_ != address(0), "treasury");
        poolManager = poolManager_;
        protocolTreasury = protocolTreasury_;
        ctoGovernor = ctoGovernor_;
    }

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

    /// @inheritdoc ISwapHook
    /// @dev PHASE 0: only pair-currency feeAmount is split. Token-denominated fees are
    ///      ignored (conversion deleted). Phase 3 takes fees on the pair side only.
    function afterSwap(PoolKey calldata key, address tokenIn, uint256 feeAmount) external {
        if (msg.sender != address(poolManager)) return;
        if (feeAmount == 0) return;
        address token = tokenOfPool[key.toId()];
        if (token == address(0)) return;

        address pair = pairOf[token];
        if (tokenIn != pair) return; // no conversion path — ignore token-denominated feeAmount
        _split(token, feeAmount);
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

    function _split(address token, uint256 pairAmount) internal {
        if (pairAmount == 0) return;
        uint256 rShare = (pairAmount * RECEIVER_BPS) / 10_000;
        uint256 tShare = pairAmount - rShare;
        receiverPairProceeds[token] += rShare;
        tokenPairProceeds[token] += tShare;
        treasuryPairProceeds += tShare;
        emit FeeSplit(token, feeReceiver[token], rShare, tShare);
    }
}
