// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vanity} from "../src/Vanity.sol";
import {VanityHelpers} from "./VanityHelpers.sol";
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

/// @title VanityPhase1 — 0x4663 CREATE2 vanity (docs/03; docs/04)
contract VanityPhase1 is Test {
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
    address internal constant FRIEND = address(0xA11CE);

    uint256 internal constant SUPPLY = 1_000_000 ether;

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

    function test_P1_minedSalt_deploysAtPredicted_0x4663() public {
        StonkzDirectListing.ListingParams memory p = _params();
        (bytes32 userSalt, address predicted) = VanityHelpers.mineExpress(express, address(this), p);
        assertTrue(Vanity.matches(predicted), "prefix");
        assertEq(Vanity.prefixOf(predicted), Vanity.PREFIX);

        StonkzDirectListing listing = express.list(p, userSalt);
        assertEq(address(listing), predicted, "deployed == predicted");
        assertTrue(Vanity.matches(address(listing)));
    }

    function test_P1_wrongSalt_reverts_VanityPrefixMismatch() public {
        StonkzDirectListing.ListingParams memory p = _params();
        // Mine a good salt then flip a bit so prefix fails (or use salt 0 if unlucky match — loop).
        bytes32 bad;
        address predicted;
        for (uint256 i; i < 1000; ++i) {
            bad = bytes32(i);
            predicted = express.predictListingAddress(address(this), bad, express.listingInitCodeHash(p));
            if (!Vanity.matches(predicted)) break;
        }
        assertFalse(Vanity.matches(predicted), "need non-vanity salt");

        vm.expectRevert(abi.encodeWithSelector(Vanity.VanityPrefixMismatch.selector, predicted));
        express.list(p, bad);
    }

    function test_P1_sameUserSalt_twoDeployers_differentAddresses() public {
        express.allowDeployer(FRIEND);
        StonkzDirectListing.ListingParams memory p = _params();

        // Mine for this (test contract as deployer).
        (bytes32 userSalt, address predThis) = VanityHelpers.mineExpress(express, address(this), p);
        StonkzDirectListing a = express.list(p, userSalt);
        assertEq(address(a), predThis);

        // Same userSalt from FRIEND → different CREATE2 address (deployer binding).
        // That address may or may not be vanity — if not, FRIEND must mine their own.
        (bytes32 friendSalt, address predFriend) = VanityHelpers.mineExpress(express, FRIEND, p);
        // Prove binding: same userSalt yields different effective salts / addresses.
        assertTrue(express.listingSalt(address(this), userSalt) != express.listingSalt(FRIEND, userSalt));

        vm.prank(FRIEND);
        StonkzDirectListing b = express.list(p, friendSalt);
        assertEq(address(b), predFriend);
        assertTrue(address(a) != address(b));
        // Same userSalt across deployers cannot both be the mined vanity for each other.
        address cross = express.predictListingAddress(FRIEND, userSalt, express.listingInitCodeHash(p));
        assertTrue(cross != address(a));
    }

    function test_P1_ladder_minedSalt_deploysAtPredicted() public {
        StonkzLadderAuction.Params memory p = _ladderParams();
        (bytes32 userSalt, address predicted) = VanityHelpers.mineLadder(ladder, address(this), p);
        assertTrue(Vanity.matches(predicted));

        StonkzLadderAuction auction = ladder.file(p, userSalt);
        assertEq(address(auction), predicted);
        assertTrue(Vanity.matches(address(auction)));
    }

    function test_P1_ladder_wrongSalt_reverts() public {
        StonkzLadderAuction.Params memory p = _ladderParams();
        bytes32 bad;
        address predicted;
        for (uint256 i; i < 1000; ++i) {
            bad = bytes32(i);
            predicted = ladder.predictAuctionAddress(address(this), bad, ladder.auctionInitCodeHash(p));
            if (!Vanity.matches(predicted)) break;
        }
        vm.expectRevert(abi.encodeWithSelector(Vanity.VanityPrefixMismatch.selector, predicted));
        ladder.file(p, bad);
    }

    function _params() internal pure returns (StonkzDirectListing.ListingParams memory p) {
        p.startMcap = 4000e18;
        p.totalSupply = SUPPLY;
        p.creatorReserveBps = 0;
        p.deliveryMode = 0;
        p.vestDuration = 0;
        p.declaredUse = bytes32(0);
        p.creator = CREATOR;
        p.createSidePool = true;
        p.sidePoolBps = 500;
        p.liquidityLocked = true;
        p.refPriceWad = 2.5e11;
    }

    function _ladderParams() internal pure returns (StonkzLadderAuction.Params memory p) {
        p.supply = SUPPLY;
        p.auctionSupply = (SUPPLY * 60) / 100;
        p.floorMcap = 40_000e18;
        p.duration = 1 days;
        p.lpShareWad = 0.95e18;
        p.lpHealthTargetWad = 0.5e18;
        p.carveBps = type(uint16).max;
        p.cashHoldbackBps = 0;
        p.holdbackBps = 0;
        p.holdbackDelivery = LadderConstants.HoldbackDelivery.None;
        p.tier = LadderTypes.Tier.God;
        p.createSidePool = true;
        p.sidePoolBps = 500;
        p.refPriceWad = 2.5e11;
        p.walletCapBps = 100;
        p.sizeBonusBps = 1000;
        p.maxUniqueActives = 0;
        p.pairToken = PAIR;
        p.creator = CREATOR;
        p.treasury = TREASURY;
        p.vaultRef = address(0);
        p.settlement = address(0);
    }
}
