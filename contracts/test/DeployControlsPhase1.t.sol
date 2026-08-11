// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FactoryVanity} from "./FactoryVanity.sol";
import {VanityHelpers} from "./VanityHelpers.sol";
import {Vanity} from "../src/Vanity.sol";
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

/// @title DeployControlsPhase1 — deploysEnabled + allowlist on Express AND Ladder
/// @notice Semantics (docs/stop-task-switches-plan §3.2):
///         off → all blocked; on+empty → open; on+nonempty → allowlisted only.
///         RIDER A: birth = on + deployer-only allowlist.
contract DeployControlsPhase1 is Test, FactoryVanity {
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
    address internal constant STRANGER = address(0xB0B);
    address internal constant FRIEND = address(0xA11CE);

    uint256 internal constant SUPPLY = 1_000_000 ether;
    uint256 internal constant TIER_4K = 4000e18;

    function setUp() public {
        vm.etch(address(0x4663), hex"00");
        pm = new MockPoolManager();
        acc = new BuybackAccumulator(PAIR, address(0x4663), address(0));
        gov = new CTOGovernor();
        hook = new StonkzFeeHook(IPoolManager(address(pm)), TREASURY, ICTOGovernor(address(gov)));
        gov.setRegistry(hook);
        locker = new FeeLockerV2(IPoolManager(address(pm)), hook);

        express = new StonkzExpressFactory(
            IPoolManager(address(pm)), locker, hook, acc, gov, PAIR, address(0)
        );
        // Gate drills do not need side pools; loud-unset would mask DeployControls reverts.
        express.setDefaultCreateSidePool(false);
        ladder = new StonkzLadderFactory();
        ladder.setDefaultCreateSidePool(false);
    }

    // ─── RIDER A birth ─────────────────────────────────────────────────────

    function test_P1_birth_softLaunchGateClosed_express() public view {
        assertTrue(express.deploysEnabled());
        assertEq(express.allowlistCount(), 1);
        assertTrue(express.isDeployerAllowed(address(this)));
        express.assertSoftLaunchGate(address(this));
    }

    function test_P1_birth_softLaunchGateClosed_ladder() public view {
        assertTrue(ladder.deploysEnabled());
        assertEq(ladder.allowlistCount(), 1);
        assertTrue(ladder.isDeployerAllowed(address(this)));
        ladder.assertSoftLaunchGate(address(this));
    }

    function test_P1_assertSoftLaunchGate_revertsWhenOff() public {
        ladder.setDeploysEnabled(false);
        vm.expectRevert(DeployControls.DeploysOff.selector);
        ladder.assertSoftLaunchGate(address(this));
    }

    function test_P1_assertSoftLaunchGate_revertsWhenOpenEmpty() public {
        ladder.revokeDeployer(address(this));
        assertEq(ladder.allowlistCount(), 0);
        vm.expectRevert(DeployControls.DeployerNotAllowed.selector);
        ladder.assertSoftLaunchGate(address(this));
    }

    // ─── Express gate ──────────────────────────────────────────────────────

    function test_P1_express_deployerCanList_atBirth() public {
        StonkzDirectListing l = _list(express, _params());
        assertEq(l.creator(), CREATOR);
        assertEq(address(l.token()).code.length > 0, true);
    }

    function test_P1_express_strangerBlocked_atBirth() public {
        vm.prank(STRANGER);
        vm.expectRevert(DeployControls.DeployerNotAllowed.selector);
        express.list(_params(), bytes32(uint256(2)));
    }

    function test_P1_express_offBlocksEveryone() public {
        express.setDeploysEnabled(false);
        vm.expectRevert(DeployControls.DeploysOff.selector);
        express.list(_params(), bytes32(uint256(3)));
    }

    function test_P1_express_openWhenEmptyAndOn() public {
        express.revokeDeployer(address(this));
        assertEq(express.allowlistCount(), 0);
        assertTrue(express.deploysEnabled());

        StonkzDirectListing l  = _listAs(express, STRANGER, _params());        assertEq(l.creator(), CREATOR);
    }

    function test_P1_express_allowlistedOnly_whenNonempty() public {
        express.allowDeployer(FRIEND);
        // this (deployer) + FRIEND still allowlisted; stranger blocked
        vm.prank(STRANGER);
        vm.expectRevert(DeployControls.DeployerNotAllowed.selector);
        express.list(_params(), bytes32(uint256(5)));

        StonkzDirectListing l  = _listAs(express, FRIEND, _params());        assertEq(l.creator(), CREATOR);
    }

    function test_P1_express_revokeRemovesAccess() public {
        express.allowDeployer(FRIEND);
        express.revokeDeployer(FRIEND);
        vm.prank(FRIEND);
        vm.expectRevert(DeployControls.DeployerNotAllowed.selector);
        express.list(_params(), bytes32(uint256(7)));
    }

    function test_P1_express_events() public {
        vm.expectEmit(true, false, false, true);
        emit DeployControls.DeploysEnabled(false);
        express.setDeploysEnabled(false);

        express.setDeploysEnabled(true);
        vm.expectEmit(true, false, false, false);
        emit DeployControls.DeployerAllowed(FRIEND);
        express.allowDeployer(FRIEND);

        vm.expectEmit(true, false, false, false);
        emit DeployControls.DeployerRevoked(FRIEND);
        express.revokeDeployer(FRIEND);
    }

    // ─── CREATE2 readiness (RIDER C) ───────────────────────────────────────

    function test_P1_express_create2_predictMatchesDeploy() public {
        StonkzDirectListing.ListingParams memory p = _params();
        bytes32 initCodeHash = express.listingInitCodeHash(p);

        (bytes32 userSalt, address predicted) = VanityHelpers.mineExpress(express, address(this), p);
        assertEq(express.predictListingAddress(address(this), userSalt, initCodeHash), predicted);
        assertEq(express.listingSalt(address(this), userSalt), keccak256(abi.encode(address(this), userSalt)));

        StonkzDirectListing first = express.list(p, userSalt);
        assertEq(address(first), predicted, "CREATE2 predict == deploy");

        // Second vanity salt (skip the one already used by first deploy).
        bytes32 otherSalt;
        address otherPred;
        bool found;
        for (uint256 i = uint256(userSalt) + 1; i < uint256(userSalt) + 500_000; ++i) {
            otherSalt = bytes32(i);
            otherPred = express.predictListingAddress(address(this), otherSalt, initCodeHash);
            if (Vanity.matches(otherPred) && otherPred != predicted) {
                found = true;
                break;
            }
        }
        assertTrue(found, "second vanity salt");
        StonkzDirectListing second = express.list(p, otherSalt);
        assertEq(address(second), otherPred, "second CREATE2 predict == deploy");
        assertTrue(address(first) != address(second));
    }

    function test_P1_express_create2_saltBindsDeployer() public {
        bytes32 userSalt = bytes32(uint256(99));
        express.allowDeployer(FRIEND);
        express.revokeDeployer(address(this)); // nonempty: only FRIEND

        bytes32 saltThis = express.listingSalt(address(this), userSalt);
        bytes32 saltFriend = express.listingSalt(FRIEND, userSalt);
        assertTrue(saltThis != saltFriend, "same userSalt, different deployer => different salt");
    }

    // ─── Ladder gate ───────────────────────────────────────────────────────

    function test_P1_ladder_deployerCanFile_atBirth() public {
        StonkzLadderAuction a = _file(ladder, _ladderParams());
        assertEq(a.creator(), CREATOR);
    }

    function test_P1_ladder_strangerBlocked_atBirth() public {
        StonkzLadderAuction.Params memory p = _ladderParams();
        vm.prank(STRANGER);
        vm.expectRevert(DeployControls.DeployerNotAllowed.selector);
        ladder.file(p, bytes32(0));
    }

    function test_P1_ladder_offBlocksEveryone() public {
        StonkzLadderAuction.Params memory p = _ladderParams();
        ladder.setDeploysEnabled(false);
        vm.expectRevert(DeployControls.DeploysOff.selector);
        ladder.file(p, bytes32(0));
    }

    function test_P1_ladder_openWhenEmptyAndOn() public {
        StonkzLadderAuction.Params memory p = _ladderParams();
        ladder.revokeDeployer(address(this));
        StonkzLadderAuction a  = _fileAs(ladder, STRANGER, p);        assertEq(a.creator(), CREATOR);
    }

    function test_P1_ladder_allowlistedOnly_whenNonempty() public {
        StonkzLadderAuction.Params memory p = _ladderParams();
        StonkzLadderAuction.Params memory p2 = _ladderParams();
        ladder.allowDeployer(FRIEND);
        vm.prank(STRANGER);
        vm.expectRevert(DeployControls.DeployerNotAllowed.selector);
        ladder.file(p, bytes32(0));

        StonkzLadderAuction a  = _fileAs(ladder, FRIEND, p2);        assertEq(a.creator(), CREATOR);
    }

    function test_P1_ladder_ownerNotImplicitlyAllowlistedAfterRevoke() public {
        // Owner can still set switches, but after self-revoke + friend-only list, owner cannot file.
        StonkzLadderAuction.Params memory p = _ladderParams();
        ladder.allowDeployer(FRIEND);
        ladder.revokeDeployer(address(this));
        vm.expectRevert(DeployControls.DeployerNotAllowed.selector);
        ladder.file(p, bytes32(0));
        // Owner can still toggle
        ladder.setDeploysEnabled(false);
        assertFalse(ladder.deploysEnabled());
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
            refPriceWad: 2.5e11 // pair-wei per STONKZ token, WAD
        });
    }

    function _ladderParams() internal returns (StonkzLadderAuction.Params memory p) {
        LadderSettlement settlement = new LadderSettlement(IPoolManager(address(pm)), hook, PAIR);
        p = StonkzLadderAuction.Params({
            supply: SUPPLY,
            auctionSupply: SUPPLY,
            floorMcap: 10_000 ether,
            duration: LadderConstants.GOD_DURATION,
            lpShareWad: 0.9e18,
            lpHealthTargetWad: 0.25e18,
            carveBps: type(uint16).max, // factory default
            cashHoldbackBps: 0,
            holdbackBps: 0,
            holdbackDelivery: LadderConstants.HoldbackDelivery.None,
            tier: LadderTypes.Tier.God,
            createSidePool: true,
            sidePoolBps: 500,
            refPriceWad: 2.5e11, // pair-wei per STONKZ token, WAD
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
