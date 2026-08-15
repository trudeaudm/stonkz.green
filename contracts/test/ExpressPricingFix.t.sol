// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {FactoryVanity} from "./FactoryVanity.sol";
import {VanityHelpers} from "./VanityHelpers.sol";
import {EthUsdRefHelpers, MockExtsloadPM} from "./EthUsdRefHelpers.sol";
import {Vanity} from "../src/Vanity.sol";
import {DeployControls} from "../src/DeployControls.sol";
import {IPoolManager} from "../src/v4/IPoolManager.sol";
import {MockPoolManager} from "../src/mock/MockPoolManager.sol";
import {PoolKey, PoolIdLibrary} from "../src/v4/types/PoolKey.sol";
import {TickMath} from "../src/v4/TickMath.sol";
import {BuybackAccumulator} from "../src/BuybackAccumulator.sol";
import {StonkzFeeHook} from "../src/StonkzFeeHook.sol";
import {FeeLockerV2} from "../src/FeeLockerV2.sol";
import {CTOGovernor} from "../src/CTOGovernor.sol";
import {ICTOGovernor} from "../src/interfaces/IStonkzGovernance.sol";
import {StonkzDirectListing} from "../src/StonkzDirectListing.sol";
import {StonkzExpressFactory} from "../src/StonkzExpressFactory.sol";

