// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
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

/// @title SidePoolSwitchesPhase2 — createSidePool + sidePoolBps stamps (docs/03 switches 2–3)
contract SidePoolSwitchesPhase2 is Test {
    MockPoolManager internal pm;
    BuybackAccumulator internal acc;
    StonkzFeeHook internal hook;
    FeeLockerV2 internal locker;
    CTOGovernor internal gov;
    StonkzExpressFactory internal express;
    StonkzLadderFactory internal ladder;

    address internal constant PAIR = address(0);
    address internal constant TREASURY = address(0x7A5E);
    address internal constant CREATOR = address(0xCEEE);
    address internal constant STONKZ = address(0x4663);

    uint256 internal constant SUPPLY = 1_000_000 ether;
    uint256 internal constant TIER_4K = 4000e18;

    function setUp() public {
        vm.etch(STONKZ, hex"00");
        pm = new MockPoolManager();
        acc = new BuybackAccumulator(PAIR, STONKZ, address(0));
        gov = new CTOGovernor();
        hook = new StonkzFeeHook(IPoolManager(address(pm)), TREASURY, ICTOGovernor(address(gov)));
        gov.setRegistry(hook);
        locker = new FeeLockerV2(IPoolManager(address(pm)), hook);
        express = new StonkzExpressFactory(
            IPoolManager(address(pm)), locker, hook, acc, gov, PAIR, STONKZ
        );
        ladder = new StonkzLadderFactory();
        ladder.setSideTokenRef(STONKZ);
    }

    // ─── units / bounds ────────────────────────────────────────────────────

    function test_P2_units_sidePoolBps_default500_ofListingSupply() public view {
        uint256 listingSupply = 1_000_000 ether;
        uint256 side = (listingSupply * uint256(express.DEFAULT_SIDE_POOL_BPS())) / 10_000;
        assertEq(side, 50_000 ether);
        assertEq(express.DEFAULT_SIDE_POOL_BPS(), 500);
        assertEq(express.SIDE_POOL_BPS_MAX(), 2000);
        assertEq(express.defaultSidePoolBps(), 500);
        assertEq(uint256(LadderConstants.SIDE_POOL_BPS), 500);
    }

    function test_P2_bounds_rejectAbove2000() public {
        vm.expectRevert(abi.encodeWithSelector(DeployControls.SidePoolBpsOutOfBounds.selector, uint16(2001)));
        express.setDefaultSidePoolBps(2001);

        StonkzDirectListing.ListingParams memory p = _baseParams();
        p.sidePoolBps = 2001;
        vm.expectRevert(abi.encodeWithSelector(StonkzDirectListing.SidePoolBpsOutOfBounds.selector, uint16(2001)));
        new StonkzDirectListing(IPoolManager(address(pm)), locker, hook, acc, gov, PAIR, STONKZ, p);
    }

    function test_P2_bounds_accept0_and_2000() public {
        express.setDefaultSidePoolBps(0);
        assertEq(express.defaultSidePoolBps(), 0);
        express.setDefaultSidePoolBps(2000);
        assertEq(express.defaultSidePoolBps(), 2000);
    }

    // ─── Express stamps ────────────────────────────────────────────────────

    function test_P2_express_stampsFactoryDefaults() public {
        StonkzDirectListing l = express.list(_baseParams(), bytes32(uint256(1)));
        assertTrue(l.createSidePool());
        assertEq(l.sidePoolBps(), 500);
        assertTrue(l.sidePoolDeployed());
        (uint256 listed, uint256 side,) = l.conservationBuckets();
        assertEq(side, (SUPPLY * 500) / 10_000);
        assertEq(listed + side, SUPPLY);
    }

    function test_P2_express_genesis_createSidePoolFalse_allMassToMain() public {
        // Genesis case: no side pool, mass on main, no park.
        express.setDefaultCreateSidePool(false);
        StonkzDirectListing l = express.list(_baseParams(), bytes32(uint256(2)));
        assertFalse(l.createSidePool());
        assertEq(l.sidePoolBps(), 500); // stamp recorded even when unused
        assertEq(l.sidePoolTokens(), 0);
        assertFalse(l.sidePoolDeployed());
        (uint256 listed, uint256 side,) = l.conservationBuckets();
        assertEq(side, 0);
        assertEq(listed, SUPPLY);
        // createSidePool=false: no side deploy, no park (park RETIRED).
        assertFalse(l.sidePoolDeployed());
        assertEq(acc.pairBalance(), 0);

        vm.expectRevert(StonkzDirectListing.SidePoolDisabled.selector);
        l.deploySidePool();
    }

    function test_P2_express_stampSurvivesDefaultChange() public {
        StonkzDirectListing first = express.list(_baseParams(), bytes32(uint256(3)));
        assertTrue(first.createSidePool());
        assertEq(first.sidePoolBps(), 500);

        express.setDefaultCreateSidePool(false);
        express.setDefaultSidePoolBps(1000);

        StonkzDirectListing second = express.list(_baseParams(), bytes32(uint256(4)));
        assertFalse(second.createSidePool());
        assertEq(second.sidePoolBps(), 1000);

        // First token unchanged.
        assertTrue(first.createSidePool());
        assertEq(first.sidePoolBps(), 500);
    }

    function test_P2_express_customRatio1000() public {
        express.setDefaultSidePoolBps(1000); // 10%
        StonkzDirectListing l = express.list(_baseParams(), bytes32(uint256(5)));
        assertEq(l.sidePoolBps(), 1000);
        (, uint256 side,) = l.conservationBuckets();
        assertEq(side, (SUPPLY * 1000) / 10_000);
    }

    // ─── Ladder stamps + settlement absence ────────────────────────────────

    function test_P2_ladder_factoryStampsDefaults() public {
        StonkzLadderAuction a = ladder.file(_ladderParams(true, 500));
        assertTrue(a.createSidePool());
        assertEq(a.sidePoolBps(), 500);
    }

    function test_P2_ladder_stampSurvivesDefaultChange() public {
        StonkzLadderAuction first = ladder.file(_ladderParams(true, 999)); // overwritten by factory
        assertTrue(first.createSidePool());
        assertEq(first.sidePoolBps(), 500);

        ladder.setDefaultCreateSidePool(false);
        ladder.setDefaultSidePoolBps(750);
        StonkzLadderAuction second = ladder.file(_ladderParams(true, 999));
        assertFalse(second.createSidePool());
        assertEq(second.sidePoolBps(), 750);

        assertTrue(first.createSidePool());
        assertEq(first.sidePoolBps(), 500);
    }

    function test_P2_ladder_settlement_createSidePoolFalse_allMassToMain() public {
        LadderSettlement s = new LadderSettlement(IPoolManager(address(pm)), hook, PAIR);
        s.setSideTokenRef(STONKZ);
        vm.deal(address(this), 100 ether);

        // Large unsold so MIN_ASK is satisfied with sideAmt=0 (all to main).
        uint256 supply = 1_000_000 ether;
        uint256 auctionSupply = 1_000_000 ether;
        uint256 sold = 100_000 ether; // unsold 900k → main ask 900k >> 5% min
        s.settle{value: 10 ether}(
            LadderSettlement.SettleArgs({
                graduated: true,
                raised: 10 ether,
                supply: supply,
                auctionSupply: auctionSupply,
                soldTokens: sold,
                printPrice: 1 ether,
                floorPrice: 0.1 ether,
                carveBps: 400,
                cashHoldbackBps: 0,
                holdbackBps: 0,
                createSidePool: false,
                sidePoolBps: 500, // stamped but unused
                refPriceWad: 0,
                liquidityLocked: true,
                unlockRecipient: CREATOR,
                vaultRef: address(0),
                creator: CREATOR,
                treasury: TREASURY,
                userToken: address(new StonkzLaunchToken("T", "T", supply, address(this)))
            })
        );
        assertEq(s.sidePoolTokens(), 0);
        assertEq(s.mainAskTokens(), auctionSupply - sold);
    }

    function test_P2_ladder_settlement_createSidePoolTrue_usesBps() public {
        LadderSettlement s = new LadderSettlement(IPoolManager(address(pm)), hook, PAIR);
        s.setSideTokenRef(STONKZ);
        vm.deal(address(this), 100 ether);

        uint256 supply = 1_000_000 ether;
        uint256 auctionSupply = 1_000_000 ether;
        uint256 sold = 100_000 ether;
        uint256 unsold = auctionSupply - sold;
        address tok = address(new StonkzLaunchToken("T2", "T2", supply, address(this)));
        StonkzLaunchToken(tok).transfer(address(s), unsold); // settlement needs tokens for pools — mock may not pull
        // Mock modifyLiquidity does not pull ERC20; settle only needs userToken address for keys.

        s.settle{value: 10 ether}(
            LadderSettlement.SettleArgs({
                graduated: true,
                raised: 10 ether,
                supply: supply,
                auctionSupply: auctionSupply,
                soldTokens: sold,
                printPrice: 1 ether,
                floorPrice: 0.1 ether,
                carveBps: 400,
                cashHoldbackBps: 0,
                holdbackBps: 0,
                createSidePool: true,
                sidePoolBps: 500,
                refPriceWad: 2.5e11, // pair-wei per STONKZ token, WAD
                liquidityLocked: true,
                unlockRecipient: CREATOR,
                vaultRef: address(0),
                creator: CREATOR,
                treasury: TREASURY,
                userToken: tok
            })
        );
        assertEq(s.sidePoolTokens(), (unsold * 500) / 10_000);
        assertEq(s.mainAskTokens(), unsold - s.sidePoolTokens());
    }

    function test_P2_events_loudOnDefaultChange() public {
        vm.expectEmit(false, false, false, true);
        emit DeployControls.DefaultCreateSidePoolSet(false);
        express.setDefaultCreateSidePool(false);

        vm.expectEmit(false, false, false, true);
        emit DeployControls.DefaultSidePoolBpsSet(1200);
        express.setDefaultSidePoolBps(1200);
    }

    // ─── helpers ───────────────────────────────────────────────────────────

    function _baseParams() internal pure returns (StonkzDirectListing.ListingParams memory p) {
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
            createSidePool: true, // overwritten by factory stamp
            sidePoolBps: 500,
            liquidityLocked: true,
            refPriceWad: 2.5e11 // pair-wei per STONKZ token, WAD
        });
    }

    function _ladderParams(bool createSide, uint16 sideBps)
        internal
        returns (StonkzLadderAuction.Params memory p)
    {
        LadderSettlement settlement = new LadderSettlement(IPoolManager(address(pm)), hook, PAIR);
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
            createSidePool: createSide, // overwritten by factory
            sidePoolBps: sideBps, // overwritten by factory
            refPriceWad: 2.5e11, // pair-wei per STONKZ token, WAD; overwritten by factory
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
