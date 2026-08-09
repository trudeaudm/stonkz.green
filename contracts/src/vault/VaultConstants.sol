// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/// @title VaultConstants — docs/10 rate units (bps + seconds)
/// @notice Launch direct-release rate: 108 seconds/bps = 3h per 1% of total supply.
library VaultConstants {
    /// @dev Direct-release launch rate. Unit: seconds per bps of total supply.
    ///      Canonical check: 100 bps × 108 s/bps = 10_800 s = 3 hours.
    uint64 internal constant LAUNCH_RATE_SECONDS_PER_BPS = 108; // seconds per bps of supply

    /// @dev 1% of supply in bps. Unit: bps of total supply.
    uint16 internal constant ONE_PERCENT_BPS = 100; // bps of supply (1%)

    /// @dev Seconds in 3 hours — pairs with ONE_PERCENT_BPS × LAUNCH_RATE_SECONDS_PER_BPS.
    uint256 internal constant THREE_HOURS = 3 hours; // seconds

    /// @dev Canary-corruptible mirror of LAUNCH_RATE_SECONDS_PER_BPS (test-only via env).
    function rateSecondsPerBps(bool wrong) internal pure returns (uint64) {
        return wrong ? uint64(999) : LAUNCH_RATE_SECONDS_PER_BPS; // wrong = 999 s/bps — must fail canary
    }
}
