// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager as ICanonPM} from "@v4-core/src/interfaces/IPoolManager.sol";
import {Deployers} from "@v4-core/test/utils/Deployers.sol";
import {Hooks} from "@v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@v4-core/src/interfaces/IHooks.sol";
import {CurrencyLibrary} from "@v4-core/src/types/Currency.sol";

import {V4Adapter} from "../src/v4/V4Adapter.sol";
import {IPoolManager} from "../src/v4/IPoolManager.sol";
import {PoolKey, PoolIdLibrary} from "../src/v4/types/PoolKey.sol";
import {Currency} from "../src/v4/types/Currency.sol";
import {TickMath} from "../src/v4/TickMath.sol";
import {SkipSettleCanary} from "./harness/SkipSettleCanary.sol";

/// @dev Minimal ERC20 for adapter netting tests.
contract V4CanonToken {
    string public name = "V4Canon";
    string public symbol = "V4C";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        uint256 al = allowance[f][msg.sender];
        if (al != type(uint256).max) allowance[f][msg.sender] = al - a;
        balanceOf[f] -= a;
        balanceOf[to] += a;
        return true;
    }
}

/// @title V4AdapterPhase0 - adapter + SkipSettleCanary (CurrencyNotSettled vacuity guard)
contract V4AdapterPhase0 is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    V4Adapter internal adapter;
    V4CanonToken internal tok;
    address internal hookAddr;

    function setUp() public {
        deployFreshManagerAndRouters();
        adapter = new V4Adapter(manager);
        adapter.setAuthorized(address(this), true);
        tok = new V4CanonToken();
        hookAddr = address(uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG));
        // Etch empty code so initialize accepts a contract at flag address (no callbacks).
        vm.etch(hookAddr, hex"00");
    }

    function _key() internal view returns (PoolKey memory key) {
        address a = address(0); // native ETH as currency0 if sorted first
        address b = address(tok);
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: 3000,
            tickSpacing: 60,
            hooks: address(0) // no hooks for Phase 0 liquidity canary
        });
    }

    function test_P0_initialize_and_isInitialized_viaStateLibrary() public {
        PoolKey memory key = _key();
        assertFalse(adapter.isInitialized(key.toId()));
        int24 tick = adapter.initialize(key, TickMath.getSqrtRatioAtTick(0));
        assertEq(tick, 0);
        assertTrue(adapter.isInitialized(key.toId()), "sqrtPrice != 0 => initialized");
        (uint160 sqrt,,, ) = adapter.getSlot0(key.toId());
        assertEq(sqrt, TickMath.getSqrtRatioAtTick(0));
    }

    function test_P0_modifyLiquidity_nets_green() public {
        PoolKey memory key = _key();
        adapter.initialize(key, TickMath.getSqrtRatioAtTick(0));

        // Fund this test contract; approve adapter for ERC20 leg.
        uint256 amt = 100 ether;
        tok.mint(address(this), amt);
        tok.approve(address(adapter), type(uint256).max);
        vm.deal(address(this), amt);

        // Full-range-ish liquidity around 0.
        adapter.modifyLiquidity{value: amt}(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -600,
                tickUpper: 600,
                liquidityDelta: 1e18,
                salt: bytes32(uint256(1))
            }),
            ""
        );
        // If we got here, unlock settled - CurrencyNotSettled did not fire.
        assertTrue(adapter.isInitialized(key.toId()));
    }

    /// @notice CANARY: SkipSettleCanary (test harness) proves PM CurrencyNotSettled; settle path green.
    function test_P0_canary_skipSettle_redThenGreen() public {
        SkipSettleCanary canary = new SkipSettleCanary(manager);
        PoolKey memory key = _key();
        adapter.initialize(key, TickMath.getSqrtRatioAtTick(0));
        tok.mint(address(this), 100 ether);
        tok.approve(address(canary), type(uint256).max);
        tok.approve(address(manager), type(uint256).max);
        vm.deal(address(this), 100 ether);

        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: -600,
            tickUpper: 600,
            liquidityDelta: 1e18,
            salt: bytes32(uint256(2))
        });

        canary.setSkipSettle(true);
        vm.expectRevert(); // CurrencyNotSettled
        canary.modifyLiquidity{value: 100 ether}(key, params.tickLower, params.tickUpper, params.liquidityDelta, params.salt);

        canary.setSkipSettle(false);
        canary.modifyLiquidity{value: 100 ether}(key, params.tickLower, params.tickUpper, params.liquidityDelta, params.salt);
    }

    function test_P0_mockSeams_revert() public {
        vm.expectRevert();
        adapter.setPoolHook(PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(1)),
            fee: 0,
            tickSpacing: 60,
            hooks: address(0)
        }).toId(), address(this));

        vm.expectRevert();
        adapter.accrueFees(PoolIdLibrary.toId(PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(1)),
            fee: 0,
            tickSpacing: 60,
            hooks: address(0)
        })), bytes32(0), 1, 1);
    }

    // Deployers already provides receive()
}
