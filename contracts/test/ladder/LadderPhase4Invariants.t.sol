// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {LadderPhase4Base, MockTok} from "./LadderPhase4Base.sol";
import {StonkzLadderAuction} from "../../src/ladder/StonkzLadderAuction.sol";
import {LadderConstants} from "../../src/ladder/LadderConstants.sol";
import {LadderMath} from "../../src/ladder/LadderMath.sol";
import {LadderSettlement} from "../../src/ladder/LadderSettlement.sol";

/// @title LadderPhase4Invariants — escrow, price monotone/Mmax, refund-once
contract LadderPhase4Invariants is LadderPhase4Base {
    /// @notice Escrow conservation at every state through bid → clear → claim → settle.
    function test_P4_escrowConservation_everyState() public {
        DeployCfg memory c = _defaultCfg();
        c.walletCapBps = 1000;
        StonkzLadderAuction a = _deploy(c);
        _assertEscrow(a);

        for (uint256 i; i < 12; i++) {
            _bid(a, address(uint160(0xE100 + i)), 120 ether, 1 ether);
            _assertEscrow(a);
        }
        for (uint256 i; i < 3; i++) {
            _bid(a, address(uint160(0xDE00 + i)), 2_000 ether, type(uint128).max);
            _assertEscrow(a);
        }

        uint256 t0 = block.timestamp;
        for (uint16 step = 1; step <= 20; step++) {
            vm.warp(t0 + (LadderConstants.GOD_DURATION * step) / 50);
            a.poke();
            _assertEscrow(a);
        }
        if (!a.done()) a.clearAllForTest();
        _assertEscrow(a);

        address decoy = address(0xDE00);
        (,,, uint256 refund) = a.fillOf(decoy);
        if (refund > 0) {
            uint256 balBefore = decoy.balance;
            vm.prank(decoy);
            a.claimRefund();
            assertEq(decoy.balance - balBefore, refund, "refund paid");
            _assertEscrow(a);
            vm.prank(decoy);
            vm.expectRevert(StonkzLadderAuction.NothingToClaim.selector);
            a.claimRefund();
        }

        if (a.graduated()) {
            (LadderSettlement s, MockTok tok) = _wireSettlement(a);
            uint256 unsold = a.auctionSupply() - a.soldTokens();
            tok.mint(address(s), unsold + a.holdbackAmount() + 1 ether);
            a.settle(address(tok));
            _assertEscrow(a);
        }
    }

    /// @notice Price monotone non-decreasing; never above Mmax (checked at advance).
    function test_P4_priceMonotone_neverAboveMmax() public {
        DeployCfg memory c = _defaultCfg();
        c.walletCapBps = 1000;
        StonkzLadderAuction a = _deploy(c);
        for (uint256 i; i < 15; i++) {
            _bid(a, address(uint160(0xA100 + i)), 200 ether, 1 ether);
        }

        uint256 prevPrice = a.price();
        uint256 prevRung = a.rung();
        while (!a.done()) {
            // Snapshot pre-clear live at current price — advance uses post-fill raised + this price's live.
            uint256 liveBefore = a.liveBudget();
            uint256 raisedBefore = a.raised();
            uint256 mmCeiling = LadderMath.mmax(
                a.floorMcap(),
                a.lpShareWad(),
                raisedBefore, // lower bound; fill only increases raised ⇒ Mmax rises
                liveBefore,
                a.lpHealthTargetWad(),
                a.circFrac()
            );

            a.clearNextForTest();

            uint256 p = a.price();
            uint256 r = a.rung();
            assertGe(p, prevPrice, "price monotone");
            assertLe(r, prevRung + 1, "at most one rung per period");
            // On-grid
            assertEq(p, LadderMath.rungPrice(r, a.floorMcap(), LadderConstants.RUNG_INTERVAL_USD, a.supply()), "on grid");

            if (r > prevRung) {
                // Advance-time: new mcap must fit under Mmax that authorized the step.
                // raised after fill >= raisedBefore; using raisedBefore is conservative (tighter).
                // Live after fill at old price <= liveBefore (spending reduces unspent).
                // Contract uses post-fill live (≤ liveBefore) and post-fill raised (≥ raisedBefore).
                // Upper bound on authorized mcap uses max plausible Mmax ≥ contract's:
                uint256 mmUpper = LadderMath.mmax(
                    a.floorMcap(),
                    a.lpShareWad(),
                    a.raised(),
                    liveBefore,
                    a.lpHealthTargetWad(),
                    a.circFrac()
                );
                assertLe(_mcapOfPrice(a, p), mmUpper, "advanced above Mmax");
                assertLe(_mcapOfPrice(a, p), mmCeiling + LadderConstants.RUNG_INTERVAL_USD, "vs pre-fill ceiling");
            }
            prevPrice = p;
            prevRung = r;

            uint16 pi = a.periodIndex();
            if (pi > 1) {
                assertGe(a.pathPrice(pi), a.pathPrice(pi - 1), "path monotone");
            }
        }
    }

    /// @notice Refund claimable exactly once; second claim reverts.
    function test_P4_refundClaimable_exactlyOnce() public {
        DeployCfg memory c = _defaultCfg();
        StonkzLadderAuction a = _deploy(c);
        for (uint256 i; i < 10; i++) {
            _bid(a, address(uint160(0xC200 + i)), 200 ether, 1 ether);
        }
        address w = address(0x2EF2);
        _bid(a, w, 5_000 ether, type(uint128).max);
        a.clearAllForTest();

        (,,, uint256 refund) = a.fillOf(w);
        assertTrue(refund > 0, "need claimable refund");

        vm.prank(w);
        a.claimRefund();
        (,,,, uint256 rc,, bool claimed) = a.wallets(w);
        assertTrue(claimed, "refundClaimed");
        assertEq(rc, 0, "refundClaimable cleared");

        vm.prank(w);
        vm.expectRevert(StonkzLadderAuction.NothingToClaim.selector);
        a.claimRefund();
    }

    function _assertEscrow(StonkzLadderAuction a) internal view {
        uint256 expect;
        uint256 n = a.uniqueBidders();
        if (!a.done()) {
            expect = a.committedTotal();
        } else {
            for (uint256 i; i < n; i++) {
                address w = a.bidderList(i);
                (,,,, uint256 rc,, bool claimed) = a.wallets(w);
                if (!claimed) expect += rc;
            }
            if (!a.settled()) expect += a.raised();
        }
        assertEq(address(a).balance, expect, "escrow conservation");
    }
}
