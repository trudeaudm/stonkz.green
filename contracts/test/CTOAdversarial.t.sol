// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "../src/v4/IPoolManager.sol";
import {MockPoolManager} from "../src/mock/MockPoolManager.sol";
import {PoolKey} from "../src/v4/types/PoolKey.sol";
import {Currency} from "../src/v4/types/Currency.sol";
import {StonkzFeeHook} from "../src/StonkzFeeHook.sol";
import {CTOGovernor} from "../src/CTOGovernor.sol";
import {StonkzLaunchToken} from "../src/StonkzLaunchToken.sol";
import {ICTOGovernor} from "../src/interfaces/IStonkzGovernance.sol";

/// @title CTOAdversarial — C3 (fees-and-governance.md §4). One named test per attack.
contract CTOAdversarial is Test {
    MockPoolManager pm;
    StonkzFeeHook hook;
    CTOGovernor gov;

    address internal constant TREASURY = address(0x7A5E);
    address internal constant CREATOR = address(0xCEEE);
    address internal constant PAIR = address(0xB111);

    uint256 internal constant SUPPLY = 1000 ether;
    // at-large == SUPPLY (registered with 0 LP/burned/parked)
    uint256 internal constant INITIATE_MIN = 10 ether; // 1%
    uint256 internal constant CAST_MIN = 1 ether; // 0.1%
    uint256 internal constant PASS_THRESH = 800 ether; // 80%
    uint256 internal constant FAIL_THRESH = 200 ether; // 20%

    function setUp() public {
        pm = new MockPoolManager();
        gov = new CTOGovernor();
        hook = new StonkzFeeHook(IPoolManager(address(pm)), TREASURY, ICTOGovernor(address(gov)));
        gov.setRegistry(hook);
    }

    function _freshToken() internal returns (StonkzLaunchToken tok) {
        tok = new StonkzLaunchToken("Gov", "GOV", SUPPLY, address(this));
        // Register a primary pool in the hook (feeReceiver = creator) for interlock tests.
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(PAIR < address(tok) ? PAIR : address(tok)),
            currency1: Currency.wrap(PAIR < address(tok) ? address(tok) : PAIR),
            fee: 3000,
            tickSpacing: 60,
            hooks: address(0)
        });
        hook.registerPool(address(tok), PAIR, CREATOR, key);
        // at-large = total − 0 − 0 − 0 = SUPPLY.
        gov.registerToken(address(tok), 0, 0, 0);
    }

    // ─── attacks ───────────────────────────────────────────────────────────

    /// @notice vote → move tokens → the moved-to address cannot re-cast (snapshot power = 0),
    ///         and the original voter's power is re-clamped down to 0.
    function test_C3_voteMoveRevote_noDoubleCount() public {
        StonkzLaunchToken tok = _freshToken();
        address A = address(0xA1);
        address B = address(0xB2);
        address C = address(0xC3);
        tok.transfer(A, 100 ether);
        tok.transfer(C, 5 ether);

        vm.prank(A);
        gov.initiate(address(tok));
        vm.roll(block.number + 1);

        vm.prank(A);
        gov.vote(address(tok), true); // support 100
        (uint256 sup,,) = gov.tally(address(tok));
        assertEq(sup, 100 ether);

        // A moves everything to B, then C votes → triggers re-clamp of A down to 0.
        vm.prank(A);
        tok.transfer(B, 100 ether);
        vm.prank(C);
        gov.vote(address(tok), true);

        (sup,,) = gov.tally(address(tok));
        assertEq(sup, 5 ether, "A reclamped to 0, only C counts");

        // B cannot re-use A's moved tokens: B held 0 at snapshot.
        vm.prank(B);
        vm.expectRevert(CTOGovernor.BelowCastThreshold.selector);
        gov.vote(address(tok), true);
    }

    /// @notice vote support then dump — finalize's full re-clamp drops the dumper's power.
    function test_C3_voteThenDump_powerReclampedDown() public {
        StonkzLaunchToken tok = _freshToken();
        address W = address(0xA1A1);
        tok.transfer(W, 810 ether); // enough to pass alone

        vm.prank(W);
        gov.initiate(address(tok));
        vm.roll(block.number + 1);
        vm.prank(W);
        gov.vote(address(tok), true);
        (uint256 sup,,) = gov.tally(address(tok));
        assertEq(sup, 810 ether);

        // Dump after voting.
        vm.prank(W);
        tok.transfer(address(0xDEAD), 810 ether);

        vm.warp(block.timestamp + 25 hours);
        gov.finalize(address(tok));
        (sup,,) = gov.tally(address(tok));
        assertEq(sup, 0, "dumped power re-clamped to 0");
        assertEq(uint256(gov.status(address(tok))), uint256(CTOGovernor.Status.Failed), "fails after dump");
    }

    /// @notice Flashloan immunity: tokens acquired AFTER the snapshot carry no voting power.
    function test_C3_flashloanImmune_postSnapshotAcquisitionHasNoPower() public {
        StonkzLaunchToken tok = _freshToken();
        address INIT = address(0x11);
        address F = address(0xF1);
        tok.transfer(INIT, 10 ether);

        vm.prank(INIT);
        gov.initiate(address(tok));
        vm.roll(block.number + 1);

        // F acquires a large position only AFTER the snapshot block.
        tok.transfer(F, 500 ether);
        vm.prank(F);
        vm.expectRevert(CTOGovernor.BelowCastThreshold.selector);
        gov.vote(address(tok), true); // snapshot balance was 0 → power 0
    }

    /// @notice The eligible denominator is frozen at initiation; later registry updates don't move it.
    function test_C3_frozenDenominator_unaffectedByLateUpdate() public {
        StonkzLaunchToken tok = _freshToken();
        address INIT = address(0x11);
        tok.transfer(INIT, 10 ether);

        vm.prank(INIT);
        gov.initiate(address(tok));
        (,, uint256 denom0) = gov.tally(address(tok));
        assertEq(denom0, SUPPLY);

        // Registrar (this test) changes the denominator inputs mid-vote.
        gov.updateDenominator(address(tok), 400 ether, 0, 0);
        (,, uint256 denom1) = gov.tally(address(tok));
        assertEq(denom1, SUPPLY, "frozen denominator unchanged");
        // Live at-large did change for FUTURE proposals.
        assertEq(gov.atLargeSupply(address(tok)), SUPPLY - 400 ether);
    }

    /// @notice Paging with pre-snapshot holders: cursor advances, all re-clamped, pass tallied.
    ///         MAX_VOTERS is a hardcoded 1000 bound; the 0.1% cast minimum makes >1000 legitimate
    ///         voters impossible (1000 × 0.1% = 100%), so this exercises multi-page re-clamp.
    function test_C3_paging_manyVotersPass() public {
        StonkzLaunchToken tok = _freshToken();
        uint256 N = 120;
        // Distribute BEFORE the snapshot so everyone has power.
        for (uint256 i = 0; i < N; ++i) {
            address v = address(uint160(0x3000 + i));
            tok.transfer(v, 8 ether); // 120 × 8 = 960e18 support ≥ 800e18 pass
        }
        address initiator = address(uint160(0x2fff));
        tok.transfer(initiator, 10 ether); // ≥1% at-large to initiate
        vm.prank(initiator);
        gov.initiate(address(tok));
        vm.roll(block.number + 1);

        for (uint256 i = 0; i < N; ++i) {
            address v = address(uint160(0x3000 + i));
            vm.prank(v);
            gov.vote(address(tok), true);
        }
        assertEq(gov.voterCount(address(tok)), N);
        // cursor wrapped within [0, N)
        assertLt(gov.clampCursorOf(address(tok)), N);

        vm.warp(block.timestamp + 25 hours);
        gov.finalize(address(tok));
        (uint256 sup,,) = gov.tally(address(tok));
        assertEq(sup, N * 8 ether);
        assertEq(uint256(gov.status(address(tok))), uint256(CTOGovernor.Status.Passed));
    }

    /// @notice Initiate threshold boundary: exactly 1% passes, one wei less reverts.
    function test_C3_initiateThresholdBoundary() public {
        StonkzLaunchToken tok = _freshToken();
        address lo = address(0x51);
        tok.transfer(lo, INITIATE_MIN - 1);
        vm.prank(lo);
        vm.expectRevert(CTOGovernor.BelowInitiateThreshold.selector);
        gov.initiate(address(tok));

        address ok = address(0x52);
        tok.transfer(ok, INITIATE_MIN);
        vm.prank(ok);
        gov.initiate(address(tok)); // succeeds
        assertTrue(gov.ctoActive(address(tok)));
    }

    /// @notice Cast threshold boundary: exactly 0.1% casts, one wei less reverts.
    function test_C3_castThresholdBoundary() public {
        StonkzLaunchToken tok = _freshToken();
        address init = address(0x61);
        address lo = address(0x62);
        address ok = address(0x63);
        tok.transfer(init, 10 ether);
        tok.transfer(lo, CAST_MIN - 1);
        tok.transfer(ok, CAST_MIN);

        vm.prank(init);
        gov.initiate(address(tok));
        vm.roll(block.number + 1);

        vm.prank(lo);
        vm.expectRevert(CTOGovernor.BelowCastThreshold.selector);
        gov.vote(address(tok), true);

        vm.prank(ok);
        gov.vote(address(tok), true);
        (uint256 sup,,) = gov.tally(address(tok));
        assertEq(sup, CAST_MIN);
    }

    /// @notice Early-fail the instant reject exceeds 20% of the frozen denominator.
    function test_C3_earlyFail_rejectOver20pct() public {
        StonkzLaunchToken tok = _freshToken();
        address init = address(0x71);
        address R = address(0x72);
        tok.transfer(init, 10 ether);
        tok.transfer(R, FAIL_THRESH + 1 ether); // 201e18 > 200e18

        vm.prank(init);
        gov.initiate(address(tok));
        vm.roll(block.number + 1);

        vm.prank(R);
        gov.vote(address(tok), false);
        assertEq(uint256(gov.status(address(tok))), uint256(CTOGovernor.Status.Failed), "early-failed");

        // No further voting once terminated.
        address x = address(0x73);
        tok.transfer(x, 5 ether);
        vm.prank(x);
        vm.expectRevert(CTOGovernor.NotActive.selector);
        gov.vote(address(tok), true);
    }

    /// @notice 7-day cooldown blocks re-initiation after a fail; allowed once elapsed.
    function test_C3_cooldown_7dayReinitiate() public {
        StonkzLaunchToken tok = _freshToken();
        address init = address(0x81);
        address R = address(0x82);
        tok.transfer(init, 10 ether);
        tok.transfer(R, FAIL_THRESH + 1 ether);

        vm.prank(init);
        gov.initiate(address(tok));
        vm.roll(block.number + 1);
        vm.prank(R);
        gov.vote(address(tok), false); // early-fail → cooldown

        vm.prank(init);
        vm.expectRevert();
        gov.initiate(address(tok)); // still in cooldown

        vm.warp(block.timestamp + 7 days);
        vm.prank(init);
        gov.initiate(address(tok)); // allowed after cooldown
        assertTrue(gov.ctoActive(address(tok)));
    }

    /// @notice Voluntary feeReceiver transfer is BLOCKED while a CTO vote is active (§1.4).
    function test_C3_voluntaryTransferBlockedWhileActive() public {
        StonkzLaunchToken tok = _freshToken();
        address init = address(0x91);
        tok.transfer(init, 10 ether);

        // Before any CTO: transfer is allowed.
        vm.prank(CREATOR);
        hook.transferFeeReceiver(address(tok), address(0xE001));
        assertEq(hook.feeReceiver(address(tok)), address(0xE001));

        // Start CTO → now blocked.
        vm.prank(init);
        gov.initiate(address(tok));
        vm.prank(address(0xE001));
        vm.expectRevert(StonkzFeeHook.CTOActiveBlocked.selector);
        hook.transferFeeReceiver(address(tok), address(0xE002));

        // After the vote fails, transfer is allowed again.
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 25 hours);
        gov.finalize(address(tok));
        vm.prank(address(0xE001));
        hook.transferFeeReceiver(address(tok), address(0xE002));
        assertEq(hook.feeReceiver(address(tok)), address(0xE002));
    }

    /// @notice On PASS, finalize transfers feeReceiver + pageAdmin to the winner (§4.4).
    function test_C3_pass_transfersReceiverAndPageAdmin() public {
        StonkzLaunchToken tok = _freshToken();
        address init = address(0xA9);
        address whale = address(0xB9);
        tok.transfer(init, 10 ether);
        tok.transfer(whale, PASS_THRESH); // 800e18 support

        vm.prank(init);
        gov.initiate(address(tok));
        vm.roll(block.number + 1);
        vm.prank(whale);
        gov.vote(address(tok), true);

        vm.warp(block.timestamp + 25 hours);
        gov.finalize(address(tok));
        assertEq(uint256(gov.status(address(tok))), uint256(CTOGovernor.Status.Passed));
        // feeReceiver + pageAdmin → winner (the initiator/candidate).
        assertEq(hook.feeReceiver(address(tok)), init);
        assertEq(hook.pageAdmin(address(tok)), init);
    }
}
