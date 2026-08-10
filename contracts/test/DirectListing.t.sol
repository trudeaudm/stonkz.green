// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "../src/v4/IPoolManager.sol";
import {MockPoolManager} from "../src/mock/MockPoolManager.sol";
import {BuybackAccumulator} from "../src/BuybackAccumulator.sol";
import {StonkzFeeHook} from "../src/StonkzFeeHook.sol";
import {FeeLockerV2} from "../src/FeeLockerV2.sol";
import {CTOGovernor} from "../src/CTOGovernor.sol";
import {StonkzDirectListing} from "../src/StonkzDirectListing.sol";
import {StonkzLaunchToken} from "../src/StonkzLaunchToken.sol";
import {ICTOGovernor} from "../src/interfaces/IStonkzGovernance.sol";
import {TickMath} from "../src/v4/TickMath.sol";

/// @title DirectListing — C2 (fees-and-governance.md §2). MAX_TICK range, rug-impossibility,
///        emergent tier volatility, wei-exact conservation.
contract DirectListing is Test {
    MockPoolManager pm;
    BuybackAccumulator acc;
    StonkzFeeHook hook;
    FeeLockerV2 locker;
    CTOGovernor gov;

    address internal constant PAIR = address(0); // native pair — fixed orientation for both tiers
    address internal constant TREASURY = address(0x7A5E);
    address internal constant CREATOR = address(0xCEEE);

    uint256 internal constant SUPPLY = 1_000_000 ether;
    uint256 internal constant TIER_4K = 4000e18;
    uint256 internal constant TIER_8K = 8000e18;

    function setUp() public {
        pm = new MockPoolManager();
        acc = new BuybackAccumulator(PAIR, address(0x4663), address(0));
        gov = new CTOGovernor();
        hook = new StonkzFeeHook(IPoolManager(address(pm)), TREASURY, ICTOGovernor(address(gov)));
        gov.setRegistry(hook);
        locker = new FeeLockerV2(IPoolManager(address(pm)), hook);
    }

    function _list(uint256 tier, uint16 crBps, uint8 delivery) internal returns (StonkzDirectListing) {
        StonkzDirectListing.ListingParams memory p = StonkzDirectListing.ListingParams({
            startMcap: tier,
            totalSupply: SUPPLY,
            creatorReserveBps: crBps,
            deliveryMode: delivery,
            vestDuration: 30 days,
            declaredUse: bytes32("ops"),
            creator: CREATOR,
            name: "Stonk",
            symbol: "STK",
            createSidePool: true,
            sidePoolBps: 500,
            liquidityLocked: true,
            stonkzRefPriceWad: 2.5e11 // pair-wei per STONKZ token, WAD
        });
        return new StonkzDirectListing(
            IPoolManager(address(pm)), locker, hook, acc, gov, PAIR, address(0), p
        );
    }

    function test_C2_onlyValidTiers() public {
        StonkzDirectListing.ListingParams memory p = StonkzDirectListing.ListingParams({
            startMcap: 5000e18, // invalid
            totalSupply: SUPPLY,
            creatorReserveBps: 0,
            deliveryMode: 0,
            vestDuration: 0,
            declaredUse: bytes32(0),
            creator: CREATOR,
            name: "X",
            symbol: "X",
            createSidePool: true,
            sidePoolBps: 500,
            liquidityLocked: true,
            stonkzRefPriceWad: 2.5e11 // pair-wei per STONKZ token, WAD
        });
        vm.expectRevert(StonkzDirectListing.BadTier.selector);
        new StonkzDirectListing(IPoolManager(address(pm)), locker, hook, acc, gov, PAIR, address(0), p);
    }

    function test_C2_maxTickRange() public {
        StonkzDirectListing l = _list(TIER_4K, 0, 0);
        int24 alignedMax = 887220; // MAX_TICK (887272) aligned down to spacing 60
        assertEq(l.mainTickUpper(), alignedMax, "range top == MAX_TICK");
        assertLt(l.mainTickLower(), l.mainTickUpper());
    }

    function test_C2_conservationWeiExact() public {
        StonkzDirectListing l = _list(TIER_4K, 1500, 1); // 15% reserve, VEST
        (uint256 listed, uint256 side, uint256 cr) = l.conservationBuckets();
        assertEq(listed + side + cr, SUPPLY, "listed + side + reserve == supply (wei-exact)");
        assertEq(l.conservationSum(), SUPPLY);
        // creatorReserve == 15% of supply.
        assertEq(cr, (SUPPLY * 1500) / 10_000);
        // side == 5% of listing supply.
        uint256 listingSupply = SUPPLY - cr;
        assertEq(side, (listingSupply * 500) / 10_000);
        assertEq(listed, listingSupply - side);
    }

    function test_C2_rugImpossible_noPrincipalWithdraw() public {
        StonkzDirectListing l = _list(TIER_4K, 0, 0); // 0 reserve
        // With zero creatorReserve there is nothing to claim, ever.
        assertEq(l.claimCreatorReserve(), 0);
        // listed principal is fixed and never withdrawable — buckets are immutable post-construction.
        (uint256 listed0,,) = l.conservationBuckets();
        vm.warp(block.timestamp + 3650 days);
        assertEq(l.claimCreatorReserve(), 0, "no principal path");
        (uint256 listed1,,) = l.conservationBuckets();
        assertEq(listed0, listed1, "listed principal untouched");
        // The launch token supply held by the listing (LP principal) is not transferable by any
        // caller: there is no admin/withdraw entrypoint (asserted by absence at compile time).
    }

    function test_C2_creatorReserveInstantTimelock() public {
        StonkzDirectListing l = _list(TIER_4K, 1000, 0); // 10% INSTANT
        // Before 10-min timelock: nothing deliverable.
        assertEq(l.claimCreatorReserve(), 0, "instant timelock pending");
        vm.warp(block.timestamp + 10 minutes);
        uint256 got = l.claimCreatorReserve();
        assertEq(got, (SUPPLY * 1000) / 10_000, "full reserve after timelock");
        assertEq(l.token().balanceOf(CREATOR), got);
        // Capped: second claim yields nothing (no over-delivery).
        assertEq(l.claimCreatorReserve(), 0);
    }

    /// @notice Emergent tier volatility (§2.4): identical buy hits a $4k pool harder than $8k.
    function test_C2_tierVolatility_4kSteeperThan8k() public {
        StonkzDirectListing l4 = _list(TIER_4K, 0, 0);
        StonkzDirectListing l8 = _list(TIER_8K, 0, 0);
        uint256 buy = 100 ether;
        uint256 impact4 = l4.quoteBuyImpactWad(buy);
        uint256 impact8 = l8.quoteBuyImpactWad(buy);
        assertGt(impact4, impact8, "lower start mcap => steeper impact");
        // Same token depth at both tiers (feature, not a parameter).
        (uint256 listed4,,) = l4.conservationBuckets();
        (uint256 listed8,,) = l8.conservationBuckets();
        assertEq(listed4, listed8, "identical depth curve");
    }

    function test_C2_registeredInHookAndGovernor() public {
        StonkzDirectListing l = _list(TIER_4K, 0, 0);
        address tok = address(l.token());
        assertEq(hook.feeReceiver(tok), CREATOR, "hook receiver = creator");
        assertEq(hook.pageAdmin(tok), CREATOR);
        (, uint256 lpHeld,, uint256 parked, bool set) = gov.tokenRegs(tok);
        assertTrue(set, "gov registered");
        // Side parked pre-genesis; LP-held = listed (95%).
        (uint256 listed, uint256 side,) = l.conservationBuckets();
        assertEq(lpHeld, listed);
        assertEq(parked, side);
    }
}
