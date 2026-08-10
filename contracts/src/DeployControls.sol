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

    // ─── stonkzRefPriceWad — pair-wei per STONKZ token, WAD (ruling B) ─────
    // ETH = address(0). Non-zero pair keys use USDG bounds (stable quote).
    /// @dev Launch mid-band ≈ $0.001 at $4k ETH. Unit: pair-wei per STONKZ token, WAD.
    uint256 public constant REF_PRICE_ETH_DEFAULT = 2.5e11; // pair-wei per STONKZ token, WAD
    /// @dev Unit: pair-wei per STONKZ token, WAD. Bounds ±6 orders from launch.
    uint256 public constant REF_PRICE_ETH_MIN = 1e8; // pair-wei per STONKZ token, WAD
    uint256 public constant REF_PRICE_ETH_MAX = 1e17; // pair-wei per STONKZ token, WAD
    /// @dev Mid-band genesis clearing. Unit: pair-wei per STONKZ token, WAD.
    uint256 public constant REF_PRICE_USDG_DEFAULT = 1e15; // pair-wei per STONKZ token, WAD
    /// @dev Unit: pair-wei per STONKZ token, WAD. Bounds ±6 orders from launch.
    uint256 public constant REF_PRICE_USDG_MIN = 1e12; // pair-wei per STONKZ token, WAD
    uint256 public constant REF_PRICE_USDG_MAX = 1e21; // pair-wei per STONKZ token, WAD

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

    /// @notice Per-pair STONKZ ref for side-pool init. Unit: pair-wei per STONKZ token, WAD.
    /// @dev Key address(0) = native ETH. Stamped immutably per deploy when createSidePool=true.
    mapping(address => uint256) public stonkzRefPriceWad;

    /// @notice True iff owner (or birth) configured a ref for `pair`. Unset ⇒ RefPriceUnset on side deploys.
    mapping(address => bool) public stonkzRefPriceConfigured;

    event OwnerTransferred(address indexed prev, address indexed next);
    event DeploysEnabled(bool enabled);
    event DeployerAllowed(address indexed deployer);
    event DeployerRevoked(address indexed deployer);
    event DefaultCreateSidePoolSet(bool createSidePool);
    event DefaultSidePoolBpsSet(uint16 bps);
    event DefaultLiquidityLockedSet(bool locked);
    /// @notice Fired on birth ETH default, Express USDG seed, and every owner update.
    event RefPriceChanged(address indexed pair, uint256 stonkzRefPriceWad_);

    error NotOwner();
    error DeploysOff();
    error DeployerNotAllowed();
    error ZeroAddress();
    error AlreadyAllowed();
    error NotOnAllowlist();
    error SidePoolBpsOutOfBounds(uint16 bps);
    error RefPriceOutOfBounds(address pair, uint256 price);
    error RefPriceUnset(address pair);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @dev Soft-launch gate closed at birth: on + deployer-only allowlist (RIDER A).
    ///      ETH ref default stamped at birth (pair-wei per STONKZ token, WAD).
    constructor() {
        owner = msg.sender;
        deploysEnabled = true;
        isDeployerAllowed[msg.sender] = true;
        allowlistCount = 1;
        emit DeploysEnabled(true);
        emit DeployerAllowed(msg.sender);

        stonkzRefPriceWad[address(0)] = REF_PRICE_ETH_DEFAULT; // pair-wei per STONKZ token, WAD
        stonkzRefPriceConfigured[address(0)] = true;
        emit RefPriceChanged(address(0), REF_PRICE_ETH_DEFAULT);
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

    /// @notice Owner-settable per-pair STONKZ ref. Unit: pair-wei per STONKZ token, WAD.
    /// @dev address(0)=ETH bounds; any other key = USDG bounds. Err-high vs drain risk.
    function setStonkzRefPrice(address pair, uint256 priceWad) external onlyOwner {
        _validateRefPrice(pair, priceWad);
        stonkzRefPriceWad[pair] = priceWad;
        stonkzRefPriceConfigured[pair] = true;
        emit RefPriceChanged(pair, priceWad);
    }

    /// @notice Clear a pair's ref. Subsequent createSidePool=true deploys for that pair revert.
    function clearStonkzRefPrice(address pair) external onlyOwner {
        delete stonkzRefPriceWad[pair];
        stonkzRefPriceConfigured[pair] = false;
        emit RefPriceChanged(pair, 0);
    }

    /// @dev Seed USDG-style default for a non-ETH factory pair (Express constructor).
    function _seedUsdgRefDefault(address pair) internal {
        if (pair == address(0)) return;
        if (stonkzRefPriceConfigured[pair]) return;
        stonkzRefPriceWad[pair] = REF_PRICE_USDG_DEFAULT; // pair-wei per STONKZ token, WAD
        stonkzRefPriceConfigured[pair] = true;
        emit RefPriceChanged(pair, REF_PRICE_USDG_DEFAULT);
    }

    /// @dev Lookup for stamping. Reverts RefPriceUnset — never a silent fallback constant.
    function _requireRefPrice(address pair) internal view returns (uint256 priceWad) {
        if (!stonkzRefPriceConfigured[pair]) revert RefPriceUnset(pair);
        return stonkzRefPriceWad[pair];
    }

    function _validateRefPrice(address pair, uint256 priceWad) internal pure {
        if (pair == address(0)) {
            if (priceWad < REF_PRICE_ETH_MIN || priceWad > REF_PRICE_ETH_MAX) {
                revert RefPriceOutOfBounds(pair, priceWad);
            }
        } else if (priceWad < REF_PRICE_USDG_MIN || priceWad > REF_PRICE_USDG_MAX) {
            revert RefPriceOutOfBounds(pair, priceWad);
        }
    }
}
