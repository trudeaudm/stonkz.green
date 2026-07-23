// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @title LadderWeights — three-phase release curve (spec §5)
/// @dev Mirrors reference/sim-source.js `makeWeights`.
library LadderWeights {
    uint256 internal constant WAD = 1e18;

    /// @notice Build schedule weights for N blocks. Sum = WAD; 40% shallow / 60% finale;
    ///         seamless B→C handoff; monotone. spec §5, invariant I10.
    function makeWeights(uint256 N) internal pure returns (uint256[] memory w) {
        require(N >= 5, "N");
        w = new uint256[](N);
        uint256 K = (N * 80) / 100; // floor(N*0.8)
        if (K == 0) K = 1;
        if (K >= N) K = N; // no finale if N tiny (still handled)
        uint256 M = N - K;

        uint256 sPre;
        for (uint256 i = 1; i <= K; i++) {
            w[i - 1] = i;
            sPre += i;
        }
        for (uint256 i = 0; i < K; i++) {
            w[i] = (w[i] * (WAD * 40 / 100)) / sPre;
        }

        if (M == 0) {
            // renormalize shallow to 100%
            for (uint256 i = 0; i < K; i++) {
                w[i] = (w[i] * WAD) / (WAD * 40 / 100);
            }
            return w;
        }

        uint256 a = w[K - 1]; // handoff rate
        uint256 finale = WAD * 60 / 100;

        if (M == 1) {
            w[K] = finale;
        } else if (a * M >= finale) {
            for (uint256 j = 0; j < M; j++) {
                w[K + j] = finale / M;
            }
        } else {
            // binary-search geometric ratio r so a*(r^M-1)/(r-1) = 0.6
            uint256 lo = WAD + 1; // > 1
            uint256 hi = 100 * WAD;
            for (uint256 it = 0; it < 80; it++) {
                uint256 mid = (lo + hi) / 2;
                if (_geomSum(a, mid, M) > finale) hi = mid;
                else lo = mid;
            }
            uint256 r = (lo + hi) / 2;
            uint256 sFin;
            uint256 term = a;
            for (uint256 j = 0; j < M; j++) {
                w[K + j] = term;
                sFin += term;
                // term *= r; overflow-safe
                if (term > type(uint256).max / r) {
                    // shouldn't happen at solved r; fall back to equal split
                    for (uint256 k = 0; k < M; k++) w[K + k] = finale / M;
                    sFin = finale;
                    break;
                }
                term = (term * r) / WAD;
            }
            if (sFin > 0 && sFin != finale) {
                for (uint256 j = 0; j < M; j++) {
                    w[K + j] = FixedPointMathLib.mulDiv(w[K + j], finale, sFin);
                }
            }
        }
    }

    /// @dev a * (r^M - 1) / (r - 1) in WAD. Returns type(uint256).max on overflow
    ///      (binary-search treats as "too big").
    function _geomSum(uint256 a, uint256 r, uint256 M) private pure returns (uint256) {
        if (r <= WAD) return FixedPointMathLib.mulDiv(a, M, 1); // degenerate
        uint256 rp = WAD;
        for (uint256 i = 0; i < M; i++) {
            if (rp > type(uint256).max / r) return type(uint256).max;
            rp = (rp * r) / WAD;
        }
        if (rp <= WAD) return 0;
        uint256 num = rp - WAD;
        uint256 den = r - WAD;
        if (a > type(uint256).max / num) return type(uint256).max;
        return (a * num) / den;
    }

    /// @notice Suffix sums: suffix[i] = Σ w[i..N). suffix[N] = 0.
    function suffixSums(uint256[] memory w) internal pure returns (uint256[] memory s) {
        uint256 N = w.length;
        s = new uint256[](N + 1);
        uint256 acc;
        for (uint256 i = N; i > 0; i--) {
            acc += w[i - 1];
            s[i - 1] = acc;
        }
    }
}
