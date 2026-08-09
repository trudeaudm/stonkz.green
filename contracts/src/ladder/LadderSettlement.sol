// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {IPoolManager} from "../v4/IPoolManager.sol";
import {PoolKey, PoolId, PoolIdLibrary} from "../v4/types/PoolKey.sol";
import {Currency} from "../v4/types/Currency.sol";
import {TickMath} from "../v4/TickMath.sol";
import {LiquidityAmounts} from "../v4/LiquidityAmounts.sol";
import {StonkzFeeHook} from "../StonkzFeeHook.sol";
import {LadderConstants} from "./LadderConstants.sol";
import {IStonkzVault} from "../vault/IStonkzVault.sol";

/// @title LadderSettlement — docs/09 §7 pool construction + raise split
/// @notice Three-leg raise split; cash [floor,print] + tokens [print,inf); side pool 5% vs STONKZ;
///         unsold → thicker LP; MIN_ASK_BPS; hook.registerPool exactly as Express.
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

    /// @notice Owner-settable STONKZ reference for side pool (modularity). address(0) ⇒ park.
    address public stonkzRef;
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

    event OwnershipTransferred(address indexed prev, address indexed next);
    event StonkzRefSet(address indexed stonkz);
    event RaiseSplit(uint256 toLP, uint256 toTreasury, uint256 toCreator);
    event HoldbackToVault(address indexed vault, uint256 amount);
    event CreatorCashPaid(address indexed creator, uint256 amount);
    event TreasuryPaid(address indexed treasury, uint256 amount);
    event MainPoolBuilt(PoolId id, int24 cashLo, int24 cashHi, int24 askLo, int24 askHi);
    event SidePoolBuilt(PoolId id, uint256 tokens);
    event SidePoolParked(uint256 tokens);
    event SettlementComplete(uint256 printPrice, uint256 raised, bool graduated);

    error NotOwner();
    error AlreadySettled();
    error NotGraduated();
    error MinAsk();
    error VaultUnset();
    error TransferFailed();
    error SplitInvariant();

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

    function setStonkzRef(address stonkz) external onlyOwner {
        stonkzRef = stonkz;
        emit StonkzRefSet(stonkz);
    }

    struct SettleArgs {
        bool graduated;
        uint256 raised;
        uint256 supply;
        uint256 auctionSupply;
        uint256 soldTokens;
        uint256 printPrice; // WAD
        uint256 floorPrice; // WAD
        uint16 carveBps; // stamped
        uint16 cashHoldbackBps;
        uint16 holdbackBps; // token vault holdback
        uint16 sidePoolBps;
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

        // ─── vault token holdback (docs/10 deposit hook when vaultRef is a contract)
        vaultHoldbackTokens = FixedPointMathLib.fullMulDiv(a.supply, a.holdbackBps, 10_000);
        if (vaultHoldbackTokens > 0) {
            if (a.vaultRef == address(0)) revert VaultUnset();
            if (a.vaultRef.code.length > 0) {
                // Pull-credit via vault.deposit — creator is beneficiary (docs/10 §1).
                _safeApprove(a.userToken, a.vaultRef, vaultHoldbackTokens);
                IStonkzVault(a.vaultRef).deposit(a.userToken, vaultHoldbackTokens, a.creator);
            } else {
                // EOA / test stub refs: plain transfer (availability-guard stubs).
                _safeTransfer(a.userToken, a.vaultRef, vaultHoldbackTokens);
            }
            emit HoldbackToVault(a.vaultRef, vaultHoldbackTokens);
        }

        // ─── LP-destined tokens: unsold auction + (no reserve) ────────────
        // auctionSupply - sold = unsold → thicker LP. Side pool = 5% of LP-destined.
        uint256 unsold = a.auctionSupply > a.soldTokens ? a.auctionSupply - a.soldTokens : 0;
        uint256 lpDestined = unsold; // docs/09: ALL unsold → thicker LP
        uint256 sideAmt = FixedPointMathLib.fullMulDiv(lpDestined, a.sidePoolBps, 10_000);
        uint256 mainTokens = lpDestined - sideAmt;
        sidePoolTokens = sideAmt;

        // MIN_ASK_BPS: ask-side tokens for main pool >= 5% of total supply
        uint256 minAsk = FixedPointMathLib.fullMulDiv(a.supply, LadderConstants.MIN_ASK_BPS, 10_000);
        if (mainTokens < minAsk) revert MinAsk();
        mainAskTokens = mainTokens;
        mainBidCash = toLP;

        // ─── pool geometry: cash [floor,print], tokens [print,inf) ────────
        _buildMainPool(a.userToken, a.creator, a.floorPrice, a.printPrice, toLP, mainTokens);

        // ─── side pool 5% vs STONKZ ref ───────────────────────────────────
        if (sideAmt > 0) {
            if (stonkzRef != address(0)) {
                _buildSidePool(a.userToken, sideAmt, a.printPrice);
            } else {
                emit SidePoolParked(sideAmt);
            }
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
        bool pairIs0 = pairToken < userToken;
        mainPoolKey = _mainPoolKey(pairToken, userToken);
        uint160 printSqrt = _sqrtPriceFromPriceWad(printP, pairIs0);
        uint160 floorSqrt = _sqrtPriceFromPriceWad(floorP, pairIs0);

        if (!poolManager.isInitialized(mainPoolKey.toId())) {
            poolManager.initialize(mainPoolKey, printSqrt);
        } else {
            try poolManager.syncToPrice(mainPoolKey, printSqrt, 50 ether) {} catch {}
        }

        // Register hook EXACTLY as Express (StonkzDirectListing).
        if (!hook.registered(userToken)) {
            hook.registerPool(userToken, pairToken, creator, mainPoolKey);
        }

        int24 printTick = _align(TickMath.getTickAtSqrtRatio(printSqrt), TICK_SPACING);
        int24 floorTick = _align(TickMath.getTickAtSqrtRatio(floorSqrt), TICK_SPACING);
        int24 maxTick = _alignDown(TickMath.MAX_TICK, TICK_SPACING);

        // Orientation: ensure floorTick < printTick < maxTick in tick space for the pair/token ordering.
        if (pairIs0) {
            // price = pair/token → higher token price ⇒ lower sqrt(token/pair); ticks invert vs mcap.
            // Keep ranges ordered: lower < upper.
            if (floorTick > printTick) (floorTick, printTick) = (printTick, floorTick);
        } else {
            if (floorTick > printTick) (floorTick, printTick) = (printTick, floorTick);
        }
        if (printTick >= maxTick) printTick = maxTick - TICK_SPACING;
        if (floorTick >= printTick) floorTick = printTick - TICK_SPACING;

        cashTickLower = floorTick;
        cashTickUpper = printTick;
        askTickLower = printTick;
        askTickUpper = maxTick;

        bytes32 salt = bytes32(uint256(uint160(address(this))));

        // Cash leg: pair in [floor, print]
        if (cash > 0 && cashTickLower < cashTickUpper) {
            uint128 liqCash = LiquidityAmounts.getLiquidityForAmounts(
                printSqrt,
                TickMath.getSqrtRatioAtTick(cashTickLower),
                TickMath.getSqrtRatioAtTick(cashTickUpper),
                pairIs0 ? cash : 0,
                pairIs0 ? 0 : cash
            );
            if (liqCash == 0) liqCash = 1;
            poolManager.modifyLiquidity(
                mainPoolKey,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: cashTickLower,
                    tickUpper: cashTickUpper,
                    liquidityDelta: int256(uint256(liqCash)),
                    salt: salt
                }),
                ""
            );
        }

        // Ask leg: tokens in [print, inf)
        if (askTokens > 0 && askTickLower < askTickUpper) {
            uint128 liqAsk = LiquidityAmounts.getLiquidityForAmounts(
                printSqrt,
                TickMath.getSqrtRatioAtTick(askTickLower),
                TickMath.getSqrtRatioAtTick(askTickUpper),
                pairIs0 ? 0 : askTokens,
                pairIs0 ? askTokens : 0
            );
            if (liqAsk == 0) liqAsk = 1;
            poolManager.modifyLiquidity(
                mainPoolKey,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: askTickLower,
                    tickUpper: askTickUpper,
                    liquidityDelta: int256(uint256(liqAsk)),
                    salt: bytes32(uint256(salt) + 1)
                }),
                ""
            );
        }

        emit MainPoolBuilt(mainPoolKey.toId(), cashTickLower, cashTickUpper, askTickLower, askTickUpper);
    }

    function _buildSidePool(address userToken, uint256 tokens, uint256 printP) internal {
        sidePoolKey = _sidePoolKey(userToken, stonkzRef);
        bool tokIs0 = userToken < stonkzRef;
        uint160 sqrtP = _sqrtPriceFromPriceWad(printP, !tokIs0);
        if (!poolManager.isInitialized(sidePoolKey.toId())) {
            poolManager.initialize(sidePoolKey, sqrtP);
        }
        int24 tick = _align(TickMath.getTickAtSqrtRatio(sqrtP), TICK_SPACING);
        int24 lo = tick;
        int24 hi = _alignDown(TickMath.MAX_TICK, TICK_SPACING);
        if (lo >= hi) lo = hi - TICK_SPACING;
        uint128 liq = LiquidityAmounts.getLiquidityForAmounts(
            sqrtP,
            TickMath.getSqrtRatioAtTick(lo),
            TickMath.getSqrtRatioAtTick(hi),
            tokIs0 ? tokens : 0,
            tokIs0 ? 0 : tokens
        );
        if (liq == 0) liq = 1;
        poolManager.modifyLiquidity(
            sidePoolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: lo, tickUpper: hi, liquidityDelta: int256(uint256(liq)), salt: bytes32(uint256(2))
            }),
            ""
        );
        emit SidePoolBuilt(sidePoolKey.toId(), tokens);
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

    function _sqrtPriceFromPriceWad(uint256 priceWad, bool pairIsToken0) internal pure returns (uint160) {
        uint256 px = priceWad;
        if (pairIsToken0) {
            px = priceWad == 0 ? WAD : FixedPointMathLib.fullMulDiv(WAD, WAD, priceWad);
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
