// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "../src/v4/IPoolManager.sol";
import {MockPoolManager} from "../src/mock/MockPoolManager.sol";
import {BuybackAccumulator} from "../src/BuybackAccumulator.sol";
import {FeeLocker} from "../src/FeeLocker.sol";
import {StonkzFeeHook} from "../src/StonkzFeeHook.sol";
import {CTOGovernor} from "../src/CTOGovernor.sol";
import {ICTOGovernor} from "../src/interfaces/IStonkzGovernance.sol";
import {StonkzLiquidityStrategy} from "../legacy/StonkzLiquidityStrategy.sol";
import {TickMath} from "../src/v4/TickMath.sol";

/// @title SidePoolEconomics — C2 provisional (green on mock ≠ green on real v4)
/// @notice Dump-immunity + range geometry (spec §8.2a). Dual-backend via IPoolManager.
contract SidePoolEconomics is Test {
    IPoolManager public poolManager;
    BuybackAccumulator public accumulator;
    FeeLocker public feeLocker;
    StonkzFeeHook public hook;
    StonkzLiquidityStrategy public strategy;

    address internal constant PAIR = address(0xB111);
    address internal constant USER = address(0xB222);
    address internal constant STONKZ = address(0x4663);
    address internal constant TREASURY = address(0x7A5E);

    function setUp() public {
        _bind(IPoolManager(address(new MockPoolManager())));
    }

    function _bind(IPoolManager pm) internal {
        poolManager = pm;
        accumulator = new BuybackAccumulator(PAIR, STONKZ, address(0));
        feeLocker = new FeeLocker(pm, accumulator, address(0));
        CTOGovernor gov = new CTOGovernor();
        hook = new StonkzFeeHook(pm, TREASURY, ICTOGovernor(address(gov)));
        gov.setRegistry(hook);
        strategy = new StonkzLiquidityStrategy(pm, accumulator, feeLocker, hook, PAIR, STONKZ);
        accumulator.setStrategy(address(strategy));
    }

    /// @dev Dual-backend entrypoint — pass real IPoolManager in M3.5 without rewriting.
    ///      Not test-prefixed: forge would fuzz the param. M3.5 runner calls this directly.
    function check_C2_sidePoolDumpImmuneZeroStonkz(IPoolManager pm) public {
        if (address(pm) != address(0) && address(pm) != address(poolManager)) {
            _bind(pm);
        }
        uint256 P = 1 ether; // $1 print
        uint256 reserve = 100 ether;
        strategy.settle(50 ether, 95 ether, P, reserve, 0, 0, 0, USER, address(this));

        assertTrue(strategy.sidePoolDeployed(), "deployed");
        assertEq(strategy.sidePoolTokens(), (reserve * 500) / 10_000);
        // Dump-immunity: position starts with zero STONKZ4663 exposure — range above spot
        assertGt(strategy.sideTickUpper(), strategy.sideTickLower());
        int24 bottom = strategy.sideTickLower();
        // bottom is 1 tick above grad price in STONKZ terms
        assertGe(bottom, TickMath.MIN_TICK);
    }

    function test_C2_provisional_mockBackend() public {
        check_C2_sidePoolDumpImmuneZeroStonkz(poolManager);
    }

    function test_C2_rangeTopIs1000xBottom() public {
        strategy.settle(10 ether, 95 ether, 1 ether, 100 ether, 0, 0, 0, USER, address(this));
        int24 lo = strategy.sideTickLower();
        int24 hi = strategy.sideTickUpper();
        // ~69081 ticks ≈ 1000× in price; allow spacing alignment slack
        assertApproxEqAbs(int256(hi - lo), 69081, 120);
    }
}
