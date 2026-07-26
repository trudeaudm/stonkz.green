// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IVotesToken, IFeeReceiverRegistry} from "./interfaces/IStonkzGovernance.sol";

/// @title CTOGovernor — per-token community takeover (fees-and-governance.md §4, spec §8.9)
/// @notice Per-token state machine. Power = min(balance@snapshot, balanceNow), paged
///         re-clamp of ALL prior voters, pass at 80% of a FROZEN eligible denominator,
///         early-fail when reject > 20%. Candidate is explicit + immutable per vote;
///         on pass, feeReceiver + page-admin transfer to the candidate. Failed
///         initiator + candidate: 7-day per-address cooldown; token: 24h spacing
///         between vote windows (hostile-squatter rationale §4.5). Abstention is a
///         veto by design (§4.6). No admin, no upgradeability.
contract CTOGovernor {
    // ─── hardcoded bounds (no admin) ─────────────────────────────────────────
    uint16 internal constant INITIATE_BPS = 100; // ≥1% at-large to initiate (§4.1)
    uint16 internal constant CAST_BPS = 10; // ≥0.1% at-large to cast (§4.2)
    uint16 internal constant PASS_BPS = 8000; // support ≥80% frozen denom (§4.3)
    uint16 internal constant FAIL_BPS = 2000; // reject >20% ⇒ early-fail (§4.3)
    uint64 internal constant VOTE_WINDOW = 24 hours; // §4.2
    uint64 internal constant ADDRESS_COOLDOWN = 7 days; // failed initiator+candidate (§4.5)
    uint64 internal constant TOKEN_SPACING = 24 hours; // between vote windows (§4.5)
    uint256 internal constant CLAMP_PAGE = 50; // per-tx re-clamp work cap (§4.2)
    uint256 internal constant MAX_VOTERS = 1000; // bounded voter set (§4.2)

    enum Status {
        None,
        Active,
        Passed,
        Failed
    }

    struct Proposal {
        Status status;
        address initiator; // address that opened the vote
        address candidate; // immutable beneficiary (§4.1 / §4.4)
        uint256 snapshotBlock; // frozen at initiate (§4.1)
        uint256 eligibleDenom; // frozen: total − LP − burned − parked (creatorReserve INCLUDED)
        uint64 voteStart;
        uint64 voteEnd;
        uint256 adjustedSupport;
        uint256 adjustedReject;
        uint256 clampCursor; // paging cursor over `voters`
        bool finalized;
    }

    struct Voter {
        address voter;
        bool support;
        uint256 snapBal; // balance @ snapshot (fixed)
        uint256 power; // last-clamped power = min(snapBal, balanceNow)
    }

    struct TokenReg {
        address registrar; // factory/listing that owns denominator inputs
        uint256 lpHeld; // supply held in LP positions
        uint256 burned; // supply burned
        uint256 parked; // protocol-parked (pre-genesis side pool etc.)
        bool set;
    }

    IFeeReceiverRegistry public registry; // the hook (set once)
    address public immutable registrySetter;

    mapping(address => Proposal) public proposals; // token => proposal
    mapping(address => Voter[]) internal _voters; // token => voters
    mapping(address => mapping(address => uint256)) public voterIndexPlus1; // token => voter => idx+1
    mapping(address => TokenReg) public tokenRegs; // token => denominator inputs
    /// @dev Failed initiator / candidate cannot reappear in either role until this time (§4.5).
    mapping(address => uint64) public addressCooldownUntil;
    /// @dev Earliest timestamp a new vote window may open on this token (§4.5).
    mapping(address => uint64) public tokenNextWindow;

    // ─── events (§4.7) ───────────────────────────────────────────────────────
    event TokenRegistered(address indexed token, address indexed registrar);
    event DenominatorUpdated(address indexed token, uint256 lpHeld, uint256 burned, uint256 parked);
    event CTOInitiated(
        address indexed token,
        address indexed initiator,
        address indexed candidate,
        uint256 snapshotBlock,
        uint256 eligibleDenom,
        uint64 voteEnd
    );
    event VoteCast(address indexed token, address indexed voter, bool support, uint256 power);
    event PageReclamped(
        address indexed token, uint256 fromCursor, uint256 count, uint256 adjustedSupport, uint256 adjustedReject
    );
    event CTOEarlyFailed(address indexed token, uint256 adjustedReject, uint256 threshold);
    event CTOPassed(address indexed token, address indexed candidate, uint256 adjustedSupport, uint256 eligibleDenom);
    event CTOFailed(
        address indexed token,
        address indexed initiator,
        address indexed candidate,
        uint256 adjustedSupport,
        uint256 eligibleDenom,
        uint64 addressCooldownUntil,
        uint64 tokenNextWindow
    );
    event CTOFinalized(address indexed token, Status status);
    event AddressCooldownSet(address indexed who, uint64 until);
    event TokenSpacingSet(address indexed token, uint64 nextWindow);

    error RegistryAlreadySet();
    error NotRegistrySetter();
    error TokenAlreadyRegistered();
    error NotRegistrar();
    error CTOAlreadyActive();
    error AddressCooldownActive(address who, uint64 until);
    error TokenSpacingActive(uint64 until);
    error BelowInitiateThreshold();
    error NotActive();
    error VotingClosed();
    error VotingNotStarted();
    error BelowCastThreshold();
    error AlreadyVoted();
    error VoterCapReached();
    error WindowNotElapsed();

    constructor() {
        registrySetter = msg.sender;
    }

    /// @notice One-shot wiring of the fee-receiver/page-admin registry (the hook).
    function setRegistry(IFeeReceiverRegistry registry_) external {
        if (msg.sender != registrySetter) revert NotRegistrySetter();
        if (address(registry) != address(0)) revert RegistryAlreadySet();
        registry = registry_;
    }

    // ─── denominator registry (§4.1) ─────────────────────────────────────────

    /// @notice Factory/listing registers a token's denominator inputs. First caller = registrar.
    /// @dev Eligible denominator = total − lpHeld − burned − parked (creatorReserve INCLUDED).
    function registerToken(address token, uint256 lpHeld, uint256 burned, uint256 parked) external {
        TokenReg storage r = tokenRegs[token];
        if (r.set) revert TokenAlreadyRegistered();
        r.registrar = msg.sender;
        r.lpHeld = lpHeld;
        r.burned = burned;
        r.parked = parked;
        r.set = true;
        emit TokenRegistered(token, msg.sender);
        emit DenominatorUpdated(token, lpHeld, burned, parked);
    }

    /// @notice Registrar updates denominator inputs (e.g. side pool deployed, tokens burned).
    ///         Only affects future initiations; an active proposal's denom is frozen.
    function updateDenominator(address token, uint256 lpHeld, uint256 burned, uint256 parked) external {
        TokenReg storage r = tokenRegs[token];
        if (msg.sender != r.registrar) revert NotRegistrar();
        r.lpHeld = lpHeld;
        r.burned = burned;
        r.parked = parked;
        emit DenominatorUpdated(token, lpHeld, burned, parked);
    }

    /// @notice At-large supply = total − LP − burned − parked (creatorReserve counted in).
    function atLargeSupply(address token) public view returns (uint256) {
        TokenReg storage r = tokenRegs[token];
        uint256 total = IVotesToken(token).totalSupply();
        uint256 sub = r.lpHeld + r.burned + r.parked;
        return sub >= total ? 0 : total - sub;
    }

    // ─── lifecycle ───────────────────────────────────────────────────────────

    /// @notice Initiate a CTO. Caller must hold ≥1% at-large.
    /// @param candidate Beneficiary of feeReceiver + page-admin on pass.
    ///        `address(0)` defaults to `msg.sender` (initiator). Immutable for this vote.
    function initiate(address token, address candidate) external {
        if (candidate == address(0)) candidate = msg.sender;

        Proposal storage p = proposals[token];
        if (p.status == Status.Active) revert CTOAlreadyActive();

        // Token spacing: 24h between vote windows (§4.5).
        if (block.timestamp < tokenNextWindow[token]) {
            revert TokenSpacingActive(tokenNextWindow[token]);
        }
        // Per-address 7d cooldown binds failed initiator AND failed candidate in either role.
        if (block.timestamp < addressCooldownUntil[msg.sender]) {
            revert AddressCooldownActive(msg.sender, addressCooldownUntil[msg.sender]);
        }
        if (block.timestamp < addressCooldownUntil[candidate]) {
            revert AddressCooldownActive(candidate, addressCooldownUntil[candidate]);
        }

        uint256 atLarge = atLargeSupply(token);
        uint256 need = (atLarge * INITIATE_BPS) / 10_000;
        if (IVotesToken(token).balanceOf(msg.sender) < need || need == 0) revert BelowInitiateThreshold();

        // Reset any prior voter set + index map (new proposal).
        _clearVoters(token);

        p.status = Status.Active;
        p.initiator = msg.sender;
        p.candidate = candidate;
        p.snapshotBlock = block.number;
        p.eligibleDenom = atLarge;
        p.voteStart = uint64(block.timestamp);
        p.voteEnd = uint64(block.timestamp) + VOTE_WINDOW;
        p.adjustedSupport = 0;
        p.adjustedReject = 0;
        p.clampCursor = 0;
        p.finalized = false;

        emit CTOInitiated(token, msg.sender, candidate, p.snapshotBlock, p.eligibleDenom, p.voteEnd);
    }

    /// @notice Cast a support/reject vote. Power = min(balance@snapshot, balanceNow), ≥0.1% to cast.
    ///         Re-clamps a page (≤50) of prior voters; may early-fail (§4.3).
    function vote(address token, bool support) external {
        Proposal storage p = proposals[token];
        if (p.status != Status.Active) revert NotActive();
        if (block.timestamp < p.voteStart) revert VotingNotStarted();
        if (block.timestamp > p.voteEnd) revert VotingClosed();
        if (voterIndexPlus1[token][msg.sender] != 0) revert AlreadyVoted();

        Voter[] storage vs = _voters[token];
        if (vs.length >= MAX_VOTERS) revert VoterCapReached();

        // Re-clamp a page of prior voters BEFORE adding the new one (§4.2 paged work cap).
        _reclampPage(token, p, vs);

        uint256 snapBal = IVotesToken(token).getPastVotes(msg.sender, p.snapshotBlock);
        uint256 balNow = IVotesToken(token).balanceOf(msg.sender);
        uint256 power = snapBal < balNow ? snapBal : balNow;

        uint256 castMin = (p.eligibleDenom * CAST_BPS) / 10_000;
        if (power < castMin || power == 0) revert BelowCastThreshold();

        vs.push(Voter({voter: msg.sender, support: support, snapBal: snapBal, power: power}));
        voterIndexPlus1[token][msg.sender] = vs.length; // idx+1

        if (support) {
            p.adjustedSupport += power;
        } else {
            p.adjustedReject += power;
        }

        emit VoteCast(token, msg.sender, support, power);

        // Early-fail: reject makes an 80% pass mathematically impossible (§4.3).
        uint256 failThresh = (p.eligibleDenom * FAIL_BPS) / 10_000;
        if (p.adjustedReject > failThresh) {
            _finish(token, p, false);
            emit CTOEarlyFailed(token, p.adjustedReject, failThresh);
        }
    }

    /// @notice Permissionless finalize after the window (or once already early-failed).
    ///         Performs a FINAL full re-clamp, then decides pass/fail (§4.4).
    function finalize(address token) external {
        Proposal storage p = proposals[token];
        if (p.status != Status.Active) revert NotActive();
        if (block.timestamp <= p.voteEnd) revert WindowNotElapsed();

        // Final full re-clamp of every voter.
        Voter[] storage vs = _voters[token];
        _reclampRange(token, p, vs, 0, vs.length);

        uint256 passThresh = (p.eligibleDenom * PASS_BPS) / 10_000;
        _finish(token, p, p.adjustedSupport >= passThresh && passThresh > 0);
    }

    /// @notice Hook interlock (§1.4): true while a vote is Active (blocks voluntary transfer).
    function ctoActive(address token) external view returns (bool) {
        return proposals[token].status == Status.Active;
    }

    // ─── views ───────────────────────────────────────────────────────────────

    function status(address token) external view returns (Status) {
        return proposals[token].status;
    }

    function candidateOf(address token) external view returns (address) {
        return proposals[token].candidate;
    }

    function initiatorOf(address token) external view returns (address) {
        return proposals[token].initiator;
    }

    function voterCount(address token) external view returns (uint256) {
        return _voters[token].length;
    }

    function voterAt(address token, uint256 i) external view returns (Voter memory) {
        return _voters[token][i];
    }

    function tally(address token)
        external
        view
        returns (uint256 adjustedSupport, uint256 adjustedReject, uint256 eligibleDenom)
    {
        Proposal storage p = proposals[token];
        return (p.adjustedSupport, p.adjustedReject, p.eligibleDenom);
    }

    function snapshotBlockOf(address token) external view returns (uint256) {
        return proposals[token].snapshotBlock;
    }

    function voteEndOf(address token) external view returns (uint64) {
        return proposals[token].voteEnd;
    }

    function clampCursorOf(address token) external view returns (uint256) {
        return proposals[token].clampCursor;
    }

    function inAddressCooldown(address who) external view returns (bool) {
        return block.timestamp < addressCooldownUntil[who];
    }

    function inTokenSpacing(address token) external view returns (bool) {
        return block.timestamp < tokenNextWindow[token];
    }

    // ─── internal ──────────────────────────────────────────────────────────

    function _finish(address token, Proposal storage p, bool passed) internal {
        p.finalized = true;
        // Token spacing always applies after a vote window closes (§4.5).
        uint64 nextWin = uint64(block.timestamp) + TOKEN_SPACING;
        tokenNextWindow[token] = nextWin;
        emit TokenSpacingSet(token, nextWin);

        if (passed) {
            p.status = Status.Passed;
            // Transfer feeReceiver + page admin to CANDIDATE ONLY (§4.4).
            if (address(registry) != address(0)) {
                registry.governorTransfer(token, p.candidate, p.candidate);
            }
            emit CTOPassed(token, p.candidate, p.adjustedSupport, p.eligibleDenom);
        } else {
            p.status = Status.Failed;
            uint64 until = uint64(block.timestamp) + ADDRESS_COOLDOWN;
            addressCooldownUntil[p.initiator] = until;
            addressCooldownUntil[p.candidate] = until;
            emit AddressCooldownSet(p.initiator, until);
            emit AddressCooldownSet(p.candidate, until);
            emit CTOFailed(
                token, p.initiator, p.candidate, p.adjustedSupport, p.eligibleDenom, until, nextWin
            );
        }
        emit CTOFinalized(token, p.status);
    }

    function _clearVoters(address token) internal {
        Voter[] storage vs = _voters[token];
        uint256 n = vs.length;
        for (uint256 i = 0; i < n; ++i) {
            delete voterIndexPlus1[token][vs[i].voter];
        }
        delete _voters[token];
    }

    /// @dev Re-clamp CLAMP_PAGE voters starting at the wrapping cursor.
    function _reclampPage(address token, Proposal storage p, Voter[] storage vs) internal {
        uint256 n = vs.length;
        if (n == 0) return;
        uint256 count = n < CLAMP_PAGE ? n : CLAMP_PAGE;
        uint256 start = p.clampCursor % n;
        _reclampWrapped(token, p, vs, start, count, n);
        p.clampCursor = (start + count) % n;
    }

    function _reclampWrapped(
        address token,
        Proposal storage p,
        Voter[] storage vs,
        uint256 start,
        uint256 count,
        uint256 n
    ) internal {
        for (uint256 k = 0; k < count; ++k) {
            uint256 i = (start + k) % n;
            _reclampOne(token, p, vs, i);
        }
        emit PageReclamped(token, start, count, p.adjustedSupport, p.adjustedReject);
    }

    function _reclampRange(address token, Proposal storage p, Voter[] storage vs, uint256 start, uint256 end)
        internal
    {
        for (uint256 i = start; i < end; ++i) {
            _reclampOne(token, p, vs, i);
        }
    }

    function _reclampOne(address token, Proposal storage p, Voter[] storage vs, uint256 i) internal {
        Voter storage v = vs[i];
        uint256 balNow = IVotesToken(token).balanceOf(v.voter);
        uint256 newPower = v.snapBal < balNow ? v.snapBal : balNow;
        if (newPower == v.power) return;
        if (v.support) {
            p.adjustedSupport = p.adjustedSupport - v.power + newPower;
        } else {
            p.adjustedReject = p.adjustedReject - v.power + newPower;
        }
        v.power = newPower;
    }
}
