// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {Hooks} from "@v4-core/src/libraries/Hooks.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {V4DualBackend} from "./V4DualBackend.sol";
import {FactoryVanity} from "./FactoryVanity.sol";
import {VanityHelpers} from "./VanityHelpers.sol";
import {IPoolManager} from "../src/v4/IPoolManager.sol";
import {PoolKey, PoolIdLibrary} from "../src/v4/types/PoolKey.sol";
import {Currency} from "../src/v4/types/Currency.sol";
import {TickMath} from "../src/v4/TickMath.sol";
import {BuybackAccumulator} from "../src/BuybackAccumulator.sol";
import {StonkzFeeHook} from "../src/StonkzFeeHook.sol";
import {HookVanity} from "../src/HookVanity.sol";
import {FeeLockerV2} from "../src/FeeLockerV2.sol";
import {CTOGovernor} from "../src/CTOGovernor.sol";
import {ICTOGovernor} from "../src/interfaces/IStonkzGovernance.sol";
import {StonkzDirectListing} from "../src/StonkzDirectListing.sol";
import {StonkzExpressFactory} from "../src/StonkzExpressFactory.sol";
import {LadderSettlement} from "../src/ladder/LadderSettlement.sol";
import {StonkzLadderAuction} from "../src/ladder/StonkzLadderAuction.sol";
import {LadderConstants} from "../src/ladder/LadderConstants.sol";
import {LadderTypes} from "../src/ladder/LadderTypes.sol";
import {LadderVectorLoader} from "./ladder/LadderVectorLoader.sol";
import {LadderTolerance} from "./ladder/LadderTolerance.sol";
import {MockVault} from "./ladder/MockVault.sol";

