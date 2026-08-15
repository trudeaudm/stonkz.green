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
    uint256 internal constant INITIATE_MIN = 10 ether; // 1%
    uint256 internal constant CAST_MIN = 1 ether; // 0.1%
    uint256 internal constant PASS_THRESH = 800 ether; // 80%
    uint256 internal constant FAIL_THRESH = 200 ether; // 20%

    function setUp() public {
        pm = new MockPoolManager();
        gov = new CTOGovernor();
        hook = new StonkzFeeHook(IPoolManager(address(pm)), TREASURY, ICTOGovernor(address(gov)), address(this));
        gov.setRegistry(hook);
    }

    function _freshToken() internal returns (StonkzLaunchToken tok) {
        tok = new StonkzLaunchToken("Gov", "GOV", SUPPLY, address(this));
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(PAIR < address(tok) ? PAIR : address(tok)),
            currency1: Currency.wrap(PAIR < address(tok) ? address(tok) : PAIR),
            fee: 3000,
            tickSpacing: 60,
            hooks: address(0)
        });
        hook.registerPool(address(tok), PAIR, CREATOR, key);
        gov.registerToken(address(tok), 0, 0, 0);
    }

    function test_C3_voteMoveRevote_noDoubleCount() public {
        StonkzLaunchToken tok = _freshToken();
        address A = address(0xA1);
        address B = address(0xB2);
        address C = address(0xC3);
        tok.transfer(A, 100 ether);
        tok.transfer(C, 5 ether);

        vm.prank(A);
        gov.initiate(address(tok), address(0));
        vm.roll(block.number + 1);

        vm.prank(A);
        gov.vote(address(tok), true);
        (uint256 sup,,) = gov.tally(address(tok));
        assertEq(sup, 100 ether);

        vm.prank(A);
        tok.transfer(B, 100 ether);
        vm.prank(C);
        gov.vote(address(tok), true);

        (sup,,) = gov.tally(address(tok));
        assertEq(sup, 5 ether, "A reclamped to 0, only C counts");

        vm.prank(B);
        vm.expectRevert(CTOGovernor.BelowCastThreshold.selector);
        gov.vote(address(tok), true);
    }

    function test_C3_voteThenDump_powerReclampedDown() public {
        StonkzLaunchToken tok = _freshToken();
        address W = address(0xA1A1);
        tok.transfer(W, 810 ether);

        vm.prank(W);
        gov.initiate(address(tok), address(0));
        vm.roll(block.number + 1);
        vm.prank(W);
        gov.vote(address(tok), true);
        (uint256 sup,,) = gov.tally(address(tok));
        assertEq(sup, 810 ether);

        vm.prank(W);
        tok.transfer(address(0xDEAD), 810 ether);

        vm.warp(block.timestamp + 25 hours);
        gov.finalize(address(tok));
        (sup,,) = gov.tally(address(tok));
        assertEq(sup, 0, "dumped power re-clamped to 0");
        assertEq(uint256(gov.status(address(tok))), uint256(CTOGovernor.Status.Failed));
    }

    function test_C3_flashloanImmune_postSnapshotAcquisitionHasNoPower() public {
        StonkzLaunchToken tok = _freshToken();
        address INIT = address(0x11);
        address F = address(0xF1);
        tok.transfer(INIT, 10 ether);

        vm.prank(INIT);
        gov.initiate(address(tok), address(0));
        vm.roll(block.number + 1);

        tok.transfer(F, 500 ether);
        vm.prank(F);
        vm.expectRevert(CTOGovernor.BelowCastThreshold.selector);
        gov.vote(address(tok), true);
    }

    function test_C3_frozenDenominator_unaffectedByLateUpdate() public {
        StonkzLaunchToken tok = _freshToken();
        address INIT = address(0x11);
        tok.transfer(INIT, 10 ether);

        vm.prank(INIT);
        gov.initiate(address(tok), address(0));
        (,, uint256 denom0) = gov.tally(address(tok));
        assertEq(denom0, SUPPLY);

        gov.updateDenominator(address(tok), 400 ether, 0, 0);
        (,, uint256 denom1) = gov.tally(address(tok));
        assertEq(denom1, SUPPLY, "frozen denominator unchanged");
        assertEq(gov.atLargeSupply(address(tok)), SUPPLY - 400 ether);
    }

    function test_C3_paging_manyVotersPass() public {
        StonkzLaunchToken tok = _freshToken();
        uint256 N = 120;
        for (uint256 i = 0; i < N; ++i) {
            address v = address(uint160(0x3000 + i));
            tok.transfer(v, 8 ether);
        }
        address initiator = address(uint160(0x2fff));
        tok.transfer(initiator, 10 ether);
        vm.prank(initiator);
        gov.initiate(address(tok), address(0));
        vm.roll(block.number + 1);

        for (uint256 i = 0; i < N; ++i) {
            address v = address(uint160(0x3000 + i));
            vm.prank(v);
            gov.vote(address(tok), true);
        }
        assertEq(gov.voterCount(address(tok)), N);
        assertLt(gov.clampCursorOf(address(tok)), N);

        vm.warp(block.timestamp + 25 hours);
        gov.finalize(address(tok));
        (uint256 sup,,) = gov.tally(address(tok));
        assertEq(sup, N * 8 ether);
        assertEq(uint256(gov.status(address(tok))), uint256(CTOGovernor.Status.Passed));
    }

    function test_C3_initiateThresholdBoundary() public {
        StonkzLaunchToken tok = _freshToken();
        address lo = address(0x51);
        tok.transfer(lo, INITIATE_MIN - 1);
        vm.prank(lo);
        vm.expectRevert(CTOGovernor.BelowInitiateThreshold.selector);
        gov.initiate(address(tok), address(0));

        address ok = address(0x52);
        tok.transfer(ok, INITIATE_MIN);
        vm.prank(ok);
        gov.initiate(address(tok), address(0));
        assertTrue(gov.ctoActive(address(tok)));
    }

    function test_C3_castThresholdBoundary() public {
        StonkzLaunchToken tok = _freshToken();
        address init = address(0x61);
        address lo = address(0x62);
        address ok = address(0x63);
        tok.transfer(init, 10 ether);
        tok.transfer(lo, CAST_MIN - 1);
        tok.transfer(ok, CAST_MIN);

        vm.prank(init);
        gov.initiate(address(tok), address(0));
        vm.roll(block.number + 1);

        vm.prank(lo);
        vm.expectRevert(CTOGovernor.BelowCastThreshold.selector);
        gov.vote(address(tok), true);

        vm.prank(ok);
        gov.vote(address(tok), true);
        (uint256 sup,,) = gov.tally(address(tok));
        assertEq(sup, CAST_MIN);
    }

    function test_C3_earlyFail_rejectOver20pct() public {
        StonkzLaunchToken tok = _freshToken();
        address init = address(0x71);
        address R = address(0x72);
        tok.transfer(init, 10 ether);
        tok.transfer(R, FAIL_THRESH + 1 ether);

        vm.prank(init);
        gov.initiate(address(tok), address(0));
        vm.roll(block.number + 1);

        vm.prank(R);
        gov.vote(address(tok), false);
        assertEq(uint256(gov.status(address(tok))), uint256(CTOGovernor.Status.Failed));

        address x = address(0x73);
        tok.transfer(x, 5 ether);
        vm.prank(x);
        vm.expectRevert(CTOGovernor.NotActive.selector);
        gov.vote(address(tok), true);
    }

    function test_C3_cooldown_7dayReinitiate() public {
        StonkzLaunchToken tok = _freshToken();
        address init = address(0x81);
        address R = address(0x82);
        tok.transfer(init, 10 ether);
        tok.transfer(R, FAIL_THRESH + 1 ether);

        vm.prank(init);
        gov.initiate(address(tok), address(0));
        vm.roll(block.number + 1);
        vm.prank(R);
        gov.vote(address(tok), false);

        // Past token 24h spacing, initiator still address-cooled for 7d.
        vm.warp(gov.tokenNextWindow(address(tok)));
        vm.prank(init);
        vm.expectRevert();
        gov.initiate(address(tok), address(0));

        vm.warp(gov.addressCooldownUntil(init));
        vm.prank(init);
        gov.initiate(address(tok), address(0));
        assertTrue(gov.ctoActive(address(tok)));
    }

    function test_C3_voluntaryTransferBlockedWhileActive() public {
        StonkzLaunchToken tok = _freshToken();
        address init = address(0x91);
        tok.transfer(init, 10 ether);

        vm.prank(CREATOR);
        hook.transferFeeReceiver(address(tok), address(0xE001));
        assertEq(hook.feeReceiver(address(tok)), address(0xE001));

        vm.prank(init);
        gov.initiate(address(tok), address(0));
        vm.prank(address(0xE001));
        vm.expectRevert(StonkzFeeHook.CTOActiveBlocked.selector);
        hook.transferFeeReceiver(address(tok), address(0xE002));

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 25 hours);
        gov.finalize(address(tok));
        vm.prank(address(0xE001));
        hook.transferFeeReceiver(address(tok), address(0xE002));
        assertEq(hook.feeReceiver(address(tok)), address(0xE002));
    }

    function test_C3_pass_transfersReceiverAndPageAdmin() public {
        StonkzLaunchToken tok = _freshToken();
        address init = address(0xA9);
        address whale = address(0xB9);
        tok.transfer(init, 10 ether);
        tok.transfer(whale, PASS_THRESH);

        vm.prank(init);
        gov.initiate(address(tok), address(0));
        vm.roll(block.number + 1);
        vm.prank(whale);
        gov.vote(address(tok), true);

        vm.warp(block.timestamp + 25 hours);
        gov.finalize(address(tok));
        assertEq(uint256(gov.status(address(tok))), uint256(CTOGovernor.Status.Passed));
        assertEq(hook.feeReceiver(address(tok)), init);
        assertEq(hook.pageAdmin(address(tok)), init);
    }

    // ─── CTO ruling amendments ───────────────────────────────────────────────

    function test_C3_candidateFieldImmutable() public {
        StonkzLaunchToken tok = _freshToken();
        address init = address(0xC01);
        address cand = address(0xC02);
        tok.transfer(init, 10 ether);

        vm.prank(init);
        gov.initiate(address(tok), cand);
        assertEq(gov.initiatorOf(address(tok)), init);
        assertEq(gov.candidateOf(address(tok)), cand);

        address other = address(0xC03);
        tok.transfer(other, 10 ether);
        vm.prank(other);
        vm.expectRevert(CTOGovernor.CTOAlreadyActive.selector);
        gov.initiate(address(tok), other);

        assertEq(gov.candidateOf(address(tok)), cand, "candidate unchanged");
    }

    function test_C3_pass_transfersToCandidateNotInitiator() public {
        StonkzLaunchToken tok = _freshToken();
        address init = address(0xD01);
        address cand = address(0xD02);
        address whale = address(0xD03);
        tok.transfer(init, 10 ether);
        tok.transfer(whale, PASS_THRESH);

        vm.prank(init);
        gov.initiate(address(tok), cand);
        assertEq(gov.candidateOf(address(tok)), cand);

        vm.roll(block.number + 1);
        vm.prank(whale);
        gov.vote(address(tok), true);

        vm.warp(block.timestamp + 25 hours);
        gov.finalize(address(tok));
        assertEq(uint256(gov.status(address(tok))), uint256(CTOGovernor.Status.Passed));
        assertEq(hook.feeReceiver(address(tok)), cand, "receiver -> candidate");
        assertEq(hook.pageAdmin(address(tok)), cand, "pageAdmin -> candidate");
        assertTrue(hook.feeReceiver(address(tok)) != init, "not initiator");
    }

    function test_C3_squatterLockout_genuineSucceedsAfter24h() public {
        StonkzLaunchToken tok = _freshToken();
        address squatter = address(0xE01);
        address rejector = address(0xE02);
        address genuine = address(0xE03);
        address multisig = address(0xE04);
        address community = address(0xE05);
        tok.transfer(squatter, 10 ether);
        tok.transfer(rejector, FAIL_THRESH + 1 ether);
        tok.transfer(genuine, 10 ether);
        tok.transfer(community, 10 ether);

        vm.prank(squatter);
        gov.initiate(address(tok), squatter);
        vm.roll(block.number + 1);
        vm.prank(rejector);
        gov.vote(address(tok), false);
        assertEq(uint256(gov.status(address(tok))), uint256(CTOGovernor.Status.Failed));

        // After 24h token spacing, genuine community opens a new vote (not 7d).
        vm.warp(gov.tokenNextWindow(address(tok)));
        vm.prank(genuine);
        gov.initiate(address(tok), multisig);
        assertTrue(gov.ctoActive(address(tok)));
        assertEq(gov.candidateOf(address(tok)), multisig);

        vm.warp(block.timestamp + 25 hours);
        gov.finalize(address(tok)); // fails (no support); cools genuine+multisig

        vm.warp(gov.tokenNextWindow(address(tok)));

        // Squatter still address-cooled as initiator.
        vm.prank(squatter);
        vm.expectRevert();
        gov.initiate(address(tok), squatter);

        // Squatter blocked as candidate.
        vm.prank(community);
        vm.expectRevert();
        gov.initiate(address(tok), squatter);

        // Fresh community succeeds.
        vm.prank(community);
        gov.initiate(address(tok), community);
        assertTrue(gov.ctoActive(address(tok)));
    }

    function test_C3_cooldownBindsBothRoles() public {
        StonkzLaunchToken tok = _freshToken();
        address init = address(0xF01);
        address cand = address(0xF02);
        address rejector = address(0xF03);
        address other = address(0xF04);
        tok.transfer(init, 10 ether);
        tok.transfer(cand, 10 ether);
        tok.transfer(rejector, FAIL_THRESH + 1 ether);
        tok.transfer(other, 10 ether);

        vm.prank(init);
        gov.initiate(address(tok), cand);
        vm.roll(block.number + 1);
        vm.prank(rejector);
        gov.vote(address(tok), false);

        vm.warp(gov.tokenNextWindow(address(tok))); // past token spacing

        uint64 untilInit = gov.addressCooldownUntil(init);
        uint64 untilCand = gov.addressCooldownUntil(cand);

        vm.prank(init);
        vm.expectRevert(abi.encodeWithSelector(CTOGovernor.AddressCooldownActive.selector, init, untilInit));
        gov.initiate(address(tok), other);

        vm.prank(cand);
        vm.expectRevert(abi.encodeWithSelector(CTOGovernor.AddressCooldownActive.selector, cand, untilCand));
        gov.initiate(address(tok), other);

        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(CTOGovernor.AddressCooldownActive.selector, cand, untilCand));
        gov.initiate(address(tok), cand);

        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(CTOGovernor.AddressCooldownActive.selector, init, untilInit));
        gov.initiate(address(tok), init);

        vm.prank(other);
        gov.initiate(address(tok), other);
        assertEq(gov.candidateOf(address(tok)), other);
    }
}
