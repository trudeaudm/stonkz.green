// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "../src/v4/IPoolManager.sol";
import {MockPoolManager} from "../src/mock/MockPoolManager.sol";
import {BuybackAccumulator} from "../src/BuybackAccumulator.sol";
import {FeeLocker} from "../legacy/FeeLocker.sol";
import {StonkzFeeHook} from "../src/StonkzFeeHook.sol";
import {CTOGovernor} from "../src/CTOGovernor.sol";
import {ICTOGovernor} from "../src/interfaces/IStonkzGovernance.sol";
import {StonkzLiquidityStrategy} from "../legacy/StonkzLiquidityStrategy.sol";
import {PoolKey, PoolIdLibrary} from "../src/v4/types/PoolKey.sol";
import {Currency} from "../src/v4/types/Currency.sol";
import {TickMath} from "../src/v4/TickMath.sol";

/// @dev Dual-backend harness: inject IPoolManager (mock now, real v4 in M3.5) — suite C1/C2.
abstract contract PoolBackendHarness is Test {
    IPoolManager public poolManager;
    BuybackAccumulator public accumulator;
    FeeLocker public feeLocker;
    StonkzFeeHook public hook;
    StonkzLiquidityStrategy public strategy;

    address internal constant PAIR = address(0xB111);
    address internal constant USER = address(0xB222);
    address internal constant STONKZ = address(0x4663);
    address internal constant TREASURY = address(0x7A5E);

    function _deployBackend(IPoolManager pm) internal {
        poolManager = pm;
        accumulator = new BuybackAccumulator(PAIR, STONKZ, address(0));
        feeLocker = new FeeLocker(pm, accumulator, address(0));
        CTOGovernor gov = new CTOGovernor();
        hook = new StonkzFeeHook(pm, TREASURY, ICTOGovernor(address(gov)), address(this));
        gov.setRegistry(hook);
        strategy = new StonkzLiquidityStrategy(pm, accumulator, feeLocker, hook, PAIR, STONKZ);
    }
}

/// @title PoolSeamAttacks — C1 provisional (green on mock ≠ green on real v4)
/// @notice Front-creation / sync-to-target defense (spec §8.7). Dual-backend.
contract PoolSeamAttacks is PoolBackendHarness {
    using PoolIdLibrary for PoolKey;

    function setUp() public {
        vm.etch(STONKZ, hex"00");
        _deployBackend(IPoolManager(address(new MockPoolManager())));
    }

    /// @dev Same test body must run against real PoolManager in M3.5 unmodified.
    ///      Not test-prefixed with a param: forge would fuzz it. M3.5 runner calls directly.
    function check_C1_syncRecoversFromFrontCreatedPool(IPoolManager /* pm */) public {
        // Use harness poolManager; signature reserved for dual-backend runners.
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(PAIR < USER ? PAIR : USER),
            currency1: Currency.wrap(PAIR < USER ? USER : PAIR),
            fee: 3000,
            tickSpacing: 60,
            hooks: address(0)
        });
        uint160 wrong = TickMath.getSqrtRatioAtTick(-10000);
        uint160 target = TickMath.getSqrtRatioAtTick(0);
        poolManager.initialize(key, wrong);
        MockPoolManager(payable(address(poolManager))).forcePrice(key.toId(), wrong);

        uint256 spent = poolManager.syncToPrice(key, target, 10 ether);
        (uint160 sqrtPrice,,,) = poolManager.getSlot0(key.toId());
        assertEq(sqrtPrice, target, "synced");
        assertLe(spent, 10 ether);
    }

    function test_C1_syncBudgetExceededIsRetryable() public {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(PAIR < USER ? PAIR : USER),
            currency1: Currency.wrap(PAIR < USER ? USER : PAIR),
            fee: 3000,
            tickSpacing: 60,
            hooks: address(0)
        });
        uint160 target = TickMath.getSqrtRatioAtTick(0);
        poolManager.initialize(key, target);
        MockPoolManager(payable(address(poolManager))).setSyncCost(key.toId(), 100 ether);

        vm.expectRevert(abi.encodeWithSelector(IPoolManager.SyncBudgetExceeded.selector, 100 ether, 1 ether));
        poolManager.syncToPrice(key, target, 1 ether);
    }
}

/// @dev Explicit dual-backend entry: forge can call with mock; M3.5 passes real PM.
contract PoolSeamAttacks_MockBackend is PoolSeamAttacks {
    function test_C1_provisional_mockBackend() public {
        check_C1_syncRecoversFromFrontCreatedPool(poolManager);
    }
}
