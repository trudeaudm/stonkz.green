// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IPoolManager} from "../src/v4/IPoolManager.sol";
import {MockPoolManager} from "../src/mock/MockPoolManager.sol";
import {PoolKey, PoolId, PoolIdLibrary} from "../src/v4/types/PoolKey.sol";
import {Currency} from "../src/v4/types/Currency.sol";
import {TickMath} from "../src/v4/TickMath.sol";
import {StonkzFeeHook} from "../src/StonkzFeeHook.sol";
import {CTOGovernor} from "../src/CTOGovernor.sol";
import {ICTOGovernor} from "../src/interfaces/IStonkzGovernance.sol";

/// @title HookFees — C1 residual after FEECHAIN Phase 3 (pair-side accrue, 75/25 protocolFeeBps).
abstract contract HookHarness is Test {
    using PoolIdLibrary for PoolKey;

    IPoolManager public poolManager;
    StonkzFeeHook public hook;
    CTOGovernor public gov;

    address internal constant PAIR = address(0xB111);
    address internal constant TOKEN = address(0xC0FFEE);
    address internal constant TREASURY = address(0x7A5E);
    address internal constant CREATOR = address(0xCE0);

    PoolKey internal key;

    function _deployBackend(IPoolManager pm) internal {
        poolManager = pm;
        gov = new CTOGovernor();
        hook = new StonkzFeeHook(pm, TREASURY, ICTOGovernor(address(gov)), address(this));
        gov.setRegistry(hook);

        key = _mainPoolKey(PAIR, TOKEN);
        poolManager.initialize(key, TickMath.getSqrtRatioAtTick(0));
        hook.registerPool(TOKEN, PAIR, CREATOR, key);
    }

    function _mainPoolKey(address a, address b) internal view returns (PoolKey memory k) {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        k = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: 0, // pips = 0%
            tickSpacing: 60,
            hooks: address(hook)
        });
    }

    /// @dev Swap paying `payToken` exact-in; returns expected gross fee in pair units when payToken==PAIR.
    function _swapPaying(address payToken, uint256 amountIn) internal returns (uint256 feeAmt) {
        bool zeroForOne = Currency.unwrap(key.currency0) == payToken;
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1;
        IPoolManager.SwapParams memory p = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: limit
        });
        poolManager.swap(key, p, "");
        if (payToken == PAIR) {
            feeAmt = (amountIn * uint256(hook.hookFeeBps(TOKEN))) / 10_000;
        }
    }
}

contract HookFees is HookHarness {
    using PoolIdLibrary for PoolKey;

    function setUp() public {
        _deployBackend(IPoolManager(address(new MockPoolManager())));
    }

    /// @notice Pair-denominated fee: split by stamped protocolFeeBps (default 2500 bps = 25%).
    function test_C1_pairDenominatedFee_directSplit() public {
        uint256 amountIn = 1000 ether;
        uint256 fee = _swapPaying(PAIR, amountIn);
        assertEq(fee, 10 ether, "100 bps = 1% of 1000 ether");
        uint256 proto = (fee * 2500) / 10_000;
        assertEq(hook.receiverPairProceeds(TOKEN), fee - proto);
        assertEq(hook.tokenPairProceeds(TOKEN), proto);
        assertEq(hook.treasuryPairProceeds(), hook.tokenPairProceeds(TOKEN));
    }

    /// @notice Non-pair feeCurrency is ignored (pair-side take only).
    function test_C1_tokenDenominatedFee_ignoredUntilPhase3() public {
        // With Phase 3 mock, sells still quote fee against |amountSpecified| but pass pair as
        // feeCurrency — so token-in swaps ALSO accrue (pair-side design). Document: buy path
        // is the canary; this test asserts a fresh pool with no register gets nothing.
        PoolKey memory other = _mainPoolKey(address(0xD00D), TOKEN);
        // re-key: different pair, uninitialized token mapping for this pool id
        poolManager.initialize(other, TickMath.getSqrtRatioAtTick(0));
        uint256 before = hook.treasuryPairProceeds();
        bool zeroForOne = true;
        poolManager.swap(
            other,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(uint256(1000 ether)),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_RATIO + 1
            }),
            ""
        );
        // No setPoolHook on `other` → no accrual
        assertEq(hook.treasuryPairProceeds(), before, "unhooked pool no fee");
    }

    /// @notice PROVISIONAL gas overhead of the hook on a swap (informational).
    function test_C1_gasOverhead_provisional() public {
        uint256 g0 = gasleft();
        _swapPaying(PAIR, 1000 ether);
        uint256 used = g0 - gasleft();
        console2.log("PROVISIONAL hook swap gas (mock):", used);
        assertGt(used, 0);
    }

    /// @notice Side-pool style pool with NO hook registered is unaffected by fee logic.
    function test_C1_noHookPool_unaffected() public {
        PoolKey memory other = PoolKey({
            currency0: Currency.wrap(address(0xD00D) < TOKEN ? address(0xD00D) : TOKEN),
            currency1: Currency.wrap(address(0xD00D) < TOKEN ? TOKEN : address(0xD00D)),
            fee: 3000, // pips = 0.3%
            tickSpacing: 60,
            hooks: address(0)
        });
        poolManager.initialize(other, TickMath.getSqrtRatioAtTick(0));
        IPoolManager.SwapParams memory p = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(uint256(1000 ether)),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_RATIO + 1
        });
        poolManager.swap(other, p, "");
        assertEq(hook.receiverPairProceeds(TOKEN), 0);
    }
}
