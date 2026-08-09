// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {VaultConstants} from "../../src/vault/VaultConstants.sol";

/// @title VaultCanary — vacuity guard on launch rate (FEECHAIN / M5 pattern)
/// @notice Detached demonstration:
///           $env:CANARY_WRONG="true"; forge test --match-test test_canary_rateSecondsPerBps_3hIdentity -vv
///         MUST go red. Corrected (default) MUST go green. Both runs recorded in stop report.
contract VaultCanary is Test {
    /// @dev Load-bearing compare — deliberately wrong rate MUST fail here (vacuity proof).
    function test_canary_rateSecondsPerBps_3hIdentity() public view {
        bool wrong = vm.envOr("CANARY_WRONG", false);
        uint64 rate = VaultConstants.rateSecondsPerBps(wrong);
        uint256 duration = uint256(VaultConstants.ONE_PERCENT_BPS) * uint256(rate);
        assertEq(duration, VaultConstants.THREE_HOURS, "vacuity: rateSecondsPerBps identity bypassed");
    }

    /// @dev In-suite red proof that does not depend on env wiring in CI.
    function test_canary_wrongRate_diverges() public pure {
        uint256 right = uint256(VaultConstants.ONE_PERCENT_BPS) * uint256(VaultConstants.rateSecondsPerBps(false));
        uint256 wrong = uint256(VaultConstants.ONE_PERCENT_BPS) * uint256(VaultConstants.rateSecondsPerBps(true));
        assertEq(right, VaultConstants.THREE_HOURS, "right rate");
        assertTrue(wrong != VaultConstants.THREE_HOURS, "wrong rate must diverge");
    }
}
