// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IPoolManager as ICanonPM} from "@v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@v4-core/src/libraries/Hooks.sol";
import {Deployers} from "@v4-core/test/utils/Deployers.sol";

import {IPoolManager} from "../src/v4/IPoolManager.sol";
import {V4Adapter} from "../src/v4/V4Adapter.sol";
import {MockPoolManager} from "../src/mock/MockPoolManager.sol";
import {PoolKey, PoolIdLibrary} from "../src/v4/types/PoolKey.sol";
import {Currency} from "../src/v4/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "../src/v4/types/BalanceDelta.sol";
import {TickMath} from "../src/v4/TickMath.sol";
import {LiquidityAmounts} from "../src/v4/LiquidityAmounts.sol";
import {BuybackAccumulator} from "../src/BuybackAccumulator.sol";
import {StonkzFeeHook} from "../src/StonkzFeeHook.sol";
import {FeeLockerV2} from "../src/FeeLockerV2.sol";
import {CTOGovernor} from "../src/CTOGovernor.sol";
import {ICTOGovernor} from "../src/interfaces/IStonkzGovernance.sol";
import {StonkzDirectListing} from "../src/StonkzDirectListing.sol";
import {HookVanity} from "../src/HookVanity.sol";

/// @dev Minimal ERC20 for non-ETH pair orientation + V4Adapter ownership tests.
contract MintFixToken {
    string public name = "PAIR";
    string public symbol = "PAIR";
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function decimals() external pure returns (uint8) {
        return 18;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        uint256 al = allowance[f][msg.sender];
        if (al != type(uint256).max) allowance[f][msg.sender] = al - a;
        balanceOf[f] -= a;
        balanceOf[to] += a;
        return true;
    }
}

