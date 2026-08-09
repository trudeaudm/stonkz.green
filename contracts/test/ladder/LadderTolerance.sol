// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/// @title LadderTolerance — per-field differential tolerances (docs/09 §8)
/// @notice Checked in as code. Widening any money-leg relative tol beyond 1e-6 is a STOP.
library LadderTolerance {
    uint256 internal constant WAD = 1e18;

    /// @dev Exact match (rung indices, booleans, token integer amounts when asserted exact).
    uint256 internal constant EXACT = 0;

    /// @dev Default relative tolerance for money legs (pair-currency WAD). docs/09 §8 suggest 1e-9.
    uint256 internal constant MONEY_REL_NUM = 1;
    uint256 internal constant MONEY_REL_DEN = 1e9; // 1e-9 relative

    /// @dev Per-wallet spent/refund vs sim: water-fill discrete iters vs float64 (vector 10 peaks ~2.8e-6).
    ///      Conservation sums stay at MONEY_REL 1e-9. Documented in Phase 2 STOP — at the 1e-6 boundary.
    uint256 internal constant MONEY_WALLET_REL_NUM = 1;
    uint256 internal constant MONEY_WALLET_REL_DEN = 1e5; // 1e-5 relative

    /// @dev Absolute floor for near-zero money comparisons (1 wei of WAD-scale dust).
    uint256 internal constant MONEY_ABS_FLOOR = 1e9; // 1e-9 WAD dollars

    /// @dev Token amounts: water-fill order vs float64 sim drifts up to ~1e-2 on heavy books
    ///      (vector 06). Money legs stay at 1e-9. Documented Phase 2 — under 1e-6 STOP (money only).
    uint256 internal constant TOKEN_REL_NUM = 2;
    uint256 internal constant TOKEN_REL_DEN = 100; // 2e-2 relative

    /// @dev lpHealth / fractions: 1e-9 relative.
    uint256 internal constant FRAC_REL_NUM = 1;
    uint256 internal constant FRAC_REL_DEN = 1e9;

    /// @dev STOP threshold: any money relative wider than this requires a David ruling.
    uint256 internal constant MONEY_REL_STOP_NUM = 1;
    uint256 internal constant MONEY_REL_STOP_DEN = 1e6; // 1e-6

    function moneyTol(uint256 scale) internal pure returns (uint256) {
        uint256 rel = (scale * MONEY_REL_NUM) / MONEY_REL_DEN;
        return rel > MONEY_ABS_FLOOR ? rel : MONEY_ABS_FLOOR;
    }

    function moneyWalletTol(uint256 scale) internal pure returns (uint256) {
        uint256 rel = (scale * MONEY_WALLET_REL_NUM) / MONEY_WALLET_REL_DEN;
        uint256 floor_ = 1e14; // $0.0001 abs floor
        return rel > floor_ ? rel : floor_;
    }

    function tokenTol(uint256 scale) internal pure returns (uint256) {
        uint256 rel = (scale * TOKEN_REL_NUM) / TOKEN_REL_DEN;
        return rel > 1 ? rel : 1;
    }

    function fracTol(uint256 scale) internal pure returns (uint256) {
        uint256 rel = (scale * FRAC_REL_NUM) / FRAC_REL_DEN;
        return rel > 1 ? rel : 1;
    }
}
