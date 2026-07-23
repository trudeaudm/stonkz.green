// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {IStonkzAuction} from "./IStonkzAuction.sol";
import {LadderWeights} from "./LadderWeights.sol";

/// @title StonkzAuction — Ladder Auction (spec §§1–7)
/// @notice Per-capita fills with size tilt, demand-gated price, three-phase release,
///         reserve top-ups, graduation-or-refund. Differential-tested vs reference/engine.js.
/// @dev Accounting: O(1) per-share accumulator (masterchef-style). Each address is one
///      weighted share (weight = committedCapital^α). Exits bucketed at price ticks.
///      poke() advances state lazily — empty-book catch-up is O(1); no wall-clock
///      per-block iteration over 100ms Robinhood Chain blocks. spec §§1–7.
contract StonkzAuction is IStonkzAuction {
    using FixedPointMathLib for uint256;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant MIN_BID = 10 * WAD; // 10 USDG — spec §2
    uint256 internal constant BID_FEE = WAD / 10; // flat per-bid fee — spec §2
    uint256 internal constant FLOOR_MCAP_MIN = 2000 * WAD;
    uint256 internal constant FLOOR_MCAP_MAX = 100_000 * WAD;

    // ─── immutables (spec §1) ─────────────────────────────────────────────
    uint256 public immutable totalSupply;
    uint256 public immutable launchSupply;
    uint256 public immutable auctionSupply;
    uint256 public immutable reserveInitial;
    uint256 public immutable floorPrice; // floorMcap / totalSupply
    uint256 public immutable floorMcapUsd;
    uint256 public immutable graduationUsd;
    uint64 public immutable durationBlocks;
    uint16 public immutable baseStepBps;
    uint16 public immutable walletCapBps;
    uint16 public immutable sizeBonusBps;
    uint16 public immutable lpShareBps;
    uint16 public immutable holdbackBps;
    uint16 public immutable kappaHundredths; // 130 = 1.3
    uint8 public immutable disposalMode;
    address public immutable pairToken;
    address public immutable creator;
    int256 public immutable alphaWad; // log2(1+sizeBonus) as WAD; 0 = pure per-capita

    // ─── schedule (spec §5) ───────────────────────────────────────────────
    uint256[] public weights; // WAD fractions, length = durationBlocks
    uint256[] public weightSuffix; // suffix[i] = Σ w[i..]
    uint256 public flatBase; // auctionSupply * w[0] / WAD (phase A cap)

    // ─── live state ───────────────────────────────────────────────────────
    uint64 public startBlock; // wall-clock block auction opened (0 = not started)
    uint64 public auctionIndex; // schedule cursor = blocks completed (S.block in engine)
    uint256 public price;
    uint256 public sold; // total tokens sold (auction + reserve top-ups)
    uint256 public raised; // USD raised
    uint256 public extraSold; // tokens sold from reserve (top-ups)
    uint256 public lastSoldPrice;
    bool public competition; // one-way ratchet — spec §5 phase A→B
    bool public done;
    bool public graduated;
    bool public settled;

    // MasterChef-style accumulator — tokens (WAD) per weight (WAD), scaled by WAD
    uint256 public accTokensPerWeight;
    uint256 public totalWeight;

    uint256 public nextPositionId;

    enum PosStatus {
        Active,
        OutPrice,
        OutBudget,
        Capped
    }

    struct Position {
        address owner;
        uint256 budget;
        uint256 maxPrice;
        uint256 spent;
        uint256 tokens;
        PosStatus status;
    }

    struct Bidder {
        uint256 weight; // committedCapital^α (WAD)
        uint256 rewardDebt; // accTokensPerWeight snapshot
        uint256 tokens; // harvested token total
        /// @dev Weight basis (spec §3): Σ FULL budgets of positions live at start of clear
        ///      (Active ∧ maxPrice ≥ price), after price-out, before fills. OutPrice /
        ///      OutBudget / Capped contribute 0 from their exit block onward (fill exits
        ///      apply from b+1). Distinct from demand basis `committedLive` (spec §4).
        uint256 activeBudget;
        uint256 activeSpent; // Σ spent of those live positions
        uint32 activeCount;
        bool capped;
        bool tracked;
    }

    mapping(uint256 => Position) public positions;
    mapping(address => Bidder) public bidders;
    mapping(address => uint256[]) internal _bidderPositions;

    /// @dev Active (in-the-money, uncapped) addresses for water-fill. Bounded by unique bidders.
    address[] public activeAddrs;
    mapping(address => uint256) internal _activeIdx; // 1-based index into activeAddrs

    // Escrow
    mapping(address => uint256) public claimableUsd; // priced-out / failed / leftover
    mapping(address => uint256) public claimableTokens; // filled tokens after graduate settle
    uint256 public totalEscrowed;

    // ─── constructor (spec §1, §7) ─────────────────────────────────────────
    constructor(Params memory p) {
        require(p.floorMcapUsd >= FLOOR_MCAP_MIN && p.floorMcapUsd <= FLOOR_MCAP_MAX, "floor mcap");
        require(p.durationBlocks >= 5, "duration");
        require(p.totalSupply > 0, "supply");
        // baseStep clamped >= 0 by uint16; explicit check for documentation (regression C)
        require(p.baseStepBps == p.baseStepBps, "step"); // tautology keeps clamp note; uint can't be <0

        totalSupply = p.totalSupply;
        floorMcapUsd = p.floorMcapUsd;
        floorPrice = FixedPointMathLib.mulDiv(p.floorMcapUsd, WAD, p.totalSupply);
        graduationUsd = p.graduationUsd;
        durationBlocks = p.durationBlocks;
        baseStepBps = p.baseStepBps;
        walletCapBps = p.walletCapBps;
        sizeBonusBps = p.sizeBonusBps;
        lpShareBps = p.lpShareBps;
        holdbackBps = p.holdbackBps;
        kappaHundredths = p.kappaHundredths == 0 ? 130 : p.kappaHundredths;
        disposalMode = p.disposalMode;
        pairToken = p.pairToken;
        creator = msg.sender;

        // launch supply after holdback — spec §0
        launchSupply = FixedPointMathLib.mulDiv(p.totalSupply, 10_000 - p.holdbackBps, 10_000);

        // auction:reserve = κ̂ : LP-share — NEVER an input (spec §1, §7)
        uint256 kappaW = (uint256(kappaHundredths) * WAD) / 100;
        uint256 lpWad = (uint256(p.lpShareBps) * WAD) / 10_000;
        // auctPct = kappa / (kappa + lpShare)
        uint256 auctWad = FixedPointMathLib.mulDiv(kappaW, WAD, kappaW + lpWad);
        auctionSupply = FixedPointMathLib.mulWad(launchSupply, auctWad);
        reserveInitial = launchSupply - auctionSupply;

        // α = log2(1 + size_bonus) — spec §3
        if (p.sizeBonusBps == 0) {
            alphaWad = 0;
        } else {
            // log2(x) = ln(x)/ln(2); size_bonus as fraction of 1
            int256 onePlus = int256(WAD + (uint256(p.sizeBonusBps) * WAD) / 10_000);
            alphaWad = FixedPointMathLib.lnWad(onePlus) * int256(WAD)
                / FixedPointMathLib.lnWad(2 * int256(WAD));
        }

        weights = LadderWeights.makeWeights(p.durationBlocks);
        weightSuffix = LadderWeights.suffixSums(weights);
        flatBase = FixedPointMathLib.mulWad(auctionSupply, weights[0]);
        price = floorPrice;

        // Raise-ceiling validation (spec §7): threshold must be ≤ ladder max raise
        uint256 ceiling = _raiseCeiling();
        require(p.graduationUsd <= ceiling, "threshold > raise ceiling");
    }

    /// @dev Max raise under full demand with base step only (conservative demand-scale ignored
    ///      as lower bound on ceiling; demand scaling only increases raise).
    function _raiseCeiling() internal view returns (uint256) {
        uint256 p = floorPrice;
        uint256 stepWad = WAD + (uint256(baseStepBps) * WAD) / 10_000;
        // With demand at graduation, step ≈ base*(1+1)=2×; use 2× base for headroom
        uint256 hotStep = WAD + (2 * uint256(baseStepBps) * WAD) / 10_000;
        if (hotStep < stepWad) hotStep = stepWad;
        uint256 raisedMax;
        uint256 N = durationBlocks;
        for (uint256 i = 0; i < N; i++) {
            uint256 q = FixedPointMathLib.mulWad(auctionSupply, weights[i]);
            raisedMax += FixedPointMathLib.mulWad(q, p);
            p = FixedPointMathLib.mulWad(p, hotStep);
        }
        return raisedMax;
    }

    // ─── external API ─────────────────────────────────────────────────────

    /// @inheritdoc IStonkzAuction
    function placeBid(uint256 budget, uint256 maxPrice) external payable returns (uint256 positionId) {
        require(!done, "done");
        require(budget >= MIN_BID, "min bid");
        require(maxPrice > 0, "max");
        require(msg.value >= budget + BID_FEE, "value");
        // Fee retained (protocol); never sponsor gas on bids — spec §2

        _startIfNeeded();
        _sync();

        positionId = ++nextPositionId;
        positions[positionId] = Position({
            owner: msg.sender,
            budget: budget,
            maxPrice: maxPrice,
            spent: 0,
            tokens: 0,
            status: PosStatus.Active
        });
        _bidderPositions[msg.sender].push(positionId);
        totalEscrowed += budget;

        Bidder storage b = bidders[msg.sender];
        if (!b.tracked) {
            b.tracked = true;
        }
        _harvest(msg.sender);

        // If already priced out at current price, mark immediately (claimable now)
        if (maxPrice < price) {
            positions[positionId].status = PosStatus.OutPrice;
            claimableUsd[msg.sender] += budget;
            emit PricedOut(msg.sender, positionId, budget, uint64(auctionIndex));
        } else if (!b.capped) {
            b.activeCount += 1;
            _setActiveBudget(msg.sender, b.activeBudget + budget, b.activeSpent);
            _ensureActive(msg.sender);
            // Competition ratchet: ONLY in _clearOneBlock after price-out (spec §5 / engine tick).
            // Do not set here — a bid arriving in the same wall block as a soon-to-be-priced-out
            // peer must not flip the flat→shallow gate before that peer is swept.
        }

        // Refund dust above budget+fee
        uint256 refund = msg.value - budget - BID_FEE;
        if (refund > 0) {
            (bool ok,) = msg.sender.call{value: refund}("");
            require(ok, "refund");
        }

        emit BidPlaced(msg.sender, positionId, budget, maxPrice, uint64(auctionIndex));
    }

    /// @inheritdoc IStonkzAuction
    function poke() external {
        _startIfNeeded();
        _sync();
    }

    /// @inheritdoc IStonkzAuction
    function claim(uint256 positionId) external {
        _sync();
        Position storage p = positions[positionId];
        require(p.owner == msg.sender, "owner");
        require(p.budget > 0, "claimed");
        _harvest(msg.sender);

        uint256 usd;
        uint256 tok = p.tokens;

        if (done && !graduated) {
            // Failure: full budget refund — invariants I5 / I8 (spec §7, §9)
            usd = p.budget;
            p.tokens = 0;
        } else if (p.status == PosStatus.OutPrice) {
            // Priced out: unspent claimable immediately — spec §3
            usd = p.budget - p.spent;
            if (!settled) tok = 0; // tokens stay until settle if any were filled
        } else if (done && graduated) {
            usd = p.budget - p.spent;
        } else if (p.status == PosStatus.Capped && done) {
            usd = p.budget - p.spent;
        } else {
            revert("not claimable");
        }

        totalEscrowed -= (done && !graduated) ? p.budget : (p.budget - p.spent);
        p.budget = 0;
        p.spent = 0;
        p.tokens = 0;

        if (usd > 0) {
            (bool ok,) = msg.sender.call{value: usd}("");
            require(ok, "usd");
        }
        if (tok > 0 && settled) {
            claimableTokens[msg.sender] += tok;
        }
    }

    /// @inheritdoc IStonkzAuction
    function ringBellEarly() external {
        require(msg.sender == creator, "creator");
        _sync();
        require(!done, "done");
        require(raised >= graduationUsd, "not graduated");
        emit BellRungEarly(creator, uint64(auctionIndex));
        _finish();
    }

    /// @inheritdoc IStonkzAuction
    function runAway() external {
        require(msg.sender == creator, "creator");
        require(!settled, "settled");
        _sync();
        // Pre-settlement cancel: mark failed so everyone can claim full budgets
        done = true;
        graduated = false;
        emit CreatorRanAway(creator, 0);
        emit Failed(raised, graduationUsd);
    }

    /// @inheritdoc IStonkzAuction
    function settle() external {
        _sync();
        require(done, "not done");
        require(!settled, "settled");
        settled = true;

        if (!graduated) {
            emit Failed(raised, graduationUsd);
            return;
        }

        // Settlement accounting (spec §8) — pool deploy is LiquidityStrategy's job;
        // here we lock conservation buckets for invariant I1 / I9.
        uint256 P = lastSoldPrice == 0 ? price : lastSoldPrice;
        uint256 lpFunds = FixedPointMathLib.mulDiv(raised, lpShareBps, 10_000);
        uint256 need = P == 0 ? 0 : FixedPointMathLib.mulDiv(lpFunds, WAD, P);
        uint256 rr = reserveRemaining();
        uint256 paired = need < rr ? need : rr;
        uint256 surplus = rr > need ? rr - need : 0;
        uint256 auctionExcess = auctionSupply > auctionSold() ? auctionSupply - auctionSold() : 0;

        emit Settled(paired, lpFunds, surplus, auctionExcess, disposalMode);

        uint256 avg = sold > 0 ? FixedPointMathLib.mulDiv(raised, WAD, sold) : P;
        uint256 realizedKappaBps = avg == 0 ? 0 : FixedPointMathLib.mulDiv(P, 10_000, avg);
        emit Graduated(raised, P, realizedKappaBps);
    }

    // ─── views (for differential tests) ───────────────────────────────────

    function auctionSold() public view returns (uint256) {
        return sold - extraSold;
    }

    function reserveRemaining() public view returns (uint256) {
        uint256 e = extraSold;
        return reserveInitial > e ? reserveInitial - e : 0;
    }

    function walletCapTokens() public view returns (uint256) {
        return FixedPointMathLib.mulDiv(totalSupply, walletCapBps, 10_000);
    }

    function kappaWad() public view returns (uint256) {
        return (uint256(kappaHundredths) * WAD) / 100;
    }

    function lpShareWad() public view returns (uint256) {
        return (uint256(lpShareBps) * WAD) / 10_000;
    }

    /// @notice Current block offer (sched + top-up) — mirrors offeredFor. Call after poke.
    function currentOffer() public view returns (uint256) {
        if (done || auctionIndex >= durationBlocks) return 0;
        return _offeredAt(auctionIndex, price, raised, auctionSold());
    }

    function currentSched() public view returns (uint256) {
        if (done || auctionIndex >= durationBlocks) return 0;
        return _schedAt(auctionIndex, auctionSold());
    }

    function bidderTokens(address who) external view returns (uint256) {
        // Task G: canonical token ledger is Σ position.tokens (not harvest accumulator).
        uint256[] storage ids = _bidderPositions[who];
        uint256 t;
        for (uint256 i = 0; i < ids.length; i++) {
            t += positions[ids[i]].tokens;
        }
        return t;
    }

    function positionCount(address who) external view returns (uint256) {
        return _bidderPositions[who].length;
    }

    function positionOf(address who, uint256 i) external view returns (uint256) {
        return _bidderPositions[who][i];
    }

    function activeAddressCount() external view returns (uint256) {
        return activeAddrs.length;
    }

    /// @notice Demand basis for step scaling (spec §4). Sum of FULL budgets of every
    ///         position EXCEPT OutPrice. All-in (OutBudget) and Capped capital still count.
    /// @dev Intentionally different from weight basis (`Bidder.activeBudget`). Updated
    ///      implicitly when `_priceOutBidder` / placeBid marks OutPrice — status is source of truth.
    function committedLive() public view returns (uint256) {
        uint256 t;
        uint256 n = nextPositionId;
        for (uint256 id = 1; id <= n; id++) {
            Position storage p = positions[id];
            if (p.budget == 0) continue;
            if (p.status != PosStatus.OutPrice) t += p.budget;
        }
        return t;
    }

    function effStepWad() public view returns (uint256) {
        uint256 base = (uint256(baseStepBps) * WAD) / 10_000; // as fraction
        uint256 d = graduationUsd == 0 ? 0 : FixedPointMathLib.mulDiv(committedLive(), WAD, graduationUsd);
        // effective_step multiplier = 1 + base*(1+d) → price *= that
        // engine: g = 1+baseStepPct/100; return 1+(g-1)*(1+d) = 1+base*(1+d)
        return WAD + FixedPointMathLib.mulWad(base, WAD + d);
    }

    // ─── sync / poke core ─────────────────────────────────────────────────

    function _startIfNeeded() internal {
        if (startBlock == 0) {
            startBlock = uint64(block.number);
        }
    }

    /// @dev Advance auctionIndex to match wall-clock. Empty book ⇒ O(1) jump (spec: 100ms blocks).
    function _sync() internal {
        if (done || startBlock == 0) return;
        uint256 target = block.number - uint256(startBlock);
        if (target > durationBlocks) target = durationBlocks;

        // Fast path: no active weight — schedule cursor jumps; price frozen; supply unsold (squish later)
        if (totalWeight == 0) {
            if (uint256(auctionIndex) < target) {
                auctionIndex = uint64(target);
            }
            if (auctionIndex >= durationBlocks) _finish();
            return;
        }

        // Process pending auction blocks. Each clear is O(actives) water-fill;
        // wall-clock empty stretches are handled by the fast path above.
        uint256 guard;
        while (uint256(auctionIndex) < target && !done && guard++ < durationBlocks) {
            _clearOneBlock();
        }
    }

    /// @dev One auction block — differential twin of reference `tick()`.
    ///      Weight basis: price-out applies BEFORE fills; OutBudget/cap exits from this
    ///      clear apply to weight from block b+1 (re-snapshot at end of clear).
    function _clearOneBlock() internal {
        uint256 b = auctionIndex;
        require(b < durationBlocks, "past");
        uint256 px = price;

        // 1. Price-outs at this tick — weight basis updates immediately (spec §3)
        _priceOutAt(px);

        // 2. Competition ratchet AFTER price-out (reference tick order — spec §5)
        if (!competition && activeAddrs.length > 1) {
            competition = true;
        }

        uint256 offered = _offeredAt(b, px, raised, auctionSold());
        uint256 cap = walletCapTokens();

        // 3. Harvest, then snapshot weight basis for this clear (reference per-block snaps)
        address[] memory snap = activeAddrs;
        uint256 n = snap.length;
        for (uint256 i = 0; i < n; i++) {
            _harvest(snap[i]);
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

        // Dust exhaustion AFTER snap (engine runs exhaustion before distribute, so a
        // position that hit spent≈budget last clear still participates in THIS clear's
        // snap, then is marked OutBudget for storage / next clear).
        for (uint256 i = 0; i < n; i++) {
            _dustExhaustPositions(snap[i]);
            _refreshWeightBasisOnly(snap[i]);
        }

        uint256 remaining = offered;
        uint256 blockRaised; // Task F: accumulate actual fill costs (not mulWad(soldNow, px))
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
                    // Canonical ledger (Task G): position accounting is source of truth.
                    (uint256 gotTok, uint256 cost) = _distributeToPositions(who, take, px);
                    if (gotTok > 0) {
                        bd.tokens += gotTok;
                        bd.activeSpent += cost;
                        snapTok[i] += gotTok;
                        snapSpent[i] += cost;
                        bd.rewardDebt = accTokensPerWeight;
                        used += gotTok;
                        blockRaised += cost;
                        emit Filled(who, gotTok, cost, px, uint64(b));
                    }
                }

                if (take + 1 < share) {
                    // Constrained — drop from further iters this clear (engine snap.status).
                    alive[i] = false;
                    if (capLeft <= budTok) {
                        // Cap: mark positions this clear (engine post-distribute cap_hit path).
                        _markCapped(who);
                    }
                    // bud_hit: do NOT mark positions OutBudget here — engine only flips
                    // snap.status; positions stay active until distribute/exhaustion so the
                    // next clear's weight-basis snap still sees fully-spent live budgets.
                }
            }
            remaining -= used;
            if (used == 0) break;
        }

        // Cap / all-in / distribute OutBudget → refresh storage for b+1.
        // Do NOT dust-mark here: same-clear spending stays Active until next clear's post-snap exhaust.
        for (uint256 i = 0; i < n; i++) {
            _refreshWeightBasisOnly(snap[i]);
        }

        uint256 soldNow = offered - remaining;
        uint256 schedQty = _schedAt(b, auctionSold());
        uint256 gate = schedQty;
        uint256 wSched = FixedPointMathLib.mulWad(weights[b], auctionSupply);
        if (gate > wSched) gate = wSched;

        bool fullySold = gate > 0 && soldNow + _gateTol(gate) >= gate;

        sold += soldNow;
        // Task F: raised tracks Σ fill costs (same mulWad as charges), not mulWad(soldNow, px)
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

        // End conditions
        if (auctionSold() + 1 >= auctionSupply && _offeredAt(auctionIndex, price, raised, auctionSold()) == 0
                && raised >= graduationUsd) {
            _finish();
        } else if (auctionIndex >= durationBlocks) {
            _finish();
        }
    }

    function _gateTol(uint256 gate) internal pure returns (uint256) {
        // engine: max(1e-12, gate*1e-9) — relative 1ppb floor
        uint256 rel = gate / 1e9;
        return rel > 0 ? rel : 1;
    }

    function _effStepWadCached() internal view returns (uint256) {
        // Demand basis = committedLive (excludes OutPrice only) — not weight basis.
        return effStepWad();
    }

    function _priceOutAt(uint256 px) internal {
        address[] memory snap = activeAddrs;
        for (uint256 i = 0; i < snap.length; i++) {
            _priceOutBidder(snap[i], px);
        }
    }

    function _priceOutBidder(address who, uint256 px) internal {
        uint256[] storage ids = _bidderPositions[who];
        Bidder storage b = bidders[who];
        _harvest(who);
        for (uint256 i = 0; i < ids.length; i++) {
            Position storage p = positions[ids[i]];
            if (p.status == PosStatus.Active && p.maxPrice < px) {
                p.status = PosStatus.OutPrice;
                uint256 left = p.budget - p.spent;
                claimableUsd[who] += left;
                // Weight basis: drop full budget immediately (before this block's fills)
                if (b.activeBudget >= p.budget) b.activeBudget -= p.budget;
                else b.activeBudget = 0;
                if (b.activeSpent >= p.spent) b.activeSpent -= p.spent;
                else b.activeSpent = 0;
                if (b.activeCount > 0) b.activeCount -= 1;
                emit PricedOut(who, ids[i], left, uint64(auctionIndex));
            }
        }
        _reweight(who);
        if (b.activeCount == 0) _removeActive(who);
    }

    /// @dev Equal water-fill across Active positions — spec §2.
    ///      Returns tokens actually placed and USD spent (canonical ledger — Task G).
    function _distributeToPositions(address who, uint256 dTok, uint256 px)
        internal
        returns (uint256 tokOut, uint256 spentOut)
    {
        uint256[] storage ids = _bidderPositions[who];
        uint256 d = dTok;
        for (uint256 it = 0; it < 6 && d > 0; it++) {
            uint256 live;
            for (uint256 i = 0; i < ids.length; i++) {
                if (positions[ids[i]].status == PosStatus.Active) live++;
            }
            if (live == 0) break;
            uint256 per = d / live;
            uint256 used;
            for (uint256 i = 0; i < ids.length; i++) {
                Position storage p = positions[ids[i]];
                if (p.status != PosStatus.Active) continue;
                uint256 budLeft = p.budget > p.spent ? p.budget - p.spent : 0;
                uint256 budTok = FixedPointMathLib.mulDiv(budLeft, WAD, px);
                uint256 take = per < budTok ? per : budTok;
                if (take == 0) continue;
                uint256 cost = FixedPointMathLib.mulWad(take, px);
                // Cap cost to budLeft so spent never exceeds budget (floor dust).
                if (cost > budLeft) cost = budLeft;
                p.tokens += take;
                p.spent += cost;
                tokOut += take;
                spentOut += cost;
                used += take;
                if (take < per) {
                    p.status = PosStatus.OutBudget;
                    emit AllIn(who, ids[i], uint64(auctionIndex));
                }
            }
            d -= used;
            if (used == 0) break;
        }
    }

    /// @dev Mark wallet-cap exit; weight basis refreshed at end of clear (effective b+1).
    function _markCapped(address who) internal {
        Bidder storage b = bidders[who];
        if (b.capped) return;
        b.capped = true;
        uint256[] storage ids = _bidderPositions[who];
        for (uint256 i = 0; i < ids.length; i++) {
            Position storage p = positions[ids[i]];
            if (p.status == PosStatus.Active) {
                p.status = PosStatus.Capped;
            }
        }
        emit Capped(who, uint64(auctionIndex));
    }

    /// @dev Address-level budget hit: all live positions → OutBudget (basis at end of clear).
    function _markAllIn(address who) internal {
        uint256[] storage ids = _bidderPositions[who];
        for (uint256 j = 0; j < ids.length; j++) {
            Position storage pos = positions[ids[j]];
            if (pos.status == PosStatus.Active) {
                pos.status = PosStatus.OutBudget;
                emit AllIn(who, ids[j], uint64(auctionIndex));
            }
        }
    }

    /// @dev Mark fully-spent Active positions OutBudget (engine exhaustion: bud−spent ≤ 1e-9 USD).
    ///      1e-9 USD in WAD = 1e9 wei.
    function _dustExhaustPositions(address who) internal {
        uint256[] storage ids = _bidderPositions[who];
        for (uint256 i = 0; i < ids.length; i++) {
            Position storage p = positions[ids[i]];
            if (p.status == PosStatus.Active && p.budget <= p.spent + 1e9) {
                p.status = PosStatus.OutBudget;
                emit AllIn(who, ids[i], uint64(auctionIndex));
            }
        }
    }

    /// @dev Recompute weight basis from remaining Active positions (spec §3).
    function _refreshWeightBasisOnly(address who) internal {
        Bidder storage b = bidders[who];
        uint256[] storage ids = _bidderPositions[who];

        if (b.capped) {
            b.activeBudget = 0;
            b.activeSpent = 0;
            b.activeCount = 0;
            _reweight(who);
            _removeActive(who);
            return;
        }

        uint256 ab;
        uint256 as_;
        uint32 ac;
        for (uint256 i = 0; i < ids.length; i++) {
            Position storage p = positions[ids[i]];
            if (p.status == PosStatus.Active) {
                ab += p.budget;
                as_ += p.spent;
                ac++;
            }
        }
        b.activeBudget = ab;
        b.activeSpent = as_;
        b.activeCount = ac;
        _reweight(who);
        if (ac == 0) _removeActive(who);
        else _ensureActive(who);
    }

    function _finish() internal {
        if (done) return;
        done = true;
        graduated = raised >= graduationUsd;
        if (graduated) {
            // Graduated event emitted at settle with kappa
        } else {
            emit Failed(raised, graduationUsd);
        }
    }

    // ─── weight / active-set / harvest ────────────────────────────────────

    function _setActiveBudget(address who, uint256 ab, uint256 as_) internal {
        Bidder storage b = bidders[who];
        b.activeBudget = ab;
        b.activeSpent = as_;
        _reweight(who);
    }

    function _reweight(address who) internal {
        Bidder storage b = bidders[who];
        _harvest(who);
        uint256 oldW = b.weight;
        uint256 newW;
        if (b.activeCount == 0 || b.capped || b.activeBudget == 0) {
            newW = 0;
        } else {
            newW = _weightOf(b.activeBudget);
        }
        if (oldW != newW) {
            totalWeight = totalWeight - oldW + newW;
            b.weight = newW;
            b.rewardDebt = FixedPointMathLib.mulDiv(newW, accTokensPerWeight, WAD);
        }
    }

    function _weightOf(uint256 capital) internal view returns (uint256) {
        if (alphaWad == 0) return WAD; // pure per-capita — one share
        uint256 c = capital < WAD ? WAD : capital; // max(1, bud) in dollar-WAD terms; engine uses max(1,bud) in $
        // Engine budgets are raw dollars (100); our budgets are 100e18. powWad expects WAD-scaled base.
        // weight = (capital/WAD)^α * WAD  → use powWad(capital, alpha) but capital already WAD-scaled:
        // powWad(100e18, α) = 100^α * 1e18. Good for relative ratios.
        int256 w = FixedPointMathLib.powWad(int256(c), alphaWad);
        require(w > 0, "weight");
        return uint256(w);
    }

    function _harvest(address who) internal {
        // Task G: fills live on positions only — accumulator debt is kept coherent for
        // weight changes but must not mint phantom bidder.tokens.
        Bidder storage b = bidders[who];
        b.rewardDebt = FixedPointMathLib.mulDiv(b.weight, accTokensPerWeight, WAD);
    }

    function _pendingTokens(address who) internal view returns (uint256) {
        Bidder storage b = bidders[who];
        if (b.weight == 0) return 0;
        uint256 accrued = FixedPointMathLib.mulDiv(b.weight, accTokensPerWeight, WAD);
        return accrued > b.rewardDebt ? accrued - b.rewardDebt : 0;
    }

    function _ensureActive(address who) internal {
        if (_activeIdx[who] != 0) return;
        if (bidders[who].activeCount == 0 || bidders[who].capped) return;
        activeAddrs.push(who);
        _activeIdx[who] = activeAddrs.length; // 1-based
    }

    function _removeActive(address who) internal {
        uint256 idx = _activeIdx[who];
        if (idx == 0) return;
        uint256 last = activeAddrs.length;
        if (idx != last) {
            address moved = activeAddrs[last - 1];
            activeAddrs[idx - 1] = moved;
            _activeIdx[moved] = idx;
        }
        activeAddrs.pop();
        _activeIdx[who] = 0;
        // Zero weight contribution
        Bidder storage b = bidders[who];
        if (b.weight > 0) {
            _harvest(who);
            totalWeight -= b.weight;
            b.weight = 0;
            b.rewardDebt = 0;
        }
    }

    // ─── schedule / offer (spec §5, §6) ───────────────────────────────────

    function _schedAt(uint256 b, uint256 aSold) internal view returns (uint256) {
        if (b >= durationBlocks) return 0;
        uint256 rem = auctionSupply > aSold ? auctionSupply - aSold : 0;
        if (rem == 0) return 0;
        uint256 ws = weightSuffix[b];
        if (ws == 0) return 0;
        uint256 q = FixedPointMathLib.mulDiv(rem, weights[b], ws);
        // Flat cap until competition — use preview so views match the next clear
        // (price-out may drop peers that placeBid already added to activeAddrs).
        if (!_previewCompetition()) {
            if (q > flatBase) q = flatBase;
        }
        return q < rem ? q : rem;
    }

    /// @dev Spec §5 / engine: competition after price-out count of active addresses > 1.
    ///      Storage ratchet is one-way; preview also treats "would survive price-out now".
    function _previewCompetition() internal view returns (bool) {
        if (competition) return true;
        uint256 n;
        address[] memory snap = activeAddrs;
        for (uint256 i = 0; i < snap.length; i++) {
            if (_survivesPriceOut(snap[i], price)) {
                unchecked {
                    n++;
                }
                if (n > 1) return true;
            }
        }
        return false;
    }

    /// @dev True if `who` has ≥1 Active position with maxPrice ≥ px (and not capped).
    function _survivesPriceOut(address who, uint256 px) internal view returns (bool) {
        Bidder storage b = bidders[who];
        if (b.capped || b.activeCount == 0) return false;
        uint256[] storage ids = _bidderPositions[who];
        for (uint256 i = 0; i < ids.length; i++) {
            Position storage p = positions[ids[i]];
            if (p.status == PosStatus.Active && p.maxPrice >= px) return true;
        }
        return false;
    }

    function _offeredAt(uint256 b, uint256 px, uint256 raised_, uint256 aSold)
        internal
        view
        returns (uint256)
    {
        uint256 sched = _schedAt(b, aSold);
        uint256 topup;
        if (graduationUsd > 0 && raised_ >= graduationUsd) {
            uint256 rr = reserveInitial > extraSold ? reserveInitial - extraSold : 0;
            if (rr > 0 && px > 0) {
                // Task F: ceil need/headroom → conservative slack (never understate reserve need)
                uint256 needNow = FixedPointMathLib.mulDivUp(raised_, lpShareBps, 10_000);
                needNow = FixedPointMathLib.mulDivUp(needNow, WAD, px);
                uint256 remSched = auctionSupply > aSold ? auctionSupply - aSold : 0;
                uint256 futureNeed = FixedPointMathLib.mulDivUp(remSched, lpShareBps, 10_000);
                futureNeed = FixedPointMathLib.mulDivUp(futureNeed, WAD, kappaWad());
                uint256 guard = needNow + futureNeed;
                uint256 slack = rr > guard ? rr - guard : 0;
                // drainable floors — sell less from reserve if anything
                uint256 drain = FixedPointMathLib.mulDiv(slack, WAD, WAD + lpShareWad());
                if (drain > rr) drain = rr;
                uint256 ws = b < weightSuffix.length ? weightSuffix[b] : 0;
                if (ws > 0 && b < weights.length) {
                    topup = FixedPointMathLib.mulDiv(drain, weights[b], ws);
                }
            }
        }
        return sched + topup;
    }

    // receive rebates / keep fee balance
    receive() external payable {}
}
