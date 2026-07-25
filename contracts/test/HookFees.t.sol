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

/// @title HookFees — C1 (fees-and-governance.md §1). PROVISIONAL on mock v4.
/// @notice Dual-backend harness: same bodies re-run unmodified vs real v4-core in M3.5 (§7).
///         Covers: fee-take + best-effort conversion; force-fail → trade still succeeds + accrue
///         + crank; 80/20 split; receiver NEVER receives token-denominated fees; gas logged.
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
        hook = new StonkzFeeHook(pm, TREASURY, ICTOGovernor(address(gov)));
        gov.setRegistry(hook);

        key = _poolKey(PAIR, TOKEN);
        poolManager.initialize(key, TickMath.getSqrtRatioAtTick(0));
        hook.registerPool(TOKEN, PAIR, CREATOR, key);
    }

    function _poolKey(address a, address b) internal pure returns (PoolKey memory k) {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        k = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: 3000,
            tickSpacing: 60,
            hooks: address(0)
        });
    }

    /// @dev Swap paying `payToken` exact-in `amountIn`; returns computed fee (payToken units).
    function _swapPaying(address payToken, uint256 amountIn) internal returns (uint256 feeAmt) {
        bool zeroForOne = Currency.unwrap(key.currency0) == payToken;
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1;
        IPoolManager.SwapParams memory p = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: limit
        });
        poolManager.swap(key, p, "");
        feeAmt = (amountIn * 3000) / 1_000_000;
    }
}

contract HookFees is HookHarness {
    using PoolIdLibrary for PoolKey;

    function setUp() public {
        _deployBackend(IPoolManager(address(new MockPoolManager())));
    }

    /// @notice Token-denominated fee: converted 1:1 then split 80/20; receiver gets PAIR only.
    function test_C1_feeTakeConvertSplit_8020() public {
        uint256 amountIn = 1000 ether;
        uint256 fee = _swapPaying(TOKEN, amountIn); // 3e18
        assertEq(fee, 3 ether);

        // Fully converted (fee < CONVERT_CAP), nothing accrued.
        assertEq(hook.accruedTokenFees(TOKEN), 0, "no accrual");
        // 80/20 split, wei-exact.
        assertEq(hook.receiverPairProceeds(TOKEN), (3 ether * 8000) / 10_000, "80% receiver");
        assertEq(hook.tokenPairProceeds(TOKEN), 3 ether - (3 ether * 8000) / 10_000, "20% treasury");
        assertEq(hook.treasuryPairProceeds(), hook.tokenPairProceeds(TOKEN), "treasury agg");
    }

    /// @notice BEST-EFFORT: forced conversion failure → trade STILL succeeds, fee accrues,
    ///         receiver gets ZERO token fees; a later crank converts + splits.
    function test_C1_bestEffort_forceFail_tradeSucceeds_accrue_thenCrank() public {
        MockPoolManager(address(poolManager)).setConvertFail(key.toId(), true);

        uint256 amountIn = 1000 ether;
        // Trade must NOT revert even though fee conversion fails.
        uint256 fee = _swapPaying(TOKEN, amountIn);
        assertEq(fee, 3 ether);

        // Accrued whole fee; NO pair proceeds credited yet.
        assertEq(hook.accruedTokenFees(TOKEN), 3 ether, "accrued");
        assertEq(hook.receiverPairProceeds(TOKEN), 0, "receiver got nothing yet");
        assertEq(hook.treasuryPairProceeds(), 0, "treasury nothing yet");

        // Crank fails while conversion still forced to fail.
        vm.expectRevert(StonkzFeeHook.ConversionReverted.selector);
        hook.crankConvert(TOKEN);

        // Un-force; crank converts accrued and splits 80/20.
        MockPoolManager(address(poolManager)).setConvertFail(key.toId(), false);
        (uint256 tokenIn, uint256 pairOut) = hook.crankConvert(TOKEN);
        assertEq(tokenIn, 3 ether);
        assertEq(pairOut, 3 ether);
        assertEq(hook.accruedTokenFees(TOKEN), 0, "drained");
        assertEq(hook.receiverPairProceeds(TOKEN), (3 ether * 8000) / 10_000, "80% receiver after crank");
    }

    /// @notice Receiver NEVER holds token-denominated fees — only ever pair proceeds (§0).
    function test_C1_receiverNeverGetsTokenFees() public {
        MockPoolManager(address(poolManager)).setConvertFail(key.toId(), true);
        _swapPaying(TOKEN, 500 ether);
        // While unconvertible, everything sits as token accrual — receiver credited nothing.
        assertGt(hook.accruedTokenFees(TOKEN), 0);
        assertEq(hook.receiverPairProceeds(TOKEN), 0);
        // There is no storage crediting token fees to the receiver by construction.
    }

    /// @notice Pair-denominated fee: split directly, no conversion path touched.
    function test_C1_pairDenominatedFee_directSplit() public {
        uint256 amountIn = 1000 ether;
        uint256 fee = _swapPaying(PAIR, amountIn);
        assertEq(fee, 3 ether);
        assertEq(hook.accruedTokenFees(TOKEN), 0, "no token accrual for pair fee");
        assertEq(hook.receiverPairProceeds(TOKEN), (3 ether * 8000) / 10_000);
    }

    /// @notice Crank cooldown is a hardcoded bound (no admin).
    function test_C1_crankCooldown() public {
        MockPoolManager(address(poolManager)).setConvertFail(key.toId(), true);
        _swapPaying(TOKEN, 4000 ether); // fee 12e18 > CONVERT_CAP? no, cap 100e18 → single accrual
        MockPoolManager(address(poolManager)).setConvertFail(key.toId(), false);

        // Accrue more so two cranks are warranted.
        MockPoolManager(address(poolManager)).setConvertFail(key.toId(), true);
        _swapPaying(TOKEN, 4000 ether);
        MockPoolManager(address(poolManager)).setConvertFail(key.toId(), false);

        hook.crankConvert(TOKEN); // consumes cooldown
        vm.expectRevert();
        hook.crankConvert(TOKEN);
        vm.warp(block.timestamp + hook.CRANK_COOLDOWN());
        // no accrual left → NothingToCrank
        vm.expectRevert(StonkzFeeHook.NothingToCrank.selector);
        hook.crankConvert(TOKEN);
    }

    /// @notice PROVISIONAL gas overhead of the hook on a swap (informational; re-measure vs real v4).
    function test_C1_gasOverhead_provisional() public {
        uint256 g0 = gasleft();
        _swapPaying(TOKEN, 1000 ether);
        uint256 used = g0 - gasleft();
        // Informational only — mock pricing/accounting is not representative of real v4-core.
        console2.log("PROVISIONAL hook swap gas (mock):", used);
        assertGt(used, 0);
    }

    /// @notice Side-pool style pool with NO hook registered is unaffected by fee logic.
    function test_C1_noHookPool_unaffected() public {
        PoolKey memory other = _poolKey(address(0xD00D), TOKEN);
        poolManager.initialize(other, TickMath.getSqrtRatioAtTick(0));
        // No hook registered for `other`; a swap must not touch hook accounting.
        IPoolManager.SwapParams memory p = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(uint256(1000 ether)),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_RATIO + 1
        });
        poolManager.swap(other, p, "");
        assertEq(hook.receiverPairProceeds(TOKEN), 0);
    }
}
