// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {SqrtPriceLib} from "../src/SqrtPriceLib.sol";
import {TickMath} from "../src/v4/TickMath.sol";
import {IPoolManager} from "../src/v4/IPoolManager.sol";
import {MockPoolManager} from "../src/mock/MockPoolManager.sol";
import {BuybackAccumulator} from "../src/BuybackAccumulator.sol";
import {StonkzFeeHook} from "../src/StonkzFeeHook.sol";
import {FeeLockerV2} from "../src/FeeLockerV2.sol";
import {CTOGovernor} from "../src/CTOGovernor.sol";
import {ICTOGovernor} from "../src/interfaces/IStonkzGovernance.sol";
import {LadderSettlement} from "../src/ladder/LadderSettlement.sol";
import {LadderConstants} from "../src/ladder/LadderConstants.sol";
import {LadderTypes} from "../src/ladder/LadderTypes.sol";
import {StonkzLadderAuction} from "../src/ladder/StonkzLadderAuction.sol";
import {MockVault} from "./ladder/MockVault.sol";
import {LadderVectorLoader} from "./ladder/LadderVectorLoader.sol";
import {LadderTolerance} from "./ladder/LadderTolerance.sol";
import {PoolKey, PoolIdLibrary} from "../src/v4/types/PoolKey.sol";
import {Currency} from "../src/v4/types/Currency.sol";

