// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {IExtsload} from "@v4-core/src/interfaces/IExtsload.sol";

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

    // ─── ETH/USD two-pool spot (owner-set; no constructor coupling) ───────────
    // StateLibrary layout (v4-core): POOLS_SLOT=6, LIQUIDITY_OFFSET=3; slot0 via extsload.
    uint256 internal constant _REF_POOLS_SLOT = 6;
    uint256 internal constant _REF_LIQUIDITY_OFFSET = 3;

    address public refPoolManager;
    bytes32 public refPoolPrimary;
    bytes32 public refPoolCheck;
    bool public refPrimaryEthIs0;
    bool public refCheckEthIs0;
    uint8 public refPrimaryStableDecimals;
    uint8 public refCheckStableDecimals;
    /// @notice Max |primary−check|/primary in bps. Default 500 = 5%.
    uint16 public refAgreementBps = 500;

    /// @notice Max |supplied−live|/live ethUsdWad accepted at list(), in bps. Default 200 = 2%.
    /// @dev Caller supplies ethUsdWad into ListingParams for CREATE2 determinism; live spot only validates.
    uint16 public ethUsdStampBandBps = 200;

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
    event RefPoolsSet(
        address indexed poolManager,
        bytes32 primaryId,
        bool primaryEthIs0,
        uint8 primaryStableDec,
        bytes32 checkId,
        bool checkEthIs0,
        uint8 checkStableDec
    );
    event RefAgreementBpsSet(uint16 bps);
    event EthUsdStampBandBpsSet(uint16 bps);

    error NotOwner();
    error DeploysOff();
    error DeployerNotAllowed();
    error ZeroAddress();
    error AlreadyAllowed();
    error NotOnAllowlist();
    error SidePoolBpsOutOfBounds(uint16 bps);
    error RefPriceOutOfBounds(address pairCurrency, uint256 price);
    error RefPriceUnset(address sideToken, address pairCurrency);
    error RefPoolUnset();
    error RefPoolEmpty(bytes32 poolId);
    error RefPoolsDisagree(uint256 primaryWad, uint256 checkWad);
    error RefAgreementBpsOutOfBounds(uint16 bps);
    error EthUsdStampBandBpsOutOfBounds(uint16 bps);
    error EthUsdStampDrift(uint256 supplied, uint256 current);

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

    /// @notice Owner-designates the two ETH/USD reference pools (initial values set post-deploy).
    function setRefPools(
        address pm,
        bytes32 primaryId,
        bool primaryEthIs0,
        uint8 primaryStableDec,
        bytes32 checkId,
        bool checkEthIs0,
        uint8 checkStableDec
    ) external onlyOwner {
        if (pm == address(0) || primaryId == bytes32(0) || checkId == bytes32(0)) revert ZeroAddress();
        if (primaryStableDec == 0 || checkStableDec == 0) revert ZeroAddress();
        refPoolManager = pm;
        refPoolPrimary = primaryId;
        refPrimaryEthIs0 = primaryEthIs0;
        refPrimaryStableDecimals = primaryStableDec;
        refPoolCheck = checkId;
        refCheckEthIs0 = checkEthIs0;
        refCheckStableDecimals = checkStableDec;
        emit RefPoolsSet(pm, primaryId, primaryEthIs0, primaryStableDec, checkId, checkEthIs0, checkStableDec);
    }

    /// @notice Max relative disagreement between primary and check, in bps of primary. Bounds [1, 2000].
    function setRefAgreementBps(uint16 bps) external onlyOwner {
        if (bps == 0 || bps > 2000) revert RefAgreementBpsOutOfBounds(bps);
        refAgreementBps = bps;
        emit RefAgreementBpsSet(bps);
    }

    /// @notice Max |supplied−live|/live ethUsd at list(), in bps of live. Bounds [1, 1000].
    function setEthUsdStampBandBps(uint16 bps) external onlyOwner {
        if (bps == 0 || bps > 1000) revert EthUsdStampBandBpsOutOfBounds(bps);
        ethUsdStampBandBps = bps;
        emit EthUsdStampBandBpsSet(bps);
    }

    /// @notice Reject caller-supplied ethUsdWad outside the stamp band of live two-pool spot.
    /// @dev Zero supplied reverts. Live read still runs all currentEthUsdWad guards.
    function requireEthUsdFresh(uint256 suppliedWad) public view {
        if (suppliedWad == 0) revert EthUsdStampDrift(0, 0);
        uint256 current = currentEthUsdWad();
        uint256 diff = suppliedWad > current ? suppliedWad - current : current - suppliedWad;
        if (diff > FixedPointMathLib.mulDiv(current, ethUsdStampBandBps, 10_000)) {
            revert EthUsdStampDrift(suppliedWad, current);
        }
    }

    /// @notice USD-per-ETH WAD from two-pool spot agreement. Returns PRIMARY's price.
    /// @dev StateLibrary (v4-core): POOLS_SLOT=6, LIQUIDITY_OFFSET=3; slot0 + liquidity via extsload.
    function currentEthUsdWad() public view returns (uint256) {
        if (refPoolManager == address(0) || refPoolPrimary == bytes32(0) || refPoolCheck == bytes32(0)) {
            revert RefPoolUnset();
        }
        uint256 primaryWad = _ethUsdWadFromPool(refPoolPrimary, refPrimaryEthIs0, refPrimaryStableDecimals);
        uint256 checkWad = _ethUsdWadFromPool(refPoolCheck, refCheckEthIs0, refCheckStableDecimals);
        uint256 diff = primaryWad > checkWad ? primaryWad - checkWad : checkWad - primaryWad;
        if (diff > FixedPointMathLib.mulDiv(primaryWad, refAgreementBps, 10_000)) {
            revert RefPoolsDisagree(primaryWad, checkWad);
        }
        return primaryWad;
    }

    /// @dev Reads slot0 + in-range liquidity; empty pool ⇒ spot freely settable ⇒ never price from it.
    function _ethUsdWadFromPool(bytes32 poolId, bool ethIs0, uint8 stableDecimals)
        internal
        view
        returns (uint256 ethUsdWad)
    {
        // pools[poolId] state slot = keccak256(abi.encodePacked(poolId, POOLS_SLOT))
        bytes32 stateSlot = keccak256(abi.encodePacked(poolId, bytes32(_REF_POOLS_SLOT)));
        IExtsload pm = IExtsload(refPoolManager);
        bytes32 slot0Data = pm.extsload(stateSlot);
        uint128 liquidity = uint128(uint256(pm.extsload(bytes32(uint256(stateSlot) + _REF_LIQUIDITY_OFFSET))));
        if (liquidity == 0) revert RefPoolEmpty(poolId);

        uint160 sqrtPriceX96;
        assembly ("memory-safe") {
            sqrtPriceX96 := and(slot0Data, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
        }
        ethUsdWad = _sqrtPriceToEthUsdWad(sqrtPriceX96, ethIs0, stableDecimals);
    }

    /// @dev USD-per-ETH WAD from Uniswap v4 sqrtPriceX96.
    ///
    /// Scaling derivation (ETH 18-dec, stable `stableDecimals`, e.g. USDG=6):
    ///   price_raw = token1/token0 = sqrtPriceX96² / 2^192
    ///   If ethIs0 (ETH=c0, stable=c1):
    ///     human_stable_per_ETH = price_raw * 10^(dec0 − dec1) = price_raw * 10^(18 − stableDecimals)
    ///     ethUsdWad = human * 1e18 = sqrtP² * 10^(36 − stableDecimals) / 2^192
    ///   If !ethIs0 (stable=c0, ETH=c1):
    ///     human_ETH_per_stable = price_raw * 10^(stableDecimals − 18)
    ///     ethUsdWad = 1e18 / human = 10^(36 − stableDecimals) * 2^192 / sqrtP²
    function _sqrtPriceToEthUsdWad(uint160 sqrtPriceX96, bool ethIs0, uint8 stableDecimals)
        internal
        pure
        returns (uint256)
    {
        uint256 sqrtP = uint256(sqrtPriceX96);
        // 10^(36 - stableDecimals): combines 10^(18-stableDec) human scale with WAD (1e18).
        uint256 scale = 10 ** (36 - uint256(stableDecimals));
        // Split 2^192 across two 2^96 steps so sub-1 price_raw does not truncate to 0.
        uint256 mid = FixedPointMathLib.fullMulDiv(sqrtP, sqrtP, uint256(1) << 96);
        if (ethIs0) {
            return FixedPointMathLib.fullMulDiv(mid, scale, uint256(1) << 96);
        }
        return FixedPointMathLib.fullMulDiv(scale, uint256(1) << 96, mid);
    }
}
