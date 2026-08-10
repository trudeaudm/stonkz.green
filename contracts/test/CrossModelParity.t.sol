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
import {PoolKey, PoolId, PoolIdLibrary} from "../src/v4/types/PoolKey.sol";
import {Currency} from "../src/v4/types/Currency.sol";
import {TickMath} from "../src/v4/TickMath.sol";

/// @title CrossModelParity — C4 (fees-and-governance.md §5). Identical fee + CTO behavior for a
///        direct-listed token and a manually-registered (auction-like) token.
contract CrossModelParity is Test {
    using PoolIdLibrary for PoolKey;

    MockPoolManager pm;
    BuybackAccumulator acc;
    StonkzFeeHook hook;
    FeeLockerV2 locker;
    CTOGovernor gov;

    address internal constant PAIR = address(0xB111);
    address internal constant TREASURY = address(0x7A5E);
    address internal constant CREATOR = address(0xCEEE);

    function setUp() public {
        pm = new MockPoolManager();
        acc = new BuybackAccumulator(PAIR, address(0x4663), address(0));
        gov = new CTOGovernor();
        hook = new StonkzFeeHook(IPoolManager(address(pm)), TREASURY, ICTOGovernor(address(gov)));
        gov.setRegistry(hook);
        locker = new FeeLockerV2(IPoolManager(address(pm)), hook);
    }

    // ─── helpers ─────────────────────────────────────────────────────────────

    function _directToken() internal returns (StonkzDirectListing l) {
        StonkzDirectListing.ListingParams memory p = StonkzDirectListing.ListingParams({
            startMcap: 4000e18,
            totalSupply: 1_000_000 ether,
            creatorReserveBps: 2000, // 20% → circulating after INSTANT claim (for CTO)
            deliveryMode: 0, // INSTANT
            vestDuration: 0,
            declaredUse: bytes32("ops"),
            creator: CREATOR,
            name: "Direct",
            symbol: "DIR",
            createSidePool: true,
            sidePoolBps: 500
        });
        l = new StonkzDirectListing(IPoolManager(address(pm)), locker, hook, acc, gov, PAIR, address(0), p);
    }

    /// @dev A manually-registered "auction-like" token: same hook + governor wiring, no listing.
    ///      FEECHAIN Phase 2: main pools use LP fee 0 + hook (docs/06), matching DirectListing.
    function _manualToken(uint256 supply, address creator) internal returns (StonkzLaunchToken tok, PoolKey memory key) {
        tok = new StonkzLaunchToken("Auct", "AUC", supply, address(this));
        key = _mainPoolKey(PAIR, address(tok));
        pm.initialize(key, TickMath.getSqrtRatioAtTick(0));
        hook.registerPool(address(tok), PAIR, creator, key);
        gov.registerToken(address(tok), 0, 0, 0); // at-large = supply
    }

    function _mainPoolKey(address a, address b) internal view returns (PoolKey memory k) {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        k = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: 0, // pips = 0%
            tickSpacing: 60,
            hooks: address(hook)
        });
    }

    function _swapPayingToken(PoolKey memory key, address token, uint256 amountIn) internal {
        bool zeroForOne = Currency.unwrap(key.currency0) == token;
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1;
        pm.swap(
            key,
            IPoolManager.SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: limit}),
            ""
        );
    }

    // ─── fee parity ──────────────────────────────────────────────────────────

    /// @notice Same pair-currency swap → same protocolFeeBps split on a direct pool and a manual pool.
    /// @dev FEECHAIN Phase 3: main LP fee 0 pips, hook 100 bps = 1%; protocolFeeBps 2500 bps = 25% of fee.
    function test_C4_feeSplitParity_directAndManual() public {
        StonkzDirectListing l = _directToken();
        address tokA = address(l.token());
        PoolKey memory keyA = l.mainKey();

        (StonkzLaunchToken tokB, PoolKey memory keyB) = _manualToken(1_000_000 ether, CREATOR);

        uint256 amountIn = 1000 ether;
        _swapPayingToken(keyA, PAIR, amountIn);
        _swapPayingToken(keyB, PAIR, amountIn);

        uint256 feeGross = (amountIn * 100) / 10_000; // 100 bps = 1%
        uint256 expectTreasury = (feeGross * 2500) / 10_000; // 2500 bps = 25% of fee
        uint256 expectReceiver = feeGross - expectTreasury;
        assertEq(hook.receiverPairProceeds(tokA), expectReceiver, "direct receiver");
        assertEq(hook.receiverPairProceeds(address(tokB)), expectReceiver, "manual receiver");
        assertEq(hook.tokenPairProceeds(tokA), expectTreasury, "direct protocol");
        assertEq(hook.tokenPairProceeds(address(tokB)), expectTreasury, "manual protocol");
        assertEq(hook.receiverPairProceeds(tokA), hook.receiverPairProceeds(address(tokB)), "parity");
    }

    // ─── CTO parity ────────────────────────────────────────────────────────────

    /// @notice Identical CTO pass flow for a manual token and a direct-listed token.
    function test_C4_ctoParity_manualAndDirect() public {
        // ----- Manual (auction-like) token: full control over distribution -----
        (StonkzLaunchToken tokB,) = _manualToken(1000 ether, CREATOR);
        address initB = address(0x1B);
        address whaleB = address(0x2B);
        tokB.transfer(initB, 10 ether); // 1% of 1000e18 at-large
        tokB.transfer(whaleB, 800 ether); // 80% support
        _ctoPassFlow(address(tokB), initB, whaleB);
        assertEq(hook.feeReceiver(address(tokB)), initB, "manual receiver -> winner");
        assertEq(hook.pageAdmin(address(tokB)), initB);

        // ----- Direct-listed token: circulating supply via INSTANT reserve claim -----
        StonkzDirectListing l = _directToken();
        StonkzLaunchToken tokA = l.token();
        // Claim the 20% creatorReserve → creator now holds the entire at-large supply.
        vm.warp(block.timestamp + 10 minutes);
        uint256 claimed = l.claimCreatorReserve();
        assertGt(claimed, 0);
        uint256 atLargeA = gov.atLargeSupply(address(tokA));
        assertEq(atLargeA, claimed, "at-large == creatorReserve");

        address initA = address(0x1A);
        address whaleA = address(0x2A);
        uint256 initNeed = (atLargeA * 100) / 10_000; // 1%
        uint256 whalePower = (atLargeA * 8000) / 10_000; // 80% → pass
        vm.prank(CREATOR);
        tokA.transfer(initA, initNeed);
        vm.prank(CREATOR);
        tokA.transfer(whaleA, whalePower);

        _ctoPassFlow(address(tokA), initA, whaleA);
        assertEq(hook.feeReceiver(address(tokA)), initA, "direct receiver -> winner");
        assertEq(hook.pageAdmin(address(tokA)), initA);
    }

    function _ctoPassFlow(address token, address initiator, address whale) internal {
        vm.prank(initiator);
        gov.initiate(token, address(0));
        // Advance well past the initiation snapshot so getPastVotes reads a strictly-past block.
        vm.roll(gov.snapshotBlockOf(token) + 10);
        vm.prank(whale);
        gov.vote(token, true);
        // Warp to an ABSOLUTE time from storage (via-ir caches block.timestamp within the tx).
        vm.warp(uint256(gov.voteEndOf(token)) + 1);
        gov.finalize(token);
        assertEq(uint256(gov.status(token)), uint256(CTOGovernor.Status.Passed), "passed");
    }
}

