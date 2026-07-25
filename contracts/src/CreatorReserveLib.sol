// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @title CreatorReserve — token-side holdback delivery (spec §8.4)
/// @dev Instant: 10-minute timelock after graduation unlock. Vest: linear over duration.
library CreatorReserveLib {
    uint256 internal constant INSTANT_TIMELOCK = 10 minutes;

    enum DeliveryMode {
        Instant,
        Vest
    }

    struct State {
        DeliveryMode mode;
        uint64 vestDuration; // seconds; 0 if Instant
        uint64 unlockedAt; // graduation timestamp + timelock (Instant) or vest start
        uint256 total; // creatorReserve tokens
        uint256 claimed;
        bool filed;
    }

    event CreatorReserveFiled(uint256 amount, DeliveryMode mode, uint64 vestDuration, bytes32 declaredUse);
    event CreatorReserveUnlocked(uint256 amount, uint64 unlockedAt);
    event CreatorReserveVested(uint256 chunk, uint256 claimedTotal);
    event CreatorReserveDelivered(address indexed to, uint256 amount);

    function vestedAvailable(State storage s, uint64 nowTs) internal view returns (uint256) {
        if (s.total == 0 || s.unlockedAt == 0) return 0;
        if (s.mode == DeliveryMode.Instant) {
            return nowTs >= s.unlockedAt ? s.total - s.claimed : 0;
        }
        // VEST: linear from unlockedAt over vestDuration
        if (nowTs < s.unlockedAt) return 0;
        uint256 elapsed = nowTs - s.unlockedAt;
        if (elapsed >= s.vestDuration) return s.total - s.claimed;
        uint256 accrued = FixedPointMathLib.mulDiv(s.total, elapsed, s.vestDuration);
        return accrued > s.claimed ? accrued - s.claimed : 0;
    }
}
