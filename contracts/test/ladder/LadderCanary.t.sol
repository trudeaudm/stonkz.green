// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test, stdJson} from "forge-std/Test.sol";
import {LadderConstants} from "../../src/ladder/LadderConstants.sol";

/// @title LadderCanary — M5 Phase 0 vacuity guard (FEECHAIN pattern)
/// @notice Asserts raise-threshold identity: threshold == floorMcap × raiseRatio.
///         Detached demonstration:
///           $env:CANARY_WRONG="true"; forge test --match-test test_canary_raiseRatio_thresholdIdentity -vv
///         MUST go red. Corrected (default) MUST go green. Both runs recorded in
///         docs/stop-task-m5-phase0.md.
contract LadderCanary is Test {
    using stdJson for string;

    /// @dev Non-negotiable vacuity guard. Green with RAISE_RATIO_BPS=6000; red when
    ///      CANARY_WRONG=true swaps in 7000 via LadderConstants.raiseRatioBps.
    function test_canary_raiseRatio_thresholdIdentity() public view {
        string memory json =
            vm.readFile(string.concat(vm.projectRoot(), "/test/fixtures/ladder/01-thin-book-fails.json"));
        uint256 floorMcap = json.readUint(".inputs.floorMcap");
        uint256 expectedThreshold = json.readUint(".inputs.threshold");

        bool wrong = vm.envOr("CANARY_WRONG", false);
        uint16 ratioBps = LadderConstants.raiseRatioBps(wrong);

        uint256 got = (floorMcap * uint256(ratioBps)) / 10_000;
        // Load-bearing compare — deliberately wrong ratio MUST fail here (vacuity proof).
        assertEq(got, expectedThreshold, "vacuity: raiseRatio identity bypassed");
    }

    /// @dev Companion: when wrong flag is forced true inside the test body, identity breaks.
    ///      This is the in-suite red proof that does not depend on env wiring in CI.
    function test_canary_wrongRatio_diverges() public pure {
        uint256 floorMcap = 2500 ether;
        uint256 expected = 1500 ether; // 0.6 × 2500
        uint256 wrong = (floorMcap * uint256(LadderConstants.raiseRatioBps(true))) / 10_000;
        uint256 right = (floorMcap * uint256(LadderConstants.raiseRatioBps(false))) / 10_000;
        assertEq(right, expected, "right ratio");
        assertTrue(wrong != expected, "wrong ratio must diverge (harness compares)");
    }
}
