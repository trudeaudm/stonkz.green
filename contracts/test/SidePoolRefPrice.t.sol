// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {IPoolManager} from "../src/v4/IPoolManager.sol";
import {MockPoolManager} from "../src/mock/MockPoolManager.sol";
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

/// @title SidePoolRefPrice — stamped pair-wei/side-token ref (ruling B) + known-value init
contract SidePoolRefPrice is Test {
    MockPoolManager internal pm;
    BuybackAccumulator internal acc;
    StonkzFeeHook internal hook;
    FeeLockerV2 internal locker;
    CTOGovernor internal gov;
    StonkzExpressFactory internal expressEth;
    StonkzExpressFactory internal expressUsdg;
    StonkzLadderFactory internal ladder;

    address internal constant ETH = address(0);
    address internal constant USDG = address(0x55534447); // stand-in USDG; pair-wei uses USDG bounds
    address internal constant TREASURY = address(0x7A5E);
    address internal constant CREATOR = address(0xCEEE);
    address internal constant STONKZ = address(0x4663);

    uint256 internal constant SUPPLY = 1_000_000 ether;
    uint256 internal constant TIER_4K = 4000e18;
    uint256 internal constant WAD = 1e18;

    function setUp() public {
        vm.etch(STONKZ, hex"00"); // sideTokenRef NotContract — fixed stand-in address has code
        pm = new MockPoolManager();
        acc = new BuybackAccumulator(ETH, STONKZ, address(0));
        gov = new CTOGovernor();
        hook = new StonkzFeeHook(IPoolManager(address(pm)), TREASURY, ICTOGovernor(address(gov)));
        gov.setRegistry(hook);
        locker = new FeeLockerV2(IPoolManager(address(pm)), hook);
        expressEth = new StonkzExpressFactory(
            IPoolManager(address(pm)), locker, hook, acc, gov, ETH, STONKZ
        );
        expressUsdg = new StonkzExpressFactory(
            IPoolManager(address(pm)), locker, hook, acc, gov, USDG, STONKZ
        );
        ladder = new StonkzLadderFactory();
        ladder.setSideTokenRef(STONKZ); // seeds (STONKZ, ETH) default
        ladder.setRefPrice(STONKZ, USDG, ladder.REF_PRICE_USDG_DEFAULT());
    }

    // ─── units / birth defaults ────────────────────────────────────────────

    function test_ref_units_ethDefault_pairWeiPerSideToken() public view {
        // Unit: pair-wei per side-token, WAD — keyed (sideToken, pairCurrency)
        assertEq(expressEth.REF_PRICE_ETH_DEFAULT(), 2.5e11);
        assertEq(expressEth.refPriceWad(STONKZ, ETH), 2.5e11);
        assertTrue(expressEth.refPriceConfigured(STONKZ, ETH));
        assertEq(expressEth.REF_PRICE_ETH_MIN(), 1e8);
        assertEq(expressEth.REF_PRICE_ETH_MAX(), 1e17);
    }

    function test_ref_units_usdgDefault_pairWeiPerSideToken() public view {
        assertEq(expressUsdg.REF_PRICE_USDG_DEFAULT(), 1e15);
        assertEq(expressUsdg.refPriceWad(STONKZ, USDG), 1e15);
        assertTrue(expressUsdg.refPriceConfigured(STONKZ, USDG));
        assertEq(expressUsdg.REF_PRICE_USDG_MIN(), 1e12);
        assertEq(expressUsdg.REF_PRICE_USDG_MAX(), 1e21);
    }

    // ─── known-value arithmetic (Express) ──────────────────────────────────

    function test_ref_express_eth_initTick_knownValue() public {
        // startPriceWad = 4000e18 * WAD / 1e24 = 4e15 pair-wei/token
        // priceInStonkz = 4e15 * WAD / 2.5e11 = 1.6e22 side-token/token
        StonkzDirectListing l = expressEth.list(_params(), bytes32(uint256(1)));
        assertEq(l.refPriceWad(), 2.5e11);
        assertEq(l.startPriceWad(), 4e15);

        uint256 priceInStonkz = FixedPointMathLib.mulDiv(l.startPriceWad(), WAD, l.refPriceWad());
        assertEq(priceInStonkz, 1.6e22);
        // Phase-4 Express real-PM orientation: sideTickLower is currency-order
        // dependent (not naive tickAbovePrice(priceInStonkz)); lock arithmetic + deploy.
        assertTrue(l.sidePoolDeployed());
        assertGt(l.sideLiquidity(), 0);
    }

    function test_ref_express_usdg_initTick_knownValue() public {
        StonkzDirectListing l = expressUsdg.list(_params(), bytes32(uint256(2)));
        assertEq(l.refPriceWad(), 1e15);
        uint256 priceInStonkz = FixedPointMathLib.mulDiv(l.startPriceWad(), WAD, l.refPriceWad());
        assertEq(priceInStonkz, 4e18);
        assertTrue(l.sidePoolDeployed());
    }

    // ─── Ladder file stamps ref ────────────────────────────────────────────

    function test_ref_ladder_file_stamps() public {
        ladder.setSettlementRef(address(new LadderSettlement(IPoolManager(address(pm)), hook, ETH)));
        StonkzLadderAuction a = ladder.file(_ladderParams(ETH));
        assertEq(a.refPriceWad(), 2.5e11); // pair-wei per side-token, WAD
        assertTrue(a.createSidePool());
    }

    // ─── stamp survives factory ref change ─────────────────────────────────

    function test_ref_express_stampSurvivesRefChange() public {
        StonkzDirectListing first = expressEth.list(_params(), bytes32(uint256(10)));
        assertEq(first.refPriceWad(), 2.5e11);

        expressEth.setRefPrice(STONKZ, ETH, 5e11); // still mid-ish; pair-wei per side-token, WAD
        StonkzDirectListing second = expressEth.list(_params(), bytes32(uint256(11)));
        assertEq(second.refPriceWad(), 5e11);
        assertEq(first.refPriceWad(), 2.5e11); // stamp immutable
    }

    function test_ref_ladder_stampSurvivesRefChange() public {
        ladder.setSettlementRef(address(new LadderSettlement(IPoolManager(address(pm)), hook, ETH)));
        StonkzLadderAuction first = ladder.file(_ladderParams(ETH));
        assertEq(first.refPriceWad(), 2.5e11);

        ladder.setRefPrice(STONKZ, ETH, 5e11);
        ladder.setSettlementRef(address(new LadderSettlement(IPoolManager(address(pm)), hook, ETH)));
        StonkzLadderAuction second = ladder.file(_ladderParams(ETH));
        assertEq(second.refPriceWad(), 5e11);
        assertEq(first.refPriceWad(), 2.5e11);
    }

    // ─── RefPriceUnset / bounds ────────────────────────────────────────────

    function test_ref_unset_revertsWhenCreateSidePool() public {
        address unknown = address(0xBEEF);
        StonkzLadderAuction.Params memory p = _ladderParams(unknown);
        vm.expectRevert(abi.encodeWithSelector(DeployControls.RefPriceUnset.selector, STONKZ, unknown));
        ladder.file(p);
    }

    function test_ref_unset_okWhenCreateSidePoolFalse() public {
        address unknown = address(0xBEEF);
        ladder.setDefaultCreateSidePool(false);
        StonkzLadderAuction a = ladder.file(_ladderParams(unknown));
        assertFalse(a.createSidePool());
        assertEq(a.refPriceWad(), 0);
    }

    function test_ref_bounds_eth() public {
        vm.expectRevert(abi.encodeWithSelector(DeployControls.RefPriceOutOfBounds.selector, ETH, uint256(1e7)));
        expressEth.setRefPrice(STONKZ, ETH, 1e7);
        vm.expectRevert(abi.encodeWithSelector(DeployControls.RefPriceOutOfBounds.selector, ETH, uint256(1e18)));
        expressEth.setRefPrice(STONKZ, ETH, 1e18);
        expressEth.setRefPrice(STONKZ, ETH, 1e8);
        expressEth.setRefPrice(STONKZ, ETH, 1e17);
    }

    function test_ref_bounds_usdg() public {
        vm.expectRevert(abi.encodeWithSelector(DeployControls.RefPriceOutOfBounds.selector, USDG, uint256(1e11)));
        expressUsdg.setRefPrice(STONKZ, USDG, 1e11);
        expressUsdg.setRefPrice(STONKZ, USDG, 1e12);
        expressUsdg.setRefPrice(STONKZ, USDG, 1e21);
    }

    function test_ref_event_loud() public {
        vm.expectEmit(true, true, false, true);
        emit DeployControls.RefPriceChanged(STONKZ, ETH, 3e11);
        expressEth.setRefPrice(STONKZ, ETH, 3e11);
    }

    // ─── helpers ───────────────────────────────────────────────────────────

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
            refPriceWad: 0 // factory overwrites
        });
    }

    function _ladderParams(address pair) internal returns (StonkzLadderAuction.Params memory p) {
        LadderSettlement settlement = new LadderSettlement(IPoolManager(address(pm)), hook, pair);
        ladder.setSettlementRef(address(settlement));
        p = StonkzLadderAuction.Params({
            supply: SUPPLY,
            auctionSupply: SUPPLY,
            floorMcap: 10_000 ether,
            duration: LadderConstants.GOD_DURATION,
            lpShareWad: 0.9e18,
            lpHealthTargetWad: 0.25e18,
            carveBps: type(uint16).max,
            cashHoldbackBps: 0,
            holdbackBps: 0,
            holdbackDelivery: LadderConstants.HoldbackDelivery.None,
            tier: LadderTypes.Tier.God,
            createSidePool: true,
            sidePoolBps: 500,
            refPriceWad: 0, // factory overwrites / unset path
            walletCapBps: 500,
            sizeBonusBps: 1000,
            maxUniqueActives: 64,
            pairToken: pair,
            creator: CREATOR,
            treasury: TREASURY,
            vaultRef: address(0),
            settlement: address(0) // stamped from factory.settlementRef
        });
    }
}
