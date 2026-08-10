// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {IPoolManager} from "../src/v4/IPoolManager.sol";
import {PoolKey, PoolId, PoolIdLibrary} from "../src/v4/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "../src/v4/types/Currency.sol";
import {TickMath} from "../src/v4/TickMath.sol";
import {LiquidityAmounts} from "../src/v4/LiquidityAmounts.sol";
import {BuybackAccumulator} from "../src/BuybackAccumulator.sol";
import {FeeLocker} from "../src/FeeLocker.sol";
import {StonkzFeeHook} from "../src/StonkzFeeHook.sol";

/// @title StonkzLiquidityStrategy — LEGACY (V4-CANON Phase 2)
/// @notice Retired from the official deploy manifest. Not imported by live Express/Ladder
///         factories. Kept for historical FEECHAIN / seam tests only. Prefer
///         StonkzDirectListing + LadderSettlement.
/// @dev Post-auction settlement into Uniswap v4 (spec §8). Dual-backend mock-era.
contract StonkzLiquidityStrategy {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using FixedPointMathLib for uint256;

    uint256 internal constant WAD = 1e18;
    uint16 internal constant MAIN_BPS = 9500; // F_main = 95% × F — spec §8.1
    uint16 internal constant CARVE_BPS = 500; // F_carve = 5% × F
    uint16 internal constant SIDE_TOKEN_BPS = 500; // 5% of LP-designated tokens — spec §8.2a
    int24 internal constant TICK_SPACING = 60;
    /// @dev PoolKey.fee is in PIPS (never mix with hookFeeBps). docs/06 rates.
    uint24 internal constant MAIN_LP_FEE = 0; // pips = 0%
    uint24 internal constant SIDE_LP_FEE = 3000; // pips = 0.3%
    uint256 internal constant DEFAULT_SYNC_BUDGET = 50 ether;

    IPoolManager public immutable poolManager;
    BuybackAccumulator public immutable accumulator;
    FeeLocker public immutable feeLocker;
    StonkzFeeHook public immutable hook;
    address public immutable stonkz4663; // address(0) until genesis
    address public immutable pairToken;

    // ─── conservation accounting (spec §9 I1 / C5) ─────────────────────────
    uint256 public sold;
    uint256 public mainPaired;
    uint256 public sidePoolTokens;
    uint256 public surplusRouted;
    uint256 public excessRouted;
    uint256 public creatorReserve;

    uint256 public fMain;
    uint256 public fCarve;
    uint256 public printPrice;
    uint256 public mainLockId;
    uint256 public sideLockId;
    bool public sidePoolDeployed;
    bool public settled;

    PoolKey public mainPoolKey;
    PoolKey public sidePoolKey;
    bytes32 public mainPositionId;
    bytes32 public sidePositionId;
    int24 public sideTickLower;
    int24 public sideTickUpper;

    address public auction; // set once; only auction may settle
    address public userToken;
    address public creator;
    uint8 public disposalMode;
    uint256 public syncBudget;

    event SettlementExecuted(
        address indexed auction,
        uint256 fMain,
        uint256 fCarve,
        uint256 mainPaired,
        uint256 sidePoolTokens,
        uint256 surplusRouted,
        uint256 excessRouted
    );
    event SidePoolDeployed(PoolId indexed id, int24 tickLower, int24 tickUpper, uint256 tokens);
    event SidePoolParked(uint256 tokens);
    event SurplusDisposed(uint8 mode, uint256 amount);
    event DustSwept(uint256 amount);

    error AlreadySettled();
    error OnlyAuction();
    error SyncOverrun(uint256 spent, uint256 budget);
    error NaiveFullRangeForbidden();
    error GenesisSpotUnavailable();

    constructor(
        IPoolManager poolManager_,
        BuybackAccumulator accumulator_,
        FeeLocker feeLocker_,
        StonkzFeeHook hook_,
        address pairToken_,
        address stonkz4663_
    ) {
        require(address(hook_) != address(0), "hook");
        poolManager = poolManager_;
        accumulator = accumulator_;
        feeLocker = feeLocker_;
        hook = hook_;
        pairToken = pairToken_;
        stonkz4663 = stonkz4663_;
        syncBudget = DEFAULT_SYNC_BUDGET;
    }

    function setAuction(address auction_) external {
        require(auction == address(0), "set");
        auction = auction_;
    }

    function setSyncBudget(uint256 budget) external {
        // Permissionless crank bound is hardcoded in accumulator; settle sync budget
        // is a caller-facing retry knob — only auction/creator path in production.
        // For M3 tests: allow anyone before settle (immutable after settle).
        require(!settled, "settled");
        syncBudget = budget;
    }

    /// @notice Settlement entry from auction after graduation (spec §8.1–§8.2).
    /// @param sold_ tokens sold to bidders
    /// @param lpFunds F = LP-share × raised (pair currency)
    /// @param printPrice_ P = last sold price (WAD)
    /// @param reserveTokens LP-designated tokens available to pair (reserve remaining + dust)
    /// @param auctionExcess unsold auction allocation
    /// @param creatorReserve_ token holdback (never paired)
    /// @param disposalMode_ 0 thicker / 1 holders / 2 creator / 3 burn
    /// @param userToken_ launch token address (mock OK)
    /// @param creator_ recipient for treasury / creator surplus
    function settle(
        uint256 sold_,
        uint256 lpFunds,
        uint256 printPrice_,
        uint256 reserveTokens,
        uint256 auctionExcess,
        uint256 creatorReserve_,
        uint8 disposalMode_,
        address userToken_,
        address creator_
    ) external payable returns (bool) {
        if (auction != address(0) && msg.sender != auction) revert OnlyAuction();
        if (settled) revert AlreadySettled();
        settled = true;

        sold = sold_;
        printPrice = printPrice_;
        creatorReserve = creatorReserve_;
        disposalMode = disposalMode_;
        userToken = userToken_;
        creator = creator_;

        // 95/5 funds split — spec §8.1 (no market buys in settle)
        fMain = FixedPointMathLib.mulDiv(lpFunds, MAIN_BPS, 10_000);
        fCarve = lpFunds - fMain;

        if (fCarve > 0 && msg.value > 0) {
            uint256 v = msg.value >= fCarve ? fCarve : msg.value;
            accumulator.receiveCarve{value: v}();
        }
        // ERC20 / accounting-only pair path: carve tracked via fCarve + SettlementExecuted event.

        // Side-pool token set-aside: 5% of LP-designated tokens — spec §8.2a
        uint256 sideAmt = FixedPointMathLib.mulDiv(reserveTokens, SIDE_TOKEN_BPS, 10_000);
        uint256 mainReserve = reserveTokens - sideAmt;
        sidePoolTokens = sideAmt;

        // Price-setting: F_main + F_main/P tokens — INVARIANT tokens*P == usd (spec §8.2)
        uint256 P = printPrice_ == 0 ? WAD : printPrice_;
        uint256 need = FixedPointMathLib.mulDiv(fMain, WAD, P);
        // Forbid naive full-range of ALL remaining tokens
        if (need > 0 && mainReserve > need * 100) {
            // soft guard for tests that pass absurd reserves — still pair only `need`
        }
        require(need == 0 || FixedPointMathLib.mulDiv(need, P, WAD) <= fMain + 1, "ratio");

        // Explicit unreachable path for invariant tests
        if (_wouldNaiveFullRange(mainReserve, fMain, P)) revert NaiveFullRangeForbidden();

        mainPaired = need < mainReserve ? need : mainReserve;
        uint256 pairingSurplus = mainReserve > mainPaired ? mainReserve - mainPaired : 0;

        // Sync spot to print with bounded budget — spec §8.7
        mainPoolKey = _mainPoolKey(pairToken, userToken_);
        uint160 targetSqrt = _sqrtPriceFromPriceWad(P, pairToken < userToken_);
        try poolManager.syncToPrice(mainPoolKey, targetSqrt, syncBudget) returns (uint256 spent) {
            spent; // silence
        } catch (bytes memory reason) {
            // Decode SyncBudgetExceeded if present → retryable
            if (reason.length >= 4) {
                bytes4 sel;
                assembly {
                    sel := mload(add(reason, 0x20))
                }
                if (sel == IPoolManager.SyncBudgetExceeded.selector) {
                    revert SyncOverrun(syncBudget, syncBudget);
                }
            }
            // If pool missing, initialize at target
            if (!poolManager.isInitialized(mainPoolKey.toId())) {
                poolManager.initialize(mainPoolKey, targetSqrt);
            }
        }

        // Attach fee hook (docs/06). Main fees: StonkzFeeHook accrue-and-flush (FeeLocker crank retired).
        if (!hook.registered(userToken_)) {
            hook.registerPool(userToken_, pairToken, creator_, mainPoolKey);
        }

        // Add price-setting liquidity spanning the print
        int24 tick = TickMath.getTickAtSqrtRatio(targetSqrt);
        int24 spacing = TICK_SPACING;
        int24 lower = tick - spacing * 10;
        int24 upper = tick + spacing * 10;
        lower = _align(lower, spacing);
        upper = _align(upper, spacing);
        if (lower >= upper) {
            lower = tick - spacing;
            upper = tick + spacing;
        }

        uint128 liq = LiquidityAmounts.getLiquidityForAmounts(
            targetSqrt,
            TickMath.getSqrtRatioAtTick(lower),
            TickMath.getSqrtRatioAtTick(upper),
            pairToken < userToken_ ? mainPaired : fMain, // amount0 heuristic
            pairToken < userToken_ ? fMain : mainPaired
        );
        if (liq == 0 && (mainPaired > 0 || fMain > 0)) liq = 1;

        bytes32 salt = bytes32(uint256(uint160(address(this))));
        poolManager.modifyLiquidity(
            mainPoolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: lower,
                tickUpper: upper,
                liquidityDelta: int256(uint256(liq)),
                salt: salt
            }),
            ""
        );
        mainPositionId = keccak256(abi.encode(address(this), lower, upper, salt));
        mainLockId = feeLocker.lockPosition(
            mainPoolKey, mainPositionId, FeeLocker.PoolKind.Main, pairToken, userToken_
        );

        // Surplus + auction excess → disposal (spec §8.2)
        uint256 surplus = pairingSurplus;
        excessRouted = auctionExcess;
        uint256 toDispose = surplus + auctionExcess;
        _dispose(toDispose, disposalMode_);
        surplusRouted = surplus;

        // Side pool: deploy if genesis spot live, else park — spec §8.2a
        if (sideAmt > 0) {
            if (stonkz4663 != address(0) && _genesisSpotLive()) {
                _deploySidePool(sideAmt, P);
            } else {
                accumulator.parkSidePoolTokens(sideAmt);
                emit SidePoolParked(sideAmt);
            }
        }

        emit SettlementExecuted(msg.sender, fMain, fCarve, mainPaired, sidePoolTokens, surplusRouted, excessRouted);
        return true;
    }

    /// @notice Permissionless side-pool deploy once STONKZ4663 genesis spot is readable (spec §8.2a).
    function deploySidePool() external {
        require(settled && !sidePoolDeployed, "state");
        require(stonkz4663 != address(0) && _genesisSpotLive(), "genesis");
        uint256 amt = sidePoolTokens;
        if (accumulator.parkedSidePoolTokens() > 0) {
            amt = accumulator.releaseSidePoolTokens(address(this));
            sidePoolTokens = amt;
        }
        require(amt > 0, "empty");
        _deploySidePool(amt, printPrice);
    }

    /// @notice Conservation view for I1 / C5: sold + mainPaired + sidePoolTokens + surplusRouted + excessRouted + creatorReserve
    function conservationSum() external view returns (uint256) {
        return sold + mainPaired + sidePoolTokens + surplusRouted + excessRouted + creatorReserve;
    }

    function conservationBuckets()
        external
        view
        returns (
            uint256 sold_,
            uint256 mainPaired_,
            uint256 sidePoolTokens_,
            uint256 surplusRouted_,
            uint256 excessRouted_,
            uint256 creatorReserve_
        )
    {
        return (sold, mainPaired, sidePoolTokens, surplusRouted, excessRouted, creatorReserve);
    }

    // ─── internal ──────────────────────────────────────────────────────────

    function _deploySidePool(uint256 tokens, uint256 gradPriceUsd) internal {
        // bottom = 1 tick above graduation price in STONKZ4663 terms
        // gradPriceUsd / stonkz4663SpotUsd — mock uses 1e18 spot ⇒ price = gradPriceUsd
        uint256 spot = _stonkzSpotUsd();
        uint256 priceInStonkz = FixedPointMathLib.mulDiv(gradPriceUsd, WAD, spot == 0 ? WAD : spot);
        int24 bottom = TickMath.tickAbovePrice(priceInStonkz, TICK_SPACING);
        // top = 1000× bottom in price space ≈ +69081 ticks (ln(1000)/ln(1.0001))
        int24 top = bottom + 69081;
        top = _align(top, TICK_SPACING);
        if (top <= bottom) top = bottom + TICK_SPACING * 100;

        sideTickLower = bottom;
        sideTickUpper = top;
        sidePoolKey = _sidePoolKey(stonkz4663, userToken);

        // Dump-immunity: initialize at bottom (range above spot) with ZERO stonkz — only userToken
        uint160 initSqrt = TickMath.getSqrtRatioAtTick(bottom - TICK_SPACING);
        if (!poolManager.isInitialized(sidePoolKey.toId())) {
            poolManager.initialize(sidePoolKey, initSqrt);
        } else {
            poolManager.syncToPrice(sidePoolKey, initSqrt, syncBudget);
        }

        bool tokensAreC1 = stonkz4663 < userToken; // if stonkz is c0, user is c1
        // Single-sided userToken above current → tokens on the side that is userToken
        bool userIsC1 = !(Currency.wrap(userToken).lessThan(Currency.wrap(stonkz4663)));
        (,, uint128 liq) = LiquidityAmounts.amountsForSingleSided(bottom, top, tokens, userIsC1);
        if (liq == 0) liq = uint128(tokens > type(uint128).max ? type(uint128).max : tokens);

        bytes32 salt = bytes32("side");
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
        sideLockId =
            feeLocker.lockPosition(sidePoolKey, sidePositionId, FeeLocker.PoolKind.Side, stonkz4663, userToken);
        sidePoolDeployed = true;
        tokensAreC1; // silence
        emit SidePoolDeployed(sidePoolKey.toId(), bottom, top, tokens);
    }

    function _dispose(uint256 amount, uint8 mode) internal {
        if (amount == 0) return;
        // 0 thicker LP above print — modeled as surplusRouted staying in accounting
        // 1 holders airdrop — accounting bucket
        // 2 creator
        // 3 burn
        emit SurplusDisposed(mode, amount);
    }

    /// @dev docs/06: fee 0, hook attached. Shared `_poolKey` removed in FEECHAIN Phase 2.
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
        // Interpret priceWad as token1/token0 in WAD. If pair is token1, price is pair/user = P.
        // sqrtPrice = sqrt(token1/token0) * 2^96
        uint256 px = priceWad;
        if (!pairIsToken0) {
            // user is token0, pair is token1 → price = P (pair per user) ✓
        } else {
            // pair is token0 → price = user/pair = 1/P
            px = priceWad == 0 ? WAD : FixedPointMathLib.mulDiv(WAD, WAD, priceWad);
        }
        uint256 sqrtP = _sqrt(px); // ~1e9 for 1e18
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

    function _sqrt(uint256 x) internal pure returns (uint256 z) {
        if (x == 0) return 0;
        z = x;
        uint256 y = (x + 1) / 2;
        while (y < z) {
            z = y;
            y = (x / y + y) / 2;
        }
    }

    function _genesisSpotLive() internal view returns (bool) {
        // Genesis live when stonkz4663 is set; mock treats spot as 1e18 always.
        return stonkz4663 != address(0);
    }

    function _stonkzSpotUsd() internal pure returns (uint256) {
        return WAD; // $1 mock until oracle/pool wired
    }

    /// @dev True iff depositing ALL tokens against fMain would open far below print.
    function _wouldNaiveFullRange(uint256 allTokens, uint256 usd, uint256 P) internal pure returns (bool) {
        if (allTokens == 0 || usd == 0 || P == 0) return false;
        uint256 openPrice = FixedPointMathLib.mulDiv(usd, WAD, allTokens);
        return openPrice < P / 2; // catastrophic below print
    }

    /// @notice Test hook: assert naive full-range is rejected.
    function assertNaiveFullRangeUnreachable(uint256 allTokens, uint256 usd, uint256 P) external pure {
        if (_wouldNaiveFullRange(allTokens, usd, P)) revert NaiveFullRangeForbidden();
    }
}
