// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/// @title DeployControls — factory switches (docs/03 Factory switches)
/// @notice Mutable on each factory instance; gate checked at file/list. Side-pool defaults
///         stamped immutably per token at deploy (Phase 2). Lock stamp is Phase 3.
///         Allowlist is NOT renounceable — purpose = factory migration.
/// @dev Birth state (RIDER A): deploysEnabled=true + allowlist = {constructor msg.sender}.
///      Semantics: off → all blocked; on+empty → open; on+nonempty → allowlisted only.
abstract contract DeployControls {
    /// @dev Side pool share of LP-destined tokens. Unit: bps (0–20%). Launch default 500 = 5%.
    uint16 public constant SIDE_POOL_BPS_MAX = 2000; // bps of LP-destined tokens (20%)
    uint16 public constant DEFAULT_SIDE_POOL_BPS = 500; // bps of LP-destined tokens (5%)

    // ─── refPriceWad — pair-wei per side-token, WAD; key (sideToken, pairCurrency) ─
    // pairCurrency address(0) = native ETH. Non-zero pair keys use USDG bounds (stable quote).
    /// @dev Launch mid-band ≈ $0.001 at $4k ETH. Unit: pair-wei per side-token, WAD.
    uint256 public constant REF_PRICE_ETH_DEFAULT = 2.5e11; // pair-wei per side-token, WAD
    /// @dev Unit: pair-wei per side-token, WAD. Bounds ±6 orders from launch.
    uint256 public constant REF_PRICE_ETH_MIN = 1e8; // pair-wei per side-token, WAD
    uint256 public constant REF_PRICE_ETH_MAX = 1e17; // pair-wei per side-token, WAD
    /// @dev Mid-band genesis clearing. Unit: pair-wei per side-token, WAD.
    uint256 public constant REF_PRICE_USDG_DEFAULT = 1e15; // pair-wei per side-token, WAD
    /// @dev Unit: pair-wei per side-token, WAD. Bounds ±6 orders from launch.
    uint256 public constant REF_PRICE_USDG_MIN = 1e12; // pair-wei per side-token, WAD
    uint256 public constant REF_PRICE_USDG_MAX = 1e21; // pair-wei per side-token, WAD

    address public owner;

    /// @notice Master deploy switch. False blocks every file/list regardless of allowlist.
    bool public deploysEnabled;

    /// @notice Owner-managed deployer set. Empty + deploysEnabled ⇒ open (any caller).
    mapping(address => bool) public isDeployerAllowed;

    /// @notice Count of allowlisted addresses. Used to distinguish empty vs nonempty without iteration.
    uint256 public allowlistCount;

    /// @notice Mutable factory default: create protocol-token side pool at deploy. Stamped per token.
    bool public defaultCreateSidePool = true;

    /// @notice Mutable factory default side-pool share. Bounds [0, SIDE_POOL_BPS_MAX]. Unit: bps.
    uint16 public defaultSidePoolBps = DEFAULT_SIDE_POOL_BPS; // bps of LP-destined tokens (5%)

    /// @notice Mutable factory default: lock LP at deploy. Stamped per token. Launch default TRUE.
    bool public defaultLiquidityLocked = true;

    /// @notice Per-(sideToken, pairCurrency) ref for side-pool init. Unit: pair-wei per side-token, WAD.
    /// @dev pairCurrency address(0) = native ETH. Stamped immutably per deploy when createSidePool=true.
    mapping(address => mapping(address => uint256)) public refPriceWad;

    /// @notice True iff owner (or seed) configured a ref for `(sideToken, pairCurrency)`.
    mapping(address => mapping(address => bool)) public refPriceConfigured;

    event OwnerTransferred(address indexed prev, address indexed next);
    event DeploysEnabled(bool enabled);
    event DeployerAllowed(address indexed deployer);
    event DeployerRevoked(address indexed deployer);
    event DefaultCreateSidePoolSet(bool createSidePool);
    event DefaultSidePoolBpsSet(uint16 bps);
    event DefaultLiquidityLockedSet(bool locked);
    /// @notice Fired on seed defaults and every owner update/clear.
    event RefPriceChanged(address indexed sideToken, address indexed pairCurrency, uint256 refPriceWad_);

    error NotOwner();
    error DeploysOff();
    error DeployerNotAllowed();
    error ZeroAddress();
    error AlreadyAllowed();
    error NotOnAllowlist();
    error SidePoolBpsOutOfBounds(uint16 bps);
    error RefPriceOutOfBounds(address pairCurrency, uint256 price);
    error RefPriceUnset(address sideToken, address pairCurrency);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @dev Soft-launch gate closed at birth: on + deployer-only allowlist (RIDER A).
    ///      Ref prices are seeded when `sideTokenRef` is set (not at DeployControls birth).
    constructor() {
        owner = msg.sender;
        deploysEnabled = true;
        isDeployerAllowed[msg.sender] = true;
        allowlistCount = 1;
        emit DeploysEnabled(true);
        emit DeployerAllowed(msg.sender);
    }

    function transferOwnership(address next) external onlyOwner {
        if (next == address(0)) revert ZeroAddress();
        emit OwnerTransferred(owner, next);
        owner = next;
    }

    function setDeploysEnabled(bool enabled) external onlyOwner {
        deploysEnabled = enabled;
        emit DeploysEnabled(enabled);
    }

    function allowDeployer(address deployer) external onlyOwner {
        if (deployer == address(0)) revert ZeroAddress();
        if (isDeployerAllowed[deployer]) revert AlreadyAllowed();
        isDeployerAllowed[deployer] = true;
        unchecked {
            ++allowlistCount;
        }
        emit DeployerAllowed(deployer);
    }

    /// @notice Remove a deployer. Emptying the list (open mode) is allowed; the allowlist
    ///         *feature* is not renounceable — owner can always re-add.
    function revokeDeployer(address deployer) external onlyOwner {
        if (!isDeployerAllowed[deployer]) revert NotOnAllowlist();
        isDeployerAllowed[deployer] = false;
        unchecked {
            --allowlistCount;
        }
        emit DeployerRevoked(deployer);
    }

    /// @notice Soft-launch / migration gate. docs/03 switch 4.
    function _requireDeployAllowed(address account) internal view {
        if (!deploysEnabled) revert DeploysOff();
        if (allowlistCount > 0 && !isDeployerAllowed[account]) revert DeployerNotAllowed();
    }

    /// @notice Soft-launch / ops assertion for RIDER A birth (or post-config) state.
    /// @dev Reverts if soft-launch gate is not closed: must be enabled + nonempty allowlist
    ///      containing `expectedDeployer`.
    function assertSoftLaunchGate(address expectedDeployer) public view {
        if (!deploysEnabled) revert DeploysOff();
        if (allowlistCount == 0) revert DeployerNotAllowed();
        if (!isDeployerAllowed[expectedDeployer]) revert DeployerNotAllowed();
    }

    /// @notice Mutable default for switch 2 (create side pool). Stamped per token at deploy.
    function setDefaultCreateSidePool(bool create) external onlyOwner {
        defaultCreateSidePool = create;
        emit DefaultCreateSidePoolSet(create);
    }

    /// @notice Mutable default for switch 3 (side pool share). Bounds [0, 2000] bps.
    function setDefaultSidePoolBps(uint16 bps) external onlyOwner {
        if (bps > SIDE_POOL_BPS_MAX) revert SidePoolBpsOutOfBounds(bps);
        defaultSidePoolBps = bps;
        emit DefaultSidePoolBpsSet(bps);
    }

    /// @notice Mutable default for switch 1 (lock liquidity). Stamped per token at deploy.
    function setDefaultLiquidityLocked(bool locked) external onlyOwner {
        defaultLiquidityLocked = locked;
        emit DefaultLiquidityLockedSet(locked);
    }

    /// @notice Owner-settable per-(sideToken, pairCurrency) ref. Unit: pair-wei per side-token, WAD.
    /// @dev pairCurrency address(0)=ETH bounds; any other key = USDG bounds. Err-high vs drain risk.
    function setRefPrice(address sideToken, address pairCurrency, uint256 priceWad) external onlyOwner {
        _validateRefPrice(pairCurrency, priceWad);
        refPriceWad[sideToken][pairCurrency] = priceWad;
        refPriceConfigured[sideToken][pairCurrency] = true;
        emit RefPriceChanged(sideToken, pairCurrency, priceWad);
    }

    /// @notice Clear a (sideToken, pair) ref. Subsequent createSidePool=true deploys for that combo revert.
    function clearRefPrice(address sideToken, address pairCurrency) external onlyOwner {
        delete refPriceWad[sideToken][pairCurrency];
        refPriceConfigured[sideToken][pairCurrency] = false;
        emit RefPriceChanged(sideToken, pairCurrency, 0);
    }

    /// @dev Seed ETH (+ optional USDG-style pair) defaults for a side-token stand-in. Idempotent per key.
    function _seedDefaultRefPrices(address sideToken, address pairCurrency) internal {
        if (sideToken == address(0)) return;
        if (!refPriceConfigured[sideToken][address(0)]) {
            refPriceWad[sideToken][address(0)] = REF_PRICE_ETH_DEFAULT; // pair-wei per side-token, WAD
            refPriceConfigured[sideToken][address(0)] = true;
            emit RefPriceChanged(sideToken, address(0), REF_PRICE_ETH_DEFAULT);
        }
        if (pairCurrency != address(0) && !refPriceConfigured[sideToken][pairCurrency]) {
            refPriceWad[sideToken][pairCurrency] = REF_PRICE_USDG_DEFAULT; // pair-wei per side-token, WAD
            refPriceConfigured[sideToken][pairCurrency] = true;
            emit RefPriceChanged(sideToken, pairCurrency, REF_PRICE_USDG_DEFAULT);
        }
    }

    /// @dev Lookup for stamping. Reverts RefPriceUnset — never a silent fallback constant.
    function _requireRefPrice(address sideToken, address pairCurrency) internal view returns (uint256 priceWad) {
        if (!refPriceConfigured[sideToken][pairCurrency]) revert RefPriceUnset(sideToken, pairCurrency);
        return refPriceWad[sideToken][pairCurrency];
    }

    function _validateRefPrice(address pairCurrency, uint256 priceWad) internal pure {
        if (pairCurrency == address(0)) {
            if (priceWad < REF_PRICE_ETH_MIN || priceWad > REF_PRICE_ETH_MAX) {
                revert RefPriceOutOfBounds(pairCurrency, priceWad);
            }
        } else if (priceWad < REF_PRICE_USDG_MIN || priceWad > REF_PRICE_USDG_MAX) {
            revert RefPriceOutOfBounds(pairCurrency, priceWad);
        }
    }
}