/// @dev 6-dec side stand-in (live USDG / Express sideTokenRef class).
contract SqrtPrecSide6 {
    uint8 public decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract SqrtPrecTok18 {
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @title SqrtPrecision — side-pool init: no pre-sqrt decimal truncation
/// @notice Locks the $MP 40→6 collapse fix; shared Express/Ladder SqrtPriceLib.
contract SqrtPrecision is Test, LadderVectorLoader {
    using PoolIdLibrary for PoolKey;
    using FixedPointMathLib for uint256;

    uint256 internal constant WAD = 1e18;
    /// @dev Bound: implied human price error vs exact ≤ 0.2% (isqrt + Q96; ≪ for live magnitudes).
    uint256 internal constant MAX_REL_ERR_BPS = 20; // 0.20%
    int24 internal constant TICK_SPACING = 60;

    address internal constant ETH = address(0);
    address internal constant TREASURY = address(0x7A5E);
    address internal constant CREATOR = address(0xCEEE);

    // Live Express stamps (chain 4663) — priceInStonkz = startPriceWad * WAD / refPriceWad.
    uint256 internal constant MP_PRICE = 40508986382159;
    uint256 internal constant SDONK_PRICE = 3999886071594842;
    uint256 internal constant MOONER_PRICE = 39808381304297;
    uint256 internal constant THOOK_PRICE = 32266086536450;

    // Pre-fix Express V4 buggy path (18-dec token / 6-dec side, no invert): divide by 1e12 then isqrt.
    uint160 internal constant MP_OLD_SQRT = 475368975085586025561; // isqrt(40)=6
    uint160 internal constant MOONER_OLD_SQRT = 475368975085586025561; // isqrt(39)=6
    uint160 internal constant THOOK_OLD_SQRT = 396140812571321687967; // isqrt(32)=5
    uint160 internal constant SDONK_OLD_SQRT = 4991374238398653268393; // isqrt(3999)=63

    MockPoolManager internal pm;
    StonkzFeeHook internal hook;
    FeeLockerV2 internal locker;
    CTOGovernor internal gov;
    SqrtPrecSide6 internal side6;

    function setUp() public {
        side6 = new SqrtPrecSide6();
        pm = new MockPoolManager();
        gov = new CTOGovernor();
        hook = new StonkzFeeHook(IPoolManager(address(pm)), TREASURY, ICTOGovernor(address(gov)), address(this));
        gov.setRegistry(hook);
        locker = new FeeLockerV2(IPoolManager(address(pm)), hook);
    }

    // ─── (a) $MP fixture ─────────────────────────────────────────────────────

    function test_a_mpOldBuggyHelper_confirms40to6() public pure {
        assertEq(FixedPointMathLib.sqrt(40), 6, "isqrt(40)=6");
        uint160 old = _oldBuggySqrt(MP_PRICE, false, 18, 6);
        assertEq(old, MP_OLD_SQRT, "helper must reproduce live MP collapse");
    }

    function test_a_mpFixture_within_0_2pct_notOldCollapse() public pure {
        // Intended human = 40508986382159 / 1e18 ≈ 4.0509e-5 side per token.
        uint160 fixedSqrt = SqrtPriceLib.sqrtPriceX96FromPriceWad(MP_PRICE, false, 18, 6);
        uint256 implied = _impliedHuman(fixedSqrt, 18, 6);
        assertLe(_relErrBps(implied, MP_PRICE), MAX_REL_ERR_BPS, "MP implied >0.2% from target");
        assertTrue(fixedSqrt != MP_OLD_SQRT, "must not emit old isqrt(40)=6 sqrt");
        assertGt(_relErrBps(_impliedHuman(MP_OLD_SQRT, 18, 6), MP_PRICE), 1000, "sanity: old >> 10% off");
    }

    // ─── (b) Live launches: old vs new implied FDV @$1 stand-in ─────────────

    function test_b_liveLaunches_oldVsNewImpliedFdv() public pure {
        _assertLive(SDONK_PRICE, 1_000_000 ether, SDONK_OLD_SQRT);
        _assertLive(MOONER_PRICE, 100_000_000 ether, MOONER_OLD_SQRT);
        _assertLive(THOOK_PRICE, 100_000_000 ether, THOOK_OLD_SQRT);
        _assertLive(MP_PRICE, 100_000_000 ether, MP_OLD_SQRT);
    }

    function _assertLive(uint256 priceWad, uint256 supply, uint160 oldSqrt) internal pure {
        uint160 neu = SqrtPriceLib.sqrtPriceX96FromPriceWad(priceWad, false, 18, 6);
        assertTrue(neu != oldSqrt, "still old sqrt");
        uint256 newH = _impliedHuman(neu, 18, 6);
        uint256 oldH = _impliedHuman(oldSqrt, 18, 6);
        assertLe(_relErrBps(newH, priceWad), MAX_REL_ERR_BPS, "new err");
        uint256 intendedFdv = FixedPointMathLib.fullMulDiv(priceWad, supply, WAD);
        uint256 newFdv = FixedPointMathLib.fullMulDiv(newH, supply, WAD);
        uint256 oldFdv = FixedPointMathLib.fullMulDiv(oldH, supply, WAD);
        assertLe(_relErrBps(newFdv, intendedFdv), MAX_REL_ERR_BPS, "new FDV");
        assertGt(newFdv, oldFdv, "truncation opened below intended");
    }

    // ─── (c) Precision sweep ─────────────────────────────────────────────────

    function test_c_precisionSweep_decCombos() public pure {
        uint256[6] memory prices = [
            uint256(1e10),
            uint256(40508986382159),
            uint256(1e15),
            uint256(1e18),
            uint256(1.6e22),
            uint256(3999886071594842)
        ];
        uint8[2][4] memory decs = [[uint8(18), uint8(18)], [18, 6], [6, 18], [8, 18]];
        for (uint256 i; i < prices.length; ++i) {
            for (uint256 j; j < decs.length; ++j) {
                uint8 d0 = decs[j][0];
                uint8 d1 = decs[j][1];
                uint160 sq = SqrtPriceLib.sqrtPriceX96FromPriceWad(prices[i], false, d0, d1);
                if (sq <= TickMath.MIN_SQRT_RATIO + 1 || sq >= TickMath.MAX_SQRT_RATIO - 1) continue;
                assertLe(_relErrBps(_impliedHuman(sq, d0, d1), prices[i]), MAX_REL_ERR_BPS, "sweep");
            }
        }
    }

    function test_c_equalDecimals_matchesHistoricalWadPath() public pure {
        uint256 px = 8510638297872000000;
        uint160 lib = SqrtPriceLib.sqrtPriceX96FromPriceWad(px, false, 18, 18);
        uint256 hist = FixedPointMathLib.fullMulDiv(FixedPointMathLib.sqrt(px), uint256(1) << 96, 1e9);
        assertEq(uint256(lib), hist, "18/18 must match legacy WAD path");
    }

    // ─── (d) Ladder path with 6-dec side — 10^12 blind error gone ───────────

    function test_d_ladderSide_sixDec_notDecimalsBlind() public {
        MockVault mockVault = new MockVault();
        LadderSettlement settlement = new LadderSettlement(IPoolManager(address(pm)), hook, ETH);
        settlement.setSideTokenRef(address(side6));
        settlement.setFeeLocker(locker);

        SqrtPrecTok18 tok = new SqrtPrecTok18();
        address userToken = address(tok);

        string memory json = _loadRaw("09-vault-holdback-cashhb.json");
        LadderTypes.Inputs memory inn = loadInputs(json);
        LadderTypes.Bid[] memory bids = loadBids(json);
        LadderTypes.Outputs memory exp = loadOutputs(json);

        StonkzLadderAuction.Params memory p;
        p.supply = inn.supply;
        p.auctionSupply = inn.auctionSupply;
        p.floorMcap = inn.floorMcap;
        p.duration = LadderConstants.GOD_DURATION;
        if (inn.tier == LadderTypes.Tier.H4) p.duration = LadderConstants.H4_DURATION;
        if (inn.tier == LadderTypes.Tier.Daily) p.duration = LadderConstants.DAILY_DURATION;
        if (inn.tier == LadderTypes.Tier.Road) p.duration = LadderConstants.ROAD_DURATION;
        p.lpShareWad = inn.lpShare;
        p.lpHealthTargetWad = inn.lpHealthTarget;
        p.carveBps = inn.protocolCarveBps;
        p.cashHoldbackBps = inn.cashHoldbackBps;
        p.holdbackBps = inn.holdbackBps;
        p.holdbackDelivery = LadderConstants.HoldbackDelivery.Vault;
        p.tier = inn.tier;
        p.createSidePool = true;
        p.sidePoolBps = inn.sidePoolBps;
        p.refPriceWad = 2.5e11;
        p.walletCapBps = inn.walletCapBps;
        p.sizeBonusBps = inn.sizeBonusBps;
        p.maxUniqueActives = 300;
        p.pairToken = ETH;
        p.creator = CREATOR;
        p.treasury = TREASURY;
        p.vaultRef = address(mockVault);
        p.settlement = address(settlement);

        StonkzLadderAuction auction = new StonkzLadderAuction(p);
        auction.start();
        for (uint256 i; i < bids.length; i++) {
            address w = bids[i].wallet;
            vm.deal(w, bids[i].size + 1 ether);
            vm.prank(w);
            auction.placeBid{value: bids[i].size}(bids[i].size, bids[i].maxPrice);
        }
        auction.clearAllForTest();
        assertTrue(auction.graduated(), "graduated");
        assertApproxEqAbs(auction.lpHealth(), exp.lpHealth, LadderTolerance.fracTol(exp.lpHealth), "lpH");

        uint256 unsold = inn.auctionSupply - auction.soldTokens();
        uint256 side = (unsold * inn.sidePoolBps) / 10_000;
        uint256 mainAsk = unsold - side;
        uint256 vaultAmt = (inn.supply * inn.holdbackBps) / 10_000;
        tok.mint(address(settlement), vaultAmt + mainAsk + side);
        auction.settle(userToken);
        assertGt(settlement.sideLiquidity(), 0, "side liq");

        uint256 priceInStonkz = FixedPointMathLib.fullMulDiv(settlement.printPrice(), WAD, settlement.refPriceWad());
        bool tokIs0 = userToken < address(side6);
        uint160 expect = SqrtPriceLib.sqrtPriceX96FromPriceWad(
            priceInStonkz, !tokIs0, tokIs0 ? uint8(18) : uint8(6), tokIs0 ? uint8(6) : uint8(18)
        );
        int24 spotAligned = _align(TickMath.getTickAtSqrtRatio(expect), TICK_SPACING);

        // Decimals-blind Ladder (pre-fix) ignores 6-dec → ~10^12 raw-ratio error.
        uint160 blind = _oldBlindSqrt(priceInStonkz, !tokIs0);
        int24 blindAligned = _align(TickMath.getTickAtSqrtRatio(blind), TICK_SPACING);
        assertTrue(spotAligned != blindAligned, "ladder must not match decimals-blind tick");

        (Currency c0, Currency c1, uint24 fee, int24 spacing, address hooksAddr) = settlement.sidePoolKey();
        PoolKey memory key = PoolKey({
            currency0: c0, currency1: c1, fee: fee, tickSpacing: spacing, hooks: hooksAddr
        });
        (, int24 tick,,) = pm.getSlot0(key.toId());
        assertEq(tick, spotAligned, "ladder slot0 tick");

        // Implied price after tick align within 0.2% + one spacing (~0.6%) slack.
        uint8 d0 = tokIs0 ? uint8(18) : uint8(6);
        uint8 d1 = tokIs0 ? uint8(6) : uint8(18);
        uint256 target = priceInStonkz;
        if (!tokIs0) target = FixedPointMathLib.fullMulDiv(WAD, WAD, priceInStonkz);
        uint256 implied = _impliedHuman(TickMath.getSqrtRatioAtTick(spotAligned), d0, d1);
        assertLe(_relErrBps(implied, target), 80, "ladder implied after align"); // 0.8% incl. spacing
    }

    // ─── helpers ─────────────────────────────────────────────────────────────

    /// @dev Express V4 buggy path: scale by 10^|dec| BEFORE isqrt.
    function _oldBuggySqrt(uint256 priceWad, bool pairIsToken0, uint8 dec0, uint8 dec1)
        internal
        pure
        returns (uint160)
    {
        uint256 px = priceWad;
        if (pairIsToken0) {
            px = priceWad == 0 ? WAD : FixedPointMathLib.mulDiv(WAD, WAD, priceWad);
        }
        if (dec1 >= dec0) {
            unchecked {
                px = px * (10 ** (dec1 - dec0));
            }
        } else {
            px = px / (10 ** (dec0 - dec1));
        }
        uint256 sqrtX96 = FixedPointMathLib.fullMulDiv(FixedPointMathLib.sqrt(px), uint256(1) << 96, 1e9);
        if (sqrtX96 <= TickMath.MIN_SQRT_RATIO) return TickMath.MIN_SQRT_RATIO + 1;
        if (sqrtX96 >= TickMath.MAX_SQRT_RATIO) return TickMath.MAX_SQRT_RATIO - 1;
        return uint160(sqrtX96);
    }

    /// @dev Pre-fix LadderSettlement: decimals-blind WAD→Q96.
    function _oldBlindSqrt(uint256 priceWad, bool pairIsToken0) internal pure returns (uint160) {
        uint256 px = priceWad;
        if (pairIsToken0) {
            px = priceWad == 0 ? WAD : FixedPointMathLib.fullMulDiv(WAD, WAD, priceWad);
        }
        uint256 sqrtX96 = FixedPointMathLib.fullMulDiv(FixedPointMathLib.sqrt(px), uint256(1) << 96, 1e9);
        if (sqrtX96 <= TickMath.MIN_SQRT_RATIO) return TickMath.MIN_SQRT_RATIO + 1;
        if (sqrtX96 >= TickMath.MAX_SQRT_RATIO) return TickMath.MAX_SQRT_RATIO - 1;
        return uint160(sqrtX96);
    }

    /// @return humanWad Implied token1/token0 human price in WAD from sqrtPriceX96.
    function _impliedHuman(uint160 sqrtX96, uint8 dec0, uint8 dec1) internal pure returns (uint256 humanWad) {
        uint256 sqrt = uint256(sqrtX96);
        // raw = (sqrt/2^96)^2 = human * 10^(dec1-dec0)
        // Keep an intermediate Q96 factor so small raw ratios do not floor to 0.
        uint256 sqX96 = FixedPointMathLib.fullMulDiv(sqrt, sqrt, uint256(1) << 96);
        if (dec1 >= dec0) {
            humanWad = FixedPointMathLib.fullMulDiv(sqX96, WAD, (uint256(1) << 96) * (10 ** (dec1 - dec0)));
        } else {
            humanWad = FixedPointMathLib.fullMulDiv(sqX96, WAD * (10 ** (dec0 - dec1)), uint256(1) << 96);
        }
    }

    function _relErrBps(uint256 got, uint256 want) internal pure returns (uint256) {
        if (want == 0) return got == 0 ? 0 : type(uint256).max;
        uint256 diff = got > want ? got - want : want - got;
        return FixedPointMathLib.fullMulDiv(diff, 10_000, want);
    }

    function _align(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 rem = tick % spacing;
        if (rem < 0) rem += spacing;
        return tick - rem;
    }
}
