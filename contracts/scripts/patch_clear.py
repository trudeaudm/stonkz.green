from pathlib import Path
import re

p = Path(__file__).resolve().parents[1] / "src" / "StonkzAuction.sol"
text = p.read_text(encoding="utf-8")
start = text.index("    /// @dev One auction block")
end = text.index("    function _dustDetect(address who)")

new = r'''    /// @dev One auction block — differential twin of reference `tick()`.
    function _clearOneBlock() internal {
        if (eagerFills) {
            _clearOneBlockEager();
        } else {
            _clearOneBlockLazy();
        }
    }

    /// @dev Legacy path: per-address writes every clear (equiv / vector oracle parity).
    function _clearOneBlockEager() internal {
        uint256 b = auctionIndex;
        require(b < durationBlocks, "past");
        uint256 px = price;

        _priceOutAt(px);

        if (!competition && activeAddrs.length > 1) {
            competition = true;
        }

        uint256 offered = _offeredAt(b, px, raised, auctionSold());
        uint256 cap = walletCapTokens();

        address[] memory snap = activeAddrs;
        uint256 n = snap.length;
        for (uint256 i = 0; i < n; i++) {
            _materialize(snap[i]);
        }

        uint256[] memory snapW = new uint256[](n);
        uint256[] memory snapBud = new uint256[](n);
        uint256[] memory snapSpent = new uint256[](n);
        uint256[] memory snapTok = new uint256[](n);
        bool[] memory alive = new bool[](n);
        for (uint256 i = 0; i < n; i++) {
            Bidder storage bd = bidders[snap[i]];
            snapW[i] = bd.weight == 0 ? WAD : bd.weight;
            snapBud[i] = bd.activeBudget;
            snapSpent[i] = bd.activeSpent;
            snapTok[i] = bd.tokens;
            alive[i] = bd.activeCount > 0 && !bd.capped && bd.activeBudget > 0;
        }

        for (uint256 i = 0; i < n; i++) {
            _dustExhaustPositions(snap[i]);
            _refreshWeightBasisOnly(snap[i]);
        }

        uint256 remaining = offered;
        uint256 blockRaised;
        for (uint256 it = 0; it < 8 && remaining > 0; it++) {
            uint256 totW;
            for (uint256 i = 0; i < n; i++) {
                if (!alive[i]) continue;
                totW += snapW[i];
            }
            if (totW == 0) break;

            uint256 used;
            for (uint256 i = 0; i < n; i++) {
                if (!alive[i]) continue;
                address who = snap[i];
                Bidder storage bd = bidders[who];

                uint256 share = FixedPointMathLib.mulDiv(remaining, snapW[i], totW);
                uint256 capLeft = cap > snapTok[i] ? cap - snapTok[i] : 0;
                uint256 budLeft = snapBud[i] > snapSpent[i] ? snapBud[i] - snapSpent[i] : 0;
                uint256 budTok = FixedPointMathLib.mulDiv(budLeft, WAD, px);

                uint256 take = share;
                if (take > capLeft) take = capLeft;
                if (take > budTok) take = budTok;

                if (take > 0) {
                    (uint256 gotTok, uint256 cost) = _distributeToPositions(who, take, px);
                    if (gotTok > 0) {
                        bd.tokens += gotTok;
                        bd.activeSpent += cost;
                        snapTok[i] += gotTok;
                        snapSpent[i] += cost;
                        bd.rewardDebt = FixedPointMathLib.mulDiv(bd.weight, accTokensPerWeight, WAD);
                        bd.usdDebt = FixedPointMathLib.mulDiv(bd.weight, accUsdPerWeight, WAD);
                        used += gotTok;
                        blockRaised += cost;
                        emit Filled(who, gotTok, cost, px, uint64(b));
                    }
                }

                if (take + 1 < share) {
                    alive[i] = false;
                    if (capLeft <= budTok) {
                        _markCapped(who);
                    }
                }
            }
            remaining -= used;
            if (used == 0) break;
        }

        for (uint256 i = 0; i < n; i++) {
            _refreshWeightBasisOnly(snap[i]);
        }

        _finishClear(b, px, offered, remaining, blockRaised);
    }

    /// @dev Task Q' lazy path: globals + constrained/exit writes only.
    function _clearOneBlockLazy() internal {
        uint256 b = auctionIndex;
        require(b < durationBlocks, "past");
        uint256 px = price;

        _priceOutAt(px);

        if (!competition && activeAddrs.length > 1) {
            competition = true;
        }

        uint256 offered = _offeredAt(b, px, raised, auctionSold());
        uint256 cap = walletCapTokens();

        address[] memory snap = activeAddrs;
        uint256 n = snap.length;

        uint256[] memory snapW = new uint256[](n);
        uint256[] memory snapBud = new uint256[](n);
        uint256[] memory snapSpent = new uint256[](n);
        uint256[] memory snapTok = new uint256[](n);
        bool[] memory alive = new bool[](n);

        for (uint256 i = 0; i < n; i++) {
            address who = snap[i];
            Bidder storage bd = bidders[who];
            snapW[i] = bd.weight == 0 ? WAD : bd.weight;
            snapBud[i] = bd.activeBudget;
            snapSpent[i] = bd.activeSpent + _pendingUsd(who);
            snapTok[i] = bd.tokens + _pendingTokens(who);
            alive[i] = bd.activeCount > 0 && !bd.capped && bd.activeBudget > 0;
        }

        for (uint256 i = 0; i < n; i++) {
            if (!alive[i]) continue;
            if (!_dustDetect(snap[i])) continue;
            _materialize(snap[i]);
            _dustExhaustPositions(snap[i]);
            _refreshWeightBasisOnly(snap[i]);
        }

        uint256[] memory takeAmt = new uint256[](n);
        uint256[] memory costAmt = new uint256[](n);
        bool[] memory constrained = new bool[](n);
        uint8[] memory constrKind = new uint8[](n);

        uint256 remaining = offered;
        for (uint256 it = 0; it < 8 && remaining > 0; it++) {
            uint256 totW;
            for (uint256 i = 0; i < n; i++) {
                if (!alive[i]) continue;
                totW += snapW[i];
            }
            if (totW == 0) break;

            uint256 used;
            for (uint256 i = 0; i < n; i++) {
                if (!alive[i]) continue;

                uint256 share = FixedPointMathLib.mulDiv(remaining, snapW[i], totW);
                uint256 capLeft = cap > snapTok[i] ? cap - snapTok[i] : 0;
                uint256 budLeft = snapBud[i] > snapSpent[i] ? snapBud[i] - snapSpent[i] : 0;
                uint256 budTok = FixedPointMathLib.mulDiv(budLeft, WAD, px);

                uint256 take = share;
                if (take > capLeft) take = capLeft;
                if (take > budTok) take = budTok;

                if (take > 0) {
                    uint256 cost = FixedPointMathLib.mulWad(take, px);
                    if (cost > budLeft) {
                        cost = budLeft;
                        take = px == 0 ? 0 : FixedPointMathLib.mulDiv(cost, WAD, px);
                    }
                    takeAmt[i] += take;
                    costAmt[i] += cost;
                    snapTok[i] += take;
                    snapSpent[i] += cost;
                    used += take;
                }

                if (take + 1 < share) {
                    alive[i] = false;
                    constrained[i] = true;
                    constrKind[i] = capLeft <= budTok ? 1 : 2;
                }
            }
            remaining -= used;
            if (used == 0) break;
        }

        uint256 blockRaised;
        uint256 soldNow;
        for (uint256 i = 0; i < n; i++) {
            soldNow += takeAmt[i];
            blockRaised += costAmt[i];
        }

        uint256 uncTok;
        uint256 uncUsd;
        uint256 uncW;
        for (uint256 i = 0; i < n; i++) {
            if (constrained[i] || takeAmt[i] == 0) continue;
            uncTok += takeAmt[i];
            uncUsd += costAmt[i];
            uncW += snapW[i];
        }
        if (uncW > 0) {
            accTokensPerWeight += FixedPointMathLib.mulDiv(uncTok, WAD, uncW);
            accUsdPerWeight += FixedPointMathLib.mulDiv(uncUsd, WAD, uncW);
        }

        for (uint256 i = 0; i < n; i++) {
            if (!constrained[i]) {
                if (takeAmt[i] > 0) emit Filled(snap[i], takeAmt[i], costAmt[i], px, uint64(b));
                continue;
            }
            address who = snap[i];
            _materialize(who);
            if (takeAmt[i] > 0) {
                (uint256 gotTok, uint256 cost) = _distributeToPositions(who, takeAmt[i], px);
                if (gotTok > 0) {
                    Bidder storage bd = bidders[who];
                    bd.tokens += gotTok;
                    bd.activeSpent += cost;
                    emit Filled(who, gotTok, cost, px, uint64(b));
                }
            }
            if (constrKind[i] == 1) _markCapped(who);
            {
                Bidder storage bd = bidders[who];
                bd.rewardDebt = FixedPointMathLib.mulDiv(bd.weight, accTokensPerWeight, WAD);
                bd.usdDebt = FixedPointMathLib.mulDiv(bd.weight, accUsdPerWeight, WAD);
            }
            _refreshWeightBasisOnly(who);
        }

        _finishClear(b, px, offered, offered - soldNow, blockRaised);
    }

    function _finishClear(uint256 b, uint256 px, uint256 offered, uint256 remaining, uint256 blockRaised) internal {
        uint256 soldNow = offered - remaining;
        uint256 schedQty = _schedAt(b, auctionSold());
        uint256 gate = schedQty;
        uint256 wSched = FixedPointMathLib.mulWad(weights[b], auctionSupply);
        if (gate > wSched) gate = wSched;

        bool fullySold = gate > 0 && soldNow + _gateTol(gate) >= gate;

        sold += soldNow;
        raised += blockRaised;
        if (soldNow > schedQty) {
            extraSold += soldNow - schedQty;
            emit ReserveToppedUp(soldNow - schedQty, px, uint64(b));
        }
        if (soldNow > 0) lastSoldPrice = px;

        if (fullySold) {
            uint256 step = _effStepWadCached();
            price = FixedPointMathLib.mulWad(price, step);
            emit PriceStepped(price, baseStepBps, uint64(b));
        }

        auctionIndex = uint64(b + 1);

        if (auctionSold() + 1 >= auctionSupply && _offeredAt(auctionIndex, price, raised, auctionSold()) == 0
                && raised >= graduationUsd) {
            _finish();
        } else if (auctionIndex >= durationBlocks) {
            _finish();
        }
    }

'''

text2 = text[:start] + new + text[end:]
text2 = re.sub(
    r"    function _applyFillsEager\([\s\S]*?\n    function _dustDetect",
    "    function _dustDetect",
    text2,
    count=1,
)
text2 = re.sub(
    r"    function _dustWouldExhaust\([\s\S]*?\n    function _gateTol",
    "    function _gateTol",
    text2,
    count=1,
)
p.write_text(text2, encoding="utf-8")
print("ok", len(text), "->", len(text2))
