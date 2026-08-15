// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IHooks} from "@v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@v4-core/src/types/PoolKey.sol";
import {Currency} from "@v4-core/src/types/Currency.sol";
import {SwapParams} from "@v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@v4-core/src/types/BeforeSwapDelta.sol";
import {BaseTestHooks} from "@v4-core/src/test/BaseTestHooks.sol";
import {PoolSwapTest} from "@v4-core/src/test/PoolSwapTest.sol";
import {Deployers} from "@v4-core/test/utils/Deployers.sol";
import {CurrencySettler} from "@v4-core/test/utils/CurrencySettler.sol";

import {IPoolManager as IMockPM} from "../src/v4/IPoolManager.sol";
import {MockPoolManager} from "../src/mock/MockPoolManager.sol";
import {PoolKey as MockPoolKey, PoolIdLibrary as MockPoolIdLibrary} from "../src/v4/types/PoolKey.sol";
import {Currency as MockCurrency} from "../src/v4/types/Currency.sol";
import {TickMath as MockTickMath} from "../src/v4/TickMath.sol";
import {StonkzFeeHook} from "../src/StonkzFeeHook.sol";
import {CTOGovernor} from "../src/CTOGovernor.sol";
import {ICTOGovernor} from "../src/interfaces/IStonkzGovernance.sol";

/// @dev Real-v4 test hook: takes `HOOK_FEE_BPS` of exact-in specified amount via BeforeSwapDelta.
///      Mirrors MockPoolManager's fee=0 hookFeeBps path for differential comparison.
contract ExactInHookFeeHarness is BaseTestHooks {
    using CurrencySettler for Currency;

    uint16 public constant HOOK_FEE_BPS = 100;
    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    modifier onlyManager() {
        require(msg.sender == address(manager));
        _;
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        override
        onlyManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        require(params.amountSpecified < 0, "exact-in only");
        uint256 absIn = uint256(-params.amountSpecified);
        uint256 fee = (absIn * HOOK_FEE_BPS) / 10_000;

        Currency specified = (params.zeroForOne) ? key.currency0 : key.currency1;
        specified.take(manager, address(this), fee, false);

        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(uint128(fee)), 0), 0);
    }
}

/// @title MockVsRealV4Fees — FEECHAIN Phase 1 differential (fuzz-halt naming).
/// @notice Identical exact-in notional + 100 bps hook fee → identical fee amounts on mock vs real.
contract MockVsRealV4Fees is Test, Deployers {
    using MockPoolIdLibrary for MockPoolKey;

    uint16 internal constant HOOK_FEE_BPS = 100;
    address internal constant TREASURY = address(0x7A5E);
    address internal constant CREATOR = address(0xCE0);
    address internal constant TOKEN = address(0xC0FFEE);

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
    }

    function _mockFee(uint256 amountIn) internal returns (uint256 feeTotal) {
        MockPoolManager mpm = new MockPoolManager();
        CTOGovernor gov = new CTOGovernor();
        StonkzFeeHook sh = new StonkzFeeHook(IMockPM(address(mpm)), TREASURY, ICTOGovernor(address(gov)), address(this));
        gov.setRegistry(sh);

        address pairAddr = Currency.unwrap(currency0);
        address tokenAddr = TOKEN;
        if (tokenAddr == pairAddr) tokenAddr = address(uint160(pairAddr) + 1);

        (address c0, address c1) = pairAddr < tokenAddr ? (pairAddr, tokenAddr) : (tokenAddr, pairAddr);
        MockPoolKey memory mkey = MockPoolKey({
            currency0: MockCurrency.wrap(c0),
            currency1: MockCurrency.wrap(c1),
            fee: 0,
            tickSpacing: 60,
            hooks: address(sh)
        });
        mpm.initialize(mkey, MockTickMath.getSqrtRatioAtTick(0));
        sh.registerPool(tokenAddr, pairAddr, CREATOR, mkey);

        bool zeroForOne = MockCurrency.unwrap(mkey.currency0) == pairAddr;
        uint160 limit = zeroForOne ? MockTickMath.MIN_SQRT_RATIO + 1 : MockTickMath.MAX_SQRT_RATIO - 1;
        mpm.swap(
            mkey,
            IMockPM.SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: limit}),
            ""
        );
        feeTotal = sh.receiverPairProceeds(tokenAddr) + sh.tokenPairProceeds(tokenAddr);
    }

    function _realFee(uint256 amountIn) internal returns (uint256 feeTaken) {
        address hookAddr = address(uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG));
        ExactInHookFeeHarness impl = new ExactInHookFeeHarness(manager);
        vm.etch(hookAddr, address(impl).code);

        (key,) = initPool(currency0, currency1, IHooks(hookAddr), 0, int24(60), SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, ZERO_BYTES);

        uint256 balBefore = currency0.balanceOf(hookAddr);
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: SQRT_PRICE_1_2});
        swapRouter.swap(key, params, settings, ZERO_BYTES);
        feeTaken = currency0.balanceOf(hookAddr) - balBefore;
    }

    function test_diff_mockVsReal_exactIn_100bps() public {
        // Keep notional small vs Deployers' 1e18 liquidity band (CustomAccounting uses ~1000).
        uint256 amountIn = 1000;
        uint256 expected = (amountIn * HOOK_FEE_BPS) / 10_000;

        uint256 mockFee = _mockFee(amountIn);
        assertEq(mockFee, expected, "mock fee");

        uint256 realFee = _realFee(amountIn);
        assertEq(realFee, expected, "real fee");
        assertEq(mockFee, realFee, "mock vs real");
    }

    /// @dev Fuzz-halt: any divergence between mock and formula fails hard.
    function testFuzz_diff_mockVsReal_exactIn_100bps(uint256 amountIn) public {
        amountIn = bound(amountIn, 1e15, 1e21);
        uint256 expected = (amountIn * HOOK_FEE_BPS) / 10_000;
        uint256 mockFee = _mockFee(amountIn);
        assertEq(mockFee, expected, "fuzz-halt: mock != formula");
    }
}