/// @dev 6-dec ERC20 stand-in for side-pool decimals vector.
contract MockUsd6 {
    string public name = "MockUSDG";
    string public symbol = "USDG";
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

/// @title ExpressPricingFix — BONZI unit root + decimals-aware sqrt + token vanity + fork ref
contract ExpressPricingFix is Test, FactoryVanity {
    using PoolIdLibrary for PoolKey;
    using FixedPointMathLib for uint256;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant SUPPLY = 1_000_000 ether;
    uint256 internal constant TIER_4K = 4000e18;
    uint256 internal constant ETH_USD = 1880e18;

    address internal constant PAIR = address(0);
    address internal constant TREASURY = address(0x7A5E);
    address internal constant CREATOR = address(0xCEEE);

    // Live designations (stonkz-refpools.md addendum) — fork test only; never hardcoded in product.
    address internal constant RH_PM = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    bytes32 internal constant REF_PRIMARY_B =
        bytes32(0x30dac7167c36242d1bacfd30561d444cf014529ee55978991d03e4ee178e725a);
    bytes32 internal constant REF_CHECK_A =
        bytes32(0x54f7883914619af9105355bf83ed678bcf9f63560218ac61c9963b9503d0ba32);

    MockPoolManager internal pm;
    BuybackAccumulator internal acc;
    StonkzFeeHook internal hook;
    FeeLockerV2 internal locker;
    CTOGovernor internal gov;
    StonkzExpressFactory internal express;
    MockUsd6 internal usd6;

    function setUp() public {
        usd6 = new MockUsd6();
        pm = new MockPoolManager();
        acc = new BuybackAccumulator(PAIR, address(usd6), address(0));
        gov = new CTOGovernor();
        hook = new StonkzFeeHook(IPoolManager(address(pm)), TREASURY, ICTOGovernor(address(gov)), address(this));
        gov.setRegistry(hook);
        locker = new FeeLockerV2(IPoolManager(address(pm)), hook);
        express = new StonkzExpressFactory(
            IPoolManager(address(pm)), locker, hook, acc, gov, PAIR, address(usd6)
        );
        // $1-band side ref at ~$1880 ETH: 1/1880 ETH per USDG ≈ 5.319e14 pair-wei WAD.
        express.setRefPrice(address(usd6), PAIR, 531914893617021);
        EthUsdRefHelpers.wireExpressRef(express, ETH_USD);
    }

    // ─── (a) BONZI regression fixture ──────────────────────────────────────

    function test_a_bonziFixture_usdTruePrice_notOldEthBlind() public {
        StonkzDirectListing.ListingParams memory p = _params();
        p.ethUsdWad = ETH_USD;
        p.refPriceWad = 531914893617021;
        StonkzDirectListing l = new StonkzDirectListing(
            IPoolManager(address(pm)), locker, hook, acc, gov, PAIR, address(usd6), p
        );

        uint256 expected = FixedPointMathLib.mulDiv(
            FixedPointMathLib.mulDiv(TIER_4K, WAD, ETH_USD), WAD, SUPPLY
        );
        assertEq(l.startPriceWad(), expected);
        assertEq(expected, 2127659574468); // ~2.12765957e12
        // Old BONZI bug outputs must NOT appear.
        assertTrue(l.startPriceWad() != 4e15);
        assertTrue(l.startTick() != int24(55200));
        // Forensics expected ~130560 region (tick alignment to spacing 60 only).
        assertGe(l.startTick(), int24(130500));
        assertLe(l.startTick(), int24(130620));
    }

    // ─── (b) 6-dec side vector ─────────────────────────────────────────────

    function test_b_sixDecSide_decimalsAdjustedTick() public {
        // Force token < side so tokIs0 path is deterministic: deploy listing and read.
        StonkzDirectListing.ListingParams memory p = _params();
        p.ethUsdWad = ETH_USD;
        // $1-band ref
        p.refPriceWad = 531914893617021;
        StonkzDirectListing l = new StonkzDirectListing(
            IPoolManager(address(pm)), locker, hook, acc, gov, PAIR, address(usd6), p
        );
        assertTrue(l.sidePoolDeployed());
        // Forensics: decimals-aware init ≈ ±331560 (sign = currency order); NOT old 18/18 ~89220.
        bool tokIs0 = address(l.token()) < address(usd6);
        int24 spotTick = tokIs0 ? (l.sideTickLower() - 60) : l.sideTickUpper();
        int24 absTick = spotTick < 0 ? -spotTick : spotTick;
        assertGe(absTick, int24(331000));
        assertLe(absTick, int24(332200));
        assertTrue(l.sideTickLower() != int24(89280));
    }

    // ─── (c) Ref read ──────────────────────────────────────────────────────

    function test_c_refRead_agreement_empty_unset_bounds() public {
        StonkzExpressFactory bare = new StonkzExpressFactory(
            IPoolManager(address(pm)), locker, hook, acc, gov, PAIR, address(usd6)
        );
        vm.expectRevert(DeployControls.RefPoolUnset.selector);
        bare.currentEthUsdWad();

        MockExtsloadPM refPm = new MockExtsloadPM();
        bytes32 primary = bytes32(uint256(0xB01));
        bytes32 check = bytes32(uint256(0xA01));
        uint160 sqrtP = EthUsdRefHelpers.sqrtPriceX96ForEthUsd(ETH_USD);
        // 0.01% delta — within default 5%
        uint160 sqrtClose = EthUsdRefHelpers.sqrtPriceX96ForEthUsd(ETH_USD + ETH_USD / 10_000);
        EthUsdRefHelpers.etchPool(refPm, primary, sqrtP, 1e18);
        EthUsdRefHelpers.etchPool(refPm, check, sqrtClose, 1e18);
        bare.setRefPools(address(refPm), primary, true, 6, check, true, 6);
        uint256 wad = bare.currentEthUsdWad();
        assertApproxEqRel(wad, ETH_USD, 0.001e18); // within 0.1% of target

        // >5% disagreement
        uint160 sqrtFar = EthUsdRefHelpers.sqrtPriceX96ForEthUsd(ETH_USD + ETH_USD / 10); // +10%
        EthUsdRefHelpers.etchPool(refPm, check, sqrtFar, 1e18);
        vm.expectRevert();
        bare.currentEthUsdWad();

        // Restore agreement then empty either pool
        EthUsdRefHelpers.etchPool(refPm, check, sqrtClose, 1e18);
        EthUsdRefHelpers.etchPool(refPm, primary, sqrtP, 0);
        vm.expectRevert(abi.encodeWithSelector(DeployControls.RefPoolEmpty.selector, primary));
        bare.currentEthUsdWad();

        EthUsdRefHelpers.etchPool(refPm, primary, sqrtP, 1e18);
        EthUsdRefHelpers.etchPool(refPm, check, sqrtClose, 0);
        vm.expectRevert(abi.encodeWithSelector(DeployControls.RefPoolEmpty.selector, check));
        bare.currentEthUsdWad();

        // Owner bounds on setters
        vm.expectRevert(DeployControls.ZeroAddress.selector);
        bare.setRefPools(address(0), primary, true, 6, check, true, 6);
        vm.expectRevert(abi.encodeWithSelector(DeployControls.RefAgreementBpsOutOfBounds.selector, uint16(0)));
        bare.setRefAgreementBps(0);
        vm.expectRevert(abi.encodeWithSelector(DeployControls.RefAgreementBpsOutOfBounds.selector, uint16(2001)));
        bare.setRefAgreementBps(2001);
        bare.setRefAgreementBps(1);
        bare.setRefAgreementBps(2000);
    }

    // ─── (d) Token vanity ──────────────────────────────────────────────────

    function test_d_tokenVanity_notListing() public {
        StonkzDirectListing.ListingParams memory p = _params();
        (bytes32 userSalt, address predictedListing) = VanityHelpers.mineExpress(express, address(this), p);
        address predictedToken = express.predictTokenAddress(predictedListing);
        assertEq(predictedToken, vm.computeCreateAddress(predictedListing, 1));
        assertTrue(Vanity.matches(predictedToken));
        // Listing prefix NOT required.
        // (may or may not match — we only require token)

        StonkzDirectListing listing = express.list(p, userSalt);
        assertEq(address(listing), predictedListing);
        assertEq(address(listing.token()), predictedToken);
        assertTrue(Vanity.matches(address(listing.token())));
        assertEq(Vanity.prefixOf(address(listing.token())), 0x4663);
    }

    // ─── (e) Full path mock PM ─────────────────────────────────────────────

    function test_e_fullPath_humanPriceAndQuote() public {
        StonkzDirectListing listing = _list(express, _params());
        // Mock sqrt round-trip is within 1 wei of target ETH/USD.
        assertApproxEqAbs(listing.ethUsdWad(), ETH_USD, 1e12);
        uint256 expectedStart = FixedPointMathLib.mulDiv(
            FixedPointMathLib.mulDiv(TIER_4K, WAD, listing.ethUsdWad()), WAD, SUPPLY
        );
        assertEq(listing.startPriceWad(), expectedStart);

        // Human main-pool price within 1 tick of $0.004/token.
        int24 expectedRegion = 130560;
        assertGe(listing.startTick(), expectedRegion - 60);
        assertLe(listing.startTick(), expectedRegion + 60);

        // $1-equivalent ETH in; tokens bought ≈ 250e18.
        uint256 pairIn = FixedPointMathLib.mulDiv(WAD, WAD, listing.ethUsdWad());
        uint256 tokensBought = FixedPointMathLib.mulDiv(pairIn, WAD, listing.startPriceWad());
        assertApproxEqRel(tokensBought, 250 ether, 0.01e18);
    }

    // ─── (f) Fork live ref read ─────────────────────────────────────────────

    function test_f_fork_liveRefPools() public {
        string memory rpc = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            rpc = "https://rpc.mainnet.chain.robinhood.com";
        }
        try vm.createSelectFork(rpc) {
            // ok
        } catch {
            emit log("skip: fork RPC unavailable");
            return;
        }
        if (block.chainid != 4663) {
            emit log("skip: chainId != 4663");
            return;
        }
        if (RH_PM.code.length == 0) {
            emit log("skip: RH PoolManager missing code");
            return;
        }

        // Fork wipes prior CREATE state — redeploy a local PM shell for factory wiring only.
        MockUsd6 forkUsd = new MockUsd6();
        MockPoolManager forkPm = new MockPoolManager();
        BuybackAccumulator forkAcc = new BuybackAccumulator(PAIR, address(forkUsd), address(0));
        CTOGovernor forkGov = new CTOGovernor();
        StonkzFeeHook forkHook =
            new StonkzFeeHook(IPoolManager(address(forkPm)), TREASURY, ICTOGovernor(address(forkGov)), address(this));
        forkGov.setRegistry(forkHook);
        FeeLockerV2 forkLocker = new FeeLockerV2(IPoolManager(address(forkPm)), forkHook);
        StonkzExpressFactory forkExpress = new StonkzExpressFactory(
            IPoolManager(address(forkPm)), forkLocker, forkHook, forkAcc, forkGov, PAIR, address(forkUsd)
        );
        forkExpress.setRefPools(RH_PM, REF_PRIMARY_B, true, 6, REF_CHECK_A, true, 6);

        uint256 wad = forkExpress.currentEthUsdWad();
        emit log_named_uint("fork currentEthUsdWad", wad);
        assertGe(wad, 1500e18);
        assertLe(wad, 2500e18);
    }

    function _params() internal view returns (StonkzDirectListing.ListingParams memory p) {
        p.startMcap = TIER_4K;
        p.totalSupply = SUPPLY;
        p.creatorReserveBps = 0;
        p.deliveryMode = 0;
        p.vestDuration = 0;
        p.declaredUse = bytes32("fix");
        p.creator = CREATOR;
        p.name = "BONZI";
        p.symbol = "BONZI";
        p.createSidePool = true;
        p.sidePoolBps = 500;
        p.liquidityLocked = true;
        p.refPriceWad = 531914893617021;
        p.ethUsdWad = ETH_USD;
    }
}
