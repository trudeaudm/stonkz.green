// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IUnlockCallback} from "@v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IPoolManager as ICanonPM} from "@v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@v4-core/src/interfaces/IHooks.sol";
import {PoolKey as CanonPoolKey} from "@v4-core/src/types/PoolKey.sol";
import {Currency as CanonCurrency} from "@v4-core/src/types/Currency.sol";
import {BalanceDelta as CanonDelta} from "@v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams as CanonModParams} from "@v4-core/src/types/PoolOperation.sol";
import {CurrencySettler} from "@v4-core/test/utils/CurrencySettler.sol";

import {PoolKey} from "../../src/v4/types/PoolKey.sol";
import {Currency} from "../../src/v4/types/Currency.sol";

/// @title SkipSettleCanary — TEST-ONLY harness proving PM enforces CurrencyNotSettled
/// @notice Intentionally skips settle/take after modifyLiquidity inside unlock.
/// @dev Never ship. Replaces removed V4Adapter.setBreakNetting / breakNetting.
contract SkipSettleCanary is IUnlockCallback {
    using CurrencySettler for CanonCurrency;

    ICanonPM public immutable manager;
    bool public skipSettle;

    constructor(ICanonPM manager_) {
        manager = manager_;
    }

    function setSkipSettle(bool skip) external {
        skipSettle = skip;
    }

    function modifyLiquidity(PoolKey memory key, int24 tickLower, int24 tickUpper, int256 liquidityDelta, bytes32 salt)
        external
        payable
    {
        manager.unlock(abi.encode(key, tickLower, tickUpper, liquidityDelta, salt, msg.sender));
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        require(msg.sender == address(manager), "only manager");
        (PoolKey memory key, int24 tickLower, int24 tickUpper, int256 liquidityDelta, bytes32 salt, address payer) =
            abi.decode(rawData, (PoolKey, int24, int24, int256, bytes32, address));

        CanonPoolKey memory ckey = CanonPoolKey({
            currency0: CanonCurrency.wrap(Currency.unwrap(key.currency0)),
            currency1: CanonCurrency.wrap(Currency.unwrap(key.currency1)),
            fee: key.fee,
            tickSpacing: key.tickSpacing,
            hooks: IHooks(key.hooks)
        });

        (CanonDelta delta,) = manager.modifyLiquidity(
            ckey,
            CanonModParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: liquidityDelta, salt: salt}),
            ""
        );

        if (!skipSettle) {
            int128 d0 = delta.amount0();
            int128 d1 = delta.amount1();
            if (d0 < 0) ckey.currency0.settle(manager, payer, uint256(uint128(-d0)), false);
            if (d1 < 0) ckey.currency1.settle(manager, payer, uint256(uint128(-d1)), false);
            if (d0 > 0) ckey.currency0.take(manager, payer, uint256(uint128(d0)), false);
            if (d1 > 0) ckey.currency1.take(manager, payer, uint256(uint128(d1)), false);
        }
        // skipSettle=true → unlock ends with open deltas → CurrencyNotSettled
        return "";
    }

    receive() external payable {}
}
