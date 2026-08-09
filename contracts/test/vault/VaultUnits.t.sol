// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {VaultConstants} from "../../src/vault/VaultConstants.sol";

/// @title VaultUnits — one arithmetic units test per constant family (docs/10)
contract VaultUnits is Test {
    /// @notice Canonical check: 100 bps × 108 s/bps = 10_800 s = 3 hours.
    function test_units_rateSecondsPerBps_3hPer1pct() public pure {
        uint256 duration = uint256(VaultConstants.ONE_PERCENT_BPS) * uint256(VaultConstants.LAUNCH_RATE_SECONDS_PER_BPS);
        assertEq(duration, VaultConstants.THREE_HOURS, "100 bps * 108 s = 3h");
        assertEq(duration, 10_800, "10_800 seconds");
    }

    function test_units_8pctPerDay_atLaunchRate() public pure {
        // duration for 1 bps = 108s; bps per day = 86400/108 = 800 bps = 8%.
        uint256 bpsDay = uint256(1 days) / uint256(VaultConstants.LAUNCH_RATE_SECONDS_PER_BPS);
        assertEq(bpsDay, 800, "800 bps/day = 8%/day");
    }
}
