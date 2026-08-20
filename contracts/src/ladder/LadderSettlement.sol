// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {IPoolManager} from "../v4/IPoolManager.sol";
import {PoolKey, PoolId, PoolIdLibrary} from "../v4/types/PoolKey.sol";
import {Currency} from "../v4/types/Currency.sol";
import {TickMath} from "../v4/TickMath.sol";
import {LiquidityAmounts} from "../v4/LiquidityAmounts.sol";
import {StonkzFeeHook} from "../StonkzFeeHook.sol";
import {FeeLockerV2} from "../FeeLockerV2.sol";
import {LadderConstants} from "./LadderConstants.sol";
import {IStonkzVault} from "../vault/IStonkzVault.sol";
import {SqrtPriceLib} from "../SqrtPriceLib.sol";

/// @title LadderSettlement — docs/09 §7 pool construction + raise split
/// @notice Three-leg raise split; cash [floor,print] + tokens [print,inf); side pool vs STONKZ;
///         unsold → thicker LP; MIN_ASK_BPS; hook.registerPool exactly as Express.
///         FeeLockerV2 registration optional (setFeeLocker) — vectors keep 3-arg ctor (RIDER B).
contract LadderSettlement {
    using FixedPointMathLib for uint256;
    using PoolIdLibrary for PoolKey;

    uint256 internal constant WAD = LadderConstants.WAD;
    int24 internal constant TICK_SPACING = 60;
    uint24 internal constant MAIN_LP_FEE = 0; // pips
    uint24 internal constant SIDE_LP_FEE = 3000; // pips = 0.3%

    IPoolManager public immutable poolManager;
    StonkzFeeHook public immutable hook;
    address public immutable pairToken;

    /// @notice Owner-settable side-token reference for side pool (modularity). address(0) ⇒ park.
    address public sideTokenRef;
    /// @notice Optional FeeLockerV2 registry. address(0) ⇒ skip lock registration (vector path).
    FeeLockerV2 public feeLocker;
    address public owner;

    bool public settled;
    uint256 public toLP;
    uint256 public toTreasury;
    uint256 public toCreator;
    uint256 public sidePoolTokens;
    uint256 public mainAskTokens;
    uint256 public mainBidCash;
    uint256 public vaultHoldbackTokens;
    uint256 public printPrice;
    uint256 public floorPrice;
    PoolKey public mainPoolKey;
    PoolKey public sidePoolKey;
    int24 public cashTickLower;
    int24 public cashTickUpper;
    int24 public askTickLower;
    int24 public askTickUpper;
    uint128 public cashLiquidity;
    uint128 public askLiquidity;
    uint128 public sideLiquidity;
    uint256 public cashLockId;
    uint256 public askLockId;
    uint256 public sideLockId;
    bytes32 public cashSalt;
    bytes32 public askSalt;
    bytes32 public sideSalt;
    int24 public sideTickLower;
    int24 public sideTickUpper;
    /// @notice Stamped from settle args (auction).
    bool public liquidityLocked;
    address public unlockRecipient;
    address public userTokenSettled;
    /// @notice Stamped from settle. Unit: pair-wei per side-token, WAD.
    uint256 public refPriceWad;

    event OwnershipTransferred(address indexed prev, address indexed next);
    event SideTokenRefSet(address indexed sideToken);
    event FeeLockerSet(address indexed feeLocker);
    event RaiseSplit(uint256 toLP, uint256 toTreasury, uint256 toCreator);
    event HoldbackToVault(address indexed vault, uint256 amount);
    event CreatorCashPaid(address indexed creator, uint256 amount);
    event TreasuryPaid(address indexed treasury, uint256 amount);
    event MainPoolBuilt(PoolId id, int24 cashLo, int24 cashHi, int24 askLo, int24 askHi);
    event SidePoolBuilt(PoolId id, uint256 tokens);
    event SettlementComplete(uint256 printPrice, uint256 raised, bool graduated);
    event LiquidityWithdrawn(address indexed token, address indexed to, bytes32 leg, uint128 liquidity);

    error NotOwner();
    error AlreadySettled();
    error NotGraduated();
    error MinAsk();
    error VaultUnset();
    error VaultNotContract();
    error TransferFailed();
    error SplitInvariant();
    error LiquidityIsLocked();
    error NotUnlockRecipient();
    error NothingToWithdraw();
    error NotSettled();
    error RefPriceUnset();
    error SideTokenRefNotContract();
    error FeeLockerNotContract();
    /// @dev createSidePool=true requires sideTokenRef (park RETIRED — PREDEPLOY-REFIT).
    error SideTokenRefUnset();
    /// @dev Cash/ask amount positive but liquidity rounds to 0 for the constructed ticks.
    ///      Not a silent dust mint (liq=1 retired). Spec addendum candidate if seen in prod sizes.
    error LiquidityDust(bytes32 leg, uint256 amount);

    receive() external payable {}

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(IPoolManager pm, StonkzFeeHook hook_, address pairToken_) {
        poolManager = pm;
        hook = hook_;
        pairToken = pairToken_;
        owner = msg.sender;
    }

    function transferOwnership(address next) external onlyOwner {
        emit OwnershipTransferred(owner, next);
        owner = next;
    }

    function setSideTokenRef(address sideToken) external onlyOwner {
        if (sideToken != address(0) && sideToken.code.length == 0) revert SideTokenRefNotContract();
        sideTokenRef = sideToken;
        emit SideTokenRefSet(sideToken);
    }

    /// @notice Wire FeeLockerV2 for lock registry (production / rehearsal). Vectors leave unset.
    function setFeeLocker(FeeLockerV2 fl) external onlyOwner {
        if (address(fl) != address(0) && address(fl).code.length == 0) revert FeeLockerNotContract();
        feeLocker = fl;
        emit FeeLockerSet(address(fl));
    }

    struct SettleArgs {
        bool graduated;
        uint256 raised;
        uint256 supply;
        uint256 auctionSupply;
        uint256 soldTokens;
        uint256 printPrice; // pair-wei per token, WAD
        uint256 floorPrice; // pair-wei per token, WAD
        uint16 carveBps; // stamped
        uint16 cashHoldbackBps;
        uint16 holdbackBps; // token vault holdback
        bool createSidePool; // stamped — docs/03 switch 2
        uint16 sidePoolBps; // stamped — bps of LP-destined tokens
        /// @dev Unit: pair-wei per side-token, WAD. Required when createSidePool && sideAmt>0.
        uint256 refPriceWad;
        bool liquidityLocked; // stamped — docs/03 switch 1
        address unlockRecipient; // stamped — creator
        address vaultRef;
        address creator;
        address treasury;
        address userToken;
    }

    /// @notice Full settlement: raise split + vault token holdback + pool geometry + hook register.
    function settle(SettleArgs memory a) external payable returns (bool) {
        if (settled) revert AlreadySettled();
        if (!a.graduated) revert NotGraduated();
        settled = true;
        printPrice = a.printPrice;
        floorPrice = a.floorPrice;
        liquidityLocked = a.liquidityLocked;
        unlockRecipient = a.unlockRecipient;
        userTokenSettled = a.userToken;
        refPriceWad = a.refPriceWad;

        // ─── three-leg raise split (docs/09 §7) ───────────────────────────
        toTreasury = FixedPointMathLib.fullMulDiv(a.raised, a.carveBps, 10_000);
        toCreator = FixedPointMathLib.fullMulDiv(a.raised, a.cashHoldbackBps, 10_000);
        toLP = a.raised - toTreasury - toCreator;
        if (toLP + toTreasury + toCreator != a.raised) revert SplitInvariant();
        emit RaiseSplit(toLP, toTreasury, toCreator);

        // Pay cash legs (native pair path).
        if (toTreasury > 0) {
            _pay(a.treasury, toTreasury);
            emit TreasuryPaid(a.treasury, toTreasury);
        }
        if (toCreator > 0) {
            _pay(a.creator, toCreator);
            emit CreatorCashPaid(a.creator, toCreator);
        }

        // ─── vault token holdback (docs/10 deposit hook — no EOA transfer fallback)
        vaultHoldbackTokens = FixedPointMathLib.fullMulDiv(a.supply, a.holdbackBps, 10_000);
        if (vaultHoldbackTokens > 0) {
            if (a.vaultRef == address(0)) revert VaultUnset();
            if (a.vaultRef.code.length == 0) revert VaultNotContract();
            // Pull-credit via vault.deposit — creator is beneficiary (docs/10 §1).
            _safeApprove(a.userToken, a.vaultRef, vaultHoldbackTokens);
            IStonkzVault(a.vaultRef).deposit(a.userToken, vaultHoldbackTokens, a.creator);
            emit HoldbackToVault(a.vaultRef, vaultHoldbackTokens);
        }

        // ─── LP-destined tokens: unsold auction + (no reserve) ────────────
        // auctionSupply - sold = unsold → thicker LP.
        // createSidePool=false ⇒ sideAmt=0, all mass to main. docs/03 switch 2.
        // Loud unset backstop: createSidePool=true never parks (PREDEPLOY-REFIT).
        if (a.createSidePool && sideTokenRef == address(0)) revert SideTokenRefUnset();

        uint256 unsold = a.auctionSupply > a.soldTokens ? a.auctionSupply - a.soldTokens : 0;
        uint256 lpDestined = unsold; // docs/09: ALL unsold → thicker LP
        uint256 sideAmt =
            a.createSidePool ? FixedPointMathLib.fullMulDiv(lpDestined, a.sidePoolBps, 10_000) : 0;
        uint256 mainTokens = lpDestined - sideAmt;
        sidePoolTokens = sideAmt;

        // MIN_ASK_BPS: ask-side tokens for main pool >= 5% of total supply
        uint256 minAsk = FixedPointMathLib.fullMulDiv(a.supply, LadderConstants.MIN_ASK_BPS, 10_000);
        if (mainTokens < minAsk) revert MinAsk();
        mainAskTokens = mainTokens;
        mainBidCash = toLP;

        // ─── pool geometry: cash [floor,print], tokens [print,inf) ────────
        _buildMainPool(a.userToken, a.creator, a.floorPrice, a.printPrice, toLP, mainTokens);

        // ─── side pool vs sideTokenRef (absent when createSidePool=false or sideAmt=0)
        if (sideAmt > 0) {
            if (a.refPriceWad == 0) revert RefPriceUnset();
            _buildSidePool(a.userToken, sideAmt, a.printPrice, a.refPriceWad);
        }

        emit SettlementComplete(a.printPrice, a.raised, true);
        return true;
    }

    function _buildMainPool(
        address userToken,
        address creator,
        uint256 floorP,
        uint256 printP,
        uint256 cash,
        uint256 askTokens
    ) internal {
        // docs/09 §7 price geometry unchanged: cash [floorPrice, printPrice], tokens [print, ∞).
        // Construction must satisfy real PM: below-range = pure token0, above-range = pure token1.
        bool pairIs0 = pairToken < userToken;
        mainPoolKey = _mainPoolKey(pairToken, userToken);
        uint8 decPair = SqrtPriceLib.tokenDecimals(pairToken);
        uint8 decTok = SqrtPriceLib.tokenDecimals(userToken);
        uint160 printSqrt = SqrtPriceLib.sqrtPriceX96FromPriceWad(printP, pairIs0, decPair, decTok);
        uint160 floorSqrt = SqrtPriceLib.sqrtPriceX96FromPriceWad(floorP, pairIs0, decPair, decTok);

        if (!poolManager.isInitialized(mainPoolKey.toId())) {
            poolManager.initialize(mainPoolKey, printSqrt);
        } else {
            try poolManager.syncToPrice(mainPoolKey, printSqrt, 50 ether) {} catch {}
        }

        if (!hook.registered(userToken)) {
            hook.registerPool(userToken, pairToken, creator, mainPoolKey);
        }

        // Identity ticks from sqrts — do NOT swap names (that was the Real-PM vacuity bug).
        int24 tickAtPrint = TickMath.getTickAtSqrtRatio(printSqrt);
        int24 tickAtFloor = TickMath.getTickAtSqrtRatio(floorSqrt);
        // Spacing-aligned usable extremes (MIN_TICK=-887272 is not divisible by 60).
        int24 maxTick = _alignDown(TickMath.MAX_TICK, TICK_SPACING);
        int24 minTick = _alignUp(TickMath.MIN_TICK, TICK_SPACING);

        // Align range bounds to spacing relative to the live spot tick.
        int24 printAligned = _align(tickAtPrint, TICK_SPACING);
        int24 floorAligned = _align(tickAtFloor, TICK_SPACING);

        if (pairIs0) {
            // Inverted: higher mcap (pair/token) → lower sqrt(token/pair) → lower tick.
            // floorTick_raw > printTick_raw. Cash mcap [floor,print] → ticks (print, floor].
            // Spot below cash range → pure token0 (pair). Ask mcap [print,∞) → ticks [min, print]
            // → spot at/above ask upper → pure token1 (token).
            if (floorAligned <= printAligned) floorAligned = printAligned + TICK_SPACING;
            cashTickLower = printAligned + TICK_SPACING;
            cashTickUpper = floorAligned;
            if (cashTickUpper <= cashTickLower) cashTickUpper = cashTickLower + TICK_SPACING;
            askTickLower = minTick;
            askTickUpper = printAligned;
            if (askTickUpper <= askTickLower) askTickUpper = askTickLower + TICK_SPACING;
        } else {
            // Normal: higher mcap → higher tick. Cash [floor, print] → spot at/above upper → pair=c1.
            // Ask [print, ∞) → spot below lower → token=c0.
            if (floorAligned >= printAligned) floorAligned = printAligned - TICK_SPACING;
            cashTickLower = floorAligned;
            cashTickUpper = printAligned;
            if (cashTickUpper <= cashTickLower) cashTickLower = cashTickUpper - TICK_SPACING;
            askTickLower = printAligned + TICK_SPACING;
            askTickUpper = maxTick;
            if (askTickLower >= askTickUpper) askTickLower = askTickUpper - TICK_SPACING;
        }

        bytes32 salt = bytes32(uint256(uint160(address(this))));
        cashSalt = salt;
        askSalt = bytes32(uint256(salt) + 1);

        // Cash leg: pair only (single-sided via amount0/1 helpers — not current-price mix).
        if (cash > 0 && cashTickLower < cashTickUpper) {
            uint160 sa = TickMath.getSqrtRatioAtTick(cashTickLower);
            uint160 sb = TickMath.getSqrtRatioAtTick(cashTickUpper);
            uint128 liqCash = pairIs0
                ? LiquidityAmounts.getLiquidityForAmount0(sa, sb, cash)
                : LiquidityAmounts.getLiquidityForAmount1(sa, sb, cash);
            if (liqCash == 0) revert LiquidityDust(bytes32("cash"), cash);
            cashLiquidity = liqCash;
            _approvePm(pairToken, cash);
            uint256 ethVal = pairToken == address(0) ? cash : 0;
            poolManager.modifyLiquidity{value: ethVal}(
                mainPoolKey,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: cashTickLower,
                    tickUpper: cashTickUpper,
                    liquidityDelta: int256(uint256(liqCash)),
                    salt: salt
                }),
                ""
            );
            cashLockId = _registerLock(
                mainPoolKey,
                keccak256(abi.encode(address(this), cashTickLower, cashTickUpper, salt)),
                FeeLockerV2.PoolKind.Main,
                pairToken,
                userToken,
                cashTickLower,
                cashTickUpper,
                salt
            );
        }

        // Ask leg: user token only.
        if (askTokens > 0 && askTickLower < askTickUpper) {
            uint160 sa = TickMath.getSqrtRatioAtTick(askTickLower);
            uint160 sb = TickMath.getSqrtRatioAtTick(askTickUpper);
            uint128 liqAsk = pairIs0
                ? LiquidityAmounts.getLiquidityForAmount1(sa, sb, askTokens)
                : LiquidityAmounts.getLiquidityForAmount0(sa, sb, askTokens);
            if (liqAsk == 0) revert LiquidityDust(bytes32("ask"), askTokens);
            askLiquidity = liqAsk;
            _approvePm(userToken, askTokens);
            poolManager.modifyLiquidity(
                mainPoolKey,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: askTickLower,
                    tickUpper: askTickUpper,
                    liquidityDelta: int256(uint256(liqAsk)),
                    salt: askSalt
                }),
                ""
            );
            askLockId = _registerLock(
                mainPoolKey,
                keccak256(abi.encode(address(this), askTickLower, askTickUpper, askSalt)),
                FeeLockerV2.PoolKind.Main,
                pairToken,
                userToken,
                askTickLower,
                askTickUpper,
                askSalt
            );
        }

        emit MainPoolBuilt(mainPoolKey.toId(), cashTickLower, cashTickUpper, askTickLower, askTickUpper);
    }

    function _buildSidePool(address userToken, uint256 tokens, uint256 printP, uint256 refPrice) internal {
        // priceInStonkz = printP / refPrice (both pair-wei per token, WAD). Ruling B: no USD leg.
        uint256 priceInStonkz = FixedPointMathLib.fullMulDiv(printP, WAD, refPrice);
        sidePoolKey = _sidePoolKey(userToken, sideTokenRef);
        bool tokIs0 = userToken < sideTokenRef;

        // Spot from price; range placed for pure userToken under real PM composition rules.
        uint8 decTok = SqrtPriceLib.tokenDecimals(userToken);
        uint8 decSide = SqrtPriceLib.tokenDecimals(sideTokenRef);
        uint160 priceSqrt = SqrtPriceLib.sqrtPriceX96FromPriceWad(
            priceInStonkz, !tokIs0, tokIs0 ? decTok : decSide, tokIs0 ? decSide : decTok
        );
        int24 spotAligned = _align(TickMath.getTickAtSqrtRatio(priceSqrt), TICK_SPACING);
        int24 maxTick = _alignDown(TickMath.MAX_TICK, TICK_SPACING);
        int24 minTick = _alignUp(TickMath.MIN_TICK, TICK_SPACING);

        int24 lo;
        int24 hi;
        uint160 initSqrt;
        if (tokIs0) {
            // token0: below-range → spot below range.
            lo = spotAligned + TICK_SPACING;
            hi = maxTick;
            if (lo >= hi) lo = hi - TICK_SPACING;
            initSqrt = TickMath.getSqrtRatioAtTick(spotAligned);
        } else {
            // token1: above-range → spot at/above upper.
            lo = minTick;
            hi = spotAligned;
            if (hi <= lo) hi = lo + TICK_SPACING;
            initSqrt = TickMath.getSqrtRatioAtTick(spotAligned);
        }

        if (!poolManager.isInitialized(sidePoolKey.toId())) {
            poolManager.initialize(sidePoolKey, initSqrt);
        }

        sideTickLower = lo;
        sideTickUpper = hi;
        uint160 sa = TickMath.getSqrtRatioAtTick(lo);
        uint160 sb = TickMath.getSqrtRatioAtTick(hi);
        uint128 liq = tokIs0
            ? LiquidityAmounts.getLiquidityForAmount0(sa, sb, tokens)
            : LiquidityAmounts.getLiquidityForAmount1(sa, sb, tokens);
        if (liq == 0) revert LiquidityDust(bytes32("side"), tokens);
        sideLiquidity = liq;
        bytes32 sideSalt_ = bytes32(uint256(2));
        sideSalt = sideSalt_;
        _approvePm(userToken, tokens);
        poolManager.modifyLiquidity(
            sidePoolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: lo, tickUpper: hi, liquidityDelta: int256(uint256(liq)), salt: sideSalt_
            }),
            ""
        );
        sideLockId = _registerLock(
            sidePoolKey,
            keccak256(abi.encode(address(this), lo, hi, sideSalt_)),
            FeeLockerV2.PoolKind.Side,
            sideTokenRef,
            userToken,
            lo,
            hi,
            sideSalt_
        );
        emit SidePoolBuilt(sidePoolKey.toId(), tokens);
    }

    function _registerLock(
        PoolKey memory key,
        bytes32 positionId,
        FeeLockerV2.PoolKind kind,
        address pairCurrency,
        address userToken,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt
    ) internal returns (uint256 lockId) {
        if (address(feeLocker) == address(0)) return 0;
        lockId = feeLocker.lockPosition(
            key,
            positionId,
            kind,
            pairCurrency,
            userToken,
            liquidityLocked,
            unlockRecipient,
            tickLower,
            tickUpper,
            salt
        );
    }

    /// @notice Withdraw main cash+ask LP. Unlocked stamp + unlockRecipient only.
    function withdrawMainLiquidity() external {
        _requireUnlockedCaller();
        if (cashLiquidity == 0 && askLiquidity == 0) revert NothingToWithdraw();
        if (cashLiquidity > 0) {
            uint128 liq = cashLiquidity;
            cashLiquidity = 0;
            poolManager.modifyLiquidity(
                mainPoolKey,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: cashTickLower,
                    tickUpper: cashTickUpper,
                    liquidityDelta: -int256(uint256(liq)),
                    salt: cashSalt
                }),
                ""
            );
            if (cashLockId != 0) feeLocker.markWithdrawn(cashLockId);
            emit LiquidityWithdrawn(userTokenSettled, unlockRecipient, bytes32("cash"), liq);
        }
        if (askLiquidity > 0) {
            uint128 liq = askLiquidity;
            askLiquidity = 0;
            poolManager.modifyLiquidity(
                mainPoolKey,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: askTickLower,
                    tickUpper: askTickUpper,
                    liquidityDelta: -int256(uint256(liq)),
                    salt: askSalt
                }),
                ""
            );
            if (askLockId != 0) feeLocker.markWithdrawn(askLockId);
            emit LiquidityWithdrawn(userTokenSettled, unlockRecipient, bytes32("ask"), liq);
        }
    }

    function withdrawSideLiquidity() external {
        _requireUnlockedCaller();
        if (sideLiquidity == 0) revert NothingToWithdraw();
        uint128 liq = sideLiquidity;
        sideLiquidity = 0;
        poolManager.modifyLiquidity(
            sidePoolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: sideTickLower,
                tickUpper: sideTickUpper,
                liquidityDelta: -int256(uint256(liq)),
                salt: sideSalt
            }),
            ""
        );
        if (sideLockId != 0) feeLocker.markWithdrawn(sideLockId);
        emit LiquidityWithdrawn(userTokenSettled, unlockRecipient, bytes32("side"), liq);
    }

    function _requireUnlockedCaller() internal view {
        if (!settled) revert NotSettled();
        if (liquidityLocked) revert LiquidityIsLocked();
        if (msg.sender != unlockRecipient) revert NotUnlockRecipient();
        if (address(feeLocker) != address(0)) {
            feeLocker.requireCanWithdraw(userTokenSettled, msg.sender);
        }
    }

    function _approvePm(address token_, uint256 amount) internal {
        if (token_ == address(0) || amount == 0) return;
        (bool ok,) = token_.call(abi.encodeWithSignature("approve(address,uint256)", address(poolManager), amount));
        require(ok, "approve");
    }

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

    function _align(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 rem = tick % spacing;
        if (rem < 0) rem += spacing;
        return tick - rem;
    }

    /// @dev Round toward +inf onto a spacing multiple (usable min tick).
    function _alignUp(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 rem = tick % spacing;
        if (rem < 0) rem += spacing;
        if (rem == 0) return tick;
        return tick + (spacing - rem);
    }

    function _alignDown(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 rem = tick % spacing;
        if (rem < 0) rem += spacing;
        return tick - rem;
    }

    function _pay(address to, uint256 amt) internal {
        if (amt == 0) return;
        (bool ok,) = to.call{value: amt}("");
        if (!ok) revert TransferFailed();
    }

    function _safeTransfer(address token, address to, uint256 amt) internal {
        (bool ok, bytes memory data) = token.call(abi.encodeWithSignature("transfer(address,uint256)", to, amt));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    function _safeApprove(address token, address spender, uint256 amt) internal {
        (bool ok, bytes memory data) = token.call(abi.encodeWithSignature("approve(address,uint256)", spender, amt));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }
}
