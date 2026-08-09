// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {console2} from "forge-std/console2.sol";

/// @dev Forensic mirror of StonkzAuction water-fill (production file untouched).
library TracedWaterFill {
    uint256 internal constant WAD = 1e18;

    struct Snap {
        address who;
        bytes32 name;
        uint256 weight;
        uint256 committedBasis;
        uint256 tokens;
        uint256 activeSpent;
        uint256 activeBudget;
        bool active;
        bool capped;
    }

    function run(
        Snap[] memory snaps,
        uint256 offered,
        uint256 price,
        uint256 cap
    ) internal returns (uint256 remainingAfter, bool hitIterCap, uint256 constraintHits) {
        console2.log("FORENSIC_SOL offered", offered);
        console2.log("FORENSIC_SOL price", price);
        console2.log("FORENSIC_SOL cap", cap);

        uint256 remaining = offered;
        uint256 itersDone;
        for (uint256 it = 0; it < 8 && remaining > 0; it++) {
            (uint256 used, uint256 hits) = _oneIter(snaps, remaining, price, cap, it);
            constraintHits += hits;
            if (used == 0) break;
            remaining -= used;
            itersDone = it + 1;
        }

        hitIterCap = itersDone >= 8 && remaining > 0;
        remainingAfter = remaining;
        console2.log("FORENSIC_SOL remainingFinal", remainingAfter);
        console2.log("FORENSIC_SOL hitIterCap", hitIterCap ? 1 : 0);
        console2.log("FORENSIC_SOL itersDone", itersDone);
        console2.log("FORENSIC_SOL constraintHits", constraintHits);
    }

    function _oneIter(
        Snap[] memory snaps,
        uint256 remaining,
        uint256 price,
        uint256 cap,
        uint256 it
    ) private returns (uint256 used, uint256 hits) {
        uint256 totW = _totW(snaps);
        if (totW == 0) return (0, 0);
        console2.log("--- iteration", it);
        console2.log("remainingBefore", remaining);
        console2.log("totW", totW);

        for (uint256 i = 0; i < snaps.length; i++) {
            if (!snaps[i].active || snaps[i].capped) continue;
            (uint256 take, uint8 kind) = _calc(snaps[i], remaining, price, cap, totW);
            console2.logBytes32(snaps[i].name);
            console2.log("weight", snaps[i].weight == 0 ? WAD : snaps[i].weight);
            console2.log("committedBasis", snaps[i].committedBasis);
            console2.log("take", take);
            console2.log("constraintHit", uint256(kind));
            if (take > 0) {
                snaps[i].tokens += take;
                snaps[i].activeSpent += FixedPointMathLib.mulWad(take, price);
                used += take;
            }
            if (kind != 0) {
                hits++;
                if (kind == 1) {
                    snaps[i].capped = true;
                    snaps[i].active = false;
                } else {
                    snaps[i].active = false;
                    snaps[i].activeBudget = 0;
                    snaps[i].activeSpent = 0;
                }
            }
        }
        console2.log("remainingAfter", remaining - used);
        console2.log("used", used);
    }

    function _totW(Snap[] memory snaps) private pure returns (uint256 totW) {
        for (uint256 i = 0; i < snaps.length; i++) {
            if (snaps[i].active && !snaps[i].capped) {
                totW += snaps[i].weight == 0 ? WAD : snaps[i].weight;
            }
        }
    }

    function _calc(
        Snap memory s,
        uint256 remaining,
        uint256 price,
        uint256 cap,
        uint256 totW
    ) private view returns (uint256 take, uint8 kind) {
        uint256 w = s.weight == 0 ? WAD : s.weight;
        uint256 share = FixedPointMathLib.mulDiv(remaining, w, totW);
        uint256 capLeft = cap > s.tokens ? cap - s.tokens : 0;
        uint256 budTok = FixedPointMathLib.mulDiv(
            s.activeBudget > s.activeSpent ? s.activeBudget - s.activeSpent : 0, WAD, price
        );
        console2.log("share", share);
        console2.log("capLeft", capLeft);
        console2.log("budLeft", budTok);
        take = share;
        if (take > capLeft) take = capLeft;
        if (take > budTok) take = budTok;
        if (take + 1 < share) kind = capLeft <= budTok ? 1 : 2;
    }
}
