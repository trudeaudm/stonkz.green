// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "../src/v4/IPoolManager.sol";
import {MockPoolManager} from "../src/mock/MockPoolManager.sol";
import {PoolKey, PoolId, PoolIdLibrary} from "../src/v4/types/PoolKey.sol";
import {Currency} from "../src/v4/types/Currency.sol";
import {TickMath} from "../src/v4/TickMath.sol";
import {StonkzFeeHook} from "../src/StonkzFeeHook.sol";
import {CTOGovernor} from "../src/CTOGovernor.sol";
import {ICTOGovernor} from "../src/interfaces/IStonkzGovernance.sol";

/// @title FeeCanary — FEECHAIN Phase 1 vacuity guard (docs/06).
/// @notice Asserts protocol revenue > 0 on a fee=0 main pool with the hook attached.
///         MUST fail if the hook take is silently bypassed (e.g. feeAmount derived from
///         key.fee alone). Detached demonstration: `CANARY_DETACH=true forge test
///         --match-test test_canary_fee0_hookAttached_protocolRevenueGtZero` → red.
contract FeeCanary is Test {
    using PoolIdLibrary for PoolKey;

    MockPoolManager internal pm;
    StonkzFeeHook internal hook;
    CTOGovernor internal gov;

    address internal constant PAIR = address(0xB111);
    address internal constant TOKEN = address(0xC0FFEE);
    address internal constant TREASURY = address(0x7A5E);
    address internal constant CREATOR = address(0xCE0);

    PoolKey internal key;

    function setUp() public {
        pm = new MockPoolManager();
        gov = new CTOGovernor();
        hook = new StonkzFeeHook(IPoolManager(address(pm)), TREASURY, ICTOGovernor(address(gov)));
        gov.setRegistry(hook);

        // docs/06 main pool: LP fee 0, hook attached, hook fee 100 bps
        (address c0, address c1) = PAIR < TOKEN ? (PAIR, TOKEN) : (TOKEN, PAIR);
        key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: 0,
            tickSpacing: 60,
            hooks: address(0)
        });
        pm.initialize(key, TickMath.getSqrtRatioAtTick(0));

        bool detach = vm.envOr("CANARY_DETACH", false);
        if (!detach) {
            hook.registerPool(TOKEN, PAIR, CREATOR, key);
        }
    }

    /// @dev Non-negotiable vacuity guard. Green with hook; red when CANARY_DETACH=true.
    function test_canary_fee0_hookAttached_protocolRevenueGtZero() public {
        uint256 amountIn = 1000 ether;
        bool zeroForOne = Currency.unwrap(key.currency0) == PAIR;
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1;
        pm.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: limit
            }),
            ""
        );

        // 100 bps of 1000 ether = 10 ether gross; treasury share 20% = 2 ether
        assertGt(hook.treasuryPairProceeds(), 0, "vacuity: fee take bypassed on fee=0 pool");
        assertEq(hook.treasuryPairProceeds(), 2 ether, "expected 20% of 100bps");
        assertEq(hook.receiverPairProceeds(TOKEN), 8 ether, "expected 80% of 100bps");
    }
}