/// @notice On-pool side-pool init price lock (orientation-aware). Closes the gap left by 08fdca3 soften.
/// @dev On launch-deploy, Express `list` requires 0x4663 vanity — mine via VanityHelpers (FactoryVanity).
abstract contract SidePoolPriceLockBase is V4DualBackend, LadderVectorLoader, FactoryVanity {
    using PoolIdLibrary for PoolKey;
    using stdJson for string;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant SUPPLY = 1_000_000 ether;
    uint256 internal constant TIER_4K = 4000e18;
    int24 internal constant TICK_SPACING = 60;

    address internal constant ETH = address(0);
    address internal constant TREASURY = address(0x7A5E);
    address internal constant CREATOR = address(0xCEEE);

    StonkzFeeHook internal hook;
    FeeLockerV2 internal locker;
    BuybackAccumulator internal acc;
    CTOGovernor internal gov;
    /// @dev Contract-backed sideTokenRef (Real PM currency + NotContract).
    MockSideToken internal sideTok;
    /// @dev Contract-backed USDG stand-in (Real PM sync requires code at pair).
    MockSideToken internal usdgPair;

    // ─── production-mirrored math (DirectListing / LadderSettlement) ─────────

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

    function _alignUp(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 rem = tick % spacing;
        if (rem < 0) rem += spacing;
        return rem == 0 ? tick : tick + (spacing - rem);
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

    /// @dev Expected init after spacing-align (matches production: initSqrt = getSqrtRatioAtTick(spotAligned)).
    function _expectedInit(uint256 priceInStonkz, bool tokIs0)
        internal
        pure
        returns (uint160 initSqrt, int24 spotAligned, int24 expectLo, int24 expectHi)
    {
        uint160 priceSqrt = _sqrtPriceFromPriceWad(priceInStonkz, !tokIs0);
        spotAligned = _align(TickMath.getTickAtSqrtRatio(priceSqrt), TICK_SPACING);
        initSqrt = TickMath.getSqrtRatioAtTick(spotAligned);
        int24 maxTick = _alignDown(TickMath.MAX_TICK, TICK_SPACING);
        int24 minTick = _alignUp(TickMath.MIN_TICK, TICK_SPACING);
        if (tokIs0) {
            expectLo = spotAligned + TICK_SPACING;
            expectHi = maxTick;
            if (expectLo >= expectHi) expectLo = expectHi - TICK_SPACING;
        } else {
            expectLo = minTick;
            expectHi = spotAligned;
            if (expectHi <= expectLo) expectHi = expectLo + TICK_SPACING;
        }
    }

    /// @return ok True iff range ticks + slot0 match ruled priceInStonkz (orientation-aware).
    function _sidePoolMatchesPrice(
        PoolKey memory sideKey,
        int24 sideLo,
        int24 sideHi,
        address userToken,
        address sideToken,
        uint256 priceInStonkz
    ) internal view returns (bool ok) {
        bool tokIs0 = userToken < sideToken;
        (uint160 expectSqrt, int24 spotAligned, int24 expectLo, int24 expectHi) =
            _expectedInit(priceInStonkz, tokIs0);
        if (sideLo != expectLo || sideHi != expectHi) return false;
        (uint160 sqrt, int24 tick,,) = pm.getSlot0(sideKey.toId());
        if (tick != spotAligned) return false;
        if (sqrt != expectSqrt) return false;
        return true;
    }

    function _assertExpressOnPoolPrice(StonkzDirectListing l, uint256 expectedPriceInStonkz) internal view {
        assertTrue(l.sidePoolDeployed(), "side deployed");
        assertGt(l.sideLiquidity(), 0, "side liq");
        uint256 priceInStonkz = FixedPointMathLib.mulDiv(l.startPriceWad(), WAD, l.refPriceWad());
        assertEq(priceInStonkz, expectedPriceInStonkz, "priceInStonkz arithmetic");
        assertTrue(
            _sidePoolMatchesPrice(
                l.sideKey(), l.sideTickLower(), l.sideTickUpper(), address(l.token()), l.sideTokenRef(), priceInStonkz
            ),
            "express side slot0/ticks != ruled refprice"
        );
    }

    function _assertLadderOnPoolPrice(LadderSettlement s, address userToken) internal view {
        uint256 priceInStonkz = FixedPointMathLib.fullMulDiv(s.printPrice(), WAD, s.refPriceWad());
        (Currency c0, Currency c1, uint24 fee, int24 spacing, address hooks) = s.sidePoolKey();
        PoolKey memory key = PoolKey({
            currency0: c0, currency1: c1, fee: fee, tickSpacing: spacing, hooks: hooks
        });
        assertTrue(
            _sidePoolMatchesPrice(
                key, s.sideTickLower(), s.sideTickUpper(), userToken, s.sideTokenRef(), priceInStonkz
            ),
            "ladder side slot0/ticks != ruled refprice"
        );
    }

    // ─── wiring ─────────────────────────────────────────────────────────────

    function _wireExpress() internal {
        sideTok = new MockSideToken();
        usdgPair = new MockSideToken();
        gov = new CTOGovernor();
        if (backend == Backend.Mock) {
            hook = new StonkzFeeHook(pm, TREASURY, ICTOGovernor(address(gov)));
        } else {
            hook = _deployFlagHook();
            hook.bindCanonManager(manager);
        }
        gov.setRegistry(hook);
        locker = new FeeLockerV2(pm, hook);
        acc = new BuybackAccumulator(ETH, address(sideTok), address(0));
    }

    function _deployFlagHook() internal returns (StonkzFeeHook h) {
        bytes memory creation = abi.encodePacked(
            type(StonkzFeeHook).creationCode, abi.encode(pm, TREASURY, ICTOGovernor(address(gov)))
        );
        bytes32 initCodeHash = keccak256(creation);
        bytes32 salt;
        address predicted;
        uint256 freemem;
        assembly {
            freemem := mload(0x40)
        }
        bool found;
        for (uint256 i; i < 1_000_000; ++i) {
            assembly {
                mstore(0x40, freemem)
            }
            salt = bytes32(i);
            predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash))))
            );
            if ((uint160(predicted) & Hooks.ALL_HOOK_MASK) == HookVanity.HOOK_FLAGS) {
                found = true;
                break;
            }
        }
        require(found, "no flag salt");
        h = new StonkzFeeHook{salt: salt}(pm, TREASURY, ICTOGovernor(address(gov)));
        require(address(h) == predicted, "flag create2");
    }

    function _listingParams() internal pure returns (StonkzDirectListing.ListingParams memory p) {
        p = StonkzDirectListing.ListingParams({
            startMcap: TIER_4K,
            totalSupply: SUPPLY,
            creatorReserveBps: 0,
            deliveryMode: 0,
            vestDuration: 0,
            declaredUse: bytes32("ops"),
            creator: CREATOR,
            name: "Stonk",
            symbol: "STK",
            createSidePool: true,
            sidePoolBps: 500,
            liquidityLocked: true,
            refPriceWad: 0
        });
    }

    function _listEth() internal returns (StonkzDirectListing l) {
        StonkzExpressFactory f =
            new StonkzExpressFactory(pm, locker, hook, acc, gov, ETH, address(sideTok));
        StonkzDirectListing.ListingParams memory p = _listingParams();
        (bytes32 userSalt,) = VanityHelpers.mineExpress(f, address(this), p);
        l = f.list{value: 1 ether}(p, userSalt);
    }

    function _listUsdg() internal returns (StonkzDirectListing l) {
        StonkzExpressFactory f =
            new StonkzExpressFactory(pm, locker, hook, acc, gov, address(usdgPair), address(sideTok));
        // Non-ETH pair uses USDG-style bounds/default (pair-wei per side-token).
        f.setRefPrice(address(sideTok), address(usdgPair), f.REF_PRICE_USDG_DEFAULT());
        StonkzDirectListing.ListingParams memory p = _listingParams();
        (bytes32 userSalt,) = VanityHelpers.mineExpress(f, address(this), p);
        l = f.list{value: 0}(p, userSalt);
    }

    // ─── Express locks ──────────────────────────────────────────────────────

    /// @notice ETH side pool: ruled 2.5e11 → priceInStonkz 1.6e22; slot0 + ticks locked.
    function test_lock_express_eth_slot0_matches_refprice() public {
        StonkzDirectListing l = _listEth();
        assertEq(l.refPriceWad(), 2.5e11);
        assertEq(l.startPriceWad(), 4e15);
        bool tokIs0 = address(l.token()) < l.sideTokenRef();
        // Orientation reported for STOP (CREATE2 token vs sideTok).
        assertTrue(tokIs0 || !tokIs0); // always true — documents both branches in coverage
        _assertExpressOnPoolPrice(l, 1.6e22);
    }

    /// @notice USDG side pool: same orientation rule (userToken vs sideTokenRef); pair ≠ side key.
    function test_lock_express_usdg_slot0_matches_refprice() public {
        StonkzDirectListing lEth = _listEth();
        StonkzDirectListing lUsdg = _listUsdg();
        bool ethTokIs0 = address(lEth.token()) < lEth.sideTokenRef();
        bool usdgTokIs0 = address(lUsdg.token()) < lUsdg.sideTokenRef();
        // Report via logs for STOP; assert lock regardless.
        emit log_named_string("eth tokIs0", ethTokIs0 ? "true" : "false");
        emit log_named_string("usdg tokIs0", usdgTokIs0 ? "true" : "false");
        emit log_named_string("tokIs0 flipped vs ETH", ethTokIs0 != usdgTokIs0 ? "yes" : "no");

        assertEq(lUsdg.refPriceWad(), 1e15);
        uint256 priceInStonkz = FixedPointMathLib.mulDiv(lUsdg.startPriceWad(), WAD, lUsdg.refPriceWad());
        assertEq(priceInStonkz, 4e18);
        _assertExpressOnPoolPrice(lUsdg, 4e18);
    }

    /// @notice Vacuity: wrong expected priceInStonkz must NOT match slot0 (1000× mispricing).
    function test_lock_vacuity_wrongPriceFailsMatch() public {
        StonkzDirectListing l = _listEth();
        uint256 correct = FixedPointMathLib.mulDiv(l.startPriceWad(), WAD, l.refPriceWad());
        assertEq(correct, 1.6e22);
        assertTrue(
            _sidePoolMatchesPrice(
                l.sideKey(), l.sideTickLower(), l.sideTickUpper(), address(l.token()), l.sideTokenRef(), correct
            ),
            "correct must pass"
        );
        uint256 wrong1000x = correct * 1000;
        assertFalse(
            _sidePoolMatchesPrice(
                l.sideKey(), l.sideTickLower(), l.sideTickUpper(), address(l.token()), l.sideTokenRef(), wrong1000x
            ),
            "1000x wrong expected must fail lock (teeth)"
        );
        // Also a near-miss ref (2×) fails.
        assertFalse(
            _sidePoolMatchesPrice(
                l.sideKey(),
                l.sideTickLower(),
                l.sideTickUpper(),
                address(l.token()),
                l.sideTokenRef(),
                FixedPointMathLib.mulDiv(l.startPriceWad(), WAD, 5e11) // pretend stamped 5e11
            ),
            "2x ref wrong expected must fail"
        );
    }

    // ─── Ladder locks ───────────────────────────────────────────────────────

    function _ladderGraduateAndSettle() internal returns (LadderSettlement settlement, address userToken) {
        MockVault mockVault = new MockVault();
        settlement = new LadderSettlement(pm, hook, ETH);
        settlement.setSideTokenRef(address(sideTok));
        if (backend == Backend.Real) {
            settlement.setFeeLocker(locker);
        }
        MockLaunchTok tok = new MockLaunchTok();
        userToken = address(tok);

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
        auction.settle(address(tok));
        assertGt(settlement.sideLiquidity(), 0, "side liq");
        assertEq(settlement.refPriceWad(), 2.5e11);
    }

    function test_lock_ladder_settle_slot0_matches_refprice() public {
        (LadderSettlement settlement, address userToken) = _ladderGraduateAndSettle();
        _assertLadderOnPoolPrice(settlement, userToken);

        // Vacuity on Ladder: 1000× wrong print/ref ratio fails.
        uint256 correct = FixedPointMathLib.fullMulDiv(settlement.printPrice(), WAD, settlement.refPriceWad());
        (Currency c0, Currency c1, uint24 fee, int24 spacing, address hooks) = settlement.sidePoolKey();
        PoolKey memory key =
            PoolKey({currency0: c0, currency1: c1, fee: fee, tickSpacing: spacing, hooks: hooks});
        assertTrue(
            _sidePoolMatchesPrice(
                key, settlement.sideTickLower(), settlement.sideTickUpper(), userToken, settlement.sideTokenRef(), correct
            )
        );
        assertFalse(
            _sidePoolMatchesPrice(
                key,
                settlement.sideTickLower(),
                settlement.sideTickUpper(),
                userToken,
                settlement.sideTokenRef(),
                correct * 1000
            ),
            "ladder 1000x wrong must fail"
        );
    }
}

contract SidePoolPriceLockMock is SidePoolPriceLockBase {
    function setUp() public {
        _setBackend(Backend.Mock);
        vm.deal(address(this), 100 ether);
        _wireExpress();
    }
}

contract SidePoolPriceLockReal is SidePoolPriceLockBase {
    function setUp() public {
        _setBackend(Backend.Real);
        vm.deal(address(this), 100 ether);
        _wireExpress();
    }
}

contract MockSideToken {
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

contract MockLaunchTok {
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
