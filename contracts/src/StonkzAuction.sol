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
    uint32 public immutable epochSeconds; // wall seconds per auction block (Task N)
    uint16 public immutable maxClearsPerSync; // E1 overflow valve (default 64)
    uint16 public immutable maxUniqueActives; // guarded launch; 0 = unlimited (Task R)
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
    /// @dev Task Q': false = lazy accumulator fills (production); true = legacy eager writes.
    bool public immutable eagerFills;

    // ─── schedule (spec §5) ───────────────────────────────────────────────
    uint256[] public weights; // WAD fractions, length = durationBlocks
    uint256[] public weightSuffix; // suffix[i] = Σ w[i..]
    uint256 public flatBase; // auctionSupply * w[0] / WAD (phase A cap)

    // ─── live state ───────────────────────────────────────────────────────
    uint64 public startTime; // wall timestamp auction opened (0 = not started)
    uint64 public auctionIndex; // schedule cursor = auction blocks completed (S.block in engine)
    uint256 public price;
    uint256 public sold; // total tokens sold (auction + reserve top-ups)
    uint256 public raised; // USD raised
    uint256 public extraSold; // tokens sold from reserve (top-ups)
    uint256 public lastSoldPrice;
    bool public competition; // one-way ratchet — spec §5 phase A→B
    bool public done;
    bool public graduated;
    bool public settled;

    // MasterChef-style accumulators — tokens/USD (WAD) per weight (WAD), scaled by WAD.
    // Token acc uses extra ACC_PREC so floor(w·ΔaccT) stays within Task S D-bound.
    uint256 internal constant ACC_PREC = 1e18;
    uint256 public accTokensPerWeight;
    uint256 public accUsdPerWeight; // Task Q': lazy spent twin (WAD scale — see STOP note)
    uint256 public totalWeight;

    uint256 public nextPositionId;
    /// @dev Distinct addresses that have placed ≥1 bid (Task R cap accounting).
    uint16 public uniqueBidders;

    enum PosStatus {
        Active,
        OutPrice,
        OutBudget,
        Capped
    }

    struct Position {
        address owner;
        uint256 budget; // committed USD; never zeroed (lifecycle via flags)
        uint256 maxPrice;
        uint256 spent;
        uint256 tokens; // survives pre-settle USD claim (Task M)
        PosStatus status;
        bool usdClaimed;
        bool tokensClaimed;
        /// @dev Auction index when position became Active (Task S D-bound).
        uint64 enteredAt;
    }

    struct Bidder {
        uint256 weight; // committedCapital^α (WAD)
        uint256 rewardDebt; // weight * accTokensPerWeight / WAD at last materialize
        uint256 usdDebt; // weight * accUsdPerWeight / WAD at last materialize
        uint256 tokens; // materialized token total (excl. pending acc)
        /// @dev Weight basis (spec §3): Σ FULL budgets of positions live at start of clear
        ///      (Active ∧ maxPrice ≥ price), after price-out, before fills. OutPrice /
        ///      OutBudget / Capped contribute 0 from their exit block onward (fill exits
        ///      apply from b+1). Distinct from demand basis `committedLive` (spec §4).
        uint256 activeBudget;
        uint256 activeSpent; // Σ spent of those live positions (materialized)
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
    mapping(address => uint256) public claimableUsd; // priced-out / failed / leftover (indexer aid)
    mapping(address => uint256) public claimableTokens; // filled tokens credited after settle claim
    uint256 public totalEscrowed;
    /// @dev Tokens moved from positions into claimableTokens (Task G accounted set).
    uint256 public totalTokensCredited;
    /// @dev Tokens wiped on failure refund (not deliverable).
    uint256 public totalTokensForfeited;
    /// @dev Σ tokens written onto positions (eager distribute + lazy materialize). Task S.
    uint256 public soldMaterialized;
    /// @dev Floor-dust swept into pairing surplus at settle (sold − soldMaterialized).
    uint256 public settleDustSurplus;
    /// @dev Task S3: read-only projSpent at dust-exhaust mark; materialize must match exactly.
    mapping(address => uint256) internal exhaustProjSpent;

    // ─── constructor (spec §1, §7) ─────────────────────────────────────────
    constructor(Params memory p) {
        require(p.floorMcapUsd >= FLOOR_MCAP_MIN && p.floorMcapUsd <= FLOOR_MCAP_MAX, "floor mcap");
        // Production launches: N ∈ [100,2000]. Differential vectors use N≥5 (oracle untouched).
        require(p.durationBlocks >= 5 && p.durationBlocks <= 2000, "duration");
        require(p.epochSeconds >= 1 && p.epochSeconds <= 3600, "epoch");
        require(p.totalSupply > 0, "supply");
        // baseStep clamped >= 0 by uint16; explicit check for documentation (regression C)
        require(p.baseStepBps == p.baseStepBps, "step"); // tautology keeps clamp note; uint can't be <0

        totalSupply = p.totalSupply;
        floorMcapUsd = p.floorMcapUsd;
        floorPrice = FixedPointMathLib.mulDiv(p.floorMcapUsd, WAD, p.totalSupply);
        graduationUsd = p.graduationUsd;
        durationBlocks = p.durationBlocks;
        epochSeconds = p.epochSeconds;
        maxClearsPerSync = p.maxClearsPerSync == 0 ? 64 : p.maxClearsPerSync;
        maxUniqueActives = p.maxUniqueActives; // 0 = unlimited
        baseStepBps = p.baseStepBps;
        walletCapBps = p.walletCapBps;
        sizeBonusBps = p.sizeBonusBps;
        lpShareBps = p.lpShareBps;
        holdbackBps = p.holdbackBps;
        kappaHundredths = p.kappaHundredths == 0 ? 130 : p.kappaHundredths;
        disposalMode = p.disposalMode;
        pairToken = p.pairToken;
        creator = msg.sender;
        eagerFills = p.eagerFills;

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

        Bidder storage b = bidders[msg.sender];
        // Task R: cap NEW addresses only; existing bidders may always add positions.
        if (!b.tracked) {
            uint16 cap = maxUniqueActives;
            require(cap == 0 || uniqueBidders < cap, "max unique actives");
        }

        _startIfNeeded();
        _sync();

        positionId = ++nextPositionId;
        positions[positionId] = Position({
            owner: msg.sender,
            budget: budget,
            maxPrice: maxPrice,
            spent: 0,
            tokens: 0,
            status: PosStatus.Active,
            usdClaimed: false,
            tokensClaimed: false,
            enteredAt: uint64(auctionIndex)
        });
        _bidderPositions[msg.sender].push(positionId);
        totalEscrowed += budget;

        if (!b.tracked) {
            b.tracked = true;
            uniqueBidders += 1;
        }
        _materialize(msg.sender);

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
    /// @dev USD claim and token claim are independent (Task M). Pre-settle OutPrice USD
    ///      claim must not erase p.tokens; tokens remain claimable after settle.
    function claim(uint256 positionId) external {
        _sync();
        Position storage p = positions[positionId];
        require(p.owner == msg.sender, "owner");
        require(!(p.usdClaimed && p.tokensClaimed), "claimed");
        _materialize(msg.sender);

        bool paidUsd;
        bool paidTok;

        // ── USD leg ───────────────────────────────────────────────────────
        if (!p.usdClaimed) {
            if (done && !graduated) {
                // Failure: full budget refund; filled tokens forfeited (spec §7 / I8)
                uint256 usd = p.budget;
                if (p.tokens > 0 && !p.tokensClaimed) {
                    totalTokensForfeited += p.tokens;
                    p.tokens = 0;
                    p.tokensClaimed = true;
                }
                totalEscrowed -= p.budget;
                p.usdClaimed = true;
                paidUsd = true;
                if (usd > 0) {
                    (bool ok,) = msg.sender.call{value: usd}("");
                    require(ok, "usd");
                }
            } else if (p.status == PosStatus.OutPrice || (done && graduated)
                    || (p.status == PosStatus.Capped && done)) {
                // Unspent USD only; keep budget/spent/tokens for token leg + G ledger
                uint256 usd = p.budget - p.spent;
                totalEscrowed -= usd;
                p.usdClaimed = true;
                paidUsd = true;
                if (usd > 0) {
                    (bool ok,) = msg.sender.call{value: usd}("");
                    require(ok, "usd");
                }
            }
        }

        // ── Token leg (post-settle graduate only) ─────────────────────────
        if (!p.tokensClaimed && settled && graduated && p.tokens > 0) {
            uint256 tok = p.tokens;
            claimableTokens[msg.sender] += tok;
            totalTokensCredited += tok;
            p.tokens = 0;
            p.tokensClaimed = true;
            paidTok = true;
        }

        require(paidUsd || paidTok, "not claimable");
    }

    /// @notice Task G/S: sold == on-positions + pending + credited + forfeited + settle dust.
    ///      When `done` but dust not yet swept, unrealized residue (sold − base) is included so
    ///      pre-settle views still conserve (Task S).
    function tokensAccounted() public view returns (uint256) {
        uint256 onPositions;
        uint256 n = nextPositionId;
        for (uint256 id = 1; id <= n; id++) {
            onPositions += positions[id].tokens;
        }
        address[] memory seen = new address[](n);
        uint256 seenN;
        for (uint256 id = 1; id <= n; id++) {
            address who = positions[id].owner;
            if (who == address(0)) continue;
            bool dup;
            for (uint256 s = 0; s < seenN; s++) {
                if (seen[s] == who) {
                    dup = true;
                    break;
                }
            }
            if (dup) continue;
            seen[seenN++] = who;
            onPositions += _pendingTokens(who);
        }
        uint256 base = onPositions + totalTokensCredited + totalTokensForfeited + settleDustSurplus;
        if (done && sold > base) return sold; // unrealized materialization dust
        return base;
    }

    /// @notice Escrow book: unclaimed budgets + spent-of-usdClaimed (raised held). Matches totalEscrowed.
    function escrowBook() public view returns (uint256) {
        uint256 s;
        uint256 n = nextPositionId;
        for (uint256 id = 1; id <= n; id++) {
            Position storage p = positions[id];
            if (p.owner == address(0)) continue;
            if (p.usdClaimed) {
                // Failure path refunded full budget (spent not retained in escrow).
                if (!(done && !graduated)) s += p.spent;
            } else {
                s += p.budget;
            }
        }
        return s;
    }

    /// @notice Unclaimed refundable USD only.
    function escrowLiability() public view returns (uint256) {
        uint256 liab;
        uint256 n = nextPositionId;
        for (uint256 id = 1; id <= n; id++) {
            Position storage p = positions[id];
            if (p.owner == address(0) || p.usdClaimed) continue;
            if (done && !graduated) liab += p.budget;
            else liab += p.budget - p.spent;
        }
        return liab;
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

        // Task S: materialize everyone so residue is well-defined, then sweep floor dust.
        {
            uint256 n = nextPositionId;
            for (uint256 id = 1; id <= n; id++) {
                address who = positions[id].owner;
                if (who != address(0)) _materialize(who);
            }
        }
        // Residue vs canonical on-position ledger (not the soldMaterialized counter).
        uint256 onPos;
        {
            uint256 n = nextPositionId;
            for (uint256 id = 1; id <= n; id++) {
                onPos += positions[id].tokens;
            }
        }
        uint256 accountedPre = onPos + totalTokensCredited + totalTokensForfeited;
        uint256 residue = sold > accountedPre ? sold - accountedPre : 0;
        // Bound: ≤ unique-actives × clears wei (≤1 wei floor dust per address per clear).
        uint256 dustCap = uint256(uniqueBidders) * uint256(durationBlocks);
        require(uniqueBidders == 0 || residue <= dustCap, "dust bound");
        settleDustSurplus = residue;
        // Keep counter aligned for views / invariants.
        soldMaterialized = onPos;

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
        surplus += settleDustSurplus; // Task S: pairing surplus absorbs materialization dust
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
        // Task G: canonical ledger = Σ position.tokens + pending accumulator credit.
        uint256[] storage ids = _bidderPositions[who];
        uint256 t;
        for (uint256 i = 0; i < ids.length; i++) {
            t += positions[ids[i]].tokens;
        }
        return t + _pendingTokens(who);
    }

    /// @notice Materialize accumulator credit into positions (Task Q'). Permissionless.
    function materialize(address who) external {
        _sync();
        _materialize(who);
    }

    /// @notice Force-materialize every position owner — test/invariant helper (Task Q'/G).
    function materializeAll() external {
        _sync();
        uint256 n = nextPositionId;
        for (uint256 id = 1; id <= n; id++) {
            address who = positions[id].owner;
            if (who != address(0)) _materialize(who);
        }
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
        if (startTime == 0) {
            startTime = uint64(block.timestamp);
        }
    }

    /// @notice Auction blocks the wall clock is ahead of the cleared cursor.
    function pendingClears() public view returns (uint256) {
        if (done || startTime == 0) return 0;
        uint256 target = _auctionTarget();
        uint256 idx = auctionIndex;
        return target > idx ? target - idx : 0;
    }

    function _auctionTarget() internal view returns (uint256) {
        uint256 elapsed = block.timestamp - uint256(startTime);
        uint256 target = elapsed / uint256(epochSeconds);
        if (target > durationBlocks) target = durationBlocks;
        return target;
    }

    /// @dev Advance auctionIndex toward wall-clock target. Empty book ⇒ O(1) jump.
    ///      Live book: at most maxClearsPerSync clears per call (Task N / E1).
    function _sync() internal {
        if (done || startTime == 0) return;
        uint256 target = _auctionTarget();

        // Fast path: no active weight — schedule cursor jumps; price frozen; supply unsold (squish later)
        if (totalWeight == 0) {
            if (uint256(auctionIndex) < target) {
                auctionIndex = uint64(target);
            }
            if (auctionIndex >= durationBlocks) _finish();
            return;
        }

        uint256 guard;
        uint256 cap = maxClearsPerSync;
        while (uint256(auctionIndex) < target && !done && guard++ < cap) {
            _clearOneBlock();
        }
    }

    /// @dev One auction block — differential twin of reference `tick()`.
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
                        bd.rewardDebt = FixedPointMathLib.mulDiv(bd.weight, accTokensPerWeight, WAD * ACC_PREC);
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

    /// @dev Task Q'/S3 lazy path: globals + constrained/exit writes only.
    ///      Dust-exhaust uses read-only projSpent including this clear's acc delta (E1).
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
        bool[] memory dustExit = new bool[](n);

        for (uint256 i = 0; i < n; i++) {
            address who = snap[i];
            Bidder storage bd = bidders[who];
            snapW[i] = bd.weight == 0 ? WAD : bd.weight;
            snapBud[i] = bd.activeBudget;
            // Pre-clear virtual spent (checkpoint only — does NOT include this clear).
            snapSpent[i] = bd.activeSpent + _pendingUsd(who);
            snapTok[i] = bd.tokens + _pendingTokens(who);
            alive[i] = bd.activeCount > 0 && !bd.capped && bd.activeBudget > 0;
        }

        // Pre-clear dust — Q'/eager twin (alive[] unchanged; refresh zeroes positions).
        for (uint256 i = 0; i < n; i++) {
            if (!alive[i]) continue;
            if (!_dustDetect(snap[i])) continue;
            dustExit[i] = true;
            address who = snap[i];
            Bidder storage bd = bidders[who];
            uint256 accrued = FixedPointMathLib.mulDiv(bd.weight, accUsdPerWeight, WAD);
            uint256 proj = bd.activeSpent + (accrued > bd.usdDebt ? accrued - bd.usdDebt : 0);
            exhaustProjSpent[who] = proj;
            _materialize(who);
            _dustExhaustPositions(who);
            _refreshWeightBasisOnly(who);
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
                    // Cap cost to budLeft; do not shrink take (matches distribute; Task S2).
                    if (cost > budLeft) cost = budLeft;
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

        // Same-clear projSpent detection deferred until after unc totals (below).
        bool anyConstrained;
        for (uint256 i = 0; i < n; i++) {
            if (constrained[i]) {
                anyConstrained = true;
                break;
            }
        }

        uint256 uncTok;
        uint256 uncUsd;
        uint256 uncW;
        for (uint256 i = 0; i < n; i++) {
            if (takeAmt[i] == 0 || constrained[i] || dustExit[i]) continue;
            uncTok += takeAmt[i];
            uncUsd += costAmt[i];
            uncW += snapW[i];
        }
        uint256 accUsdAfter = accUsdPerWeight;
        uint256 accTokAfter = accTokensPerWeight;
        if (uncW > 0 && !anyConstrained) {
            accTokAfter += FixedPointMathLib.mulDiv(uncTok, WAD * ACC_PREC, uncW);
            accUsdAfter += FixedPointMathLib.mulDiv(uncUsd, WAD, uncW);
        }

        // Task S3: read-only projSpent including this clear — record only; mark at b+1.
        if (!anyConstrained) {
            for (uint256 i = 0; i < n; i++) {
                if (dustExit[i] || constrained[i] || takeAmt[i] == 0) continue;
                Bidder storage bd = bidders[snap[i]];
                if (bd.activeCount == 0 || bd.capped || bd.weight == 0) continue;
                uint256 accrued = FixedPointMathLib.mulDiv(bd.weight, accUsdAfter, WAD);
                uint256 proj = bd.activeSpent + (accrued > bd.usdDebt ? accrued - bd.usdDebt : 0);
                if (bd.activeBudget <= proj + 1e9) {
                    exhaustProjSpent[snap[i]] = proj; // do not flip dustExit — avoids fill divergence
                }
            }
        }

        if (anyConstrained) {
            // Mixed clear: exact distribute for everyone; globals from water-fill projection.
            for (uint256 i = 0; i < n; i++) {
                if (takeAmt[i] == 0 && !constrained[i] && !dustExit[i]) continue;
                address who = snap[i];
                _materialize(who);
                if (takeAmt[i] > 0) {
                    (uint256 gotTok, uint256 cost) = _distributeToPositions(who, takeAmt[i], px);
                    if (gotTok > 0) {
                        Bidder storage bd = bidders[who];
                        bd.tokens += gotTok;
                        bd.activeSpent += cost;
                        bd.rewardDebt = FixedPointMathLib.mulDiv(bd.weight, accTokensPerWeight, WAD * ACC_PREC);
                        bd.usdDebt = FixedPointMathLib.mulDiv(bd.weight, accUsdPerWeight, WAD);
                        emit Filled(who, gotTok, cost, px, uint64(b));
                    }
                }
                if (constrained[i]) {
                    if (constrKind[i] == 1) _markCapped(who);
                    _refreshWeightBasisOnly(who);
                } else if (dustExit[i]) {
                    _markAllIn(who);
                    _refreshWeightBasisOnly(who);
                }
            }
        } else {
            // Sync non-participants to pre-bump checkpoint (pre-clear dust already exited).
            for (uint256 i = 0; i < n; i++) {
                if (takeAmt[i] == 0 && snapW[i] > 0 && !dustExit[i]) _materialize(snap[i]);
            }
            if (uncW > 0) {
                accTokensPerWeight = accTokAfter;
                accUsdPerWeight = accUsdAfter;
            }
            for (uint256 i = 0; i < n; i++) {
                if (takeAmt[i] > 0) {
                    emit Filled(snap[i], takeAmt[i], costAmt[i], px, uint64(b));
                } else if (snapW[i] > 0 && !dustExit[i]) {
                    Bidder storage bd = bidders[snap[i]];
                    bd.rewardDebt = FixedPointMathLib.mulDiv(bd.weight, accTokensPerWeight, WAD * ACC_PREC);
                    bd.usdDebt = FixedPointMathLib.mulDiv(bd.weight, accUsdPerWeight, WAD);
                }
            }
            // Same-clear dust: record-only (exhaustProjSpent set); mark on next clear.
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

    function _dustDetect(address who) internal view returns (bool) {
        uint256[] storage ids = _bidderPositions[who];
        uint256 pend = _pendingUsd(who);
        // Allocate pending pro-rata across active positions for dust check (read-only)
        uint256 live;
        for (uint256 i = 0; i < ids.length; i++) {
            if (positions[ids[i]].status == PosStatus.Active) live++;
        }
        if (live == 0) return false;
        uint256 per = pend / live;
        uint256 rem = pend - per * live;
        for (uint256 i = 0; i < ids.length; i++) {
            Position storage p = positions[ids[i]];
            if (p.status != PosStatus.Active) continue;
            uint256 virt = p.spent + per + (rem > 0 ? 1 : 0);
            if (rem > 0) rem--;
            if (p.budget <= virt + 1e9) return true;
        }
        return false;
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
        // Peek: any exit? If not, zero writes (Task Q').
        bool any;
        for (uint256 i = 0; i < ids.length; i++) {
            Position storage p = positions[ids[i]];
            if (p.status == PosStatus.Active && p.maxPrice < px) {
                any = true;
                break;
            }
        }
        if (!any) return;

        _materialize(who);
        Bidder storage b = bidders[who];
        for (uint256 i = 0; i < ids.length; i++) {
            Position storage p = positions[ids[i]];
            if (p.status == PosStatus.Active && p.maxPrice < px) {
                p.status = PosStatus.OutPrice;
                uint256 left = p.budget - p.spent;
                claimableUsd[who] += left;
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
        if (tokOut > 0) soldMaterialized += tokOut;
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
    ///      Event-driven only (Task Q'): call on placeBid / price-out / dust / cap / bud exit.
    function _refreshWeightBasisOnly(address who) internal {
        // Materialize first so position.spent includes lazy activeSpent credits (Task S).
        _materialize(who);

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

    // ─── weight / active-set / materialize (Task Q') ──────────────────────

    function _setActiveBudget(address who, uint256 ab, uint256 as_) internal {
        Bidder storage b = bidders[who];
        b.activeBudget = ab;
        b.activeSpent = as_;
        _reweight(who);
    }

    function _reweight(address who) internal {
        Bidder storage b = bidders[who];
        _materialize(who);
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
            b.rewardDebt = FixedPointMathLib.mulDiv(newW, accTokensPerWeight, WAD * ACC_PREC);
            b.usdDebt = FixedPointMathLib.mulDiv(newW, accUsdPerWeight, WAD);
        }
    }

    function _weightOf(uint256 capital) internal view returns (uint256) {
        if (alphaWad == 0) return WAD; // pure per-capita — one share
        uint256 c = capital < WAD ? WAD : capital;
        int256 w = FixedPointMathLib.powWad(int256(c), alphaWad);
        require(w > 0, "weight");
        return uint256(w);
    }

    /// @dev Credit pending accumulator fills into positions; sync debts. Task S2/S3:
    ///      pure acc for tokens AND USD; exhaust-marked addresses must match projSpent.
    function _materialize(address who) internal {
        Bidder storage b = bidders[who];
        uint256 pendT = _pendingTokens(who);
        uint256 pendU = _pendingUsd(who);
        uint256 wantT = FixedPointMathLib.mulDiv(b.weight, accTokensPerWeight, WAD * ACC_PREC);
        uint256 wantU = FixedPointMathLib.mulDiv(b.weight, accUsdPerWeight, WAD);
        if (pendT == 0 && pendU == 0 && b.rewardDebt == wantT && b.usdDebt == wantU) {
            uint256 expect = exhaustProjSpent[who];
            if (expect != 0) {
                require(b.activeSpent == expect, "projSpent");
                delete exhaustProjSpent[who];
            }
            return;
        }
        if (pendT > 0 || pendU > 0) {
            _applyPendingToPositions(who, pendT, pendU);
            b.tokens += pendT;
            b.activeSpent += pendU;
        }
        b.rewardDebt = wantT;
        b.usdDebt = wantU;
        uint256 expect2 = exhaustProjSpent[who];
        if (expect2 != 0) {
            require(b.activeSpent == expect2, "projSpent");
            delete exhaustProjSpent[who];
        }
    }

    /// @dev Split pending tokens/USD across Active positions.
    ///      Equal water-fill + largest-remainder (tie → lowest positionId). Task S.
    function _applyPendingToPositions(address who, uint256 dTok, uint256 dUsd) internal {
        if (dTok == 0 && dUsd == 0) return;
        uint256[] storage ids = _bidderPositions[who];
        uint256 live;
        for (uint256 i = 0; i < ids.length; i++) {
            if (positions[ids[i]].status == PosStatus.Active) live++;
        }
        if (live == 0) {
            if (ids.length == 0) return;
            Position storage p0 = positions[ids[0]];
            p0.tokens += dTok;
            p0.spent += dUsd;
            if (dTok > 0) soldMaterialized += dTok;
            return;
        }

        // Collect live ids and insertion-sort ascending (largest-remainder tie-break).
        uint256[] memory liveIds = new uint256[](live);
        uint256 k;
        for (uint256 i = 0; i < ids.length; i++) {
            if (positions[ids[i]].status == PosStatus.Active) {
                liveIds[k++] = ids[i];
            }
        }
        for (uint256 i = 1; i < live; i++) {
            uint256 key = liveIds[i];
            uint256 j = i;
            while (j > 0 && liveIds[j - 1] > key) {
                liveIds[j] = liveIds[j - 1];
                j--;
            }
            liveIds[j] = key;
        }

        // Tokens: equal water-fill + largest-remainder (tie → lowest positionId).
        uint256 tPer = dTok / live;
        uint256 tRem = dTok - tPer * live;
        uint256[] memory tShare = new uint256[](live);
        for (uint256 i = 0; i < live; i++) {
            tShare[i] = tPer + (i < tRem ? 1 : 0);
        }
        // Spent follows tokens (eager couples cost = mulWad(take, px) per chunk).
        // Pro-rata dUsd by tShare + largest-remainder on residue; tie → lowest id.
        uint256[] memory uShare = new uint256[](live);
        if (dTok == 0) {
            uint256 uPer = dUsd / live;
            uint256 uRem = dUsd - uPer * live;
            for (uint256 i = 0; i < live; i++) {
                uShare[i] = uPer + (i < uRem ? 1 : 0);
            }
        } else {
            uint256 uAssigned;
            for (uint256 i = 0; i < live; i++) {
                uShare[i] = FixedPointMathLib.mulDiv(dUsd, tShare[i], dTok);
                uAssigned += uShare[i];
            }
            uint256 uRem = dUsd - uAssigned;
            for (uint256 i = 0; i < live && uRem > 0; i++) {
                uShare[i] += 1;
                uRem--;
            }
        }
        for (uint256 i = 0; i < live; i++) {
            Position storage p = positions[liveIds[i]];
            uint256 u = uShare[i];
            uint256 budLeft = p.budget > p.spent ? p.budget - p.spent : 0;
            if (u > budLeft) u = budLeft;
            p.tokens += tShare[i];
            p.spent += u;
        }
        if (dTok > 0) soldMaterialized += dTok;
    }

    function _pendingTokens(address who) internal view returns (uint256) {
        Bidder storage b = bidders[who];
        if (b.weight == 0) return 0;
        uint256 accrued = FixedPointMathLib.mulDiv(b.weight, accTokensPerWeight, WAD * ACC_PREC);
        return accrued > b.rewardDebt ? accrued - b.rewardDebt : 0;
    }

    function _pendingUsd(address who) internal view returns (uint256) {
        Bidder storage b = bidders[who];
        if (b.weight == 0) return 0;
        uint256 accrued = FixedPointMathLib.mulDiv(b.weight, accUsdPerWeight, WAD);
        return accrued > b.usdDebt ? accrued - b.usdDebt : 0;
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
            _materialize(who);
            totalWeight -= b.weight;
            b.weight = 0;
            b.rewardDebt = 0;
            b.usdDebt = 0;
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
