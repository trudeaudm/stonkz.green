// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StonkzVault} from "../../src/vault/StonkzVault.sol";
import {VaultConstants} from "../../src/vault/VaultConstants.sol";
import {VaultMockToken} from "./VaultMockToken.sol";

/// @title VaultPhase0 — custody + proportional serial direct-release queue (docs/10 §§1–3,5)
contract VaultPhase0 is Test {
    StonkzVault internal vault;
    VaultMockToken internal tok;

    address internal constant CREATOR = address(0xCE0);
    address internal constant DEST = address(0xD57);
    address internal constant OTHER = address(0x0711);

    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    function setUp() public {
        vault = new StonkzVault(
            VaultConstants.LAUNCH_RATE_SECONDS_PER_BPS,
            1, // min seconds/bps
            10_000 // max seconds/bps
        );
        tok = new VaultMockToken();
        tok.mint(CREATOR, SUPPLY);
    }

    function _deposit(address who, uint256 amt) internal {
        vm.startPrank(who);
        tok.approve(address(vault), amt);
        vault.deposit(address(tok), amt);
        vm.stopPrank();
    }

    function test_P0_deposit_creditsBeneficiary_andCustody() public {
        uint256 amt = 60_000_000 ether; // 6%
        vm.startPrank(CREATOR);
        tok.approve(address(vault), amt);
        vault.deposit(address(tok), amt, CREATOR);
        vm.stopPrank();

        assertEq(vault.custody(address(tok)), amt);
        assertEq(vault.balanceOf(address(tok), CREATOR), amt);
        assertEq(vault.lockedBalance(address(tok)), amt);
        assertEq(tok.balanceOf(address(vault)), amt);
    }

    function test_P0_perTokenIsolation() public {
        VaultMockToken tok2 = new VaultMockToken();
        tok2.mint(CREATOR, SUPPLY);
        _deposit(CREATOR, 10_000_000 ether);
        vm.startPrank(CREATOR);
        tok2.approve(address(vault), 20_000_000 ether);
        vault.deposit(address(tok2), 20_000_000 ether);
        vm.stopPrank();

        assertEq(vault.custody(address(tok)), 10_000_000 ether);
        assertEq(vault.custody(address(tok2)), 20_000_000 ether);
        assertEq(vault.lockedBalance(address(tok)), 10_000_000 ether);
        assertEq(vault.lockedBalance(address(tok2)), 20_000_000 ether);
    }

    /// @notice Ruled example: 1% + 2% + 1% → lands at 3h, 9h, 12h.
    function test_P0_fifo_ruledExample_1_2_1() public {
        _deposit(CREATOR, 40_000_000 ether); // 4%
        uint256 a1 = SUPPLY / 100; // 1%
        uint256 a2 = (SUPPLY * 2) / 100; // 2%
        uint256 a3 = SUPPLY / 100; // 1%

        uint256 t0 = block.timestamp;
        vm.startPrank(CREATOR);
        (uint256 id1, uint256 eta1) = vault.requestDirectRelease(address(tok), a1, DEST);
        (uint256 id2, uint256 eta2) = vault.requestDirectRelease(address(tok), a2, DEST);
        (uint256 id3, uint256 eta3) = vault.requestDirectRelease(address(tok), a3, DEST);
        vm.stopPrank();

        assertEq(eta1, t0 + 3 hours, "1% @ 3h");
        assertEq(eta2, t0 + 9 hours, "2% @ 9h");
        assertEq(eta3, t0 + 12 hours, "1% @ 12h");

        // lockedBalance excludes queued direct amounts
        assertEq(vault.queuedDirect(address(tok)), a1 + a2 + a3);
        assertEq(vault.lockedBalance(address(tok)), 0);

        vm.warp(t0 + 3 hours);
        vault.executeDirectRelease(id1);
        assertEq(tok.balanceOf(DEST), a1);

        // second not ready until predecessor completes + 6h
        vm.expectRevert(StonkzVault.NotReady.selector);
        vault.executeDirectRelease(id2);

        vm.warp(t0 + 9 hours);
        vault.executeDirectRelease(id2);
        vm.warp(t0 + 12 hours);
        vault.executeDirectRelease(id3);
        assertEq(tok.balanceOf(DEST), a1 + a2 + a3);
        assertEq(vault.custody(address(tok)), 0);
    }

    function test_P0_cancel_reflowsSuccessors() public {
        _deposit(CREATOR, 40_000_000 ether);
        uint256 a1 = SUPPLY / 100;
        uint256 a2 = (SUPPLY * 2) / 100;
        uint256 a3 = SUPPLY / 100;

        vm.startPrank(CREATOR);
        (uint256 id1,) = vault.requestDirectRelease(address(tok), a1, DEST);
        (uint256 id2,) = vault.requestDirectRelease(address(tok), a2, DEST);
        (uint256 id3, uint256 eta3Before) = vault.requestDirectRelease(address(tok), a3, DEST);
        assertEq(eta3Before, block.timestamp + 12 hours);

        // Cancel middle 2% → 1%+1% chain = 6h for id3
        vault.cancelDirectRelease(id2);
        uint256 eta3After = vault.directEta(id3);
        assertEq(eta3After, block.timestamp + 6 hours, "reflow drops 6h");

        // Cancel head → id3 starts now, ready in 3h
        vault.cancelDirectRelease(id1);
        assertEq(vault.directReadyAt(id3), block.timestamp + 3 hours);
        assertEq(vault.balanceOf(address(tok), CREATOR), a1 + a2); // refunded
        vm.stopPrank();
    }

    function test_P0_rateStamp_survivesRateChange() public {
        _deposit(CREATOR, 30_000_000 ether);
        uint256 a1 = SUPPLY / 100;

        vm.prank(CREATOR);
        (uint256 id1, uint256 eta1) = vault.requestDirectRelease(address(tok), a1, DEST);
        assertEq(eta1, block.timestamp + 3 hours);

        // Owner doubles the rate (slower): 216 s/bps
        vault.setDirectRate(216);
        assertEq(vault.directReadyAt(id1), eta1, "old ETA unchanged");

        vm.prank(CREATOR);
        (, uint256 eta2) = vault.requestDirectRelease(address(tok), a1, DEST);
        // id2 waits for id1 (3h) then own duration at new rate (100*216=21600=6h) → 9h total
        assertEq(eta2, block.timestamp + 3 hours + 6 hours, "new request uses new rate");
    }

    function test_P0_permissionlessExecute_onlyToDestination() public {
        _deposit(CREATOR, SUPPLY / 100);
        vm.prank(CREATOR);
        (uint256 id,) = vault.requestDirectRelease(address(tok), SUPPLY / 100, DEST);

        vm.warp(block.timestamp + 3 hours);
        vm.prank(OTHER); // anyone may crank
        vault.executeDirectRelease(id);
        assertEq(tok.balanceOf(DEST), SUPPLY / 100);
        assertEq(tok.balanceOf(OTHER), 0);
    }

    function test_P0_ownerCannotExtract() public {
        _deposit(CREATOR, 10_000_000 ether);
        // Owner rate set within bounds is fine; no withdraw exists.
        vault.setDirectRate(108);
        vm.expectRevert(StonkzVault.RateOutOfBounds.selector);
        vault.setDirectRate(0); // below min
        assertEq(vault.balanceOf(address(tok), CREATOR), 10_000_000 ether);
        assertEq(tok.balanceOf(address(this)), 0);
    }
}
