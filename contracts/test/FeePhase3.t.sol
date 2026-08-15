// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "../src/v4/IPoolManager.sol";
import {MockPoolManager} from "../src/mock/MockPoolManager.sol";
import {PoolKey, PoolIdLibrary} from "../src/v4/types/PoolKey.sol";
import {Currency} from "../src/v4/types/Currency.sol";
import {TickMath} from "../src/v4/TickMath.sol";
import {StonkzFeeHook} from "../src/StonkzFeeHook.sol";
import {CTOGovernor} from "../src/CTOGovernor.sol";
import {ICTOGovernor} from "../src/interfaces/IStonkzGovernance.sol";

/// @title FeePhase3 — FEECHAIN Phase 3: units, accrue-flush, custom deploy, trade-never-reverts.
contract FeePhase3 is Test {
    using PoolIdLibrary for PoolKey;

    MockPoolManager internal pm;
    StonkzFeeHook internal hook;
    CTOGovernor internal gov;

    address internal constant PAIR_ERC20 = address(0xB111);
    address internal constant TOKEN = address(0xC0FFEE);
    address payable internal treasury;
    address internal constant CREATOR = address(0xCE0);

    RevertingReceiver internal badReceiver;

    function setUp() public {
        pm = new MockPoolManager();
        vm.deal(address(pm), 1_000_000 ether);
        treasury = payable(address(0x7A5E));
        vm.deal(treasury, 0);
        gov = new CTOGovernor();
        hook = new StonkzFeeHook(IPoolManager(address(pm)), treasury, ICTOGovernor(address(gov)), address(this));
        gov.setRegistry(hook);
        badReceiver = new RevertingReceiver();
    }

    function _mainKey(address pair, address token) internal view returns (PoolKey memory key) {
        (address c0, address c1) = pair < token ? (pair, token) : (token, pair);
        key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: 0, // pips = 0%
            tickSpacing: 60,
            hooks: address(hook)
        });
    }

    function _swapPairIn(PoolKey memory key, address pair, uint256 amountIn) internal {
        bool zeroForOne = Currency.unwrap(key.currency0) == pair;
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1;
        pm.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: limit
            }),
            ""
        );
    }

    /// @notice Units discipline: stamped default is 100 bps AND a known swap yields exactly 1%.
    function test_units_default100bps_swapYieldsExact1Percent() public {
        PoolKey memory key = _mainKey(PAIR_ERC20, TOKEN);
        pm.initialize(key, TickMath.getSqrtRatioAtTick(0));
        hook.registerPool(TOKEN, PAIR_ERC20, CREATOR, key);

        assertEq(hook.defaultHookFeeBps(), 100, "factory default 100 bps = 1%");
        assertEq(hook.hookFeeBps(TOKEN), 100, "stamped 100 bps = 1%");

        uint256 amountIn = 1000 ether;
        _swapPairIn(key, PAIR_ERC20, amountIn);

        uint256 gross = hook.receiverPairProceeds(TOKEN) + hook.tokenPairProceeds(TOKEN);
        assertEq(gross, amountIn / 100, "exact 1% of notional (units error fails arithmetically)");
        // protocolFeeBps default 2500 bps = 25% of fee
        assertEq(hook.tokenPairProceeds(TOKEN), (gross * 2500) / 10_000, "protocol 25% of fee");
        assertEq(hook.receiverPairProceeds(TOKEN), gross - hook.tokenPairProceeds(TOKEN), "receiver remainder");
    }

    function test_customDeploy_300bps_and_standardUnaffected() public {
        address tokenCustom = address(0xC001);
        address tokenStd = address(0xC002);
        PoolKey memory keyC = _mainKey(PAIR_ERC20, tokenCustom);
        PoolKey memory keyS = _mainKey(PAIR_ERC20, tokenStd);
        pm.initialize(keyC, TickMath.getSqrtRatioAtTick(0));
        pm.initialize(keyS, TickMath.getSqrtRatioAtTick(0));

        hook.registerPoolCustom(tokenCustom, PAIR_ERC20, CREATOR, keyC, 300); // bps = 3%
        hook.registerPool(tokenStd, PAIR_ERC20, CREATOR, keyS);

        assertEq(hook.hookFeeBps(tokenCustom), 300, "custom stamped 300 bps = 3%");
        assertEq(hook.hookFeeBps(tokenStd), 100, "standard stamped default 100 bps = 1%");
        assertEq(hook.defaultHookFeeBps(), 100, "global default unchanged");
    }

    function test_customDeploy_outOfBounds_reverts() public {
        PoolKey memory key = _mainKey(PAIR_ERC20, TOKEN);
        pm.initialize(key, TickMath.getSqrtRatioAtTick(0));
        vm.expectRevert(abi.encodeWithSelector(StonkzFeeHook.HookFeeBpsOutOfBounds.selector, uint16(1001)));
        hook.registerPoolCustom(TOKEN, PAIR_ERC20, CREATOR, key, 1001);
    }

    function test_hostileReceiver_cannotRevertSwap() public {
        address pair = address(0); // native — flush path exercises ETH
        address token = address(0xC0FE);
        PoolKey memory key = _mainKey(pair, token);
        pm.initialize(key, TickMath.getSqrtRatioAtTick(0));
        hook.registerPool(token, pair, address(badReceiver), key);

        uint256 amountIn = 100 ether;
        // Must not revert despite feeReceiver being a reverting contract (no transfer in swap).
        _swapPairIn(key, pair, amountIn);
        assertGt(hook.receiverPairProceeds(token), 0, "accrued to hostile receiver");
    }

    function test_hostileReceiver_cannotBlockTreasuryFlush() public {
        address pair = address(0);
        address token = address(0xC0FE);
        PoolKey memory key = _mainKey(pair, token);
        pm.initialize(key, TickMath.getSqrtRatioAtTick(0));
        hook.registerPool(token, pair, address(badReceiver), key);

        _swapPairIn(key, pair, 100 ether);
        uint256 protoBefore = hook.tokenPairProceeds(token);
        uint256 recvBefore = hook.receiverPairProceeds(token);
        assertGt(protoBefore, 0);
        assertGt(recvBefore, 0);

        uint256 treasBalBefore = treasury.balance;
        hook.flush(token);

        assertEq(hook.receiverPairProceeds(token), recvBefore, "hostile receiver still accrued");
        assertEq(hook.tokenPairProceeds(token), 0, "treasury flushed");
        assertEq(treasury.balance, treasBalBefore + protoBefore, "treasury received");
    }

    function testFuzz_accruedExactAcrossSwaps(uint8 nSwaps, uint256 amountSeed) public {
        nSwaps = uint8(bound(nSwaps, 1, 12));
        PoolKey memory key = _mainKey(PAIR_ERC20, TOKEN);
        pm.initialize(key, TickMath.getSqrtRatioAtTick(0));
        hook.registerPool(TOKEN, PAIR_ERC20, CREATOR, key);

        uint256 expectGross;
        for (uint256 i = 0; i < nSwaps; i++) {
            uint256 amountIn = bound(amountSeed >> (i * 8), 1e15, 1e21);
            expectGross += (amountIn * uint256(hook.hookFeeBps(TOKEN))) / 10_000;
            _swapPairIn(key, PAIR_ERC20, amountIn);
        }
        uint256 got = hook.receiverPairProceeds(TOKEN) + hook.tokenPairProceeds(TOKEN);
        assertEq(got, expectGross, "fuzz-halt: accrued != sum of per-swap fees");
    }

    function test_hookFail_tradeNeverReverts() public {
        PoolKey memory key = _mainKey(PAIR_ERC20, TOKEN);
        pm.initialize(key, TickMath.getSqrtRatioAtTick(0));
        hook.registerPool(TOKEN, PAIR_ERC20, CREATOR, key);

        hook.setForceFailNextAccrue(true);
        _swapPairIn(key, PAIR_ERC20, 100 ether);
        assertEq(hook.receiverPairProceeds(TOKEN), 0, "failed accrue left zero");
        _swapPairIn(key, PAIR_ERC20, 100 ether);
        assertGt(hook.receiverPairProceeds(TOKEN) + hook.tokenPairProceeds(TOKEN), 0);
    }

    function testFuzz_hookFail_tradeNeverReverts(uint256 amountIn) public {
        amountIn = bound(amountIn, 1e15, 1e21);
        // Fresh token per fuzz run so registerPool always succeeds.
        address token = address(uint160(uint256(keccak256(abi.encode(amountIn, "hookfail")))));
        PoolKey memory key = _mainKey(PAIR_ERC20, token);
        pm.initialize(key, TickMath.getSqrtRatioAtTick(0));
        hook.registerPool(token, PAIR_ERC20, CREATOR, key);

        hook.setForceFailNextAccrue(true);
        _swapPairIn(key, PAIR_ERC20, amountIn);
        assertEq(hook.receiverPairProceeds(token), 0, "failed accrue left zero");
        _swapPairIn(key, PAIR_ERC20, amountIn);
        assertGt(hook.receiverPairProceeds(token) + hook.tokenPairProceeds(token), 0);
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
