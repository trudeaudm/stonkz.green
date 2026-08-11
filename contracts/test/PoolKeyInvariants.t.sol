// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "../src/v4/IPoolManager.sol";
import {MockPoolManager} from "../src/mock/MockPoolManager.sol";
import {BuybackAccumulator} from "../src/BuybackAccumulator.sol";
import {FeeLocker} from "../legacy/FeeLocker.sol";
import {FeeLockerV2} from "../src/FeeLockerV2.sol";
import {StonkzFeeHook} from "../src/StonkzFeeHook.sol";
import {CTOGovernor} from "../src/CTOGovernor.sol";
import {ICTOGovernor} from "../src/interfaces/IStonkzGovernance.sol";
import {StonkzLiquidityStrategy} from "../legacy/StonkzLiquidityStrategy.sol";
import {StonkzDirectListing} from "../src/StonkzDirectListing.sol";
import {PoolKey, PoolIdLibrary} from "../src/v4/types/PoolKey.sol";
import {Currency} from "../src/v4/types/Currency.sol";

/// @title PoolKeyInvariants — FEECHAIN Phase 2 (docs/06).
/// @notice No naked main pools; no hook on side pools. Fuzzed over listing tiers / settle inputs.
contract PoolKeyInvariants is Test {
    using PoolIdLibrary for PoolKey;

    MockPoolManager internal pm;
    StonkzFeeHook internal hook;
    CTOGovernor internal gov;
    BuybackAccumulator internal acc;
    FeeLockerV2 internal lockerV2;
    FeeLocker internal locker;

    address internal constant PAIR = address(0xB111);
    address internal constant STONKZ = address(0x4663);
    address internal constant TREASURY = address(0x7A5E);
    address internal constant CREATOR = address(0xCEEE);
    address internal constant USER = address(0xB222);

    uint256 internal constant SUPPLY = 1_000_000 ether;
    uint256 internal constant TIER_4K = 4000e18;
    uint256 internal constant TIER_8K = 8000e18;

    function setUp() public {
        vm.etch(STONKZ, hex"00");
        pm = new MockPoolManager();
        gov = new CTOGovernor();
        hook = new StonkzFeeHook(IPoolManager(address(pm)), TREASURY, ICTOGovernor(address(gov)));
        gov.setRegistry(hook);
        acc = new BuybackAccumulator(PAIR, STONKZ, address(0));
        lockerV2 = new FeeLockerV2(IPoolManager(address(pm)), hook);
        locker = new FeeLocker(IPoolManager(address(pm)), acc, address(0));
    }

    function _readStrategyMain(StonkzLiquidityStrategy s) internal view returns (PoolKey memory key) {
        (Currency c0, Currency c1, uint24 fee, int24 spacing, address hooksAddr) = s.mainPoolKey();
        key = PoolKey(c0, c1, fee, spacing, hooksAddr);
    }

    function _readStrategySide(StonkzLiquidityStrategy s) internal view returns (PoolKey memory key) {
        (Currency c0, Currency c1, uint24 fee, int24 spacing, address hooksAddr) = s.sidePoolKey();
        key = PoolKey(c0, c1, fee, spacing, hooksAddr);
    }

    function _assertMainWired(IPoolManager mgr, StonkzFeeHook expectedHook, PoolKey memory key) internal view {
        assertEq(key.fee, 0, "main LP fee must be 0");
        assertEq(key.hooks, address(expectedHook), "main key.hooks must be fee hook");
        assertEq(mgr.poolHook(key.toId()), address(expectedHook), "main poolManager hook must be set (no naked pool)");
    }

    function _assertSideNaked(IPoolManager mgr, PoolKey memory key) internal view {
        assertEq(key.fee, 3000, "side LP fee must be 3000 pips = 0.3%");
        assertEq(key.hooks, address(0), "side key.hooks must be zero");
        assertEq(mgr.poolHook(key.toId()), address(0), "side must never have poolManager hook");
    }

    function _list(uint256 tier) internal returns (StonkzDirectListing) {
        StonkzDirectListing.ListingParams memory p = StonkzDirectListing.ListingParams({
            startMcap: tier,
            totalSupply: SUPPLY,
            creatorReserveBps: 0,
            deliveryMode: 0,
            vestDuration: 0,
            declaredUse: bytes32("ops"),
            creator: CREATOR,
            name: "Stonk",
            symbol: "STK",
            createSidePool: true,
            sidePoolBps: 500,
            liquidityLocked: true,
            refPriceWad: 1e15 // pair-wei per STONKZ token, WAD (USDG-style pair)
        });
        return new StonkzDirectListing(
            IPoolManager(address(pm)), lockerV2, hook, acc, gov, PAIR, STONKZ, p
        );
    }

    function test_noNakedMain_directListing() public {
        StonkzDirectListing l = _list(TIER_4K);
        _assertMainWired(IPoolManager(address(pm)), hook, l.mainKey());
        assertTrue(l.sidePoolDeployed(), "side deployed when stonkz set");
        _assertSideNaked(IPoolManager(address(pm)), l.sideKey());
    }

    function test_noNakedMain_auctionSettle() public {
        StonkzLiquidityStrategy s =
            new StonkzLiquidityStrategy(IPoolManager(address(pm)), acc, locker, hook, PAIR, STONKZ);
        s.settle(50 ether, 95 ether, 1 ether, 100 ether, 0, 0, 0, USER, CREATOR);
        _assertMainWired(IPoolManager(address(pm)), hook, _readStrategyMain(s));
        assertTrue(s.sidePoolDeployed());
        _assertSideNaked(IPoolManager(address(pm)), _readStrategySide(s));
    }

    /// @dev Fuzz: every valid Express tier produces a hooked fee-0 main and unhooked 30bps side.
    function testFuzz_noNakedMain_directListing(bool use8k) public {
        StonkzDirectListing l = _list(use8k ? TIER_8K : TIER_4K);
        _assertMainWired(IPoolManager(address(pm)), hook, l.mainKey());
        _assertSideNaked(IPoolManager(address(pm)), l.sideKey());
    }

    /// @dev Fuzz-halt: settle always wires hook on main; never on side.
    function testFuzz_noNakedMain_auctionSettle(uint256 sold_, uint256 reserve) public {
        sold_ = bound(sold_, 1 ether, 80 ether);
        // Keep reserve below naive-full-range trip (openPrice >= P/2 at P=1e18, lpFunds=95e18).
        reserve = bound(reserve, 20 ether, 150 ether);

        MockPoolManager pm2 = new MockPoolManager();
        CTOGovernor gov2 = new CTOGovernor();
        StonkzFeeHook hook2 = new StonkzFeeHook(IPoolManager(address(pm2)), TREASURY, ICTOGovernor(address(gov2)));
        gov2.setRegistry(hook2);
        BuybackAccumulator acc2 = new BuybackAccumulator(PAIR, STONKZ, address(0));
        FeeLocker locker2 = new FeeLocker(IPoolManager(address(pm2)), acc2, address(0));
        StonkzLiquidityStrategy s =
            new StonkzLiquidityStrategy(IPoolManager(address(pm2)), acc2, locker2, hook2, PAIR, STONKZ);

        s.settle(sold_, 95 ether, 1 ether, reserve, 0, 0, 0, USER, CREATOR);
        _assertMainWired(IPoolManager(address(pm2)), hook2, _readStrategyMain(s));
        _assertSideNaked(IPoolManager(address(pm2)), _readStrategySide(s));
    }
}
