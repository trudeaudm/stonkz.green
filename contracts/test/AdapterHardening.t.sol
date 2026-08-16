// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager as ICanonPM} from "@v4-core/src/interfaces/IPoolManager.sol";
import {Deployers} from "@v4-core/test/utils/Deployers.sol";
import {Hooks} from "@v4-core/src/libraries/Hooks.sol";

import {V4Adapter} from "../src/v4/V4Adapter.sol";
import {IPoolManager} from "../src/v4/IPoolManager.sol";
import {PoolKey, PoolIdLibrary} from "../src/v4/types/PoolKey.sol";
import {Currency} from "../src/v4/types/Currency.sol";
import {TickMath} from "../src/v4/TickMath.sol";
import {BuybackAccumulator} from "../src/BuybackAccumulator.sol";
import {StonkzFeeHook} from "../src/StonkzFeeHook.sol";
import {FeeLockerV2} from "../src/FeeLockerV2.sol";
import {CTOGovernor} from "../src/CTOGovernor.sol";
import {ICTOGovernor} from "../src/interfaces/IStonkzGovernance.sol";
import {StonkzDirectListing} from "../src/StonkzDirectListing.sol";
import {StonkzExpressFactory} from "../src/StonkzExpressFactory.sol";
import {HookVanity} from "../src/HookVanity.sol";
import {SkipSettleCanary} from "./harness/SkipSettleCanary.sol";
import {FactoryVanity} from "./FactoryVanity.sol";
import {VanityHelpers} from "./VanityHelpers.sol";

/// @dev Minimal ERC20 for adapter hardening tests.
contract HardeningToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
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

