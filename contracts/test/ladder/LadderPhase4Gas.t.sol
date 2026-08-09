// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {LadderPhase4Base, MockTok} from "./LadderPhase4Base.sol";
import {StonkzLadderAuction} from "../../src/ladder/StonkzLadderAuction.sol";
import {LadderSettlement} from "../../src/ladder/LadderSettlement.sol";

/// @title LadderPhase4Gas — bid / claim / settle snapshots at 300 actives
/// @dev User-action gas only. clearAll setup cost is NOT the sanity bar (Phase 1 note).
contract LadderPhase4Gas is LadderPhase4Base {
    uint256 internal constant N_ACTIVES = 300;
    /// @dev Soft ceilings for "sane" user ops on RH-class L2. Not hard product SLOs.
    uint256 internal constant BID_GAS_SOFT = 2_000_000;
    uint256 internal constant CLAIM_GAS_SOFT = 150_000;
    uint256 internal constant SETTLE_GAS_SOFT = 5_000_000;

    function test_P4_gas_bid_claim_settle_300actives() public {
        DeployCfg memory c = _defaultCfg();
        c.walletCapBps = 1000;
        c.maxUniqueActives = uint16(N_ACTIVES);
        c.floorMcap = 2_500 ether;
        // Generous cash share so graduation is easy after book fills.
        c.cashHoldbackBps = 500;
        StonkzLadderAuction a = _deploy(c);

        // Seed 299 actives (cold book, no period clears yet).
        for (uint256 i; i < N_ACTIVES - 1; i++) {
            _bid(a, address(uint160(0x3000 + i)), 20 ether, 1 ether);
        }
        assertEq(a.uniqueBidders(), N_ACTIVES - 1);

        // ── bid @300 ─────────────────────────────────────────────────────
        address bidder300 = address(uint160(0x3000 + N_ACTIVES - 1));
        uint256 size = 20 ether;
        vm.deal(bidder300, size + 1 ether);
        vm.prank(bidder300);
        uint256 g0 = gasleft();
        a.placeBid{value: size}(size, 1 ether);
        uint256 gasBid = g0 - gasleft();
        emit log_named_uint("gas_placeBid_at_300_actives", gasBid);
        assertEq(a.uniqueBidders(), N_ACTIVES);
        assertTrue(gasBid > 0, "bid metered");
        assertLe(gasBid, BID_GAS_SOFT, "bid gas soft ceiling");

        // Setup: finish auction (harness cost — not snapshotted).
        a.clearAllForTest();
        assertTrue(a.done(), "done");

        // Pick a wallet with refund for claim snapshot; else any spent wallet still
        // exercises claim path via a decoy we add... after done can't bid. Use unspent.
        address claimer;
        uint256 refundAmt;
        for (uint256 i; i < N_ACTIVES; i++) {
            address w = address(uint160(0x3000 + i));
            (,,, uint256 r) = a.fillOf(w);
            if (r > 0) {
                claimer = w;
                refundAmt = r;
                break;
            }
        }
        // If book fully spent everyone, still measure claim on zero-path is impossible —
        // seed expected: 300 × $20 = $6k raise on $2.5k floor → heavy oversub ⇒ refunds.
        assertTrue(refundAmt > 0, "expected refunds under oversub book");

        // ── claim @300 ───────────────────────────────────────────────────
        vm.prank(claimer);
        g0 = gasleft();
        a.claimRefund();
        uint256 gasClaim = g0 - gasleft();
        emit log_named_uint("gas_claimRefund_at_300_actives", gasClaim);
        assertTrue(gasClaim > 0, "claim metered");
        assertLe(gasClaim, CLAIM_GAS_SOFT, "claim gas soft ceiling");

        // ── settle @300 (graduated) ──────────────────────────────────────
        assertTrue(a.graduated(), "need graduate for settle snapshot");
        (LadderSettlement s, MockTok tok) = _wireSettlement(a);
        uint256 unsold = a.auctionSupply() - a.soldTokens();
        tok.mint(address(s), unsold + a.holdbackAmount() + 1 ether);

        g0 = gasleft();
        a.settle(address(tok));
        uint256 gasSettle = g0 - gasleft();
        emit log_named_uint("gas_settle_at_300_actives", gasSettle);
        assertTrue(a.settled(), "settled");
        assertTrue(gasSettle > 0, "settle metered");
        assertLe(gasSettle, SETTLE_GAS_SOFT, "settle gas soft ceiling");
    }
}