/// @title ExpressMintFix — main-ask orientation + setBreakNetting owner + fork fill
contract ExpressMintFix is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant SUPPLY = 1_000_000 ether;
    uint256 internal constant TIER_4K = 4000e18;
    uint256 internal constant LISTED = 950_000 ether;
    /// @dev Live SDONK ethUsd stamp → startTick 130620, recon L exact.
    uint256 internal constant SDONK_ETH_USD = 1882169409521695205329;
    uint128 internal constant SDONK_CORRECT_L = 1385122402272340266780;
    int24 internal constant SDONK_START_TICK = 130620;
    int24 internal constant MIN_TICK_ALIGNED = -887220;
    int24 internal constant MAX_TICK_ALIGNED = 887220;

    address internal constant TREASURY = address(0x7A5E);
    address internal constant CREATOR = address(0xCEEE);
    address internal constant SIDE = address(0x4663);
    address internal constant RH_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant RH_ADAPTER_LIVE = 0xA4b41704AdD5603DE6b9ffb4C29c2978C7c4469a;

    MockPoolManager internal pm;
    BuybackAccumulator internal acc;
    StonkzFeeHook internal hook;
    FeeLockerV2 internal locker;
    CTOGovernor internal gov;

    function setUp() public {
        vm.etch(SIDE, hex"00");
        pm = new MockPoolManager();
        acc = new BuybackAccumulator(address(0), SIDE, address(0));
        gov = new CTOGovernor();
        hook = new StonkzFeeHook(IPoolManager(address(pm)), TREASURY, ICTOGovernor(address(gov)), address(this));
        gov.setRegistry(hook);
        locker = new FeeLockerV2(IPoolManager(address(pm)), hook);
    }

    function _params(uint256 ethUsd, uint256 refPrice)
        internal
        pure
        returns (StonkzDirectListing.ListingParams memory p)
    {
        p = StonkzDirectListing.ListingParams({
            startMcap: TIER_4K,
            totalSupply: SUPPLY,
            creatorReserveBps: 0,
            deliveryMode: 0,
            vestDuration: 0,
            declaredUse: bytes32("mintfix"),
            creator: CREATOR,
            name: "MintFix",
            symbol: "MFIX",
            createSidePool: true,
            sidePoolBps: 500,
            liquidityLocked: true,
            refPriceWad: refPrice,
            ethUsdWad: ethUsd
        });
    }

    function _paramsEth(uint256 ethUsd) internal pure returns (StonkzDirectListing.ListingParams memory p) {
        return _params(ethUsd, 2.5e11); // ETH-band ref
    }

    // ─── (a) SDONK expected-value fixture ──────────────────────────────────

    function test_a_sdonkFixture_correctedMainAsk() public {
        StonkzDirectListing l = new StonkzDirectListing(
            IPoolManager(address(pm)), locker, hook, acc, gov, address(0), SIDE, _paramsEth(SDONK_ETH_USD)
        );

        assertEq(l.listed(), LISTED);
        assertEq(l.sidePoolTokens(), 50_000 ether);
        assertEq(l.creatorReserve(), 0);

        assertEq(l.startTick(), SDONK_START_TICK, "startTick == SDONK");
        assertEq(l.mainTickLower(), MIN_TICK_ALIGNED, "ask floor");
        assertEq(l.mainTickUpper(), SDONK_START_TICK, "ask upper == startTick");
        assertEq(uint256(l.mainLiquidity()), uint256(SDONK_CORRECT_L), "exact recon L");

        // Old broken values must NOT appear.
        assertTrue(l.mainTickLower() != int24(130680), "not old lower");
        assertTrue(l.mainTickUpper() != MAX_TICK_ALIGNED, "not old MAX upper");
        assertTrue(uint256(l.mainLiquidity()) != 51635, "not old stranded L");
    }

    // ─── (c) orientation: token as currency0 (pair sorts after token) ───────

    function test_c_tokenCurrency0_aboveSpotAsk() public {
        // High-address pair so pair > launch token → pairIs0=false → token=c0.
        MintFixToken impl = new MintFixToken();
        address hiPair = address(type(uint160).max);
        vm.etch(hiPair, address(impl).code);

        BuybackAccumulator acc2 = new BuybackAccumulator(hiPair, SIDE, address(0));
        StonkzDirectListing l = new StonkzDirectListing(
            IPoolManager(address(pm)), locker, hook, acc2, gov, hiPair, SIDE, _params(SDONK_ETH_USD, 1e15)
        );

        assertTrue(hiPair > address(l.token()), "pair > token => token is c0");
        assertEq(l.mainTickLower(), l.startTick() + int24(60), "above-spot lower");
        assertEq(l.mainTickUpper(), MAX_TICK_ALIGNED, "above-spot upper MAX");

        uint160 sa = TickMath.getSqrtRatioAtTick(l.mainTickLower());
        uint160 sb = TickMath.getSqrtRatioAtTick(l.mainTickUpper());
        uint128 expect = LiquidityAmounts.getLiquidityForAmount0(sa, sb, LISTED);
        assertEq(uint256(l.mainLiquidity()), uint256(expect), "amount0 L");
        // Broken ETH-pair values must not appear on this branch.
        assertTrue(l.mainTickLower() != MIN_TICK_ALIGNED, "not c1 below-spot floor");
        assertTrue(l.mainTickUpper() != l.startTick(), "not c1 upper=startTick");
    }

    // ─── (c fill) Deployers real-PM: c0 ask fills on buy ───────────────────

    function test_c_tokenCurrency0_buyFills_realPm() public {
        deployFreshManagerAndRouters();
        V4Adapter adapter = new V4Adapter(manager);
        IPoolManager ipm = IPoolManager(address(adapter));

        CTOGovernor gov2 = new CTOGovernor();
        StonkzFeeHook hook2 = _mineHook(ipm, gov2);
        hook2.bindCanonManager(manager);
        hook2.setDefaultHookFeeBps(0); // fee take on etched max-address pair panics; geometry is the subject
        gov2.setRegistry(hook2);
        FeeLockerV2 locker2 = new FeeLockerV2(ipm, hook2);

        MintFixToken impl = new MintFixToken();
        address hiPair = address(type(uint160).max);
        vm.etch(hiPair, address(impl).code);
        vm.etch(SIDE, hex"00");
        MintFixToken(hiPair).mint(address(this), 0); // no-op warm
        BuybackAccumulator acc2 = new BuybackAccumulator(hiPair, SIDE, address(0));

        StonkzDirectListing l = new StonkzDirectListing(
            ipm, locker2, hook2, acc2, gov2, hiPair, SIDE, _params(SDONK_ETH_USD, 1e15)
        );
        require(hiPair > address(l.token()), "need token < pair for c0 branch");

        assertEq(l.mainTickUpper(), MAX_TICK_ALIGNED, "c0 above-spot upper");
        assertEq(l.mainTickLower(), l.startTick() + int24(60), "c0 above-spot lower");
        uint256 tokLeft = l.token().balanceOf(address(l));
        assertLt(tokLeft, 1e18, "listed+side consumed into pools");

        address buyer = address(0xB0B);
        MintFixToken(hiPair).mint(buyer, 100 ether);
        vm.prank(buyer);
        MintFixToken(hiPair).approve(address(adapter), type(uint256).max);

        PoolKey memory key = l.mainKey();
        (, int24 tickBefore,,) = adapter.getSlot0(key.toId());
        vm.prank(buyer);
        adapter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(1 ether),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_RATIO - 1
            }),
            ""
        );
        uint256 got = l.token().balanceOf(buyer);
        assertGt(got, 0, "c0 ask: buyer received tokens");
        (, int24 tickAfter,,) = adapter.getSlot0(key.toId());
        assertGt(tickAfter, tickBefore, "tick up as c0 ask fills");
    }

    // ─── (d) setBreakNetting onlyOwner ─────────────────────────────────────

    function test_d_setBreakNetting_onlyOwner() public {
        deployFreshManagerAndRouters();
        V4Adapter adapter = new V4Adapter(manager);
        assertEq(adapter.owner(), address(this));

        address stranger = address(0xBAD);
        vm.prank(stranger);
        vm.expectRevert(V4Adapter.NotOwner.selector);
        adapter.setBreakNetting(true);

        adapter.setBreakNetting(true);
        assertTrue(adapter.breakNetting());
        adapter.setBreakNetting(false);
        assertFalse(adapter.breakNetting());
    }

    // ─── (b) fork fill proof (acceptance) ──────────────────────────────────

    function test_b_forkFillProof_ethPair() public {
        string memory rpc = vm.envOr("ROBINHOOD_RPC_URL", string("https://rpc.mainnet.chain.robinhood.com"));
        vm.createSelectFork(rpc);
        require(block.chainid == 4663, "chain");

        ICanonPM manager_ = ICanonPM(RH_POOL_MANAGER);
        V4Adapter adapter = new V4Adapter(manager_);
        IPoolManager ipm = IPoolManager(address(adapter));

        CTOGovernor gov2 = new CTOGovernor();
        StonkzFeeHook hook2 = _mineHook(ipm, gov2);
        hook2.bindCanonManager(manager_);
        gov2.setRegistry(hook2);
        FeeLockerV2 locker2 = new FeeLockerV2(ipm, hook2);
        vm.etch(SIDE, hex"00");
        BuybackAccumulator acc2 = new BuybackAccumulator(address(0), SIDE, address(0));

        vm.deal(address(this), 2 ether);
        StonkzDirectListing l = new StonkzDirectListing{value: 1 ether}(
            ipm, locker2, hook2, acc2, gov2, address(0), SIDE, _paramsEth(SDONK_ETH_USD)
        );

        assertEq(l.mainTickLower(), MIN_TICK_ALIGNED);
        assertEq(l.mainTickUpper(), SDONK_START_TICK);
        assertEq(uint256(l.mainLiquidity()), uint256(SDONK_CORRECT_L));

        // Listed + side tokens pulled into pools; listing retains dust only.
        uint256 listingBal = l.token().balanceOf(address(l));
        console2.log("listing bal after mint", listingBal);
        console2.log("tokens pulled from listing", SUPPLY - listingBal);
        assertLt(listingBal, 1e18, "listed+side left listing");
        assertGt(SUPPLY - listingBal, LISTED - 1e18, "at least listed mass pulled");

        PoolKey memory key = l.mainKey();
        (uint160 sqrtBefore, int24 tickBefore,,) = adapter.getSlot0(key.toId());
        console2.log("tickBefore");
        console2.logInt(tickBefore);
        console2.log("sqrtBefore", uint256(sqrtBefore));

        address buyer = address(0xB0B);
        vm.deal(buyer, 10 ether);
        uint256 buyIn = 0.01 ether;
        vm.prank(buyer);
        BalanceDelta d = adapter.swap{value: buyIn * 2}(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(buyIn),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_RATIO + 1
            }),
            ""
        );
        console2.log("swap delta0");
        console2.logInt(d.amount0());
        console2.log("swap delta1");
        console2.logInt(d.amount1());

        uint256 buyerTok = l.token().balanceOf(buyer);
        console2.log("buyer tokens", buyerTok);
        assertGt(buyerTok, 4000 ether, "buyer ~4680 region lower");
        assertLt(buyerTok, 6000 ether, "buyer ~4680 region upper");

        (uint160 sqrtAfter, int24 tickAfter,,) = adapter.getSlot0(key.toId());
        console2.log("tickAfter");
        console2.logInt(tickAfter);
        console2.log("sqrtAfter", uint256(sqrtAfter));
        assertLt(tickAfter, tickBefore, "tick down = mcap up for token=c1");
        assertLt(uint256(sqrtAfter), uint256(sqrtBefore), "sqrt down");

        // Live unauthed adapter still exists (pre-redeploy); our new adapter is owned.
        assertEq(adapter.owner(), address(this));
        // Sanity: live adapter address still has code (not replaced by this test).
        assertGt(RH_ADAPTER_LIVE.code.length, 0);
    }

    function _mineHook(IPoolManager ipm, CTOGovernor gov_) internal returns (StonkzFeeHook h) {
        bytes memory creation =
            abi.encodePacked(type(StonkzFeeHook).creationCode, abi.encode(ipm, TREASURY, ICTOGovernor(address(gov_)), address(this)));
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
        h = new StonkzFeeHook{salt: salt}(ipm, TREASURY, ICTOGovernor(address(gov_)), address(this));
        require(address(h) == predicted, "flag create2");
        h.validateHookAddress(address(h));
    }
}