/// @title AdapterHardening — theft reverts, allowlist, sync no-init, dust ETH, CTO, canary harness
contract AdapterHardening is Test, Deployers, FactoryVanity {
    using PoolIdLibrary for PoolKey;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant SUPPLY = 1_000_000 ether;
    uint256 internal constant TIER_4K = 4000e18;
    uint256 internal constant SDONK_ETH_USD = 1882169409521695205329;

    address internal constant TREASURY = address(0x7A5E);
    address internal constant CREATOR = address(0xCEEE);
    address internal constant SIDE = address(0x4663);

    V4Adapter internal adapter;
    HardeningToken internal tok;
    StonkzFeeHook internal hook;
    FeeLockerV2 internal locker;
    CTOGovernor internal gov;
    BuybackAccumulator internal acc;
    StonkzExpressFactory internal express;

    function setUp() public {
        deployFreshManagerAndRouters();
        adapter = new V4Adapter(manager);
        tok = new HardeningToken();
        vm.etch(SIDE, hex"00");

        gov = new CTOGovernor();
        hook = _mineHook();
        hook.bindCanonManager(manager);
        gov.setRegistry(hook);
        locker = new FeeLockerV2(IPoolManager(address(adapter)), hook);
        acc = new BuybackAccumulator(address(0), SIDE, address(0));

        // Generation allowlist: factory + FeeLocker (+ this for direct fixture mints).
        adapter.setAuthorized(address(this), true);
        adapter.setAuthorized(address(locker), true);

        express = new StonkzExpressFactory(
            IPoolManager(address(adapter)), locker, hook, acc, gov, address(0), SIDE
        );
        adapter.setAuthorized(address(express), true);
        _ensureEthUsdRef(express);
    }

    function _mineHook() internal returns (StonkzFeeHook h) {
        bytes memory creation = abi.encodePacked(
            type(StonkzFeeHook).creationCode,
            abi.encode(IPoolManager(address(adapter)), TREASURY, ICTOGovernor(address(gov)), address(this))
        );
        bytes32 initCodeHash = keccak256(creation);
        bytes32 salt;
        address predicted;
        bool found;
        for (uint256 i; i < 1_000_000; ++i) {
            salt = bytes32(i);
            predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash))))
            );
            if ((uint160(predicted) & Hooks.ALL_HOOK_MASK) == HookVanity.HOOK_FLAGS) {
                found = true;
                break;
            }
        }
        require(found, "no flag salt");
        h = new StonkzFeeHook{salt: salt}(
            IPoolManager(address(adapter)), TREASURY, ICTOGovernor(address(gov)), address(this)
        );
        require(address(h) == predicted, "flag create2");
        h.validateHookAddress(address(h));
    }

    function _key() internal view returns (PoolKey memory key) {
        address a = address(0);
        address b = address(tok);
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: 3000,
            tickSpacing: 60,
            hooks: address(0)
        });
    }

    function _paramsEth() internal pure returns (StonkzDirectListing.ListingParams memory p) {
        p = StonkzDirectListing.ListingParams({
            startMcap: TIER_4K,
            totalSupply: SUPPLY,
            creatorReserveBps: 500,
            deliveryMode: 0,
            vestDuration: 0,
            declaredUse: bytes32("harden"),
            creator: CREATOR,
            name: "Harden",
            symbol: "HRDN",
            createSidePool: true,
            sidePoolBps: 500,
            liquidityLocked: true,
            refPriceWad: 2.5e11,
            ethUsdWad: SDONK_ETH_USD
        });
    }

    function _authorizeNextCreate() internal {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        adapter.setAuthorized(predicted, true);
    }

    // ─── (a) THEFT REVERTS ─────────────────────────────────────────────────

    function test_a_hostile_modifyLiquidity_reverts() public {
        PoolKey memory key = _key();
        adapter.initialize(key, TickMath.getSqrtRatioAtTick(0));
        tok.mint(address(this), 100 ether);
        tok.approve(address(adapter), type(uint256).max);
        vm.deal(address(this), 100 ether);
        bytes32 salt = bytes32(uint256(uint160(address(0xBEEF))));
        adapter.modifyLiquidity{value: 50 ether}(
            key,
            IPoolManager.ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 1e18, salt: salt}),
            ""
        );

        address hostile = address(0xBAD);
        vm.prank(hostile);
        vm.expectRevert(V4Adapter.NotAuthorized.selector);
        adapter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -600,
                tickUpper: 600,
                liquidityDelta: -int256(1e18),
                salt: salt
            }),
            ""
        );
    }

    function test_a_hostile_initialize_reverts() public {
        address hostile = address(0xBAD);
        vm.prank(hostile);
        vm.expectRevert(V4Adapter.NotAuthorized.selector);
        adapter.initialize(_key(), TickMath.getSqrtRatioAtTick(0));
    }

    function test_a_hostile_pokeCollect_reverts() public {
        PoolKey memory key = _key();
        adapter.initialize(key, TickMath.getSqrtRatioAtTick(0));
        address hostile = address(0xBAD);
        vm.prank(hostile);
        vm.expectRevert(V4Adapter.NotAuthorized.selector);
        adapter.pokeCollect(key, -600, 600, bytes32(uint256(1)));
    }

    // ─── (b) LEGIT PATH: factory listing + FeeLocker authorized ─────────────

    function test_b_factory_listing_mints_under_allowlist() public {
        vm.deal(address(this), 2 ether);
        StonkzDirectListing.ListingParams memory p = _paramsEth();
        p.ethUsdWad = 0;
        _ensureEthUsdRef(express);
        p.ethUsdWad = express.currentEthUsdWad();
        (bytes32 userSalt,) = VanityHelpers.mineExpress(express, address(this), p);
        StonkzDirectListing listing = express.list{value: 1 ether}(p, userSalt);
        assertTrue(adapter.authorized(address(listing)), "listing authorized at create");
        assertGt(uint256(listing.mainLiquidity()), 0, "main minted");
        assertTrue(adapter.isInitialized(listing.mainKey().toId()));
    }

    function test_b_feeLocker_is_authorized() public view {
        assertTrue(adapter.authorized(address(locker)));
    }

    // ─── (c) syncToPrice: init ok / uninit reverts / public ────────────────

    function test_c_syncToPrice_initialized_works() public {
        PoolKey memory key = _key();
        uint160 mid = TickMath.getSqrtRatioAtTick(0);
        adapter.initialize(key, mid);
        tok.mint(address(this), 100 ether);
        tok.approve(address(adapter), type(uint256).max);
        vm.deal(address(this), 100 ether);
        adapter.modifyLiquidity{value: 50 ether}(
            key,
            IPoolManager.ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 1e18, salt: bytes32(0)}),
            ""
        );

        address stranger = address(0x51C);
        vm.deal(stranger, 10 ether);
        // Permissionless: stranger need not be authorized.
        vm.prank(stranger);
        uint256 spent = adapter.syncToPrice{value: 1 ether}(key, TickMath.getSqrtRatioAtTick(-60), 1 ether);
        spent; // may be 0 if already near; must not revert
    }

    function test_c_syncToPrice_uninitialized_reverts() public {
        PoolKey memory key = _key();
        assertFalse(adapter.isInitialized(key.toId()));
        vm.expectRevert(IPoolManager.PoolNotInitialized.selector);
        adapter.syncToPrice(key, TickMath.getSqrtRatioAtTick(0), 1 ether);
    }

    // ─── (e) _refundDustEth: cannot drain stuck prior ETH ──────────────────

    function test_e_refundDustEth_only_caller_unused_value() public {
        // Seed stuck ETH on adapter (simulates prior grief / leftover).
        vm.deal(address(adapter), 5 ether);
        uint256 stuck = 5 ether;

        PoolKey memory key = _key();
        adapter.initialize(key, TickMath.getSqrtRatioAtTick(0));
        tok.mint(address(this), 100 ether);
        tok.approve(address(adapter), type(uint256).max);

        address caller = address(0xCA11);
        adapter.setAuthorized(caller, true);
        tok.mint(caller, 100 ether);
        vm.prank(caller);
        tok.approve(address(adapter), type(uint256).max);
        vm.deal(caller, 2 ether);

        uint256 callerBefore = caller.balance;
        vm.prank(caller);
        // Send 1 ETH; most unused should refund to caller; stuck 5 stays.
        adapter.modifyLiquidity{value: 1 ether}(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -600,
                tickUpper: 600,
                liquidityDelta: 1e18,
                salt: bytes32(uint256(99))
            }),
            ""
        );

        assertEq(address(adapter).balance, stuck, "stuck ETH untouched");
        assertLe(caller.balance, callerBefore, "caller did not gain stuck ETH");
        // Caller should have been refunded unused portion of their 1 ETH (spent some on settle).
        assertGt(caller.balance, callerBefore - 1 ether, "unused value refunded");
    }

    // ─── (f) CTO: fee receiver path not blocked by allowlist ───────────────

    function test_f_cto_feeReceiver_unaffected_by_allowlist() public {
        vm.deal(address(this), 2 ether);
        StonkzDirectListing.ListingParams memory p = _paramsEth();
        p.ethUsdWad = 0;
        _ensureEthUsdRef(express);
        p.ethUsdWad = express.currentEthUsdWad();
        (bytes32 userSalt,) = VanityHelpers.mineExpress(express, address(this), p);
        StonkzDirectListing listing = express.list{value: 1 ether}(p, userSalt);
        address token = address(listing.token());
        assertEq(hook.feeReceiver(token), CREATOR);

        address candidate = address(0xC70);
        // Simulate CTO finalize transfer (hook governor path).
        vm.prank(address(gov));
        hook.governorTransfer(token, candidate, candidate);
        assertEq(hook.feeReceiver(token), candidate);

        // Listing remains authorized for any later withdraw/ops; candidate needs no adapter auth.
        assertTrue(adapter.authorized(address(listing)));
        assertFalse(adapter.authorized(candidate));
    }

    // ─── F1 canary harness (not in shipped adapter) ────────────────────────

    function test_f1_skipSettleCanary_redThenGreen() public {
        SkipSettleCanary canary = new SkipSettleCanary(manager);
        PoolKey memory key = _key();
        // Canary is not the adapter — initialize via adapter (authorized).
        adapter.initialize(key, TickMath.getSqrtRatioAtTick(0));
        tok.mint(address(this), 100 ether);
        tok.approve(address(canary), type(uint256).max);
        // Canary settle pulls from payer=this; also need adapter-style approve for transferFrom to PM.
        tok.approve(address(manager), type(uint256).max);
        vm.deal(address(this), 100 ether);

        canary.setSkipSettle(true);
        vm.expectRevert(); // CurrencyNotSettled
        canary.modifyLiquidity{value: 50 ether}(key, -600, 600, 1e18, bytes32(uint256(7)));

        canary.setSkipSettle(false);
        canary.modifyLiquidity{value: 50 ether}(key, -600, 600, 1e18, bytes32(uint256(7)));
    }

    function test_constructor_rejects_zero_manager() public {
        vm.expectRevert(V4Adapter.ZeroAddress.selector);
        new V4Adapter(ICanonPM(address(0)));
    }
}
