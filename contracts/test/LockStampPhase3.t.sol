// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "../src/v4/IPoolManager.sol";
import {MockPoolManager} from "../src/mock/MockPoolManager.sol";
import {BuybackAccumulator} from "../src/BuybackAccumulator.sol";
import {StonkzFeeHook} from "../src/StonkzFeeHook.sol";
import {FeeLockerV2} from "../src/FeeLockerV2.sol";
import {CTOGovernor} from "../src/CTOGovernor.sol";
import {ICTOGovernor} from "../src/interfaces/IStonkzGovernance.sol";
import {StonkzDirectListing} from "../src/StonkzDirectListing.sol";
import {StonkzExpressFactory} from "../src/StonkzExpressFactory.sol";
import {StonkzLadderFactory} from "../src/ladder/StonkzLadderFactory.sol";
import {StonkzLadderAuction} from "../src/ladder/StonkzLadderAuction.sol";
import {LadderConstants} from "../src/ladder/LadderConstants.sol";
import {LadderTypes} from "../src/ladder/LadderTypes.sol";
import {LadderSettlement} from "../src/ladder/LadderSettlement.sol";
import {DeployControls} from "../src/DeployControls.sol";
import {StonkzLaunchToken} from "../src/StonkzLaunchToken.sol";
import {PoolIdLibrary} from "../src/v4/types/PoolKey.sol";

