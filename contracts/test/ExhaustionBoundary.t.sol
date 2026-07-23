// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IStonkzAuction} from "../src/IStonkzAuction.sol";
import {StonkzAuction} from "../src/StonkzAuction.sol";

/// @notice Task S3: exhaustion-boundary with same-clear projSpent (E1).
/// (a) budgets >= D wei from epsilon: exit blocks MUST match eager exactly.
/// (b) budgets within D of crossing: |lazyExit-eagerExit|<=1 and fill d within fuzz tol.
contract ExhaustionBoundaryTest is Test {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BID_FEE = WAD / 10;
    uint256 internal constant DUST_EPS = 1e9;
    uint256 internal constant DELTA_ABS_FLOOR = 1e12;

    address internal constant WHO = address(0xE401);
    address internal constant PEER = address(0xBEEF);

    // --- (a) far from razor: exact exit match ---

    function test_exhaustion_a_weight1() public {
        _assertExactExit(_base(0), 1000 ether, 1);
    }

    function test_exhaustion_a_weight865() public {
        _assertExactExit(_base(1000), 2_000 ether, 865);
    }

    function test_exhaustion_a_weight50() public {
        _assertExactExit(_base(1000), 50_000 ether, 50);
    }

    function test_exhaustion_a_weight500() public {
        _assertExactExit(_base(1000), 500_000 ether, 500);
    }

    // --- (b) razor window ---

    function test_exhaustion_b_razor_weight1() public {
        _assertRazorWindow(_base(0), 1);
    }

    function test_exhaustion_b_razor_weight865() public {
        _assertRazorWindow(_base(1000), 865);
    }

    function _assertExactExit(IStonkzAuction.Params memory p, uint256 budget, uint256 tag) internal {
        StonkzAuction eager = new StonkzAuction(_eager(p, true));
        StonkzAuction lazy = new StonkzAuction(_eager(p, false));
        _bid(eager, PEER, 100_000 ether, type(uint256).max);
        _bid(lazy, PEER, 100_000 ether, type(uint256).max);
        _bid(eager, WHO, budget, type(uint256).max);
        _bid(lazy, WHO, budget, type(uint256).max);

        (uint256 w,,,,,,,,) = eager.bidders(WHO);
        emit log_named_uint("tag_a", tag);
        emit log_named_uint("weight", w);

        (uint64 exitE, uint64 exitL) = _exitBlocksLockstep(eager, lazy);
        if (exitE != exitL) {
            emit log_string("STOP: exact exit mismatch (class a)");
            emit log_named_uint("eagerExit", exitE);
            emit log_named_uint("lazyExit", exitL);
            fail();
        }
    }

    /// @dev Construct budget near epsilon crossing via lazy projection headroom.
    function _assertRazorWindow(IStonkzAuction.Params memory p, uint256 tag) internal {
        // Nominal mid budget, then nudge by D/2 toward the eps razor.
        uint256 budget = 200 ether + DUST_EPS;
        uint256 D = _dustBound(p, budget);
        if (D > 0 && budget > D) budget = budget - (D / 2);

        StonkzAuction eager = new StonkzAuction(_eager(p, true));
        StonkzAuction lazy = new StonkzAuction(_eager(p, false));
        _bid(eager, PEER, 100_000 ether, type(uint256).max);
        _bid(lazy, PEER, 100_000 ether, type(uint256).max);
        _bid(eager, WHO, budget, type(uint256).max);
        _bid(lazy, WHO, budget, type(uint256).max);

        emit log_named_uint("tag_b", tag);
        emit log_named_uint("razorBud", budget);
        emit log_named_uint("D", D);

        uint256 tokE0 = eager.bidderTokens(WHO);
        uint256 tokL0 = lazy.bidderTokens(WHO);
        (uint64 exitE, uint64 exitL) = _exitBlocksLockstep(eager, lazy);
        lazy.materialize(WHO);
        uint256 tokE1 = eager.bidderTokens(WHO);
        uint256 tokL1 = lazy.bidderTokens(WHO);

        uint256 dExit = exitE > exitL ? exitE - exitL : exitL - exitE;
        if (dExit > 1) {
            emit log_string("STOP: razor exit |d|>1");
            emit log_named_uint("eagerExit", exitE);
            emit log_named_uint("lazyExit", exitL);
            fail();
        }
        uint256 fillE = tokE1 - tokE0;
        uint256 fillL = tokL1 - tokL0;
        uint256 dFill = fillE > fillL ? fillE - fillL : fillL - fillE;
        uint256 scale = fillE > fillL ? fillE : fillL;
        uint256 tol = _deltaTol(scale);
        if (dFill > tol) {
            emit log_string("STOP: razor fill d exceeds fuzz tol");
            emit log_named_uint("dFill", dFill);
            emit log_named_uint("tol", tol);
            fail();
        }
    }

    /// @dev Advance both auctions in lockstep so wall-clock epochs stay aligned.
    function _exitBlocksLockstep(StonkzAuction eager, StonkzAuction lazy)
        internal
        returns (uint64 exitE, uint64 exitL)
    {
        uint256 t = block.timestamp;
        bool eDone;
        bool lDone;
        for (uint256 i = 0; i < 120; i++) {
            if (!eDone && !_hasActive(eager, WHO)) {
                exitE = uint64(eager.auctionIndex());
                eDone = true;
            }
            if (!lDone && !_hasActive(lazy, WHO)) {
                exitL = uint64(lazy.auctionIndex());
                lDone = true;
            }
            if (eDone && lDone) return (exitE, exitL);
            if (eager.done() && lazy.done()) break;

            t += 1;
            vm.warp(t);
            if (!eager.done()) eager.poke();
            if (!lazy.done()) {
                lazy.poke();
                lazy.materialize(WHO);
            }
        }
        if (!eDone) exitE = uint64(eager.auctionIndex());
        if (!lDone) exitL = uint64(lazy.auctionIndex());
    }

    function _dustBound(IStonkzAuction.Params memory p, uint256 budget) internal returns (uint256 D) {
        StonkzAuction a = new StonkzAuction(_eager(p, true));
        _bid(a, PEER, 100_000 ether, type(uint256).max);
        _bid(a, WHO, budget, type(uint256).max);
        (uint256 w,,,,,,,,) = a.bidders(WHO);
        uint256 ceilW = w == 0 ? 1 : (w + WAD - 1) / WAD;
        D = 4 * ceilW * uint256(p.durationBlocks) + 1;
    }

    function _hasActive(StonkzAuction a, address who) internal view returns (bool) {
        uint256 n = a.nextPositionId();
        for (uint256 id = 1; id <= n; id++) {
            (address o,,,,, StonkzAuction.PosStatus st,,,) = a.positions(id);
            if (o == who && st == StonkzAuction.PosStatus.Active) return true;
        }
        return false;
    }

    function _deltaTol(uint256 scale) internal pure returns (uint256) {
        uint256 rel = scale / 1e9;
        return rel > DELTA_ABS_FLOOR ? rel : DELTA_ABS_FLOOR;
    }

    function _bid(StonkzAuction a, address who, uint256 budget, uint256 maxP) internal {
        vm.deal(who, budget + BID_FEE + 1 ether);
        vm.prank(who);
        a.placeBid{value: budget + BID_FEE}(budget, maxP);
    }

    function _base(uint16 sizeBonusBps) internal pure returns (IStonkzAuction.Params memory p) {
        p.totalSupply = 1_000_000 ether;
        p.floorMcapUsd = 50_000 ether;
        p.graduationUsd = 0;
        p.durationBlocks = 100;
        p.epochSeconds = 1;
        p.maxClearsPerSync = 0;
        p.maxUniqueActives = 0;
        p.baseStepBps = 500;
        p.walletCapBps = 10_000;
        p.sizeBonusBps = sizeBonusBps;
        p.lpShareBps = 8000;
        p.holdbackBps = 0;
        p.kappaHundredths = 130;
    }

    function _eager(IStonkzAuction.Params memory p, bool e)
        internal
        pure
        returns (IStonkzAuction.Params memory)
    {
        p.eagerFills = e;
        return p;
    }
}
