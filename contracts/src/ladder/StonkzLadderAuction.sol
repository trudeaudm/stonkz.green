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
///      circFrac = 1 - holdbackBps/1e4 when holdbackBps > 0, else 1 (David 2026-08-08 ruling).
///      Holdback is VAULT-only; TAKE removed.
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
    uint256 public immutable circFrac; // WAD fraction
    uint256 public immutable threshold; // WAD dollars = raiseRatio * floorMcap
    uint16 public immutable carveBps; // stamped — bps of raised
    uint16 public immutable cashHoldbackBps; // bps of raised
    uint16 public immutable holdbackBps; // bps of total supply → vault
    uint16 public immutable sidePoolBps; // bps of LP-destined tokens
    uint16 public immutable walletCapBps; // bps of auction supply
    uint16 public immutable sizeBonusBps; // bps
    int256 public immutable alphaWad; // log2(1+beta) WAD
    uint16 public immutable maxUniqueActives;
    LadderConstants.HoldbackDelivery public immutable holdbackDelivery;
    LadderTypes.Tier public immutable tier;
    address public immutable pairToken; // address(0) = native
    address public immutable creator;
    address public immutable treasury;
    /// @notice Stamped vault at filing. address(0) only when holdbackBps == 0.
    address public immutable vaultRef;

    // ─── schedule ─────────────────────────────────────────────────────────
    uint256[] public weights; // WAD fractions, length DESIGN_N
    uint16 public constant N = LadderConstants.DESIGN_N;

    // ─── live state ───────────────────────────────────────────────────────
    uint64 public startTime;
    uint16 public periodIndex; // periods completed (0..N)
    uint256 public rung;
    uint256 public price;
    uint256 public raised;
    uint256 public soldTokens;
    uint256 public committedTotal;
    bool public done;
    bool public graduated;
    bool public holdbackDeposited;
    uint16 public uniqueBidders;

    struct Wallet {
        uint256 committed;
        uint256 spent;
        uint256 tokens;
        uint256 maxPrice;
        uint256 refundClaimable;
        bool exists;
        bool refundClaimed;
    }

    mapping(address => Wallet) public wallets;
    address[] public bidderList;

    mapping(uint16 => uint256) public pathPrice;
    mapping(uint16 => uint256) public pathSold;
    mapping(uint16 => uint256) public pathOffered;

    address public owner;

    event BidPlaced(address indexed wallet, uint256 size, uint256 maxPrice, uint16 period);
    event PeriodCleared(uint16 indexed period, uint256 price, uint256 offered, uint256 sold, uint256 rung);
    event AuctionDone(bool graduated, uint256 raised, uint256 clearingPrice);
    event HoldbackDeposited(address indexed vault, uint256 amount);
    event RefundClaimed(address indexed wallet, uint256 amount);

    error MinBid();
    error MaxPriceBelowLive();
    error AuctionFinished();
    error TooManyUniques();
    error NothingToClaim();
    error NotOwner();
    error TransferFailed();
    error VaultRequiredForHoldback();
    error HoldbackCeiling();
    error TakeRemoved();
    error NotGraduated();
    error HoldbackAlreadyDeposited();
    error VaultUnsetAtSettlement();

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
        uint16 holdbackBps; // bps of total supply
        LadderConstants.HoldbackDelivery holdbackDelivery;
        LadderTypes.Tier tier;
        uint16 sidePoolBps;
        uint16 walletCapBps;
        uint16 sizeBonusBps;
        uint16 maxUniqueActives;
        address pairToken;
        address creator;
        address treasury;
        address vaultRef; // stamped from factory
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

        // Holdback: NONE or VAULT only; availability + ceiling guards.
        if (uint8(p.holdbackDelivery) > uint8(LadderConstants.HoldbackDelivery.Vault)) revert TakeRemoved();
        if (p.holdbackBps > 0) {
            if (p.vaultRef == address(0)) revert VaultRequiredForHoldback();
            if (p.holdbackDelivery != LadderConstants.HoldbackDelivery.Vault) revert VaultRequiredForHoldback();
            if (p.holdbackBps > LadderConstants.holdbackCeilingBps(uint8(p.tier))) revert HoldbackCeiling();
        }

        supply = p.supply;
        auctionSupply = p.auctionSupply;
        floorMcap = p.floorMcap;
        floorPrice = FixedPointMathLib.fullMulDiv(p.floorMcap, WAD, p.supply);
        rungIntervalUsd = LadderConstants.RUNG_INTERVAL_USD;
        duration = p.duration;
        lpShareWad = p.lpShareWad;
        lpHealthTargetWad = p.lpHealthTargetWad;
        holdbackBps = p.holdbackBps;
        holdbackDelivery = p.holdbackBps == 0 ? LadderConstants.HoldbackDelivery.None : p.holdbackDelivery;
        circFrac = LadderMath.circFracWad(p.holdbackBps);
        tier = p.tier;
        vaultRef = p.vaultRef;
        threshold = FixedPointMathLib.fullMulDiv(p.floorMcap, LadderConstants.RAISE_RATIO_BPS, 10_000);
        carveBps = p.carveBps;
        cashHoldbackBps = p.cashHoldbackBps;
        sidePoolBps = p.sidePoolBps;
        walletCapBps = p.walletCapBps;
        sizeBonusBps = p.sizeBonusBps;
        alphaWad = p.sizeBonusBps == 0 ? int256(0) : LadderConstants.ALPHA_WAD;
        maxUniqueActives = p.maxUniqueActives;
        pairToken = p.pairToken;
        creator = p.creator;
        treasury = p.treasury;
        owner = msg.sender;

        weights = LadderWeights.makeWeights(N);
        price = floorPrice;
        rung = 0;
    }

    function start() external {
        if (startTime != 0) revert AuctionFinished();
        startTime = uint64(block.timestamp);
    }

    /// @notice Place bid. Min $5. Reverts if maxPrice < live price. No cancel. Not a swap.
    function placeBid(uint256 size, uint256 maxPrice) external payable {
        _sync();
        if (done) revert AuctionFinished();
        if (startTime == 0) startTime = uint64(block.timestamp);
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
        if (periodIndex >= N && !done) _finalize();
    }

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

    function clearAllForTest() external {
        if (done) revert AuctionFinished();
        if (startTime == 0) startTime = uint64(block.timestamp);
        while (periodIndex < N) {
            _clearPeriod();
        }
        if (!done) _finalize();
    }

    function _clearPeriod() internal {
        uint16 next = periodIndex + 1;
        uint256 offered = FixedPointMathLib.fullMulDiv(auctionSupply, weights[periodIndex], WAD);
        uint256 sold;
        if (_anyLive(price)) sold = _fill(offered, price);

        pathPrice[next] = price;
        pathSold[next] = sold;
        pathOffered[next] = offered;
        emit PeriodCleared(next, price, offered, sold, rung);
        periodIndex = next;

        if (sold > 0) {
            uint256 live = _liveBudget(price);
            uint256 mm = LadderMath.mmax(floorMcap, lpShareWad, raised, live, lpHealthTargetWad, circFrac);
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
        if (sizeBonusBps == 0) return WAD;
        uint256 base = capital < WAD ? WAD : capital;
        int256 alpha = alphaWad;
        if (sizeBonusBps != LadderConstants.SIZE_BONUS_BPS) {
            uint256 onePlus = WAD + FixedPointMathLib.fullMulDiv(WAD, sizeBonusBps, 10_000);
            alpha = FixedPointMathLib.lnWad(int256(onePlus)) * 1e18 / FixedPointMathLib.lnWad(2 ether);
        }
        return uint256(FixedPointMathLib.powWad(int256(base), alpha));
    }

    function _fill(uint256 offered, uint256 p) internal returns (uint256 sold) {
        if (offered == 0 || p == 0) return 0;
        uint256 capTok = _walletCapTokens();
        uint256 n = bidderList.length;

        address[] memory addrs = new address[](n);
        uint256[] memory ws = new uint256[](n);
        uint256 m;
        for (uint256 i; i < n; i++) {
            address a = bidderList[i];
            Wallet storage w = wallets[a];
            if (w.maxPrice < p || w.committed <= w.spent || w.tokens >= capTok) continue;
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
                if (w.maxPrice < p || w.committed <= w.spent || w.tokens >= capTok) continue;
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
        uint256 n = bidderList.length;
        for (uint256 i; i < n; i++) {
            Wallet storage w = wallets[bidderList[i]];
            uint256 unspent = w.committed - w.spent;
            if (unspent > 0) w.refundClaimable += unspent;
        }
        // Gate: raised >= 0.6*startMcap AND lpHealth >= tierFloor
        // lpHealth = poolCash / (circMcap - circStart); circMcap = FDV * circFrac
        uint256 poolCash = FixedPointMathLib.fullMulDiv(raised, lpShareWad, WAD);
        uint256 fdv = FixedPointMathLib.fullMulDiv(price, supply, WAD);
        uint256 circMcap = FixedPointMathLib.fullMulDiv(fdv, circFrac, WAD);
        uint256 circStart = FixedPointMathLib.fullMulDiv(floorMcap, circFrac, WAD);
        uint256 denom = circMcap > circStart ? circMcap - circStart : 0;
        uint256 lpHealth = denom == 0 ? 0 : FixedPointMathLib.fullMulDiv(poolCash, WAD, denom);
        graduated = (raised >= threshold) && (lpHealth >= lpHealthTargetWad);
        emit AuctionDone(graduated, raised, price);
    }

    /// @notice Deposit holdbackPct × supply tokens to the stamped vault. Belt-and-braces vault check.
    /// @dev Caller must have pre-funded this contract with the token amount (or mint path in Phase 3).
    function depositHoldback(address token) external {
        if (!done || !graduated) revert NotGraduated();
        if (holdbackBps == 0) revert NothingToClaim();
        if (holdbackDeposited) revert HoldbackAlreadyDeposited();
        if (vaultRef == address(0)) revert VaultUnsetAtSettlement();
        uint256 amt = FixedPointMathLib.fullMulDiv(supply, holdbackBps, 10_000);
        holdbackDeposited = true;
        _safeTransfer(token, vaultRef, amt);
        emit HoldbackDeposited(vaultRef, amt);
    }

    function holdbackAmount() external view returns (uint256) {
        return FixedPointMathLib.fullMulDiv(supply, holdbackBps, 10_000);
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

    function _safeTransfer(address token, address to, uint256 amt) internal {
        (bool ok, bytes memory data) = token.call(abi.encodeWithSignature("transfer(address,uint256)", to, amt));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    // ─── views ────────────────────────────────────────────────────────────

    function liveBudget() external view returns (uint256) {
        return _liveBudget(price);
    }

    function currentMmax() external view returns (uint256) {
        return LadderMath.mmax(floorMcap, lpShareWad, raised, _liveBudget(price), lpHealthTargetWad, circFrac);
    }

    function raiseSplit() external view returns (uint256 toLP, uint256 toTreasury, uint256 toCreator) {
        toTreasury = FixedPointMathLib.fullMulDiv(raised, carveBps, 10_000);
        toCreator = FixedPointMathLib.fullMulDiv(raised, cashHoldbackBps, 10_000);
        toLP = raised - toTreasury - toCreator;
    }

    function fillOf(address wallet) external view returns (uint256 committed, uint256 spent, uint256 tokens, uint256 refund) {
        Wallet storage w = wallets[wallet];
        committed = w.committed;
        spent = w.spent;
        tokens = w.tokens;
        refund = w.committed > w.spent ? w.committed - w.spent : 0;
        if (done && w.refundClaimable > 0 && !w.refundClaimed) refund = w.refundClaimable;
    }
}
