// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IStonkzVault} from "./IStonkzVault.sol";
import {IReleasePath} from "./IReleasePath.sol";
import {VaultConstants} from "./VaultConstants.sol";

/// @title StonkzVault — Management Vault (docs/10)
/// @notice Per-token custody + proportional serial direct-release queue + path registry.
///         Launch surface: deposit + direct release only. Paths register later (§4).
contract StonkzVault is IStonkzVault {
    using FixedPointMathLib for uint256;

    // ─── ownership ──────────────────────────────────────────────────────────
    address public owner;

    // ─── direct-release rate (built-in path; bounds fixed at construction) ─
    /// @notice Seconds per bps of total supply. Launch: 108. Unit: seconds/bps.
    uint64 public directRateSecondsPerBps;
    uint64 public immutable directRateMinSecondsPerBps;
    uint64 public immutable directRateMaxSecondsPerBps;

    // ─── per-token custody (strictly isolated — no cross-token math) ───────
    mapping(address => uint256) public custody;
    mapping(address => mapping(address => uint256)) public balanceOf;
    /// @notice Sum of amounts in pending + matured-unexecuted direct-release requests.
    mapping(address => uint256) public queuedDirect;
    /// @notice Amounts reserved for path transfers not yet executed (still locked for gate).
    mapping(address => uint256) public pendingToPath;

    // ─── direct-release queue (FIFO per token) ─────────────────────────────
    struct DirectRequest {
        address token;
        address requester;
        address destination;
        uint128 amount;
        uint64 duration; // stamped seconds (rate-stamp rule §5)
        uint64 readyAt; // 0 = waiting for predecessor completion
        bool executed;
        bool cancelled;
    }

    uint256 public nextRequestId = 1;
    mapping(uint256 => DirectRequest) public requests;
    mapping(address => uint256[]) internal _queue; // request ids, FIFO
    mapping(address => uint256) public queueHead; // index of first non-terminal

    // ─── path registry (docs/10 §4) ────────────────────────────────────────
    struct PathBounds {
        uint64 minRateSecondsPerBps;
        uint64 maxRateSecondsPerBps;
        uint16 minMaxPerTransferBps;
        uint16 maxMaxPerTransferBps;
        uint64 minCooldownSeconds;
        uint64 maxCooldownSeconds;
    }

    struct PathConfig {
        address path;
        uint64 rateSecondsPerBps; // 0 ⇒ instant (cooldown may still apply)
        uint16 maxPerTransferBps; // bps of total supply per transfer
        uint64 cooldownSeconds;
        PathBounds bounds;
        bool active;
        bool registered;
    }

    struct PathRequest {
        address token;
        address requester;
        uint64 pathId;
        uint128 amount;
        uint64 duration; // stamped
        uint64 readyAt;
        bool executed;
        bool cancelled;
    }

    uint64 public nextPathId = 1;
    mapping(uint64 => PathConfig) public paths;
    mapping(uint256 => PathRequest) public pathRequests;
    uint256 public nextPathRequestId = 1;
    mapping(address => mapping(uint64 => uint64)) public lastPathTransferAt; // token => pathId => ts
    mapping(address => uint256[]) internal _pathQueue;
    mapping(address => uint256) public pathQueueHead;

    // ─── events ────────────────────────────────────────────────────────────
    event OwnerTransferred(address indexed prev, address indexed next);
    event Deposited(address indexed token, address indexed beneficiary, uint256 amount);
    event DirectRateChanged(uint64 oldRate, uint64 newRate);
    event DirectRequested(
        uint256 indexed id,
        address indexed token,
        address indexed requester,
        address destination,
        uint256 amount,
        uint256 position,
        uint256 eta
    );
    event DirectCancelled(uint256 indexed id, address indexed token);
    event DirectExecuted(uint256 indexed id, address indexed token, address destination, uint256 amount);
    event PathRegistered(uint64 indexed pathId, address path);
    event PathRemoved(uint64 indexed pathId);
    event PathRateChanged(uint64 indexed pathId, uint64 rateSecondsPerBps, uint16 maxPerTransferBps, uint64 cooldown);
    event PathTransferRequested(
        uint256 indexed id, address indexed token, uint64 indexed pathId, uint256 amount, uint256 eta
    );
    event PathTransferCancelled(uint256 indexed id);
    event PathTransferExecuted(uint256 indexed id, address indexed token, uint64 indexed pathId, uint256 amount);

    // ─── errors ────────────────────────────────────────────────────────────
    error NotOwner();
    error ZeroAddress();
    error ZeroAmount();
    error InsufficientBalance();
    error RateOutOfBounds();
    error NotRequester();
    error NotPending();
    error NotReady();
    error NotHead();
    error DustAmount();
    error PathNotContract();
    error PathInactive();
    error PathUnknown();
    error TransferExceedsMax();
    error CooldownActive();
    error PathAlreadyRemoved();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @param rateSecondsPerBps_ launch direct-release rate (108). Unit: seconds/bps.
    /// @param minRate_ / maxRate_ hard bounds for owner setDirectRate (construction-fixed).
    constructor(uint64 rateSecondsPerBps_, uint64 minRate_, uint64 maxRate_) {
        if (minRate_ == 0 || minRate_ > maxRate_) revert RateOutOfBounds();
        if (rateSecondsPerBps_ < minRate_ || rateSecondsPerBps_ > maxRate_) revert RateOutOfBounds();
        owner = msg.sender;
        directRateSecondsPerBps = rateSecondsPerBps_;
        directRateMinSecondsPerBps = minRate_;
        directRateMaxSecondsPerBps = maxRate_;
    }

    function transferOwnership(address next) external onlyOwner {
        if (next == address(0)) revert ZeroAddress();
        emit OwnerTransferred(owner, next);
        owner = next;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // deposits (docs/10 §1–§2)
    // ═══════════════════════════════════════════════════════════════════════

    /// @inheritdoc IStonkzVault
    function deposit(address token, uint256 amount, address beneficiary) external {
        if (token == address(0) || beneficiary == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        SafeTransferLib.safeTransferFrom(token, msg.sender, address(this), amount);
        custody[token] += amount;
        balanceOf[token][beneficiary] += amount;
        emit Deposited(token, beneficiary, amount);
    }

    /// @notice Voluntary lock: deposit to self.
    function deposit(address token, uint256 amount) external {
        if (token == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        SafeTransferLib.safeTransferFrom(token, msg.sender, address(this), amount);
        custody[token] += amount;
        balanceOf[token][msg.sender] += amount;
        emit Deposited(token, msg.sender, amount);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // gate (docs/10 §6)
    // ═══════════════════════════════════════════════════════════════════════

    /// @inheritdoc IStonkzVault
    function lockedBalance(address token) external view returns (uint256) {
        uint256 c = custody[token];
        uint256 q = queuedDirect[token];
        // pending-to-path remains inside custody and is NOT subtracted (still locked).
        return c > q ? c - q : 0;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // direct-release rate governance (docs/10 §3 + §5)
    // ═══════════════════════════════════════════════════════════════════════

    function setDirectRate(uint64 rateSecondsPerBps_) external onlyOwner {
        if (rateSecondsPerBps_ < directRateMinSecondsPerBps || rateSecondsPerBps_ > directRateMaxSecondsPerBps) {
            revert RateOutOfBounds();
        }
        uint64 old = directRateSecondsPerBps;
        directRateSecondsPerBps = rateSecondsPerBps_;
        emit DirectRateChanged(old, rateSecondsPerBps_);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // direct release — proportional serial queue (docs/10 §3)
    // ═══════════════════════════════════════════════════════════════════════

    function requestDirectRelease(address token, uint256 amount, address destination)
        external
        returns (uint256 id, uint256 eta)
    {
        if (destination == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        uint256 bal = balanceOf[token][msg.sender];
        if (amount > bal) revert InsufficientBalance();

        uint256 supply = _totalSupply(token);
        uint256 bps = amount.fullMulDiv(10_000, supply);
        if (bps == 0) revert DustAmount();

        uint64 duration = uint64(bps * uint256(directRateSecondsPerBps)); // stamped (§5)
        balanceOf[token][msg.sender] = bal - amount;
        queuedDirect[token] += amount;

        id = nextRequestId++;
        bool isHead = !_hasActiveDirect(token);
        uint64 readyAt = isHead ? uint64(block.timestamp) + duration : 0;

        requests[id] = DirectRequest({
            token: token,
            requester: msg.sender,
            destination: destination,
            amount: uint128(amount),
            duration: duration,
            readyAt: readyAt,
            executed: false,
            cancelled: false
        });
        _queue[token].push(id);

        eta = _directEta(token, id);
        uint256 position = _directPosition(token, id);
        emit DirectRequested(id, token, msg.sender, destination, amount, position, eta);
    }

    function cancelDirectRelease(uint256 id) external {
        DirectRequest storage r = requests[id];
        if (r.executed || r.cancelled) revert NotPending();
        if (r.requester != msg.sender) revert NotRequester();
        r.cancelled = true;
        balanceOf[r.token][r.requester] += r.amount;
        queuedDirect[r.token] -= r.amount;
        emit DirectCancelled(id, r.token);
        _reflowDirect(r.token);
    }

    function executeDirectRelease(uint256 id) external {
        DirectRequest storage r = requests[id];
        if (r.executed || r.cancelled) revert NotPending();
        if (_queueHeadId(r.token) != id) revert NotHead();
        if (r.readyAt == 0 || block.timestamp < r.readyAt) revert NotReady();

        r.executed = true;
        queuedDirect[r.token] -= r.amount;
        custody[r.token] -= r.amount;
        SafeTransferLib.safeTransfer(r.token, r.destination, r.amount);
        emit DirectExecuted(id, r.token, r.destination, r.amount);
        _reflowDirect(r.token);
    }

    function directReadyAt(uint256 id) external view returns (uint256) {
        return requests[id].readyAt;
    }

    function directEta(uint256 id) external view returns (uint256) {
        DirectRequest storage r = requests[id];
        if (r.executed || r.cancelled) return 0;
        return _directEta(r.token, id);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // path registry (docs/10 §4–§5) — present; empty at launch is fine
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Register a release path contract with rate config + hard bounds.
    function registerPath(
        address path,
        uint64 rateSecondsPerBps_,
        uint16 maxPerTransferBps_,
        uint64 cooldownSeconds_,
        PathBounds calldata bounds
    ) external onlyOwner returns (uint64 pathId) {
        if (path == address(0) || path.code.length == 0) revert PathNotContract();
        _validatePathRate(rateSecondsPerBps_, maxPerTransferBps_, cooldownSeconds_, bounds);

        pathId = nextPathId++;
        paths[pathId] = PathConfig({
            path: path,
            rateSecondsPerBps: rateSecondsPerBps_,
            maxPerTransferBps: maxPerTransferBps_,
            cooldownSeconds: cooldownSeconds_,
            bounds: bounds,
            active: true,
            registered: true
        });
        emit PathRegistered(pathId, path);
        emit PathRateChanged(pathId, rateSecondsPerBps_, maxPerTransferBps_, cooldownSeconds_);
    }

    /// @notice Deactivate a path. Pending path transfers complete or cancel — never limbo.
    function removePath(uint64 pathId) external onlyOwner {
        PathConfig storage p = paths[pathId];
        if (!p.registered) revert PathUnknown();
        if (!p.active) revert PathAlreadyRemoved();
        p.active = false;
        emit PathRemoved(pathId);
    }

    function setPathRate(uint64 pathId, uint64 rateSecondsPerBps_, uint16 maxPerTransferBps_, uint64 cooldownSeconds_)
        external
        onlyOwner
    {
        PathConfig storage p = paths[pathId];
        if (!p.registered || !p.active) revert PathInactive();
        _validatePathRate(rateSecondsPerBps_, maxPerTransferBps_, cooldownSeconds_, p.bounds);
        p.rateSecondsPerBps = rateSecondsPerBps_;
        p.maxPerTransferBps = maxPerTransferBps_;
        p.cooldownSeconds = cooldownSeconds_;
        emit PathRateChanged(pathId, rateSecondsPerBps_, maxPerTransferBps_, cooldownSeconds_);
    }

    /// @notice Request a transfer to a registered path. Instant paths (rate=0) execute when ready
    ///         (readyAt=now); delayed paths FIFO-chain like direct release. Pending counts locked.
    function requestPathTransfer(address token, uint64 pathId, uint256 amount)
        external
        returns (uint256 id, uint256 eta)
    {
        PathConfig storage p = paths[pathId];
        if (!p.registered || !p.active) revert PathInactive();
        if (amount == 0) revert ZeroAmount();
        uint256 bal = balanceOf[token][msg.sender];
        if (amount > bal) revert InsufficientBalance();

        uint256 supply = _totalSupply(token);
        uint256 bps = amount.fullMulDiv(10_000, supply);
        if (bps == 0) revert DustAmount();
        if (bps > p.maxPerTransferBps) revert TransferExceedsMax();

        if (p.cooldownSeconds > 0) {
            uint64 last = lastPathTransferAt[token][pathId];
            if (last != 0 && block.timestamp < uint256(last) + p.cooldownSeconds) revert CooldownActive();
        }

        uint64 duration = uint64(bps * uint256(p.rateSecondsPerBps)); // 0 if instant
        balanceOf[token][msg.sender] = bal - amount;
        pendingToPath[token] += amount;

        id = nextPathRequestId++;
        bool isHead = !_hasActivePath(token);
        uint64 readyAt = isHead ? uint64(block.timestamp) + duration : 0;

        pathRequests[id] = PathRequest({
            token: token,
            requester: msg.sender,
            pathId: pathId,
            amount: uint128(amount),
            duration: duration,
            readyAt: readyAt,
            executed: false,
            cancelled: false
        });
        _pathQueue[token].push(id);

        // Stamp cooldown acceptance time at request (shape of airdropper gate).
        lastPathTransferAt[token][pathId] = uint64(block.timestamp);

        eta = _pathEta(token, id);
        emit PathTransferRequested(id, token, pathId, amount, eta);

        // Instant + already ready: leave for permissionless execute (crank), same as direct.
    }

    function cancelPathTransfer(uint256 id) external {
        PathRequest storage r = pathRequests[id];
        if (r.executed || r.cancelled) revert NotPending();
        if (r.requester != msg.sender) revert NotRequester();
        r.cancelled = true;
        balanceOf[r.token][r.requester] += r.amount;
        pendingToPath[r.token] -= r.amount;
        emit PathTransferCancelled(id);
        _reflowPath(r.token);
    }

    function executePathTransfer(uint256 id) external {
        PathRequest storage r = pathRequests[id];
        if (r.executed || r.cancelled) revert NotPending();
        if (_pathQueueHeadId(r.token) != id) revert NotHead();
        if (r.readyAt == 0 || block.timestamp < r.readyAt) revert NotReady();

        PathConfig storage p = paths[r.pathId];
        // Removal strands nothing: execute still allowed for pending transfers.
        if (!p.registered) revert PathUnknown();

        r.executed = true;
        pendingToPath[r.token] -= r.amount;
        custody[r.token] -= r.amount;
        SafeTransferLib.safeTransfer(r.token, p.path, r.amount);
        IReleasePath(p.path).onVaultPathReceive(r.token, r.amount, r.requester);
        emit PathTransferExecuted(id, r.token, r.pathId, r.amount);
        _reflowPath(r.token);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // internals
    // ═══════════════════════════════════════════════════════════════════════

    function _totalSupply(address token) internal view returns (uint256 supply) {
        (bool ok, bytes memory data) = token.staticcall(abi.encodeWithSignature("totalSupply()"));
        if (!ok || data.length < 32) revert DustAmount();
        supply = abi.decode(data, (uint256));
        if (supply == 0) revert DustAmount();
    }

    function _hasActiveDirect(address token) internal view returns (bool) {
        uint256[] storage q = _queue[token];
        uint256 h = queueHead[token];
        while (h < q.length) {
            DirectRequest storage r = requests[q[h]];
            if (!r.executed && !r.cancelled) return true;
            unchecked {
                ++h;
            }
        }
        return false;
    }

    function _queueHeadId(address token) internal view returns (uint256) {
        uint256[] storage q = _queue[token];
        uint256 h = queueHead[token];
        while (h < q.length) {
            DirectRequest storage r = requests[q[h]];
            if (!r.executed && !r.cancelled) return q[h];
            unchecked {
                ++h;
            }
        }
        return 0;
    }

    function _reflowDirect(address token) internal {
        uint256[] storage q = _queue[token];
        uint256 h = queueHead[token];
        while (h < q.length) {
            DirectRequest storage r = requests[q[h]];
            if (!r.executed && !r.cancelled) {
                queueHead[token] = h;
                if (r.readyAt == 0) {
                    r.readyAt = uint64(block.timestamp) + r.duration;
                }
                return;
            }
            unchecked {
                ++h;
            }
        }
        queueHead[token] = h;
    }

    function _directPosition(address token, uint256 id) internal view returns (uint256 pos) {
        uint256[] storage q = _queue[token];
        uint256 h = queueHead[token];
        for (uint256 i = h; i < q.length; i++) {
            DirectRequest storage r = requests[q[i]];
            if (r.executed || r.cancelled) continue;
            unchecked {
                ++pos;
            }
            if (q[i] == id) return pos;
        }
        return 0;
    }

    function _directEta(address token, uint256 id) internal view returns (uint256) {
        uint256[] storage q = _queue[token];
        uint256 h = queueHead[token];
        uint256 t;
        bool started;
        for (uint256 i = h; i < q.length; i++) {
            DirectRequest storage r = requests[q[i]];
            if (r.executed || r.cancelled) continue;
            if (!started) {
                t = r.readyAt != 0 ? r.readyAt : block.timestamp + r.duration;
                started = true;
            } else {
                t += r.duration;
            }
            if (q[i] == id) return t;
        }
        return 0;
    }

    function _hasActivePath(address token) internal view returns (bool) {
        uint256[] storage q = _pathQueue[token];
        uint256 h = pathQueueHead[token];
        while (h < q.length) {
            PathRequest storage r = pathRequests[q[h]];
            if (!r.executed && !r.cancelled) return true;
            unchecked {
                ++h;
            }
        }
        return false;
    }

    function _pathQueueHeadId(address token) internal view returns (uint256) {
        uint256[] storage q = _pathQueue[token];
        uint256 h = pathQueueHead[token];
        while (h < q.length) {
            PathRequest storage r = pathRequests[q[h]];
            if (!r.executed && !r.cancelled) return q[h];
            unchecked {
                ++h;
            }
        }
        return 0;
    }

    function _reflowPath(address token) internal {
        uint256[] storage q = _pathQueue[token];
        uint256 h = pathQueueHead[token];
        while (h < q.length) {
            PathRequest storage r = pathRequests[q[h]];
            if (!r.executed && !r.cancelled) {
                pathQueueHead[token] = h;
                if (r.readyAt == 0) {
                    r.readyAt = uint64(block.timestamp) + r.duration;
                }
                return;
            }
            unchecked {
                ++h;
            }
        }
        pathQueueHead[token] = h;
    }

    function _pathEta(address token, uint256 id) internal view returns (uint256) {
        uint256[] storage q = _pathQueue[token];
        uint256 h = pathQueueHead[token];
        uint256 t;
        bool started;
        for (uint256 i = h; i < q.length; i++) {
            PathRequest storage r = pathRequests[q[i]];
            if (r.executed || r.cancelled) continue;
            if (!started) {
                t = r.readyAt != 0 ? r.readyAt : block.timestamp + r.duration;
                started = true;
            } else {
                t += r.duration;
            }
            if (q[i] == id) return t;
        }
        return 0;
    }

    function _validatePathRate(uint64 rate, uint16 maxBps, uint64 cooldown, PathBounds memory b) internal pure {
        if (rate < b.minRateSecondsPerBps || rate > b.maxRateSecondsPerBps) revert RateOutOfBounds();
        if (maxBps < b.minMaxPerTransferBps || maxBps > b.maxMaxPerTransferBps) revert RateOutOfBounds();
        if (cooldown < b.minCooldownSeconds || cooldown > b.maxCooldownSeconds) revert RateOutOfBounds();
    }
}
