// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {LadderMath} from "../../src/ladder/LadderMath.sol";
import {LadderConstants} from "../../src/ladder/LadderConstants.sol";

contract LadderMathTest is Test {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    uint256 internal constant FLOOR = 2500 ether;
    uint256 internal constant RUNG = 1000 ether;

    function test_rungPrice_exactOnGrid() public pure {
        uint256 p0 = LadderMath.rungPrice(0, FLOOR, RUNG, SUPPLY);
        assertEq(p0, 2_500_000_000_000); // 0.0000025e18
        uint256 p6 = LadderMath.rungPrice(6, FLOOR, RUNG, SUPPLY);
        assertEq(p6, 8_500_000_000_000); // 0.0000085e18
    }

    function test_rungOf_roundsDown() public pure {
        assertEq(LadderMath.rungOf(2500 ether, FLOOR, RUNG), 0);
        assertEq(LadderMath.rungOf(3499 ether, FLOOR, RUNG), 0);
        assertEq(LadderMath.rungOf(3500 ether, FLOOR, RUNG), 1);
        assertEq(LadderMath.rungOf(8608 ether, FLOOR, RUNG), 6);
    }

    function test_mmax_circFracOne() public pure {
        // liveBudget=$1678.091..., raised=0, lpShare=0.91, target=0.25
        uint256 live = 1678.0910366455 ether;
        uint256 mm = LadderMath.mmax(FLOOR, 0.91e18, 0, live, 0.25e18);
        // 2500 + 0.91*1678.091/0.25 ≈ 8608.25
        assertApproxEqAbs(mm, 8608.25 ether, 0.01 ether);
        assertEq(LadderMath.maxRung(mm, FLOOR, RUNG), 6);
    }

    function test_walletLiveContribution_capRoomClamp() public pure {
        uint256 price = 0.00001 ether; // $0.00001
        uint256 remCap = 50_000_000 ether; // tokens
        uint256 capCash = (remCap * price) / WAD; // $500
        assertEq(LadderMath.walletLiveContribution(10_000 ether, remCap, price), capCash);
        assertEq(LadderMath.walletLiveContribution(100 ether, remCap, price), 100 ether);
    }

    function test_periodIndex_matchesDesignN() public pure {
        assertEq(LadderConstants.periodIndex(0, LadderConstants.GOD_DURATION, LadderConstants.GOD_DURATION), 1000);
    }
}
