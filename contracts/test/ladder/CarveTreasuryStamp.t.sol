// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "../../src/v4/IPoolManager.sol";
import {MockPoolManager} from "../../src/mock/MockPoolManager.sol";
import {StonkzFeeHook} from "../../src/StonkzFeeHook.sol";
import {CTOGovernor} from "../../src/CTOGovernor.sol";
import {ICTOGovernor} from "../../src/interfaces/IStonkzGovernance.sol";
import {FeeLockerV2} from "../../src/FeeLockerV2.sol";
import {StonkzLadderFactory} from "../../src/ladder/StonkzLadderFactory.sol";
import {StonkzLadderAuction} from "../../src/ladder/StonkzLadderAuction.sol";
import {LadderSettlement} from "../../src/ladder/LadderSettlement.sol";
import {LadderConstants} from "../../src/ladder/LadderConstants.sol";
import {LadderTypes} from "../../src/ladder/LadderTypes.sol";
import {StonkzLaunchToken} from "../../src/StonkzLaunchToken.sol";

/// @title CarveTreasuryStamp — factory stamps protocol carve; filer cannot capture
contract CarveTreasuryStamp is Test {
    MockPoolManager internal pm;
    StonkzFeeHook internal hook;
    FeeLockerV2 internal locker;
    StonkzLadderFactory internal factory;
    LadderSettlement internal settlement;

    address internal constant ETH = address(0);
    address internal constant FEE_SAFE = address(0xEF2F); // FeeHook protocolTreasury stand-in
    address internal constant PROTOCOL_SAFE = address(0x9D11); // factory carveTreasury
    address internal constant ATTACKER = address(0xA77A);
    address internal constant CREATOR = address(0xCEEE);
    address internal constant SIDE = address(0x4663);
    address internal constant BIDDER = address(0xB1D);

    uint256 internal constant SUPPLY = 1_000_000 ether;

    function setUp() public {
        vm.etch(SIDE, hex"00");
        pm = new MockPoolManager();
        CTOGovernor gov = new CTOGovernor();
        hook = new StonkzFeeHook(IPoolManager(address(pm)), FEE_SAFE, ICTOGovernor(address(gov)));
        gov.setRegistry(hook);
        locker = new FeeLockerV2(IPoolManager(address(pm)), hook);
        factory = new StonkzLadderFactory();
        factory.setCarveTreasury(PROTOCOL_SAFE);
        factory.setSideTokenRef(SIDE);
        factory.setDefaultCreateSidePool(false); // settle without side pool for carve-only drill
        settlement = new LadderSettlement(IPoolManager(address(pm)), hook, ETH);
        settlement.setFeeLocker(locker);
        factory.setSettlementRef(address(settlement));
    }

    function test_setCarveTreasury_rejectsZero() public {
        vm.expectRevert(StonkzLadderFactory.CarveTreasuryZero.selector);
        factory.setCarveTreasury(address(0));
    }

    function test_file_revertsWhenCarveTreasuryUnset() public {
        StonkzLadderFactory bare = new StonkzLadderFactory();
        bare.setSideTokenRef(SIDE);
        bare.setDefaultCreateSidePool(false);
        vm.expectRevert(StonkzLadderFactory.CarveTreasuryUnset.selector);
        bare.file(_params(ATTACKER));
    }

    /// @notice Teeth: filer passes attacker as p.treasury — stamp overwrites; settle pays PROTOCOL_SAFE.
    function test_filerCannotOverrideCarveTreasury_settlementPaysStamp() public {
        StonkzLadderAuction.Params memory p = _params(ATTACKER);
        assertEq(p.treasury, ATTACKER, "precondition: filer supplied attacker");

        StonkzLadderAuction a = factory.file(p);
        assertEq(a.treasury(), PROTOCOL_SAFE, "stamp ignored filer");
        assertTrue(a.treasury() != ATTACKER);

        // Graduate + settle; carve ETH must land at PROTOCOL_SAFE, not ATTACKER.
        a.start();
        uint256 bid = 10_000 ether;
        vm.deal(BIDDER, bid + 1 ether);
        vm.prank(BIDDER);
        a.placeBid{value: bid}(bid, 1 ether);
        a.clearAllForTest();
        assertTrue(a.graduated(), "graduated");

        StonkzLaunchToken tok = new StonkzLaunchToken("T", "T", SUPPLY, address(this));
        uint256 unsold = a.auctionSupply() - a.soldTokens();
        tok.transfer(address(settlement), unsold);

        uint256 protoBefore = PROTOCOL_SAFE.balance;
        uint256 attackBefore = ATTACKER.balance;
        (uint256 toLP, uint256 toTreasury, uint256 toCreator) = a.raiseSplit();
        assertGt(toTreasury, 0, "carve > 0");

        a.settle(address(tok));

        assertEq(PROTOCOL_SAFE.balance - protoBefore, toTreasury, "carve to protocol Safe");
        assertEq(ATTACKER.balance - attackBefore, 0, "attacker got nothing");
        assertEq(settlement.toTreasury(), toTreasury);
        toLP;
        toCreator;
    }

    /// @notice Stamp survives factory default change after file (immutable per auction).
    function test_stampSurvivesFactoryCarveTreasuryChange() public {
        StonkzLadderAuction first = factory.file(_params(ATTACKER));
        assertEq(first.treasury(), PROTOCOL_SAFE);

        address otherSafe = address(0xBEEF);
        factory.setCarveTreasury(otherSafe);
        StonkzLadderAuction second = factory.file(_params(ATTACKER));
        assertEq(second.treasury(), otherSafe);
        assertEq(first.treasury(), PROTOCOL_SAFE, "prior stamp immutable");
    }

    function test_event_loud() public {
        vm.expectEmit(true, false, false, true);
        emit StonkzLadderFactory.CarveTreasuryChanged(address(0xCAFE));
        factory.setCarveTreasury(address(0xCAFE));
    }

    function _params(address filerTreasury) internal view returns (StonkzLadderAuction.Params memory p) {
        p = StonkzLadderAuction.Params({
            supply: SUPPLY,
            auctionSupply: SUPPLY,
            floorMcap: 5_000 ether,
            duration: LadderConstants.GOD_DURATION,
            lpShareWad: 0.9e18,
            lpHealthTargetWad: 0.01e18,
            carveBps: type(uint16).max,
            cashHoldbackBps: 0,
            holdbackBps: 0,
            holdbackDelivery: LadderConstants.HoldbackDelivery.None,
            tier: LadderTypes.Tier.God,
            createSidePool: false,
            sidePoolBps: 0,
            refPriceWad: 0,
            walletCapBps: 1000,
            sizeBonusBps: 0,
            maxUniqueActives: 64,
            pairToken: ETH,
            creator: CREATOR,
            treasury: filerTreasury,
            vaultRef: address(0),
            settlement: address(0)
        });
    }
}
