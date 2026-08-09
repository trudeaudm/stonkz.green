// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {stdJson} from "forge-std/StdJson.sol";
import {LadderVectorLoader} from "./LadderVectorLoader.sol";
import {LadderAsserts} from "./LadderAsserts.sol";
import {LadderTypes} from "../../src/ladder/LadderTypes.sol";
import {LadderConstants} from "../../src/ladder/LadderConstants.sol";
import {LadderTolerance} from "./LadderTolerance.sol";

/// @title LadderHarness — M5 differential spine (docs/09 §8)
/// @notice Phase 0: loader + A1..A5 + fixture self-consistency. Contract replay lands in
///         Phases 1–3; `replay` currently projects fixture expected outputs so the
///         assertion surface is exercised end-to-end (vacuity guarded by LadderCanary).
contract LadderHarness is LadderVectorLoader, LadderAsserts {
    using stdJson for string;
    /// @dev Phase 0 placeholder: returns expected outputs (+ path) without a live auction.
    ///      Replaced by StonkzLadderAuction poke/bid/settle replay in Phases 1–3.
    function replay(string memory file)
        public
        view
        returns (
            LadderTypes.Inputs memory inputs,
            LadderTypes.Bid[] memory bids,
            LadderTypes.Outputs memory expected,
            LadderTypes.ReplayResult memory got
        )
    {
        string memory json = _loadRaw(file);
        inputs = loadInputs(json);
        bids = loadBids(json);
        expected = loadOutputs(json);
        LadderTypes.PathRow[] memory path = loadPath(json);

        got.raised = expected.raised;
        got.committed = expected.committed;
        got.raiseSplit = expected.raiseSplit;
        got.fills = expected.fills;
        got.graduated = expected.graduated;
        got.failReasons = expected.failReasons;
        got.clearingPrice = expected.clearingPrice;
        got.lpHealth = expected.lpHealth;
        got.lpHealthFloor = expected.lpHealthFloor;
        got.soldTokens = expected.soldTokens;
        got.sidePoolTokens = expected.sidePoolTokens;
        got.clearingPath = path;
    }

    function _runAllAsserts(string memory file) internal view {
        (
            LadderTypes.Inputs memory inputs,
            ,
            LadderTypes.Outputs memory exp,
            LadderTypes.ReplayResult memory got
        ) = replay(file);

        assertA1_raiseSplit(got.raiseSplit, got.raised, exp.raiseSplit);
        assertA2_fillConservation(got.fills, exp.fills, got.raised, got.committed);
        assertA3(got.graduated, got.failReasons, exp.graduated, exp.failReasons);
        assertA4_lpHealth(got.graduated, got.lpHealth, got.lpHealthFloor);
        assertA5_rungGrid(got.clearingPath, inputs.floorMcap, inputs.supply, inputs.rungIntervalUsd);
    }

    // ─── Phase 0: fixture load + assert surface for all 10 ────────────────

    function test_P0_loadAllTen_schema() public view {
        for (uint256 i; i < VECTOR_FILES.length; i++) {
            string memory json = _loadRaw(VECTOR_FILES[i]);
            assertEq(json.readString(".schema"), "stonkz-ladder-fixture/1", "fixture schema");
            assertEq(json.readString(".sourceSchema"), "stonkz-ladder-vector/1", "source schema");
            LadderTypes.Inputs memory inn = loadInputs(json);
            assertEq(inn.N, LadderConstants.DESIGN_N, "N frozen at 1000");
            assertEq(inn.raiseRatioBps, LadderConstants.RAISE_RATIO_BPS, "raiseRatio bps");
        }
    }

    function test_P0_A1_to_A5_allTen_fixtureProjection() public view {
        for (uint256 i; i < VECTOR_FILES.length; i++) {
            _runAllAsserts(VECTOR_FILES[i]);
        }
    }

    function test_P0_toleranceTable_moneyRelIs1e9() public pure {
        assertEq(LadderTolerance.MONEY_REL_DEN, 1e9, "money rel den");
        assertEq(LadderTolerance.MONEY_REL_NUM, 1, "money rel num");
        assertEq(LadderTolerance.MONEY_REL_STOP_DEN, 1e6, "stop at 1e-6");
        assertEq(LadderTolerance.EXACT, 0, "exact");
        // 1e-9 of $1000 = 1e12 wei; floor is 1e9 → returns rel
        assertEq(LadderTolerance.moneyTol(1000 ether), 1000 ether / 1e9);
    }

    function test_P0_atBarVectors_listed() public view {
        // Phase 1 differential targets (docs/09 prompt): 02, 04, 05, 07
        assertEq(keccak256(bytes("02-god-2p5k-at-bar.json")), keccak256(bytes(VECTOR_FILES[1])));
        assertEq(keccak256(bytes("04-4h-5k-at-bar.json")), keccak256(bytes(VECTOR_FILES[3])));
        assertEq(keccak256(bytes("05-daily-10k-at-bar.json")), keccak256(bytes(VECTOR_FILES[4])));
        assertEq(keccak256(bytes("07-road-40k-at-bar.json")), keccak256(bytes(VECTOR_FILES[6])));
    }
}
