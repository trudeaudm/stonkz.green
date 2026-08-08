// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {LadderConstants} from "./LadderConstants.sol";

/// @title LadderMath — rung grid, Mmax, liveBudget clamps (docs/09 §1)
/// @dev Prices always exactly on grid: price = (startMcap + k * rungInterval) / supply.
library LadderMath {
    using FixedPointMathLib for uint256;

    uint256 internal constant WAD = LadderConstants.WAD;

    /// @notice Rung index for a mcap (round DOWN). docs/09 §1.
    function rungOf(uint256 mcap, uint256 startMcap, uint256 rungInterval) internal pure returns (uint256) {
        if (mcap <= startMcap) return 0;
        return (mcap - startMcap) / rungInterval;
    }

    /// @notice Price (WAD pair/token) at rung k. Exact on grid.
    function rungPrice(uint256 k, uint256 startMcap, uint256 rungInterval, uint256 supply)
        internal
        pure
        returns (uint256)
    {
        require(supply > 0, "supply");
        uint256 mcap = startMcap + k * rungInterval;
        return FixedPointMathLib.fullMulDiv(mcap, WAD, supply);
    }

    /// @notice Mmax mcap (WAD dollars). circFrac = 1 ALWAYS until vault (docs/09 §1).
    /// Mmax = startMcap + lpShare * (raised + liveBudget) / (lpHealthTarget * circFrac)
    function mmax(
        uint256 startMcap,
        uint256 lpShareWad,
        uint256 raised,
        uint256 liveBudget,
        uint256 lpHealthTargetWad
    ) internal pure returns (uint256) {
        // circFrac = 1 (FDV fallback). vault hook = owner-settable later; default no exclusion.
        if (lpHealthTargetWad == 0) return startMcap;
        uint256 num = FixedPointMathLib.fullMulDiv(lpShareWad, raised + liveBudget, WAD);
        uint256 add = FixedPointMathLib.fullMulDiv(num, WAD, lpHealthTargetWad);
        return startMcap + add;
    }

    /// @notice Highest rung k with rung mcap <= Mmax.
    function maxRung(uint256 mmaxMcap, uint256 startMcap, uint256 rungInterval) internal pure returns (uint256) {
        return rungOf(mmaxMcap, startMcap, rungInterval);
    }

    /// @notice Wallet contribution to liveBudget at price p:
    ///         min(unspent, remainingCapRoomTokens * price). docs/09 §1 whale-cap clamp.
    function walletLiveContribution(uint256 unspent, uint256 remCapTokens, uint256 priceWad)
        internal
        pure
        returns (uint256)
    {
        if (unspent == 0 || remCapTokens == 0 || priceWad == 0) return 0;
        uint256 capCash = FixedPointMathLib.fullMulDiv(remCapTokens, priceWad, WAD);
        return unspent < capCash ? unspent : capCash;
    }
}
