// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "../../src/v4/IPoolManager.sol";
import {MockPoolManager} from "../../src/mock/MockPoolManager.sol";
import {StonkzFeeHook} from "../../src/StonkzFeeHook.sol";
import {CTOGovernor} from "../../src/CTOGovernor.sol";
import {ICTOGovernor} from "../../src/interfaces/IStonkzGovernance.sol";
import {StonkzLadderFactory} from "../../src/ladder/StonkzLadderFactory.sol";
import {StonkzLadderAuction} from "../../src/ladder/StonkzLadderAuction.sol";
import {LadderSettlement} from "../../src/ladder/LadderSettlement.sol";
import {LadderConstants} from "../../src/ladder/LadderConstants.sol";
import {LadderTypes} from "../../src/ladder/LadderTypes.sol";
import {StonkzLaunchToken} from "../../src/StonkzLaunchToken.sol";

/// @title LadderLoudUnset — filing guard + settlement backstop (PREDEPLOY-REFIT)
contract LadderLoudUnset is Test {
    MockPoolManager internal pm;
    StonkzFeeHook internal hook;
    StonkzLadderFactory internal factory;

    address internal constant ETH = address(0);
    address internal constant TREASURY = address(0x7A5E);
    address internal constant CREATOR = address(0xCEEE);
    address internal constant SIDE = address(0x4663);
    address internal constant BIDDER = address(0xB1D);

    uint256 internal constant SUPPLY = 1_000_000 ether;

    function setUp() public {
        vm.etch(SIDE, hex"00");
        pm = new MockPoolManager();
        CTOGovernor gov = new CTOGovernor();
        hook = new StonkzFeeHook(IPoolManager(address(pm)), TREASURY, ICTOGovernor(address(gov)));
        gov.setRegistry(hook);
        factory = new StonkzLadderFactory();
        factory.setCarveTreasury(TREASURY);
    }

    function test_file_revertsWhenCreateSidePoolAndSideTokenUnset() public {
        assertEq(factory.sideTokenRef(), address(0));
        assertTrue(factory.defaultCreateSidePool());
        vm.expectRevert(StonkzLadderFactory.SideTokenRefUnset.selector);
        factory.file(_params(address(0)));
    }

    function test_file_succeedsWhenSideTokenSet() public {
        factory.setSideTokenRef(SIDE);
        LadderSettlement s = new LadderSettlement(IPoolManager(address(pm)), hook, ETH);
        s.setSideTokenRef(SIDE);
        factory.setSettlementRef(address(s));
        StonkzLadderAuction a = factory.file(_params(address(0)));
        assertTrue(a.createSidePool());
        assertEq(a.refPriceWad(), 2.5e11);
        assertEq(address(a.settlement()), address(s));
    }

    /// @notice Mid-auction edge: file with ref set, unset settlement.sideTokenRef, settle reverts.
    /// @dev Recovery: auction.settled stays false (tx atomic); raised ETH remains escrowed;
    ///      claimRefund for unspent still works; re-set sideTokenRef then settle succeeds.
    function test_settle_backstop_unsetMidAuction_recoveryState() public {
        factory.setSideTokenRef(SIDE);
        LadderSettlement s = new LadderSettlement(IPoolManager(address(pm)), hook, ETH);
        s.setSideTokenRef(SIDE);
        factory.setSettlementRef(address(s));

        StonkzLadderAuction a = factory.file(_params(address(0)));
        a.start();

        // Multiple wallets to clear raise + health gates (walletCap binds a single bidder).
        for (uint256 i; i < 20; i++) {
            address w = address(uint160(0xB100 + i));
            vm.deal(w, 2_000 ether);
            vm.prank(w);
            a.placeBid{value: 500 ether}(500 ether, type(uint256).max);
        }
        vm.warp(block.timestamp + LadderConstants.GOD_DURATION + 1);
        a.clearAllForTest();
        assertTrue(a.graduated(), "must graduate for settle path");
        assertFalse(a.settled());

        uint256 escrowBefore = address(a).balance;
        assertGt(escrowBefore, 0);

        // Unset settlement ref mid-auction (filing guard already passed).
        s.setSideTokenRef(address(0));
        assertEq(s.sideTokenRef(), address(0));

        StonkzLaunchToken tok = new StonkzLaunchToken("U", "U", SUPPLY, address(s));
        vm.expectRevert(LadderSettlement.SideTokenRefUnset.selector);
        a.settle(address(tok));

        // Recovery state after failed settle crank:
        assertFalse(a.settled(), "settled flag rolled back with revert");
        assertEq(address(a).balance, escrowBefore, "raised ETH still escrowed on auction");
        assertTrue(a.graduated());
        assertTrue(a.done());

        // Re-wire and settle successfully.
        s.setSideTokenRef(SIDE);
        a.settle(address(tok));
        assertTrue(a.settled());
        assertTrue(s.settled());
    }

    function test_genesis_createSidePoolFalse_filesAndSettlesWithRefUnset() public {
        factory.setDefaultCreateSidePool(false);
        assertEq(factory.sideTokenRef(), address(0));

        LadderSettlement s = new LadderSettlement(IPoolManager(address(pm)), hook, ETH);
        // settlement sideTokenRef left unset — OK when createSidePool=false
        factory.setSettlementRef(address(s));

        StonkzLadderAuction a = factory.file(_params(address(0)));
        assertFalse(a.createSidePool());
        assertEq(a.refPriceWad(), 0);

        a.start();
        for (uint256 i; i < 20; i++) {
            address w = address(uint160(0xC100 + i));
            vm.deal(w, 2_000 ether);
            vm.prank(w);
            a.placeBid{value: 500 ether}(500 ether, type(uint256).max);
        }
        vm.warp(block.timestamp + LadderConstants.GOD_DURATION + 1);
        a.clearAllForTest();
        assertTrue(a.graduated());

        StonkzLaunchToken tok = new StonkzLaunchToken("G", "G", SUPPLY, address(s));
        a.settle(address(tok));
        assertTrue(a.settled());
        assertTrue(s.settled());
        assertEq(s.sidePoolTokens(), 0);
    }

    function _params(address settlement) internal pure returns (StonkzLadderAuction.Params memory p) {
        p = StonkzLadderAuction.Params({
            supply: SUPPLY,
            auctionSupply: SUPPLY,
            floorMcap: 2_500 ether,
            duration: LadderConstants.GOD_DURATION,
            lpShareWad: 0.91e18,
            lpHealthTargetWad: 0.25e18,
            carveBps: type(uint16).max,
            cashHoldbackBps: 500,
            holdbackBps: 0,
            holdbackDelivery: LadderConstants.HoldbackDelivery.None,
            tier: LadderTypes.Tier.God,
            createSidePool: true, // overwritten by factory
            sidePoolBps: 500,
            refPriceWad: 0,
            walletCapBps: 1000,
            sizeBonusBps: 1000,
            maxUniqueActives: 300,
            pairToken: ETH,
            creator: CREATOR,
            treasury: TREASURY,
            vaultRef: address(0),
            settlement: settlement
        });
    }
}
