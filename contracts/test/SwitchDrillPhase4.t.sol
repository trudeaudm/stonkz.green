// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FactoryVanity} from "./FactoryVanity.sol";
import {IPoolManager} from "../src/v4/IPoolManager.sol";
import {MockPoolManager} from "../src/mock/MockPoolManager.sol";
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
import {StonkzLadderFactory} from "../src/ladder/StonkzLadderFactory.sol";
import {StonkzLadderAuction} from "../src/ladder/StonkzLadderAuction.sol";
import {LadderConstants} from "../src/ladder/LadderConstants.sol";
import {LadderTypes} from "../src/ladder/LadderTypes.sol";
import {LadderSettlement} from "../src/ladder/LadderSettlement.sol";
import {DeployControls} from "../src/DeployControls.sol";

/// @title SwitchDrillPhase4 — rehearsal-style drill of all four factory switches + fee/carve stamps
/// @notice Mirrors Phase 4 reconciliation checklist: off/on, allowlist, side-pool toggle,
///         lock coexistence, custom-fee 300 bps, carve stamp.
contract SwitchDrillPhase4 is Test, FactoryVanity {
    using PoolIdLibrary for PoolKey;

    MockPoolManager internal pm;
    BuybackAccumulator internal acc;
    StonkzFeeHook internal hook;
    FeeLockerV2 internal locker;
    CTOGovernor internal gov;
    StonkzExpressFactory internal express;
    StonkzLadderFactory internal ladder;

    address internal constant PAIR = address(0);
    address internal constant PAIR_ERC20 = address(0xB111);
    address internal constant TREASURY = address(0x7A5E);
    address internal constant CREATOR = address(0xCEEE);
    address internal constant STRANGER = address(0xB0B);
    address internal constant FRIEND = address(0xA11CE);
    address internal constant STONKZ = address(0x4663);

    uint256 internal constant SUPPLY = 1_000_000 ether;
    uint256 internal constant TIER_4K = 4000e18;

    function setUp() public {
        vm.etch(STONKZ, hex"00");
        pm = new MockPoolManager();
        acc = new BuybackAccumulator(PAIR, STONKZ, address(0));
        gov = new CTOGovernor();
        hook = new StonkzFeeHook(IPoolManager(address(pm)), TREASURY, ICTOGovernor(address(gov)), address(this));
        gov.setRegistry(hook);
        locker = new FeeLockerV2(IPoolManager(address(pm)), hook);
        express = new StonkzExpressFactory(IPoolManager(address(pm)), locker, hook, acc, gov, PAIR, STONKZ
        );
        ladder = new StonkzLadderFactory();
        ladder.setCarveTreasury(TREASURY);
        ladder.setSideTokenRef(STONKZ);
    }

    /// @notice Full drill: gate → allowlist → side → lock coexistence → custom fee → carve.
    function test_P4_switchDrill_full() public {
        // 1) deploysEnabled off blocks; on restores
        express.setDeploysEnabled(false);
        vm.expectRevert(DeployControls.DeploysOff.selector);
        express.list(_params(), bytes32(uint256(1)));
        express.setDeploysEnabled(true);

        // 2) allowlist nonempty → stranger blocked; friend allowed
        express.allowDeployer(FRIEND);
        vm.prank(STRANGER);
        vm.expectRevert(DeployControls.DeployerNotAllowed.selector);
        express.list(_params(), bytes32(uint256(2)));
        StonkzDirectListing listed  = _listAs(express, FRIEND, _params());        assertTrue(listed.liquidityLocked());

        // 3) side-pool toggle stamp
        express.setDefaultCreateSidePool(false);
        StonkzDirectListing noSide  = _listAs(express, FRIEND, _params());        assertFalse(noSide.createSidePool());
        assertFalse(noSide.sidePoolDeployed());
        express.setDefaultCreateSidePool(true);
        express.setDefaultSidePoolBps(1000); // bps of LP-destined (10%)
        StonkzDirectListing withSide  = _listAs(express, FRIEND, _params());        assertTrue(withSide.createSidePool());
        assertEq(withSide.sidePoolBps(), 1000);

        // 4) lock coexistence (locked stamp still refuses after factory unlock)
        express.setDefaultLiquidityLocked(true);
        StonkzDirectListing locked  = _listAs(express, FRIEND, _params());        express.setDefaultLiquidityLocked(false);
        StonkzDirectListing unlocked  = _listAs(express, FRIEND, _params());        assertTrue(locked.liquidityLocked());
        assertFalse(unlocked.liquidityLocked());
        vm.prank(CREATOR);
        vm.expectRevert(StonkzDirectListing.LiquidityIsLocked.selector);
        locked.withdrawMainLiquidity();
        vm.prank(CREATOR);
        unlocked.withdrawMainLiquidity();

        // 5) custom-fee 300 bps stamp (rehearsal drill) — standard unaffected
        address tokenCustom = address(0xC001);
        address tokenStd = address(0xC002);
        PoolKey memory keyC = _mainKey(PAIR_ERC20, tokenCustom);
        PoolKey memory keyS = _mainKey(PAIR_ERC20, tokenStd);
        pm.initialize(keyC, TickMath.getSqrtRatioAtTick(0));
        pm.initialize(keyS, TickMath.getSqrtRatioAtTick(0));
        hook.registerPoolCustom(tokenCustom, PAIR_ERC20, CREATOR, keyC, 300); // bps = 3%
        hook.registerPool(tokenStd, PAIR_ERC20, CREATOR, keyS);
        assertEq(hook.hookFeeBps(tokenCustom), 300);
        assertEq(hook.hookFeeBps(tokenStd), 100);

        // 6) carve stamp survives factory default change
        StonkzLadderAuction a = _file(ladder, _ladderParams(type(uint16).max));
        assertEq(a.carveBps(), LadderConstants.DEFAULT_CARVE_BPS);
        ladder.setDefaultCarveBps(700);
        assertEq(a.carveBps(), LadderConstants.DEFAULT_CARVE_BPS);
        StonkzLadderAuction b = _file(ladder, _ladderParams(type(uint16).max));
        assertEq(b.carveBps(), 700);

        // 7) refprice stamp (pair-wei per STONKZ, WAD) survives default change
        assertEq(withSide.refPriceWad(), express.REF_PRICE_ETH_DEFAULT());
        express.setRefPrice(STONKZ, PAIR, 5e11); // pair-wei per side-token, WAD
        StonkzDirectListing later  = _listAs(express, FRIEND, _params());        assertEq(later.refPriceWad(), 5e11);
        assertEq(withSide.refPriceWad(), 2.5e11); // prior ETH stamp intact
    }

    function _mainKey(address pair, address token) internal view returns (PoolKey memory key) {
        (address c0, address c1) = pair < token ? (pair, token) : (token, pair);
        key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: 0,
            tickSpacing: 60,
            hooks: address(hook)
        });
    }

    function _params() internal pure returns (StonkzDirectListing.ListingParams memory p) {
        p = StonkzDirectListing.ListingParams({
            startMcap: TIER_4K,
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
            refPriceWad: 0
        });
    }

    function _ladderParams(uint16 carve) internal returns (StonkzLadderAuction.Params memory p) {
        LadderSettlement settlement = new LadderSettlement(IPoolManager(address(pm)), hook, PAIR);
        p = StonkzLadderAuction.Params({
            supply: SUPPLY,
            auctionSupply: SUPPLY,
            floorMcap: 10_000 ether,
            duration: LadderConstants.GOD_DURATION,
            lpShareWad: 0.9e18,
            lpHealthTargetWad: 0.25e18,
            carveBps: carve,
            cashHoldbackBps: 0,
            holdbackBps: 0,
            holdbackDelivery: LadderConstants.HoldbackDelivery.None,
            tier: LadderTypes.Tier.God,
            createSidePool: true,
            sidePoolBps: 500,
            refPriceWad: 0,
            walletCapBps: 500,
            sizeBonusBps: 1000,
            maxUniqueActives: 64,
            pairToken: PAIR,
            creator: CREATOR,
            treasury: TREASURY,
            vaultRef: address(0),
            settlement: address(settlement)
        });
    }
}
