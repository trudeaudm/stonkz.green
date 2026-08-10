// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@v4-core/src/interfaces/IHooks.sol";
import {IPoolManager as ICanonPM} from "@v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@v4-core/src/libraries/Hooks.sol";
import {PoolKey as CanonPoolKey} from "@v4-core/src/types/PoolKey.sol";
import {Currency} from "@v4-core/src/types/Currency.sol";
import {SwapParams} from "@v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@v4-core/src/test/PoolSwapTest.sol";
import {Deployers} from "@v4-core/test/utils/Deployers.sol";

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "../src/v4/IPoolManager.sol";
import {MockPoolManager} from "../src/mock/MockPoolManager.sol";
import {PoolKey as OurPoolKey, PoolId, PoolIdLibrary} from "../src/v4/types/PoolKey.sol";
import {Currency as OurCurrency} from "../src/v4/types/Currency.sol";
import {TickMath} from "../src/v4/TickMath.sol";
import {StonkzFeeHook} from "../src/StonkzFeeHook.sol";
import {HookVanity} from "../src/HookVanity.sol";
import {CTOGovernor} from "../src/CTOGovernor.sol";
import {ICTOGovernor} from "../src/interfaces/IStonkzGovernance.sol";

/// @title FeeHookPhase1 — V4-CANON Phase 1: real IHooks + flags + exact-in/out under real PM
contract FeeHookPhase1 is Test, Deployers {
    using PoolIdLibrary for OurPoolKey;

    address internal constant TREASURY = address(0x7A5E);
    address internal constant CREATOR = address(0xCE0);
    address internal constant TOKEN = address(0xC0FFEE);

    /// @dev Flag-valid etch target (tests). Production mines 0x4663…088.
    address internal hookAddr;

    StonkzFeeHook internal hook; // the etched address cast
    CTOGovernor internal gov;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        gov = new CTOGovernor();
        // CREATE2 to a flag-valid address so constructor storage runs (etch would skip it).
        // Tests mine flags only (~2^14). Production miner adds 0x4663 prefix (~2^30).
        bytes memory creation = abi.encodePacked(
            type(StonkzFeeHook).creationCode,
            abi.encode(IPoolManager(address(manager)), TREASURY, ICTOGovernor(address(gov)))
        );
        bytes32 initCodeHash = keccak256(creation);
        bytes32 salt;
        address predicted;
        uint256 freemem;
        assembly {
            freemem := mload(0x40)
        }
        bool found;
        for (uint256 i; i < 1_000_000; ++i) {
            assembly {
                mstore(0x40, freemem)
            }
            salt = bytes32(i);
            predicted = address(
                uint160(
                    uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash)))
                )
            );
            if ((uint160(predicted) & Hooks.ALL_HOOK_MASK) == HookVanity.HOOK_FLAGS) {
                found = true;
                break;
            }
        }
        require(found, "no flag salt");
        hook = new StonkzFeeHook{salt: salt}(
            IPoolManager(address(manager)), TREASURY, ICTOGovernor(address(gov))
        );
        hookAddr = address(hook);
        require(hookAddr == predicted, "create2");
        hook.validateHookAddress(hookAddr);
        assertEq(hook.defaultHookFeeBps(), 100);
        gov.setRegistry(hook);
    }

    function test_flags_etchAddress_passesValidateHookPermissions() public view {
        hook.validateHookAddress(hookAddr);
        assertEq(uint160(hookAddr) & Hooks.ALL_HOOK_MASK, hook.HOOK_FLAGS());
    }

    function test_hookVanity_constants_matchTarget() public view {
        assertEq(HookVanity.PREFIX, uint16(0x4663));
        assertEq(HookVanity.HOOK_FLAGS, uint160(0x088));
        // Synthetic address: prefix + zeros + flags
        address synth = address((uint160(0x4663) << 144) | uint160(0x088));
        assertTrue(HookVanity.matches(synth));
        hook.validateHookAddress(synth);
    }

    function test_real_exactIn_pairSide_100bps() public {
        address pair = Currency.unwrap(currency0);
        address token = TOKEN;
        if (token == pair) token = address(uint160(pair) + 1);

        (key,) = initPool(currency0, currency1, IHooks(hookAddr), 0, int24(60), SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, ZERO_BYTES);

        // Stamp with OUR PoolKey shape matching canon key encoding.
        OurPoolKey memory ourKey = OurPoolKey({
            currency0: OurCurrency.wrap(Currency.unwrap(key.currency0)),
            currency1: OurCurrency.wrap(Currency.unwrap(key.currency1)),
            fee: key.fee,
            tickSpacing: key.tickSpacing,
            hooks: hookAddr
        });
        // tokenOfPool keyed by our PoolId = keccak(abi.encode(ourKey)).
        // Canon uses same 5-field encode — must match.
        // Register token against pool; pair = currency0 for zeroForOne exact-in fee.
        // Deployers currency0/currency1 ordering: currency0 < currency1.
        // For pair=currency0, zeroForOne exact-in takes fee in currency0 (specified).
        hook.registerPoolCustom(token, pair, CREATOR, ourKey, 100);
        // Ensure pool id mapping: our encode must equal canon encode of key.
        assertEq(PoolId.unwrap(PoolIdLibrary.toId(ourKey)), keccak256(abi.encode(key)), "pool id encode mismatch");

        uint256 amountIn = 1000;
        uint256 balBefore = currency0.balanceOf(hookAddr);
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: SQRT_PRICE_1_2});
        swapRouter.swap(key, params, settings, ZERO_BYTES);

        uint256 feeTaken = currency0.balanceOf(hookAddr) - balBefore;
        assertEq(feeTaken, 10, "100 bps of 1000"); // 1000 * 100 / 10000 = 10
        uint256 gross = hook.receiverPairProceeds(token) + hook.tokenPairProceeds(token);
        assertEq(gross, 10, "accrued");
    }

    function test_real_exactOut_pairSide_100bps() public {
        address pair = Currency.unwrap(currency0);
        address token = TOKEN;
        if (token == pair) token = address(uint160(pair) + 1);

        // currency1 -> currency0 (zeroForOne=false): exact-out of currency0 (unspecified = pair)
        // Wait: exact-out amountSpecified > 0 means amount of unspecified currency out? 
        // In v4: amountSpecified > 0 = exact output of the unspecified currency... 
        // Actually: negative = exact in of specified, positive = exact out of specified.
        // specified = zeroForOne ? c0 : c1.
        // For fee on pair=c0 with exact-out: feeCurrency = unspecified when exactOut.
        // We need unspecified == pair. So specified != pair → zeroForOne means specified=c0=pair,
        // so for exact-out fee on pair we need zeroForOne=false (specified=c1, unspecified=c0=pair).

        (key,) = initPool(currency0, currency1, IHooks(hookAddr), 0, int24(60), SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, ZERO_BYTES);

        OurPoolKey memory ourKey = OurPoolKey({
            currency0: OurCurrency.wrap(Currency.unwrap(key.currency0)),
            currency1: OurCurrency.wrap(Currency.unwrap(key.currency1)),
            fee: key.fee,
            tickSpacing: key.tickSpacing,
            hooks: hookAddr
        });
        hook.registerPoolCustom(token, pair, CREATOR, ourKey, 100);

        uint256 amountOut = 1000; // exact out of specified (c1 when !zeroForOne)
        // Fee = 100 bps of |amountSpecified| = 10, taken from unspecified (c0=pair).
        uint256 balBefore = currency0.balanceOf(hookAddr);
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        SwapParams memory params = SwapParams({
            zeroForOne: false,
            amountSpecified: int256(amountOut),
            sqrtPriceLimitX96: SQRT_PRICE_1_1 + 1 // move price up slightly
        });
        // Use a looser limit from Deployers if needed
        params.sqrtPriceLimitX96 = TickMath.MAX_SQRT_RATIO - 1;
        swapRouter.swap(key, params, settings, ZERO_BYTES);

        uint256 feeTaken = currency0.balanceOf(hookAddr) - balBefore;
        assertEq(feeTaken, 10, "exact-out 100 bps of 1000 on pair");
        assertEq(hook.receiverPairProceeds(token) + hook.tokenPairProceeds(token), 10);
    }

    function test_real_hostileReceiver_tradeNeverReverts() public {
        address pair = Currency.unwrap(currency0);
        address token = address(0xC0FE);
        RevertingReceiver bad = new RevertingReceiver();

        (key,) = initPool(currency0, currency1, IHooks(hookAddr), 0, int24(60), SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, ZERO_BYTES);

        OurPoolKey memory ourKey = OurPoolKey({
            currency0: OurCurrency.wrap(Currency.unwrap(key.currency0)),
            currency1: OurCurrency.wrap(Currency.unwrap(key.currency1)),
            fee: key.fee,
            tickSpacing: key.tickSpacing,
            hooks: hookAddr
        });
        hook.registerPoolCustom(token, pair, address(bad), ourKey, 100);

        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        // Must not revert despite hostile feeReceiver (accrue only — no transfer in swap).
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -int256(1000), sqrtPriceLimitX96: SQRT_PRICE_1_2}),
            settings,
            ZERO_BYTES
        );
        assertGt(hook.receiverPairProceeds(token), 0, "accrued to hostile");
    }

    function test_mock_still_afterSwap_path() public {
        MockPoolManager mpm = new MockPoolManager();
        CTOGovernor g = new CTOGovernor();
        StonkzFeeHook sh = new StonkzFeeHook(IPoolManager(address(mpm)), TREASURY, ICTOGovernor(address(g)));
        address pair = address(0xB111);
        OurPoolKey memory mkey = OurPoolKey({
            currency0: OurCurrency.wrap(pair),
            currency1: OurCurrency.wrap(TOKEN),
            fee: 0,
            tickSpacing: 60,
            hooks: address(sh)
        });
        mpm.initialize(mkey, TickMath.getSqrtRatioAtTick(0));
        sh.registerPool(TOKEN, pair, CREATOR, mkey);
        mpm.swap(
            mkey,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(1000 ether),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_RATIO + 1
            }),
            ""
        );
        assertEq(sh.receiverPairProceeds(TOKEN) + sh.tokenPairProceeds(TOKEN), 10 ether);
    }
}

contract RevertingReceiver {
    receive() external payable {
        revert("nope");
    }

    fallback() external payable {
        revert("nope");
    }
}
