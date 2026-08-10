// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FactoryVanity} from "./FactoryVanity.sol";
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
import {StonkzLaunchToken} from "../src/StonkzLaunchToken.sol";
import {TickMath} from "../src/v4/TickMath.sol";

/// @title SidePoolRefPrice — stamped pair-wei/STONKZ ref (ruling B) + known-value init
contract SidePoolRefPrice is Test, FactoryVanity {
    MockPoolManager internal pm;
    BuybackAccumulator internal acc;
    StonkzFeeHook internal hook;
    FeeLockerV2 internal locker;
    CTOGovernor internal gov;
    StonkzExpressFactory internal expressEth;
    StonkzExpressFactory internal expressUsdg;
    StonkzLadderFactory internal ladder;

    address internal constant ETH = address(0);
    address internal constant USDG = address(0x55534447); // stand-in USDG; pair-wei per STONKZ uses USDG bounds
    address internal constant TREASURY = address(0x7A5E);
    address internal constant CREATOR = address(0xCEEE);
    address internal constant STONKZ = address(0x4663);

    uint256 internal constant SUPPLY = 1_000_000 ether;
    uint256 internal constant TIER_4K = 4000e18;
    uint256 internal constant WAD = 1e18;

    function setUp() public {
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
        // Ladder birth has ETH; seed USDG for ladder USDG filings.
        ladder.setStonkzRefPrice(USDG, ladder.REF_PRICE_USDG_DEFAULT());
    }

    // ─── units / birth defaults ────────────────────────────────────────────

    function test_ref_units_ethDefault_pairWeiPerStonkz() public view {
        // Unit: pair-wei per STONKZ token, WAD
        assertEq(expressEth.REF_PRICE_ETH_DEFAULT(), 2.5e11);
        assertEq(expressEth.stonkzRefPriceWad(ETH), 2.5e11);
        assertTrue(expressEth.stonkzRefPriceConfigured(ETH));
        assertEq(expressEth.REF_PRICE_ETH_MIN(), 1e8);
        assertEq(expressEth.REF_PRICE_ETH_MAX(), 1e17);
    }

    function test_ref_units_usdgDefault_pairWeiPerStonkz() public view {
        // Unit: pair-wei per STONKZ token, WAD
        assertEq(expressUsdg.REF_PRICE_USDG_DEFAULT(), 1e15);
        assertEq(expressUsdg.stonkzRefPriceWad(USDG), 1e15);
        assertTrue(expressUsdg.stonkzRefPriceConfigured(USDG));
        assertEq(expressUsdg.REF_PRICE_USDG_MIN(), 1e12);
        assertEq(expressUsdg.REF_PRICE_USDG_MAX(), 1e21);
    }

    // ─── known-value arithmetic (Express) ──────────────────────────────────

    function test_ref_express_eth_initTick_knownValue() public {
        // startPriceWad = 4000e18 * WAD / 1e24 = 4e15 pair-wei/token
        // priceInStonkz = 4e15 * WAD / 2.5e11 = 1.6e22 STONKZ/token
        StonkzDirectListing l = _list(expressEth, _params());
        assertEq(l.stonkzRefPriceWad(), 2.5e11);
        assertEq(l.startPriceWad(), 4e15);

        uint256 priceInStonkz = FixedPointMathLib.mulDiv(l.startPriceWad(), WAD, l.stonkzRefPriceWad());
        assertEq(priceInStonkz, 1.6e22);

        int24 expectedBottom = TickMath.tickAbovePrice(priceInStonkz, 60);
        assertEq(l.sideTickLower(), expectedBottom);
        assertTrue(l.sidePoolDeployed());
    }

    function test_ref_express_usdg_initTick_knownValue() public {
        // priceInStonkz = 4e15 * WAD / 1e15 = 4e18 STONKZ/token
        StonkzDirectListing l = _list(expressUsdg, _params());
        assertEq(l.stonkzRefPriceWad(), 1e15);
        uint256 priceInStonkz = FixedPointMathLib.mulDiv(l.startPriceWad(), WAD, l.stonkzRefPriceWad());
        assertEq(priceInStonkz, 4e18);
        assertEq(l.sideTickLower(), TickMath.tickAbovePrice(priceInStonkz, 60));
    }

    // ─── known-value arithmetic (Ladder settlement) ────────────────────────

    function test_ref_ladder_eth_sideInit_convertsPrintP() public {
        LadderSettlement s = new LadderSettlement(IPoolManager(address(pm)), hook, ETH);
        s.setStonkzRef(STONKZ);
        vm.deal(address(this), 100 ether);

        uint256 supply = 1_000_000 ether;
        uint256 auctionSupply = 1_000_000 ether;
        uint256 sold = 100_000 ether;
        uint256 printP = 4e15; // pair-wei per token, WAD
        uint256 ref = 2.5e11; // pair-wei per STONKZ token, WAD
        address tok = address(new StonkzLaunchToken("T", "T", supply, address(this)));

        s.settle{value: 10 ether}(
            LadderSettlement.SettleArgs({
                graduated: true,
                raised: 10 ether,
                supply: supply,
                auctionSupply: auctionSupply,
                soldTokens: sold,
                printPrice: printP,
                floorPrice: printP / 10,
                carveBps: 400,
                cashHoldbackBps: 0,
                holdbackBps: 0,
                createSidePool: true,
                sidePoolBps: 500,
                stonkzRefPriceWad: ref,
                liquidityLocked: true,
                unlockRecipient: CREATOR,
                vaultRef: address(0),
                creator: CREATOR,
                treasury: TREASURY,
                userToken: tok
            })
        );
        assertEq(s.stonkzRefPriceWad(), ref);
        uint256 priceInStonkz = FixedPointMathLib.fullMulDiv(printP, WAD, ref);
        assertEq(priceInStonkz, 1.6e22);
        assertGt(s.sideLiquidity(), 0);
        int24 rem = s.sideTickLower() % 60;
        if (rem < 0) rem += 60;
        assertEq(rem, 0);
    }

    // ─── stamp survives default change ─────────────────────────────────────

    function test_ref_express_stampSurvivesDefaultChange() public {
        StonkzDirectListing first = _list(expressEth, _params());
        assertEq(first.stonkzRefPriceWad(), 2.5e11);

        expressEth.setStonkzRefPrice(ETH, 5e11); // still mid-ish; pair-wei per STONKZ token, WAD
        StonkzDirectListing second = _list(expressEth, _params());
        assertEq(second.stonkzRefPriceWad(), 5e11);
        assertEq(first.stonkzRefPriceWad(), 2.5e11); // stamp immutable
    }

    function test_ref_ladder_stampSurvivesDefaultChange() public {
        StonkzLadderAuction first = _file(ladder, _ladderParams(ETH));
        assertEq(first.stonkzRefPriceWad(), 2.5e11);

        ladder.setStonkzRefPrice(ETH, 5e11);
        StonkzLadderAuction second = _file(ladder, _ladderParams(ETH));
        assertEq(second.stonkzRefPriceWad(), 5e11);
        assertEq(first.stonkzRefPriceWad(), 2.5e11);
    }

    // ─── RefPriceUnset / bounds ────────────────────────────────────────────

    function test_ref_unset_revertsWhenCreateSidePool() public {
        address unknown = address(0xBEEF);
        StonkzLadderAuction.Params memory p = _ladderParams(unknown);
        vm.expectRevert(abi.encodeWithSelector(DeployControls.RefPriceUnset.selector, unknown));
        ladder.file(p, bytes32(0));
    }

    function test_ref_unset_okWhenCreateSidePoolFalse() public {
        address unknown = address(0xBEEF);
        ladder.setDefaultCreateSidePool(false);
        StonkzLadderAuction a = _file(ladder, _ladderParams(unknown));
        assertFalse(a.createSidePool());
        assertEq(a.stonkzRefPriceWad(), 0);
    }

    function test_ref_bounds_eth() public {
        vm.expectRevert(abi.encodeWithSelector(DeployControls.RefPriceOutOfBounds.selector, ETH, uint256(1e7)));
        expressEth.setStonkzRefPrice(ETH, 1e7);
        vm.expectRevert(abi.encodeWithSelector(DeployControls.RefPriceOutOfBounds.selector, ETH, uint256(1e18)));
        expressEth.setStonkzRefPrice(ETH, 1e18);
        expressEth.setStonkzRefPrice(ETH, 1e8);
        expressEth.setStonkzRefPrice(ETH, 1e17);
    }

    function test_ref_bounds_usdg() public {
        vm.expectRevert(abi.encodeWithSelector(DeployControls.RefPriceOutOfBounds.selector, USDG, uint256(1e11)));
        expressUsdg.setStonkzRefPrice(USDG, 1e11);
        expressUsdg.setStonkzRefPrice(USDG, 1e12);
        expressUsdg.setStonkzRefPrice(USDG, 1e21);
    }

    function test_ref_event_loud() public {
        vm.expectEmit(true, false, false, true);
        emit DeployControls.RefPriceChanged(ETH, 3e11);
        expressEth.setStonkzRefPrice(ETH, 3e11);
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
            stonkzRefPriceWad: 0 // factory overwrites
        });
    }

    function _ladderParams(address pair) internal returns (StonkzLadderAuction.Params memory p) {
        LadderSettlement settlement = new LadderSettlement(IPoolManager(address(pm)), hook, pair);
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
            stonkzRefPriceWad: 0, // factory overwrites / unset path
            walletCapBps: 500,
            sizeBonusBps: 1000,
            maxUniqueActives: 64,
            pairToken: pair,
            creator: CREATOR,
            treasury: TREASURY,
            vaultRef: address(0),
            settlement: address(settlement)
        });
    }
}
