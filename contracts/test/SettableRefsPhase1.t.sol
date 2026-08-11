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
import {StonkzLaunchToken} from "../src/StonkzLaunchToken.sol";

/// @title SettableRefsPhase1 — stamp isolation + genesis-day sideTokenRef swap (PREDEPLOY-REFIT)
contract SettableRefsPhase1 is Test {

    MockPoolManager internal pm;
    BuybackAccumulator internal acc;
    StonkzFeeHook internal hook;
    FeeLockerV2 internal locker;
    CTOGovernor internal gov;
    StonkzExpressFactory internal express;
    StonkzLadderFactory internal ladder;

    address internal constant ETH = address(0);
    address internal constant TREASURY = address(0x7A5E);
    address internal constant CREATOR = address(0xCEEE);
    address internal constant STAND_IN = address(0x4663);

    StonkzLaunchToken internal genesisToken;

    uint256 internal constant SUPPLY = 1_000_000 ether;
    uint256 internal constant TIER_4K = 4000e18;

    function setUp() public {
        vm.etch(STAND_IN, hex"00");
        pm = new MockPoolManager();
        acc = new BuybackAccumulator(ETH, STAND_IN, address(0));
        gov = new CTOGovernor();
        hook = new StonkzFeeHook(IPoolManager(address(pm)), TREASURY, ICTOGovernor(address(gov)));
        gov.setRegistry(hook);
        locker = new FeeLockerV2(IPoolManager(address(pm)), hook);
        express = new StonkzExpressFactory(
            IPoolManager(address(pm)), locker, hook, acc, gov, ETH, STAND_IN
        );
        ladder = new StonkzLadderFactory();
        ladder.setSideTokenRef(STAND_IN);
        genesisToken = new StonkzLaunchToken("GENESIS", "GEN", 1, address(this));
    }

    function test_P1_express_refChange_neverAffectsPriorLaunch() public {
        StonkzDirectListing prior = express.list(_params(), bytes32(uint256(1)));
        address stampedSide = prior.sideTokenRef();
        address stampedHook = address(prior.hook());
        address stampedLocker = address(prior.feeLocker());
        uint256 stampedRef = prior.refPriceWad();
        address stampedToken = address(prior.token());

        // Retarget every settable factory ref + prices.
        FeeLockerV2 locker2 = new FeeLockerV2(IPoolManager(address(pm)), hook);
        BuybackAccumulator acc2 = new BuybackAccumulator(ETH, address(genesisToken), address(0));
        express.setFeeLocker(address(locker2));
        express.setAccumulator(address(acc2));
        express.setSideTokenRef(address(genesisToken));
        express.setRefPrice(address(genesisToken), ETH, 5e11);

        StonkzDirectListing next = express.list(_params(), bytes32(uint256(2)));
        assertEq(next.sideTokenRef(), address(genesisToken));
        assertEq(address(next.feeLocker()), address(locker2));
        assertEq(next.refPriceWad(), 5e11);

        // Prior launch immutable stamps untouched.
        assertEq(prior.sideTokenRef(), stampedSide);
        assertEq(address(prior.hook()), stampedHook);
        assertEq(address(prior.feeLocker()), stampedLocker);
        assertEq(prior.refPriceWad(), stampedRef);
        assertEq(address(prior.token()), stampedToken);
    }

    function test_P1_express_settableRefs_rejectEOA() public {
        vm.expectRevert(StonkzExpressFactory.FeeLockerNotContract.selector);
        express.setFeeLocker(address(0xBEEF));
        vm.expectRevert(StonkzExpressFactory.SideTokenRefNotContract.selector);
        express.setSideTokenRef(address(0xBEEF));
        vm.expectRevert(StonkzExpressFactory.HookNotContract.selector);
        express.setHook(address(0xBEEF));
    }

    function test_P1_genesisDay_sideTokenSwap_nextPairsNew_priorUnchanged() public {
        StonkzDirectListing prior = express.list(_params(), bytes32(uint256(10)));
        assertEq(prior.sideTokenRef(), STAND_IN);
        assertTrue(prior.sidePoolDeployed());
        address priorLaunchToken = address(prior.token());

        // Genesis day: point factory at real side token + set its prices.
        express.setSideTokenRef(address(genesisToken));
        express.setRefPrice(address(genesisToken), ETH, express.REF_PRICE_ETH_DEFAULT());

        StonkzDirectListing next = express.list(_params(), bytes32(uint256(11)));
        assertEq(next.sideTokenRef(), address(genesisToken));
        assertTrue(next.sidePoolDeployed());
        assertTrue(address(next.token()) != priorLaunchToken);

        // Prior pools unchanged.
        assertEq(prior.sideTokenRef(), STAND_IN);
        assertEq(address(prior.token()), priorLaunchToken);
        assertTrue(prior.sidePoolDeployed());
    }

    function test_P1_ladder_settlementRef_and_sideToken_stampIsolation() public {
        LadderSettlement s1 = new LadderSettlement(IPoolManager(address(pm)), hook, ETH);
        s1.setSideTokenRef(STAND_IN);
        ladder.setSettlementRef(address(s1));
        StonkzLadderAuction prior = ladder.file(_ladderParams());
        assertEq(address(prior.settlement()), address(s1));
        assertEq(prior.refPriceWad(), 2.5e11);

        LadderSettlement s2 = new LadderSettlement(IPoolManager(address(pm)), hook, ETH);
        s2.setSideTokenRef(address(genesisToken));
        ladder.setSettlementRef(address(s2));
        ladder.setSideTokenRef(address(genesisToken));
        ladder.setRefPrice(address(genesisToken), ETH, 5e11);

        StonkzLadderAuction next = ladder.file(_ladderParams());
        assertEq(address(next.settlement()), address(s2));
        assertEq(next.refPriceWad(), 5e11);

        // Prior auction still wired to s1 + old ref stamp.
        assertEq(address(prior.settlement()), address(s1));
        assertEq(prior.refPriceWad(), 2.5e11);
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

    function _ladderParams() internal pure returns (StonkzLadderAuction.Params memory p) {
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
            refPriceWad: 0,
            walletCapBps: 500,
            sizeBonusBps: 1000,
            maxUniqueActives: 64,
            pairToken: ETH,
            creator: CREATOR,
            treasury: TREASURY,
            vaultRef: address(0),
            settlement: address(0)
        });
    }
}
