// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {LadderTypes} from "../../src/ladder/LadderTypes.sol";
import {LadderTolerance} from "./LadderTolerance.sol";
import {LadderConstants} from "../../src/ladder/LadderConstants.sol";

/// @title LadderAsserts — named load-bearing assertions A1..A5 (docs/09 §8)
abstract contract LadderAsserts is Test {
    /// @notice A1: raise-split conservation exact on contract outputs;
    ///         each leg within money tolerance of expected.
    function assertA1_raiseSplit(
        LadderTypes.RaiseSplit memory got,
        uint256 raised,
        LadderTypes.RaiseSplit memory exp
    ) internal pure {
        // Conservation exact (docs/09 §7 INVARIANT).
        assertEq(got.toLP + got.toTreasury + got.toCreator, raised, "A1: legs != raised");
        assertApproxEqAbs(got.toLP, exp.toLP, LadderTolerance.moneyTol(exp.toLP), "A1: toLP");
        assertApproxEqAbs(got.toTreasury, exp.toTreasury, LadderTolerance.moneyTol(exp.toTreasury), "A1: toTreasury");
        assertApproxEqAbs(got.toCreator, exp.toCreator, LadderTolerance.moneyTol(exp.toCreator), "A1: toCreator");
    }

    /// @notice A2: fill conservation — sum spent == raised; sum refund == committed - raised;
    ///         per-wallet spent/tokens/refund within tolerance.
    function assertA2_fillConservation(
        LadderTypes.Fill[] memory got,
        LadderTypes.Fill[] memory exp,
        uint256 raised,
        uint256 committed
    ) internal pure {
        uint256 sumSpent;
        uint256 sumRefund;
        for (uint256 i; i < got.length; i++) {
            sumSpent += got[i].spent;
            sumRefund += got[i].refund;
        }
        assertApproxEqAbs(sumSpent, raised, LadderTolerance.moneyTol(raised), "A2: sum spent != raised");
        uint256 expRefund = committed > raised ? committed - raised : 0;
        assertApproxEqAbs(sumRefund, expRefund, LadderTolerance.moneyTol(expRefund), "A2: sum refund");

        // Per-wallet: match by address (order-independent).
        for (uint256 i; i < exp.length; i++) {
            (bool found, LadderTypes.Fill memory g) = _findFill(got, exp[i].wallet);
            assertTrue(found, "A2: missing wallet fill");
            assertApproxEqAbs(g.spent, exp[i].spent, LadderTolerance.moneyWalletTol(exp[i].spent), "A2: spent");
            assertApproxEqAbs(g.refund, exp[i].refund, LadderTolerance.moneyWalletTol(exp[i].refund), "A2: refund");
            assertApproxEqAbs(g.tokens, exp[i].tokens, LadderTolerance.tokenTol(exp[i].tokens), "A2: tokens");
            assertApproxEqAbs(
                g.committed, exp[i].committed, LadderTolerance.moneyTol(exp[i].committed), "A2: committed"
            );
        }
    }

    /// @notice A3: denial names the failing gate (exact reason string match via keccak).
    function assertA3(
        bool gotGraduated,
        bytes32[] memory gotReasons,
        bool expGraduated,
        bytes32[] memory expReasons
    ) internal pure {
        assertEq(gotGraduated, expGraduated, "A3: graduated");
        if (expGraduated) {
            assertEq(gotReasons.length, 0, "A3: graduated but failReasons non-empty");
        } else {
            assertEq(gotReasons.length, expReasons.length, "A3: failReasons length");
            for (uint256 i; i < expReasons.length; i++) {
                assertTrue(_contains(gotReasons, expReasons[i]), "A3: missing failReason");
            }
        }
    }

    /// @notice A4: lpHealth >= floor for every graduated case (exact boolean gate).
    function assertA4_lpHealth(bool graduated, uint256 lpHealth, uint256 lpHealthFloor) internal pure {
        if (graduated) {
            assertGe(lpHealth, lpHealthFloor, "A4: lpHealth < floor on graduated");
        }
    }

    /// @notice A5: every path price exactly on the rung grid; steps in {0,+1}.
    function assertA5_rungGrid(
        LadderTypes.PathRow[] memory path,
        uint256 floorMcap,
        uint256 supply,
        uint256 rungIntervalUsd
    ) internal pure {
        uint256 prevRung = type(uint256).max;
        for (uint256 i; i < path.length; i++) {
            uint256 price = path[i].price;
            // rung k: price = (floorMcap + k * rungInterval) / supply
            // ⇒ price * supply - floorMcap is divisible by rungInterval (exact in WAD math).
            uint256 mcap = _mulWad(price, supply);
            assertGe(mcap + 1, floorMcap, "A5: mcap below floor"); // +1 wei dust guard on mul
            uint256 above = mcap >= floorMcap ? mcap - floorMcap : 0;
            // Allow 1 WAD dollar dust from float→WAD fixture conversion on price.
            uint256 k = above / rungIntervalUsd;
            uint256 rem = above - k * rungIntervalUsd;
            assertTrue(rem <= WAD_DUST || rungIntervalUsd - rem <= WAD_DUST, "A5: price off rung grid");

            if (prevRung != type(uint256).max) {
                if (k > prevRung) {
                    assertEq(k, prevRung + 1, "A5: multi-rung step");
                } else {
                    assertEq(k, prevRung, "A5: price decreased");
                }
            }
            prevRung = k;
        }
    }

    uint256 internal constant WAD_DUST = 1e15; // $0.001 mcap dust from float fixtures

    function _mulWad(uint256 price, uint256 supply) private pure returns (uint256) {
        return (price * supply) / LadderConstants.WAD;
    }

    function _findFill(LadderTypes.Fill[] memory fills, address wallet)
        private
        pure
        returns (bool, LadderTypes.Fill memory)
    {
        for (uint256 i; i < fills.length; i++) {
            if (fills[i].wallet == wallet) return (true, fills[i]);
        }
        LadderTypes.Fill memory empty;
        return (false, empty);
    }

    function _contains(bytes32[] memory arr, bytes32 x) private pure returns (bool) {
        for (uint256 i; i < arr.length; i++) {
            if (arr[i] == x) return true;
        }
        return false;
    }
}
