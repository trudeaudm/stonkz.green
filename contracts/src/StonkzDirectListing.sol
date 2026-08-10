// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {IPoolManager} from "./v4/IPoolManager.sol";
import {PoolKey, PoolId, PoolIdLibrary} from "./v4/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "./v4/types/Currency.sol";
import {TickMath} from "./v4/TickMath.sol";
import {LiquidityAmounts} from "./v4/LiquidityAmounts.sol";
import {BuybackAccumulator} from "./BuybackAccumulator.sol";
import {FeeLockerV2} from "./FeeLockerV2.sol";
import {StonkzFeeHook} from "./StonkzFeeHook.sol";
import {CTOGovernor} from "./CTOGovernor.sol";
import {CreatorReserveLib} from "./CreatorReserveLib.sol";
import {StonkzLaunchToken} from "./StonkzLaunchToken.sol";

/// @title StonkzDirectListing — Direct-to-DEX, no auction (fees-and-governance.md §2, spec §8.8)
/// @notice INSTANT coins: creator picks a $4k or $8k start-mcap tier; 95% of listing supply is
///         deployed single-sided into the primary pool over `[startTick, MAX_TICK]` (start mcap →
///         infinity) under FeeLockerV2 custody with StonkzFeeHook attached; 5% seeds the
///         STONKZ4663 side pool (pre-genesis parking + permissionless `deploySidePool`).
///
/// @dev **Rug-impossible by construction (§2.4):** there is no raise and NO function withdraws
///      LP principal. The only outward token transfer is `claimCreatorReserve`, hard-capped by
///      the filed creatorReserve holdback (spec §8.4). Deployed immutable; no admin.
/// @dev **Emergent tier volatility (§2.4):** identical token depth at both tiers, so a lower
///      start mcap ($4k vs $8k) gives a steeper price impact for the same buy — see
///      `quoteBuyImpactWad`. A feature, not a parameter.
contract StonkzDirectListing {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using FixedPointMathLib for uint256;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant TIER_4K = 4000e18;
    uint256 internal constant TIER_8K = 8000e18;
    int24 internal constant TICK_SPACING = 60;
    /// @dev PoolKey.fee is in PIPS (never mix with hookFeeBps). docs/06 rates.
    uint24 internal constant MAIN_LP_FEE = 0; // pips = 0%
    uint24 internal constant SIDE_LP_FEE = 3000; // pips = 0.3%
    /// @dev Side-pool share bounds (docs/03 switch 3). Unit: bps of listing supply.
    uint16 internal constant SIDE_POOL_BPS_MAX = 2000; // bps (20%)

    // ─── immutable wiring ────────────────────────────────────────────────────
    IPoolManager public immutable poolManager;
    FeeLockerV2 public immutable feeLocker;
    StonkzFeeHook public immutable hook;
    BuybackAccumulator public immutable accumulator;
    CTOGovernor public immutable ctoGovernor;
    address public immutable pairToken;
    address public immutable stonkz4663; // address(0) until genesis
    address public immutable creator;
    StonkzLaunchToken public immutable token;

    /// @notice Stamped at deploy (docs/03 switch 2). False ⇒ all listing supply to main, no park.
    bool public immutable createSidePool;
    /// @notice Stamped at deploy (docs/03 switch 3). Unit: bps of listing supply. Recorded even if createSidePool=false.
    uint16 public immutable sidePoolBps;
    /// @notice Stamped at deploy (docs/03 switch 1). TRUE = today's lock behavior (no principal withdraw).
    bool public immutable liquidityLocked;
    /// @notice Stamped at deploy — always creator. Sole withdrawer when unlocked. Immutable.
    address public immutable unlockRecipient;
    /// @notice Stamped at deploy. Unit: pair-wei per STONKZ token, WAD. 0 when createSidePool=false.
    uint256 public immutable stonkzRefPriceWad;

    uint256 public immutable startMcap;
    uint256 public immutable totalSupply;
    uint256 public immutable startPriceWad; // pair per token
    uint160 public immutable startSqrtPriceX96;
    int24 public immutable startTick;

    // ─── conservation buckets (§2.5) ─────────────────────────────────────────
    uint256 public listed; // main-pool tokens (95%)
    uint256 public sidePoolTokens; // side-pool tokens (5%)
    uint256 public creatorReserve; // holdback (§8.4)
    uint128 public mainLiquidity;
    uint128 public sideLiquidity;

    PoolKey public mainPoolKey;
    PoolKey public sidePoolKey;
    bytes32 public mainPositionId;
    bytes32 public sidePositionId;
    uint256 public mainLockId;
    uint256 public sideLockId;
    int24 public sideTickLower;
    int24 public sideTickUpper;
    int24 public mainTickLower;
    int24 public mainTickUpper;
    bool public sidePoolDeployed;

    CreatorReserveLib.State public creatorReserveState;

    // ─── filing params ───────────────────────────────────────────────────────
    struct ListingParams {
        uint256 startMcap; // TIER_4K or TIER_8K only
        uint256 totalSupply;
        uint16 creatorReserveBps; // of total supply (§0)
        uint8 deliveryMode; // 0 INSTANT | 1 VEST (§8.4)
        uint64 vestDuration; // seconds (VEST only)
        bytes32 declaredUse; // optional transparency (§8.5)
        address creator;
        string name;
        string symbol;
        /// @dev Factory path overwrites from DeployControls defaults. Direct tests set explicitly.
        bool createSidePool;
        /// @dev Unit: bps of listing supply (after creatorReserve). Bounds [0, 2000].
        uint16 sidePoolBps;
        /// @dev Factory stamps defaultLiquidityLocked. Direct tests: true = legacy lock.
        bool liquidityLocked;
        /// @dev Unit: pair-wei per STONKZ token, WAD. Factory stamps from DeployControls; 0 if !createSidePool.
        uint256 stonkzRefPriceWad;
    }

    event DirectListed(
        address indexed token,
        address indexed creator,
        uint256 startMcap,
        uint256 listed,
        uint256 sidePoolTokens,
        uint256 creatorReserve,
        bool instant,
        bool createSidePool,
        uint16 sidePoolBps,
        bool liquidityLocked
    );
    event MainPoolCreated(PoolId indexed id, int24 startTick, int24 topTick, uint128 liquidity);
    event SidePoolParked(uint256 tokens);
    event SidePoolDeployed(PoolId indexed id, int24 tickLower, int24 tickUpper, uint256 tokens);
    event CreatorReserveDelivered(address indexed to, uint256 amount);
    event LiquidityWithdrawn(address indexed token, address indexed to, bool main, uint128 liquidity);

    error BadTier();
    error BadSupply();
    error GenesisUnavailable();
    error SideAlreadyDeployed();
    error SidePoolBpsOutOfBounds(uint16 bps);
    error SidePoolDisabled();
    error LiquidityIsLocked();
    error NotUnlockRecipient();
    error NothingToWithdraw();
    error RefPriceUnset();
    error RefPriceOutOfBounds(uint256 price);

    constructor(
        IPoolManager poolManager_,
        FeeLockerV2 feeLocker_,
        StonkzFeeHook hook_,
        BuybackAccumulator accumulator_,
        CTOGovernor ctoGovernor_,
        address pairToken_,
        address stonkz4663_,
        ListingParams memory p
    ) {
        if (p.startMcap != TIER_4K && p.startMcap != TIER_8K) revert BadTier();
        if (p.totalSupply == 0) revert BadSupply();
        if (p.sidePoolBps > SIDE_POOL_BPS_MAX) revert SidePoolBpsOutOfBounds(p.sidePoolBps);
        if (p.createSidePool) {
            if (p.stonkzRefPriceWad == 0) revert RefPriceUnset();
            _validateRefPriceBounds(pairToken_, p.stonkzRefPriceWad);
        }

        poolManager = poolManager_;
        feeLocker = feeLocker_;
        hook = hook_;
        accumulator = accumulator_;
        ctoGovernor = ctoGovernor_;
        pairToken = pairToken_;
        stonkz4663 = stonkz4663_;
        creator = p.creator;
        createSidePool = p.createSidePool;
        sidePoolBps = p.sidePoolBps;
        liquidityLocked = p.liquidityLocked;
        unlockRecipient = p.creator; // stamped immutable — never mutable (Phase 0 rider 4)
        stonkzRefPriceWad = p.createSidePool ? p.stonkzRefPriceWad : 0;
        startMcap = p.startMcap;
        totalSupply = p.totalSupply;

        // Mint checkpointed launch token — all supply to this listing (custody).
        token = new StonkzLaunchToken(p.name, p.symbol, p.totalSupply, address(this));

        // creatorReserve holdback + delivery filing (spec §8.4 / §8.5).
        creatorReserve = FixedPointMathLib.mulDiv(p.totalSupply, p.creatorReserveBps, 10_000);
        uint256 listingSupply = p.totalSupply - creatorReserve;

        bool instant = p.deliveryMode == 0;
        if (creatorReserve > 0) {
            creatorReserveState.mode =
                instant ? CreatorReserveLib.DeliveryMode.Instant : CreatorReserveLib.DeliveryMode.Vest;
            creatorReserveState.vestDuration = p.vestDuration;
            creatorReserveState.total = creatorReserve;
            creatorReserveState.filed = true;
            // INSTANT still passes the 10-min timelock (§8.4); VEST starts now.
            creatorReserveState.unlockedAt = instant
                ? uint64(block.timestamp + CreatorReserveLib.INSTANT_TIMELOCK)
                : uint64(block.timestamp);
        }

        // Side split from stamped switch (docs/03). createSidePool=false ⇒ all mass to main, no park.
        if (p.createSidePool) {
            sidePoolTokens = FixedPointMathLib.mulDiv(listingSupply, p.sidePoolBps, 10_000);
            listed = listingSupply - sidePoolTokens; // remainder-exact
        } else {
            sidePoolTokens = 0;
            listed = listingSupply;
        }

        // Start price = mcap / supply (pair per token), WAD.
        startPriceWad = FixedPointMathLib.mulDiv(p.startMcap, WAD, p.totalSupply);
        bool pairIsToken0 = pairToken_ < address(token);
        startSqrtPriceX96 = _sqrtPriceFromPriceWad(startPriceWad, pairIsToken0);
        startTick = _align(TickMath.getTickAtSqrtRatio(startSqrtPriceX96), TICK_SPACING);

        _createMainPool(pairIsToken0);

        // Side pool: only when stamped createSidePool and sideAmt > 0.
        // Pre-genesis (stonkz unset): park. Genesis createSidePool=false: nothing to park.
        if (sidePoolTokens > 0) {
            if (stonkz4663_ != address(0)) {
                _deploySidePool(sidePoolTokens);
            } else {
                accumulator.parkSidePoolTokens(sidePoolTokens);
                emit SidePoolParked(sidePoolTokens);
            }
        }

        // Register with governance: hook receiver = creator; CTO denominator inputs (§4.1).
        hook.registerPool(address(token), pairToken_, p.creator, mainPoolKey);
        uint256 parked = sidePoolDeployed ? 0 : sidePoolTokens;
        uint256 lpHeld = sidePoolDeployed ? listed + sidePoolTokens : listed;
        ctoGovernor.registerToken(address(token), lpHeld, 0, parked);

        emit DirectListed(
            address(token),
            p.creator,
            p.startMcap,
            listed,
            sidePoolTokens,
            creatorReserve,
            instant,
            p.createSidePool,
            p.sidePoolBps,
            p.liquidityLocked
        );
    }

    // ─── main pool: single-sided [startTick, MAX_TICK] (§2.2) ────────────────

    function _createMainPool(bool pairIsToken0) internal {
        mainPoolKey = _mainPoolKey(pairToken, address(token));
        if (!poolManager.isInitialized(mainPoolKey.toId())) {
            poolManager.initialize(mainPoolKey, startSqrtPriceX96);
        }

        // Range from start to the top usable tick — start mcap → infinity.
        int24 topTick = _alignDown(TickMath.MAX_TICK, TICK_SPACING);
        int24 lowerTick = startTick;
        if (lowerTick >= topTick) lowerTick = topTick - TICK_SPACING;
        mainTickLower = lowerTick;
        mainTickUpper = topTick;

        // Single-sided token liquidity above the opening price.
        bool tokenIsCurrency1 = pairIsToken0; // if pair is currency0, token is currency1
        (,, uint128 liq) = LiquidityAmounts.amountsForSingleSided(lowerTick, topTick, listed, tokenIsCurrency1);
        if (liq == 0 && listed > 0) liq = 1;
        mainLiquidity = liq;

        bytes32 salt = bytes32(uint256(uint160(address(this))));
        poolManager.modifyLiquidity(
            mainPoolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: lowerTick,
                tickUpper: topTick,
                liquidityDelta: int256(uint256(liq)),
                salt: salt
            }),
            ""
        );
        mainPositionId = keccak256(abi.encode(address(this), lowerTick, topTick, salt));
        mainLockId = feeLocker.lockPosition(
            mainPoolKey,
            mainPositionId,
            FeeLockerV2.PoolKind.Main,
            pairToken,
            address(token),
            liquidityLocked,
            unlockRecipient
        );
        emit MainPoolCreated(mainPoolKey.toId(), lowerTick, topTick, liq);
    }

    // ─── side pool (§2.2 / §8.2a) ────────────────────────────────────────────

    /// @notice Permissionless: deploy the side pool once STONKZ4663 genesis spot is readable.
    function deploySidePool() external {
        if (!createSidePool) revert SidePoolDisabled();
        if (sidePoolDeployed) revert SideAlreadyDeployed();
        if (stonkz4663 == address(0)) revert GenesisUnavailable();
        uint256 amt = sidePoolTokens;
        if (accumulator.parkedSidePoolTokens() > 0) {
            amt = accumulator.releaseSidePoolTokens(address(this));
            sidePoolTokens = amt;
        }
        _deploySidePool(amt);
        // Reflect that parked tokens moved into an LP position (§4.1 denominator).
        ctoGovernor.updateDenominator(address(token), listed + sidePoolTokens, 0, 0);
    }

    function _deploySidePool(uint256 tokens) internal {
        // priceInStonkz = startPriceWad / stonkzRefPriceWad (both pair-wei per token, WAD).
        // Unit: STONKZ per userToken. No USD crossing (ruling B).
        uint256 priceInStonkz = FixedPointMathLib.mulDiv(startPriceWad, WAD, stonkzRefPriceWad);
        int24 bottom = TickMath.tickAbovePrice(priceInStonkz, TICK_SPACING);
        int24 top = _align(bottom + 69081, TICK_SPACING);
        if (top <= bottom) top = bottom + TICK_SPACING * 100;

        sideTickLower = bottom;
        sideTickUpper = top;
        sidePoolKey = _sidePoolKey(stonkz4663, address(token));

        uint160 initSqrt = TickMath.getSqrtRatioAtTick(bottom - TICK_SPACING);
        if (!poolManager.isInitialized(sidePoolKey.toId())) {
            poolManager.initialize(sidePoolKey, initSqrt);
        }

        // Dump-immunity: single-sided userToken above spot (zero STONKZ4663 exposure).
        bool userIsC1 = !(Currency.wrap(address(token)).lessThan(Currency.wrap(stonkz4663)));
        (,, uint128 liq) = LiquidityAmounts.amountsForSingleSided(bottom, top, tokens, userIsC1);
        if (liq == 0 && tokens > 0) liq = 1;
        sideLiquidity = liq;

        bytes32 salt = bytes32("directside");
        poolManager.modifyLiquidity(
            sidePoolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: bottom,
                tickUpper: top,
                liquidityDelta: int256(uint256(liq)),
                salt: salt
            }),
            ""
        );
        sidePositionId = keccak256(abi.encode(address(this), bottom, top, salt));
        sideLockId = feeLocker.lockPosition(
            sidePoolKey,
            sidePositionId,
            FeeLockerV2.PoolKind.Side,
            stonkz4663,
            address(token),
            liquidityLocked,
            unlockRecipient
        );
        sidePoolDeployed = true;
        emit SidePoolDeployed(sidePoolKey.toId(), bottom, top, tokens);
    }

    /// @dev Bounds mirror DeployControls: ETH [1e8,1e17]; else USDG [1e12,1e21]. Unit: pair-wei/STONKZ WAD.
    function _validateRefPriceBounds(address pair, uint256 priceWad) internal pure {
        if (pair == address(0)) {
            if (priceWad < 1e8 || priceWad > 1e17) revert RefPriceOutOfBounds(priceWad);
        } else if (priceWad < 1e12 || priceWad > 1e21) {
            revert RefPriceOutOfBounds(priceWad);
        }
    }

    // ─── unlock withdraw (docs/03 switch 1) — gated on stamped liquidityLocked ─

    /// @notice Withdraw main-pool LP principal. Only when `liquidityLocked == false` and
    ///         caller == stamped `unlockRecipient` (creator).
    function withdrawMainLiquidity() external {
        _requireUnlockedCaller();
        if (mainLiquidity == 0) revert NothingToWithdraw();
        uint128 liq = mainLiquidity;
        mainLiquidity = 0;
        bytes32 salt = bytes32(uint256(uint160(address(this))));
        poolManager.modifyLiquidity(
            mainPoolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: mainTickLower,
                tickUpper: mainTickUpper,
                liquidityDelta: -int256(uint256(liq)),
                salt: salt
            }),
            ""
        );
        feeLocker.markWithdrawn(mainLockId);
        emit LiquidityWithdrawn(address(token), unlockRecipient, true, liq);
    }

    /// @notice Withdraw side-pool LP principal. Same gate as main.
    function withdrawSideLiquidity() external {
        _requireUnlockedCaller();
        if (!sidePoolDeployed || sideLiquidity == 0) revert NothingToWithdraw();
        uint128 liq = sideLiquidity;
        sideLiquidity = 0;
        bytes32 salt = bytes32("directside");
        poolManager.modifyLiquidity(
            sidePoolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: sideTickLower,
                tickUpper: sideTickUpper,
                liquidityDelta: -int256(uint256(liq)),
                salt: salt
            }),
            ""
        );
        feeLocker.markWithdrawn(sideLockId);
        emit LiquidityWithdrawn(address(token), unlockRecipient, false, liq);
    }

    function _requireUnlockedCaller() internal view {
        if (liquidityLocked) revert LiquidityIsLocked();
        if (msg.sender != unlockRecipient) revert NotUnlockRecipient();
        feeLocker.requireCanWithdraw(address(token), msg.sender);
    }

    // ─── creatorReserve delivery (§8.4) — bounded, NOT a rug ──────────────────

    /// @notice Deliver vested/unlocked creatorReserve to the creator. Hard-capped by the filed
    ///         holdback; touches NO LP principal (§2.4 rug-impossibility).
    function claimCreatorReserve() external returns (uint256 amount) {
        amount = CreatorReserveLib.vestedAvailable(creatorReserveState, uint64(block.timestamp));
        if (amount == 0) return 0;
        creatorReserveState.claimed += amount;
        token.transfer(creator, amount);
        emit CreatorReserveDelivered(creator, amount);
    }

    // ─── views ───────────────────────────────────────────────────────────────

    /// @notice Full primary-pool key (the flattened public getter can't return the struct).
    function mainKey() external view returns (PoolKey memory) {
        return mainPoolKey;
    }

    function sideKey() external view returns (PoolKey memory) {
        return sidePoolKey;
    }

    /// @notice Conservation (§2.5): listed + sidePoolTokens + creatorReserve == totalSupply.
    function conservationSum() external view returns (uint256) {
        return listed + sidePoolTokens + creatorReserve;
    }

    function conservationBuckets() external view returns (uint256 listed_, uint256 side_, uint256 creatorReserve_) {
        return (listed, sidePoolTokens, creatorReserve);
    }

    /// @notice Emergent tier-volatility quote (§2.4): fraction (WAD) of the single-sided token
    ///         depth consumed by a `pairIn` buy = (pairIn / startPrice) / listed. Orientation-
    ///         independent and monotone: identical token depth (`listed`) at both tiers, so a
    ///         lower start mcap (lower `startPriceWad`) ⇒ more tokens per dollar ⇒ larger value
    ///         ⇒ steeper price impact. A feature, not a parameter.
    function quoteBuyImpactWad(uint256 pairIn) external view returns (uint256) {
        if (startPriceWad == 0 || listed == 0) return 0;
        uint256 tokensBought = FixedPointMathLib.mulDiv(pairIn, WAD, startPriceWad);
        return FixedPointMathLib.mulDiv(tokensBought, WAD, listed);
    }

    // ─── internal helpers (mirror StonkzLiquidityStrategy) ───────────────────

    /// @dev docs/06: fee 0, hook attached (StonkzFeeHook). Shared `_poolKey` removed in FEECHAIN Phase 2.
    function _mainPoolKey(address a, address b) internal view returns (PoolKey memory key) {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: MAIN_LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: address(hook)
        });
    }

    /// @dev docs/06: LP fee 3000 pips = 0.3%, NO hook.
    function _sidePoolKey(address a, address b) internal pure returns (PoolKey memory key) {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: SIDE_LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: address(0)
        });
    }

    function _sqrtPriceFromPriceWad(uint256 priceWad, bool pairIsToken0) internal pure returns (uint160) {
        uint256 px = priceWad;
        if (pairIsToken0) {
            px = priceWad == 0 ? WAD : FixedPointMathLib.mulDiv(WAD, WAD, priceWad);
        }
        uint256 sqrtP = _sqrt(px);
        uint256 sqrtX96 = FixedPointMathLib.fullMulDiv(sqrtP, uint256(1) << 96, 1e9);
        if (sqrtX96 <= TickMath.MIN_SQRT_RATIO) return TickMath.MIN_SQRT_RATIO + 1;
        if (sqrtX96 >= TickMath.MAX_SQRT_RATIO) return TickMath.MAX_SQRT_RATIO - 1;
        return uint160(sqrtX96);
    }

    function _align(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 rem = tick % spacing;
        if (rem < 0) rem += spacing;
        return tick - rem;
    }

    function _alignDown(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 rem = tick % spacing;
        if (rem < 0) rem += spacing;
        return tick - rem;
    }

    function _sqrt(uint256 x) internal pure returns (uint256 z) {
        if (x == 0) return 0;
        z = x;
        uint256 y = (x + 1) / 2;
        while (y < z) {
            z = y;
            y = (x / y + y) / 2;
        }
    }
}