/// @title LockStampPhase3 — liquidityLocked stamp + unlock withdraw (docs/03 switch 1)
contract LockStampPhase3 is Test {
    using PoolIdLibrary for *;

    MockPoolManager internal pm;
    BuybackAccumulator internal acc;
    StonkzFeeHook internal hook;
    FeeLockerV2 internal locker;
    CTOGovernor internal gov;
    StonkzExpressFactory internal express;
    StonkzLadderFactory internal ladder;

    address internal constant PAIR = address(0);
    address internal constant TREASURY = address(0x7A5E);
    address internal constant CREATOR = address(0xCEEE);
    address internal constant STRANGER = address(0xB0B);
    address internal constant STONKZ = address(0x4663);

    uint256 internal constant SUPPLY = 1_000_000 ether;
    uint256 internal constant TIER_4K = 4000e18;

    function setUp() public {
        vm.etch(STONKZ, hex"00");
        pm = new MockPoolManager();
        acc = new BuybackAccumulator(PAIR, STONKZ, address(0));
        gov = new CTOGovernor();
        hook = new StonkzFeeHook(IPoolManager(address(pm)), TREASURY, ICTOGovernor(address(gov)));
        gov.setRegistry(hook);
        locker = new FeeLockerV2(IPoolManager(address(pm)), hook);
        express = new StonkzExpressFactory(
            IPoolManager(address(pm)), locker, hook, acc, gov, PAIR, STONKZ
        );
        ladder = new StonkzLadderFactory();
        ladder.setSideTokenRef(STONKZ);
    }

    function test_P3_birth_defaultLiquidityLockedTrue() public view {
        assertTrue(express.defaultLiquidityLocked());
        assertTrue(ladder.defaultLiquidityLocked());
    }

    function test_P3_express_lockedStamp_withdrawReverts() public {
        StonkzDirectListing l = express.list(_params(), bytes32(uint256(1)));
        assertTrue(l.liquidityLocked());
        assertEq(l.unlockRecipient(), CREATOR);
        assertTrue(locker.liquidityLocked(address(l.token())));
        assertEq(locker.unlockRecipient(address(l.token())), CREATOR);

        vm.prank(CREATOR);
        vm.expectRevert(StonkzDirectListing.LiquidityIsLocked.selector);
        l.withdrawMainLiquidity();
    }

    function test_P3_express_unlocked_creatorWithdraws() public {
        express.setDefaultLiquidityLocked(false);
        StonkzDirectListing l = express.list(_params(), bytes32(uint256(2)));
        assertFalse(l.liquidityLocked());
        assertEq(l.unlockRecipient(), CREATOR);
        assertGt(l.mainLiquidity(), 0);

        vm.prank(STRANGER);
        vm.expectRevert(StonkzDirectListing.NotUnlockRecipient.selector);
        l.withdrawMainLiquidity();

        vm.prank(CREATOR);
        l.withdrawMainLiquidity();
        assertEq(l.mainLiquidity(), 0);

        vm.prank(CREATOR);
        vm.expectRevert(StonkzDirectListing.NothingToWithdraw.selector);
        l.withdrawMainLiquidity();
    }

    function test_P3_coexistence_lockedAndUnlocked() public {
        StonkzDirectListing locked = express.list(_params(), bytes32(uint256(10)));
        express.setDefaultLiquidityLocked(false);
        StonkzDirectListing unlocked = express.list(_params(), bytes32(uint256(11)));

        assertTrue(locked.liquidityLocked());
        assertFalse(unlocked.liquidityLocked());

        vm.prank(CREATOR);
        vm.expectRevert(StonkzDirectListing.LiquidityIsLocked.selector);
        locked.withdrawMainLiquidity();

        vm.prank(CREATOR);
        unlocked.withdrawMainLiquidity();
        assertEq(unlocked.mainLiquidity(), 0);
        assertGt(locked.mainLiquidity(), 0);
    }

    function test_P3_stampSurvivesDefaultChange() public {
        StonkzDirectListing first = express.list(_params(), bytes32(uint256(20)));
        express.setDefaultLiquidityLocked(false);
        StonkzDirectListing second = express.list(_params(), bytes32(uint256(21)));
        assertTrue(first.liquidityLocked());
        assertFalse(second.liquidityLocked());
    }

    /// @notice PHASE-4-GO item 2: read-once at construction — factory flip must not unlock.
    function test_P3_express_readOnce_lockedSurvivesFactoryUnlock() public {
        StonkzDirectListing locked = express.list(_params(), bytes32(uint256(30)));
        assertTrue(locked.liquidityLocked());
        assertGt(locked.mainLiquidity(), 0);

        express.setDefaultLiquidityLocked(false);
        assertFalse(express.defaultLiquidityLocked());
        assertTrue(locked.liquidityLocked()); // stamp immutable

        vm.prank(CREATOR);
        vm.expectRevert(StonkzDirectListing.LiquidityIsLocked.selector);
        locked.withdrawMainLiquidity();
        assertGt(locked.mainLiquidity(), 0);
    }

    /// @notice Inverse: unlocked stamp still withdraws after factory flips back to locked.
    function test_P3_express_readOnce_unlockedSurvivesFactoryRelock() public {
        express.setDefaultLiquidityLocked(false);
        StonkzDirectListing unlocked = express.list(_params(), bytes32(uint256(31)));
        assertFalse(unlocked.liquidityLocked());

        express.setDefaultLiquidityLocked(true);
        assertTrue(express.defaultLiquidityLocked());
        assertFalse(unlocked.liquidityLocked());

        vm.prank(CREATOR);
        unlocked.withdrawMainLiquidity();
        assertEq(unlocked.mainLiquidity(), 0);
    }

    function test_P3_ladder_factoryStampsLockedFromControls() public {
        StonkzLadderAuction a = ladder.file(_ladderParams());
        assertTrue(a.liquidityLocked());
        assertEq(a.unlockRecipient(), CREATOR);

        ladder.setDefaultLiquidityLocked(false);
        StonkzLadderAuction b = ladder.file(_ladderParams());
        assertFalse(b.liquidityLocked());
        assertTrue(a.liquidityLocked()); // first unchanged
    }

    /// @notice Ladder msg.sender path: auction stamp survives factory flip (read-once).
    function test_P3_ladder_readOnce_lockedSurvivesFactoryUnlock() public {
        StonkzLadderAuction a = ladder.file(_ladderParams());
        assertTrue(a.liquidityLocked());
        ladder.setDefaultLiquidityLocked(false);
        assertFalse(ladder.defaultLiquidityLocked());
        assertTrue(a.liquidityLocked());
        assertEq(a.unlockRecipient(), CREATOR);
    }

    /// @notice Settlement withdraw gated on SettleArgs stamp, not live factory default.
    function test_P3_ladder_settlement_readOnce_lockedSurvivesFactoryUnlock() public {
        LadderSettlement s = _settleMinimal(true);
        assertTrue(s.liquidityLocked());
        ladder.setDefaultLiquidityLocked(false); // irrelevant to already-settled stamp
        vm.prank(CREATOR);
        vm.expectRevert(LadderSettlement.LiquidityIsLocked.selector);
        s.withdrawMainLiquidity();
        assertGt(s.cashLiquidity() + s.askLiquidity(), 0);
    }

    function test_P3_ladder_settlement_readOnce_unlockedSurvivesFactoryRelock() public {
        LadderSettlement s = _settleMinimal(false);
        assertFalse(s.liquidityLocked());
        ladder.setDefaultLiquidityLocked(true);
        vm.prank(CREATOR);
        s.withdrawMainLiquidity();
        assertEq(s.cashLiquidity() + s.askLiquidity(), 0);
    }

    function test_P3_ladder_directDeployDefaultsLocked() public {
        // Vector path: new auction from test contract → no defaultLiquidityLocked() → true
        StonkzLadderAuction.Params memory p = _ladderParams();
        p.carveBps = LadderConstants.DEFAULT_CARVE_BPS; // factory sentinel not valid on direct deploy
        StonkzLadderAuction a = new StonkzLadderAuction(p);
        assertTrue(a.liquidityLocked());
        assertEq(a.unlockRecipient(), CREATOR);
    }

    function test_P3_ladder_settlement_withdrawGate_notSettled() public {
        LadderSettlement s = new LadderSettlement(IPoolManager(address(pm)), hook, PAIR);
        vm.expectRevert(LadderSettlement.NotSettled.selector);
        s.withdrawMainLiquidity();
    }

    function _settleMinimal(bool locked) internal returns (LadderSettlement s) {
        s = new LadderSettlement(IPoolManager(address(pm)), hook, PAIR);
        s.setFeeLocker(locker);
        s.setSideTokenRef(STONKZ);
        vm.deal(address(this), 50 ether);
        uint256 supply = 1_000_000 ether;
        s.settle{value: 10 ether}(
            LadderSettlement.SettleArgs({
                graduated: true,
                raised: 10 ether,
                supply: supply,
                auctionSupply: supply,
                soldTokens: 100_000 ether,
                printPrice: 1 ether,
                floorPrice: 0.1 ether,
                carveBps: 400,
                cashHoldbackBps: 0,
                holdbackBps: 0,
                createSidePool: false,
                sidePoolBps: 500,
                refPriceWad: 0,
                liquidityLocked: locked,
                unlockRecipient: CREATOR,
                vaultRef: address(0),
                creator: CREATOR,
                treasury: TREASURY,
                userToken: address(new StonkzLaunchToken("T", "T", supply, address(this)))
            })
        );
    }

    function test_P3_invariantFuzz_lockedNeverWithdraws(uint8 saltSeed, bool trySide) public {
        StonkzDirectListing l = express.list(_params(), bytes32(uint256(saltSeed) + 1000));
        assertTrue(l.liquidityLocked());
        address caller = saltSeed % 2 == 0 ? CREATOR : STRANGER;
        vm.prank(caller);
        if (trySide) {
            vm.expectRevert();
            l.withdrawSideLiquidity();
        } else {
            vm.expectRevert();
            l.withdrawMainLiquidity();
        }
        assertGt(l.mainLiquidity(), 0);
    }

    function test_P3_events_loudOnLockDefaultChange() public {
        vm.expectEmit(false, false, false, true);
        emit DeployControls.DefaultLiquidityLockedSet(false);
        express.setDefaultLiquidityLocked(false);
    }

    function _params() internal pure returns (StonkzDirectListing.ListingParams memory p) {
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
            refPriceWad: 2.5e11 // pair-wei per STONKZ token, WAD
        });
    }

    function _ladderParams() internal returns (StonkzLadderAuction.Params memory p) {
        LadderSettlement settlement = new LadderSettlement(IPoolManager(address(pm)), hook, PAIR);
        p = StonkzLadderAuction.Params({
            supply: SUPPLY,
            auctionSupply: SUPPLY,
            floorMcap: 10_000 ether,
            duration: LadderConstants.GOD_DURATION,
            lpShareWad: 0.9e18,
            lpHealthTargetWad: 0.25e18,
            carveBps: type(uint16).max,
            cashHoldbackBps: 0,
            holdbackBps: 0,
            holdbackDelivery: LadderConstants.HoldbackDelivery.None,
            tier: LadderTypes.Tier.God,
            createSidePool: true,
            sidePoolBps: 500,
            refPriceWad: 2.5e11, // pair-wei per STONKZ token, WAD
            walletCapBps: 500,
            sizeBonusBps: 1000,
            maxUniqueActives: 64,
            pairToken: PAIR,
            creator: CREATOR,
            treasury: TREASURY,
            vaultRef: address(0),
            settlement: address(settlement)
        });
    }
}
