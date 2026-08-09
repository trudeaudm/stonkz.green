// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/// @title LadderConstants — docs/09 parameter grid + units discipline
/// @notice Fixed-point choice (Phase 0): WAD = 1e18 (solady FixedPointMathLib),
///         semantically equivalent to UD60x18 without adding a PRBMath dependency.
///         Money = pair-currency wei (WAD dollars when pair is 18-dec USDG/ETH quote).
///         Prices = pair-per-token in WAD. Fractions that are bps-native stay in bps.
library LadderConstants {
    uint256 internal constant WAD = 1e18;

    // ─── globals (docs/09 §3) ─────────────────────────────────────────────
    /// @dev Platform raise/pass line only — zero effect on dynamics. Unit: bps of startMcap.
    uint16 internal constant RAISE_RATIO_BPS = 6000; // bps of startMcap (60%)
    /// @dev Rung spacing in mcap dollars (WAD).
    uint256 internal constant RUNG_INTERVAL_USD = 1000 * WAD; // $1,000 mcap
    /// @dev Default protocol carve of raise. Unit: bps of raised. Bounds [0, 1000].
    uint16 internal constant DEFAULT_CARVE_BPS = 400; // bps of raised (4%)
    uint16 internal constant CARVE_BPS_MAX = 1000; // bps of raised (10%)
    /// @dev Side pool share of LP-destined tokens. Unit: bps of LP-destined token amount.
    uint16 internal constant SIDE_POOL_BPS = 500; // bps of LP-destined tokens (5%)
    /// @dev Minimum bid notional. Unit: pair-currency wei.
    uint256 internal constant MIN_BID = 5 * WAD; // $5
    /// @dev Default wallet cap. Unit: bps of auction supply.
    uint16 internal constant DEFAULT_WALLET_CAP_BPS = 500; // bps of auction supply (5%)
    uint16 internal constant WALLET_CAP_BPS_MIN = 1; // bps (0.01%)
    uint16 internal constant WALLET_CAP_BPS_MAX = 1000; // bps (10%)
    /// @dev Default cash holdback. Unit: bps of raised.
    uint16 internal constant DEFAULT_CASH_HOLDBACK_BPS = 500; // bps of raised (5%)
    uint16 internal constant CASH_HOLDBACK_BPS_MAX = 2000; // bps of raised (20%)
    /// @dev Size-tilt beta. Unit: bps (10% → alpha = log2(1.1)).
    uint16 internal constant SIZE_BONUS_BPS = 1000; // bps (10%)
    /// @dev Hard floor on main-pool ask-side tokens at settlement. Unit: bps of total supply.
    uint16 internal constant MIN_ASK_BPS = 500; // bps of total supply (5%)
    /// @dev Design resolution N — frozen on-chain (docs/09 §2 / §9). Not chain blocks.
    uint16 internal constant DESIGN_N = 1000;

    // ─── tier durations (seconds). Fractional rungPeriod (3.6s etc.) is NOT stored:
    //      periodIndex = elapsed * DESIGN_N / duration  (docs/09 §2 quantization).
    //      Equivalent to real-valued rungPeriod = duration/1000 without truncating to int seconds.
    uint256 internal constant GOD_DURATION = 1 hours; // 3600
    uint256 internal constant H4_DURATION = 4 hours; // 14400
    uint256 internal constant DAILY_DURATION = 24 hours; // 86400
    uint256 internal constant ROAD_DURATION = 7 days; // 604800

    /// @dev Timestamp → period index. Caps at DESIGN_N (finale).
    function periodIndex(uint256 startTime, uint256 timestamp, uint256 duration)
        internal
        pure
        returns (uint256)
    {
        if (timestamp <= startTime || duration == 0) return 0;
        uint256 elapsed = timestamp - startTime;
        uint256 idx = (elapsed * uint256(DESIGN_N)) / duration;
        return idx > DESIGN_N ? DESIGN_N : idx;
    }

    // ─── tier lpHealth floors (WAD fractions) ─────────────────────────────
    uint256 internal constant GOD_LP_HEALTH_FLOOR = 0.25e18; // WAD fraction
    uint256 internal constant H4_LP_HEALTH_FLOOR = 0.30e18; // WAD fraction
    uint256 internal constant DAILY_LP_HEALTH_FLOOR = 0.35e18; // WAD fraction
    uint256 internal constant ROAD_LP_HEALTH_FLOOR = 0.40e18; // WAD fraction

    /// @dev alpha = log2(1.1) as WAD. Checked: 2^(ALPHA_WAD/WAD) ≈ 1.1.
    ///      solady powWad uses this directly. Value from ln(1.1)/ln(2) * 1e18.
    int256 internal constant ALPHA_WAD = 137_503_523_749_934_908; // WAD; log2(1.1)

    // ─── holdback ceilings (bps of total supply). Vault-only; TAKE removed. ─
    uint16 internal constant GOD_HOLDBACK_BPS_MAX = 4000; // bps of supply (40%)
    uint16 internal constant H4_HOLDBACK_BPS_MAX = 5000; // bps of supply (50%)
    uint16 internal constant DAILY_HOLDBACK_BPS_MAX = 6000; // bps of supply (60%)
    uint16 internal constant ROAD_HOLDBACK_BPS_MAX = 7000; // bps of supply (70%)

    /// @dev Holdback delivery: NONE or VAULT only. TAKE is dead.
    enum HoldbackDelivery {
        None,
        Vault
    }

    function holdbackCeilingBps(uint8 tierId) internal pure returns (uint16) {
        if (tierId == 0) return GOD_HOLDBACK_BPS_MAX;
        if (tierId == 1) return H4_HOLDBACK_BPS_MAX;
        if (tierId == 2) return DAILY_HOLDBACK_BPS_MAX;
        return ROAD_HOLDBACK_BPS_MAX;
    }

    /// @dev Canary-corruptible mirror of RAISE_RATIO_BPS (test-only via env). Production
    ///      code MUST use RAISE_RATIO_BPS. Exposed so LadderCanary can prove non-vacuity.
    function raiseRatioBps(bool wrong) internal pure returns (uint16) {
        return wrong ? uint16(7000) : RAISE_RATIO_BPS; // wrong = 70% — must fail canary
    }
}
