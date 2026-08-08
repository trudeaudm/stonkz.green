// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {LadderWeights} from "../LadderWeights.sol";
import {LadderConstants} from "./LadderConstants.sol";
import {LadderMath} from "./LadderMath.sol";
import {LadderTypes} from "./LadderTypes.sol";

/// @title StonkzLadderAuction — fair-launch ladder (docs/09)
/// @notice Time-derived rung periods, Mmax/liveBudget price rule, per-address weight fills.
/// @dev Bids are NOT swaps (docs/03 2026-08-08): escrow in pair currency; no hook fee on bid.
///      circFrac = 1 ALWAYS until vault; vault ref owner-settable (modularity), default none.
contract StonkzLadderAuction {
    using FixedPointMathLib for uint256;

    uint256 internal constant WAD = LadderConstants.WAD;

    // ─── immutables ───────────────────────────────────────────────────────
    uint256 public immutable supply;
    uint256 public immutable auctionSupply;
    uint256 public immutable floorMcap; // WAD dollars
    uint256 public immutable floorPrice; // WAD
    uint256 public immutable rungIntervalUsd; // WAD dollars
    uint256 public immutable duration; // seconds
    uint256 public immutable lpShareWad;
    uint256 public immutable lpHealthTargetWad;
    uint256 public immutable threshold; // WAD dollars = raiseRatio * floorMcap
    uint16 public immutable carveBps; // stamped — bps of raised
    uint16 public immutable cashHoldbackBps; // bps of raised
    uint16 public immutable sidePoolBps; // bps of LP-destined tokens
    uint16 public immutable walletCapBps; // bps of auction supply
    uint16 public immutable sizeBonusBps; // bps
    int256 public immutable alphaWad; // log2(1+beta) WAD
    uint16 public immutable maxUniqueActives;
    address public immutable pairToken; // address(0) = native
    address public immutable creator;
    address public immutable treasury;

    /// @notice Owner-settable vault reference for future circFrac exclusion. Default address(0) = none.
    address public circExclusionVault;

    // ─── schedule ─────────────────────────────────────────────────────────
    uint256[] public weights; // WAD fractions, length DESIGN_N
    uint16 public constant N = LadderConstants.DESIGN_N;

    // ─── live state ───────────────────────────────────────────────────────
    uint64 public startTime;
    uint16 public periodIndex; // periods completed (0..N); next clear is periodIndex+1
    uint256 public rung; // current rung k
    uint256 public price; // current price WAD
    uint256 public raised;
    uint256 public soldTokens;
    uint256 public committedTotal;
    bool public done;
    bool public graduated;

    uint16 public uniqueBidders;

    struct Wallet {
        uint256 committed; // total capital (weight base)
        uint256 spent;
        uint256 tokens;
        uint256 maxPrice;
        uint256 refundClaimable;
        bool exists;
        bool refundClaimed;
    }

    mapping(address => Wallet) public wallets;
    address[] public bidderList;

    // Path recording for differential harness (period → price at clear)
    mapping(uint16 => uint256) public pathPrice; // 1-indexed period
    mapping(uint16 => uint256) public pathSold;
    mapping(uint16 => uint256) public pathOffered;

    address public owner;

    event BidPlaced(address indexed wallet, uint256 size, uint256 maxPrice, uint16 period);
    event PeriodCleared(uint16 indexed period, uint256 price, uint256 offered, uint256 sold, uint256 rung);
    event AuctionDone(bool graduated, uint256 raised, uint256 clearingPrice);
    event CircExclusionVaultSet(address indexed vault);
    event RefundClaimed(address indexed wallet, uint256 amount);

    error MinBid();
    error MaxPriceBelowLive();
    error AuctionNotLive();
    error AuctionFinished();
    error TooManyUniques();
    error NothingToClaim();
    error NotOwner();
    error TransferFailed();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    struct Params {
        uint256 supply;
        uint256 auctionSupply;
        uint256 floorMcap;
        uint256 duration;
        uint256 lpShareWad;
        uint256 lpHealthTargetWad;
        uint16 carveBps;
        uint16 cashHoldbackBps;
        uint16 sidePoolBps;
        uint16 walletCapBps;
        uint16 sizeBonusBps;
        uint16 maxUniqueActives;
        address pairToken;
        address creator;
        address treasury;
    }

    constructor(Params memory p) {
        require(p.supply > 0 && p.auctionSupply > 0, "supply");
        require(p.duration > 0, "duration");
        require(p.carveBps <= LadderConstants.CARVE_BPS_MAX, "carve");
        require(
            p.walletCapBps >= LadderConstants.WALLET_CAP_BPS_MIN && p.walletCapBps <= LadderConstants.WALLET_CAP_BPS_MAX,
            "cap"
        );
        require(p.cashHoldbackBps <= LadderConstants.CASH_HOLDBACK_BPS_MAX, "cashHb");

        supply = p.supply;
        auctionSupply = p.auctionSupply;
        floorMcap = p.floorMcap;
        floorPrice = FixedPointMathLib.fullMulDiv(p.floorMcap, WAD, p.supply);
        rungIntervalUsd = LadderConstants.RUNG_INTERVAL_USD;
        duration = p.duration;
        lpShareWad = p.lpShareWad;
        lpHealthTargetWad = p.lpHealthTargetWad;
        threshold = FixedPointMathLib.fullMulDiv(p.floorMcap, LadderConstants.RAISE_RATIO_BPS, 10_000);
        carveBps = p.carveBps;
        cashHoldbackBps = p.cashHoldbackBps;
        sidePoolBps = p.sidePoolBps;
        walletCapBps = p.walletCapBps;
        sizeBonusBps = p.sizeBonusBps;
        alphaWad = p.sizeBonusBps == 0
            ? int256(0)
            : LadderConstants.ALPHA_WAD; // production beta=10%; vector sizeBonus drives Phase 2 pow
        // Store size-bonus for weight via runtime log2(1+b) when != default — see _weight.
        maxUniqueActives = p.maxUniqueActives;
        pairToken = p.pairToken;
        creator = p.creator;
        treasury = p.treasury;
        owner = msg.sender;

        weights = LadderWeights.makeWeights(N);
        price = floorPrice;
        rung = 0;
    }

    /// @notice Modularity: vault ref for future circFrac. Default address(0) → circFrac=1.
    function setCircExclusionVault(address vault) external onlyOwner {
        circExclusionVault = vault;
        emit CircExclusionVaultSet(vault);
    }

    function start() external {
        if (startTime != 0) revert AuctionFinished();
        startTime = uint64(block.timestamp);
    }

    /// @notice Place bid. Min $5. Reverts if maxPrice < live price. No cancel. Not a swap.
    function placeBid(uint256 size, uint256 maxPrice) external payable {
        _sync();
        if (done) revert AuctionFinished();
        if (startTime == 0) {
            startTime = uint64(block.timestamp);
        }
        if (size < LadderConstants.MIN_BID) revert MinBid();
        if (maxPrice < price) revert MaxPriceBelowLive();
        if (pairToken == address(0)) {
            if (msg.value != size) revert MinBid();
        }

        Wallet storage w = wallets[msg.sender];
        if (!w.exists) {
            if (maxUniqueActives != 0 && uniqueBidders >= maxUniqueActives) revert TooManyUniques();
            w.exists = true;
            uniqueBidders++;
            bidderList.push(msg.sender);
        }
        w.committed += size;
        if (maxPrice > w.maxPrice) w.maxPrice = maxPrice;
        committedTotal += size;

        emit BidPlaced(msg.sender, size, maxPrice, periodIndex);
    }

    /// @notice Advance clearing for elapsed rung periods (lazy catch-up).
    function poke() external {
        _sync();
    }

    function _sync() internal {
        if (startTime == 0 || done) return;
        uint256 target = LadderConstants.periodIndex(startTime, block.timestamp, duration);
        if (target > N) target = N;
        while (periodIndex < target) {
            _clearPeriod();
        }
        if (periodIndex >= N && !done) {
            _finalize();
        }
    }

    /// @dev Force-clear exactly one period (harness).
    function clearNextForTest() external {
        if (done) revert AuctionFinished();
        if (startTime == 0) startTime = uint64(block.timestamp);
        if (periodIndex >= N) {
            _finalize();
            return;
        }
        _clearPeriod();
        if (periodIndex >= N) _finalize();
    }

    /// @dev Clear all remaining periods in one call (harness) — avoids 1000× external-call overhead.
    function clearAllForTest() external {
        if (done) revert AuctionFinished();
        if (startTime == 0) startTime = uint64(block.timestamp);
        while (periodIndex < N) {
            _clearPeriod();
        }
        if (!done) _finalize();
    }

    function _clearPeriod() internal {
        uint16 next = periodIndex + 1; // 1-indexed
        uint256 offered = FixedPointMathLib.fullMulDiv(auctionSupply, weights[periodIndex], WAD);
        // Fast path: no live demand at current price → record zeros without O(actives) fill.
        uint256 sold;
        if (_anyLive(price)) {
            sold = _fill(offered, price);
        }

        pathPrice[next] = price;
        pathSold[next] = sold;
        pathOffered[next] = offered;
        emit PeriodCleared(next, price, offered, sold, rung);

        periodIndex = next;

        if (sold > 0) {
            uint256 live = _liveBudget(price);
            uint256 mm = LadderMath.mmax(floorMcap, lpShareWad, raised, live, lpHealthTargetWad);
            uint256 maxK = LadderMath.maxRung(mm, floorMcap, rungIntervalUsd);
            if (rung < maxK) {
                rung += 1;
                price = LadderMath.rungPrice(rung, floorMcap, rungIntervalUsd, supply);
            }
        }
    }

    function _anyLive(uint256 p) internal view returns (bool) {
        uint256 capTok = _walletCapTokens();
        uint256 n = bidderList.length;
        for (uint256 i; i < n; i++) {
            Wallet storage w = wallets[bidderList[i]];
            if (w.maxPrice < p) continue;
            if (w.committed <= w.spent) continue;
            if (w.tokens >= capTok) continue;
            return true;
        }
        return false;
    }

    function _walletCapTokens() internal view returns (uint256) {
        return FixedPointMathLib.fullMulDiv(auctionSupply, walletCapBps, 10_000);
    }

    function _liveBudget(uint256 p) internal view returns (uint256 live) {
        uint256 capTok = _walletCapTokens();
        uint256 n = bidderList.length;
        for (uint256 i; i < n; i++) {
            Wallet storage w = wallets[bidderList[i]];
            if (w.maxPrice < p) continue;
            uint256 unspent = w.committed - w.spent;
            if (unspent == 0) continue;
            uint256 remCap = capTok > w.tokens ? capTok - w.tokens : 0;
            live += LadderMath.walletLiveContribution(unspent, remCap, p);
        }
    }

    function _weight(uint256 capital) internal view returns (uint256) {
        if (sizeBonusBps == 0) return WAD; // equal split
        uint256 base = capital < WAD ? WAD : capital; // max(1, capital) in dollars WAD; $1 = 1e18
        // weight = base^alpha. alphaWad = log2(1.1) for 10% bonus.
        int256 alpha = alphaWad;
        if (sizeBonusBps != LadderConstants.SIZE_BONUS_BPS) {
            // alpha = log2(1 + beta) = ln(1+beta)/ln(2)
            uint256 onePlus = WAD + FixedPointMathLib.fullMulDiv(WAD, sizeBonusBps, 10_000);
            alpha = FixedPointMathLib.lnWad(int256(onePlus)) * 1e18 / FixedPointMathLib.lnWad(2 ether);
        }
        int256 w = FixedPointMathLib.powWad(int256(base), alpha);
        return uint256(w);
    }

    function _fill(uint256 offered, uint256 p) internal returns (uint256 sold) {
        if (offered == 0 || p == 0) return 0;
        uint256 capTok = _walletCapTokens();
        uint256 n = bidderList.length;

        // Gather actives into memory arrays (maxUniqueActives-bound).
        address[] memory addrs = new address[](n);
        uint256[] memory ws = new uint256[](n);
        uint256 m;
        for (uint256 i; i < n; i++) {
            address a = bidderList[i];
            Wallet storage w = wallets[a];
            if (w.maxPrice < p) continue;
            if (w.committed <= w.spent) continue;
            if (w.tokens >= capTok) continue;
            addrs[m] = a;
            ws[m] = _weight(w.committed);
            m++;
        }
        if (m == 0) return 0;

        uint256 remaining = offered;
        for (uint256 iter; iter < 32 && remaining > 0; iter++) {
            uint256 sumW;
            uint256 liveCount;
            for (uint256 i; i < m; i++) {
                Wallet storage w = wallets[addrs[i]];
                if (w.maxPrice < p) continue;
                uint256 unspent = w.committed - w.spent;
                if (unspent == 0) continue;
                if (w.tokens >= capTok) continue;
                sumW += ws[i];
                liveCount++;
            }
            if (liveCount == 0 || sumW == 0) break;

            uint256 used;
            for (uint256 i; i < m; i++) {
                Wallet storage w = wallets[addrs[i]];
                if (w.maxPrice < p) continue;
                uint256 unspent = w.committed - w.spent;
                if (unspent == 0) continue;
                uint256 remCap = capTok > w.tokens ? capTok - w.tokens : 0;
                if (remCap == 0) continue;

                uint256 share = FixedPointMathLib.fullMulDiv(remaining, ws[i], sumW);
                uint256 maxTokBudget = FixedPointMathLib.fullMulDiv(unspent, WAD, p);
                uint256 take = share;
                if (take > remCap) take = remCap;
                if (take > maxTokBudget) take = maxTokBudget;
                if (take == 0) continue;

                uint256 cost = FixedPointMathLib.fullMulDiv(take, p, WAD);
                // Keep cost <= unspent (rounding).
                if (cost > unspent) {
                    cost = unspent;
                    take = FixedPointMathLib.fullMulDiv(cost, WAD, p);
                    if (take == 0) continue;
                }
                w.tokens += take;
                w.spent += cost;
                sold += take;
                raised += cost;
                used += take;
            }
            if (used == 0) break;
            remaining = offered > sold ? offered - sold : 0;
        }
        soldTokens += sold;
    }

    function _finalize() internal {
        done = true;
        // Refund unspent
        uint256 n = bidderList.length;
        for (uint256 i; i < n; i++) {
            Wallet storage w = wallets[bidderList[i]];
            uint256 unspent = w.committed - w.spent;
            if (unspent > 0) w.refundClaimable += unspent;
        }
        // Gate: docs/09 §6
        // circFrac = 1 ALWAYS until vault verifiable (circExclusionVault is the future hook).
        if (circExclusionVault != address(0)) {
            // Reserved: vault-verified holdback exclusion (docs/10). No-op until vault ships.
        }
        uint256 poolCash = FixedPointMathLib.fullMulDiv(raised, lpShareWad, WAD);
        // lpHealth = poolCash / (circMcap - circStartMcap); circMcap = price * supply * circFrac
        uint256 circMcap = FixedPointMathLib.fullMulDiv(price, supply, WAD); // FDV with circFrac=1
        uint256 denom = circMcap > floorMcap ? circMcap - floorMcap : 0;
        uint256 lpHealth = denom == 0 ? 0 : FixedPointMathLib.fullMulDiv(poolCash, WAD, denom);
        bool raiseOk = raised >= threshold;
        bool healthOk = lpHealth >= lpHealthTargetWad; // floor == target for tier in vectors
        graduated = raiseOk && healthOk;
        emit AuctionDone(graduated, raised, price);
    }

    function claimRefund() external {
        Wallet storage w = wallets[msg.sender];
        uint256 amt = w.refundClaimable;
        if (amt == 0 || w.refundClaimed) revert NothingToClaim();
        w.refundClaimed = true;
        w.refundClaimable = 0;
        if (pairToken == address(0)) {
            (bool ok,) = msg.sender.call{value: amt}("");
            if (!ok) revert TransferFailed();
        }
        emit RefundClaimed(msg.sender, amt);
    }

    // ─── views ────────────────────────────────────────────────────────────

    function liveBudget() external view returns (uint256) {
        return _liveBudget(price);
    }

    function currentMmax() external view returns (uint256) {
        return LadderMath.mmax(floorMcap, lpShareWad, raised, _liveBudget(price), lpHealthTargetWad);
    }

    function raiseSplit()
        external
        view
        returns (uint256 toLP, uint256 toTreasury, uint256 toCreator)
    {
        toTreasury = FixedPointMathLib.fullMulDiv(raised, carveBps, 10_000);
        uint256 toCreatorGross = FixedPointMathLib.fullMulDiv(raised, cashHoldbackBps, 10_000);
        toLP = raised - toTreasury - toCreatorGross;
        toCreator = toCreatorGross;
    }

    function durationOfTier(LadderTypes.Tier t) external pure returns (uint256) {
        if (t == LadderTypes.Tier.God) return LadderConstants.GOD_DURATION;
        if (t == LadderTypes.Tier.H4) return LadderConstants.H4_DURATION;
        if (t == LadderTypes.Tier.Daily) return LadderConstants.DAILY_DURATION;
        return LadderConstants.ROAD_DURATION;
    }
}
