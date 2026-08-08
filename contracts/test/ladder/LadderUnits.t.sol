// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {LadderConstants} from "../../src/ladder/LadderConstants.sol";

/// @title LadderUnits — one arithmetic units test per new constant family (FEECHAIN rule)
contract LadderUnits is Test {
    using FixedPointMathLib for uint256;

    function test_units_raiseRatioBps_ofStartMcap() public pure {
        // 6000 bps of $2,500 = $1,500
        uint256 threshold = (2500 ether * uint256(LadderConstants.RAISE_RATIO_BPS)) / 10_000;
        assertEq(threshold, 1500 ether);
    }

    function test_units_carveBps_ofRaised() public pure {
        // 400 bps of $10,000 raised = $400 toTreasury
        uint256 raised = 10_000 ether;
        uint256 toTreasury = (raised * uint256(LadderConstants.DEFAULT_CARVE_BPS)) / 10_000;
        assertEq(toTreasury, 400 ether);
    }

    function test_units_cashHoldbackBps_ofRaised() public pure {
        uint256 raised = 10_000 ether;
        uint256 hb = (raised * uint256(LadderConstants.DEFAULT_CASH_HOLDBACK_BPS)) / 10_000;
        assertEq(hb, 500 ether);
    }

    function test_units_sidePoolBps_ofLpDestinedTokens() public pure {
        uint256 lpTokens = 1_000_000 ether;
        uint256 side = (lpTokens * uint256(LadderConstants.SIDE_POOL_BPS)) / 10_000;
        assertEq(side, 50_000 ether);
    }

    function test_units_minAskBps_ofTotalSupply() public pure {
        uint256 supply = 1_000_000_000 ether;
        uint256 minAsk = (supply * uint256(LadderConstants.MIN_ASK_BPS)) / 10_000;
        assertEq(minAsk, 50_000_000 ether);
    }

    function test_units_walletCapBps_ofAuctionSupply() public pure {
        uint256 auctionSupply = 1_000_000_000 ether;
        uint256 cap = (auctionSupply * uint256(LadderConstants.DEFAULT_WALLET_CAP_BPS)) / 10_000;
        assertEq(cap, 50_000_000 ether);
    }

    function test_units_rungPeriod_timeDerived() public pure {
        // Real rungPeriod = duration/1000; on-chain via elapsed*N/duration (no int truncation).
        // GOD: end of auction → period 1000. Truncating rungPeriod to 3s would desync N.
        assertEq(
            LadderConstants.periodIndex(1000, 1000 + LadderConstants.GOD_DURATION, LadderConstants.GOD_DURATION),
            1000
        );
        // Real 3.6s period: elapsed=3 → idx 0; elapsed=4 → 4*1000/3600 = 1.
        assertEq(LadderConstants.periodIndex(0, 3, LadderConstants.GOD_DURATION), 0);
        assertEq(LadderConstants.periodIndex(0, 4, LadderConstants.GOD_DURATION), 1);
        // 4H: 14.4s period → elapsed=14 → 0; elapsed=15 → 1.
        assertEq(LadderConstants.periodIndex(0, 14, LadderConstants.H4_DURATION), 0);
        assertEq(LadderConstants.periodIndex(0, 15, LadderConstants.H4_DURATION), 1);
    }

    function test_units_alphaWad_isLog2_1_1() public pure {
        // 2^alpha ≈ 1.1; solady powWad(2e18, ALPHA_WAD) ≈ 1.1e18
        int256 two = 2 ether;
        int256 got = FixedPointMathLib.powWad(two, LadderConstants.ALPHA_WAD);
        // 1e15 abs ≈ 0.1% — constant-check only; fill precision strategy lands in Phase 2.
        assertApproxEqAbs(uint256(got), 1.1e18, 1e15);
    }

    function test_units_lpShare_fromCarveAndCashHb() public pure {
        // lpShare = 1 - carve - cashHoldback = 10000 - 400 - 500 = 9100 bps
        uint16 lpShareBps = 10_000 - LadderConstants.DEFAULT_CARVE_BPS - LadderConstants.DEFAULT_CASH_HOLDBACK_BPS;
        assertEq(lpShareBps, 9100);
        uint256 lpShareWad = (uint256(lpShareBps) * LadderConstants.WAD) / 10_000;
        assertEq(lpShareWad, 0.91e18);
    }

    function test_units_minBid_pairWei() public pure {
        assertEq(LadderConstants.MIN_BID, 5 ether);
    }
}
