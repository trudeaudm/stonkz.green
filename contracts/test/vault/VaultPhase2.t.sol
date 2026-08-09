// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StonkzVault} from "../../src/vault/StonkzVault.sol";
import {VaultConstants} from "../../src/vault/VaultConstants.sol";
import {IReleasePath} from "../../src/vault/IReleasePath.sol";
import {VaultMockToken} from "./VaultMockToken.sol";

/// @dev Mock path — receives vault transfers; no first-party airdropper in this chain.
contract MockReleasePath is IReleasePath {
    mapping(address => uint256) public received;

    function onVaultPathReceive(address token, uint256 amount, address) external {
        received[token] += amount;
    }
}

/// @title VaultPhase2 — path registry present/empty/mock-tested (docs/10 §4)
contract VaultPhase2 is Test {
    StonkzVault internal vault;
    VaultMockToken internal tok;
    MockReleasePath internal path;

    address internal constant CREATOR = address(0xCE0);

    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    function setUp() public {
        vault = new StonkzVault(VaultConstants.LAUNCH_RATE_SECONDS_PER_BPS, 1, 10_000);
        tok = new VaultMockToken();
        tok.mint(CREATOR, SUPPLY);
        path = new MockReleasePath();

        vm.startPrank(CREATOR);
        tok.approve(address(vault), 50_000_000 ether);
        vault.deposit(address(tok), 50_000_000 ether);
        vm.stopPrank();
    }

    function _airdropperBounds() internal pure returns (StonkzVault.PathBounds memory b) {
        // Launch airdropper shape (spec only): 0.1%/transfer, 1h cooldown, instant rate.
        b = StonkzVault.PathBounds({
            minRateSecondsPerBps: 0,
            maxRateSecondsPerBps: 0,
            minMaxPerTransferBps: 1,
            maxMaxPerTransferBps: 100, // up to 1%
            minCooldownSeconds: 0,
            maxCooldownSeconds: 7 days
        });
    }

    function test_P2_registerPath_rejectsEOA() public {
        StonkzVault.PathBounds memory b = _airdropperBounds();
        vm.expectRevert(StonkzVault.PathNotContract.selector);
        vault.registerPath(address(0xBEEF), 0, 10, 1 hours, b);
    }

    function test_P2_mockPath_cooldownAndLockedPending() public {
        StonkzVault.PathBounds memory b = _airdropperBounds();
        // Instant (rate=0), max 0.1% = 10 bps, 1h cooldown — airdropper launch shape.
        uint64 pathId = vault.registerPath(address(path), 0, 10, 1 hours, b);

        uint256 amt = (SUPPLY * 10) / 10_000; // 0.1%
        uint256 lockedBefore = vault.lockedBalance(address(tok));

        vm.prank(CREATOR);
        (uint256 id, uint256 eta) = vault.requestPathTransfer(address(tok), pathId, amt);
        assertEq(eta, block.timestamp, "instant ready");
        // Pending-to-path still counts as locked (docs/10 §6).
        assertEq(vault.pendingToPath(address(tok)), amt);
        assertEq(vault.lockedBalance(address(tok)), lockedBefore, "path pending still locked");

        vault.executePathTransfer(id);
        assertEq(path.received(address(tok)), amt);
        assertEq(vault.pendingToPath(address(tok)), 0);
        assertEq(vault.lockedBalance(address(tok)), lockedBefore - amt);

        // Cooldown enforcement
        vm.prank(CREATOR);
        vm.expectRevert(StonkzVault.CooldownActive.selector);
        vault.requestPathTransfer(address(tok), pathId, amt);

        vm.warp(block.timestamp + 1 hours);
        vm.prank(CREATOR);
        (uint256 id2,) = vault.requestPathTransfer(address(tok), pathId, amt);
        vault.executePathTransfer(id2);
        assertEq(path.received(address(tok)), amt * 2);
    }

    function test_P2_removePath_pendingStillExecutable() public {
        StonkzVault.PathBounds memory b = StonkzVault.PathBounds({
            minRateSecondsPerBps: 1,
            maxRateSecondsPerBps: 1000,
            minMaxPerTransferBps: 1,
            maxMaxPerTransferBps: 500,
            minCooldownSeconds: 0,
            maxCooldownSeconds: 0
        });
        // Delayed path: 108 s/bps so 1% = 3h
        uint64 pathId = vault.registerPath(address(path), 108, 100, 0, b);
        uint256 amt = SUPPLY / 100;

        vm.prank(CREATOR);
        (uint256 id,) = vault.requestPathTransfer(address(tok), pathId, amt);
        assertEq(vault.pendingToPath(address(tok)), amt);
        assertEq(vault.lockedBalance(address(tok)), 50_000_000 ether); // pending still locked

        vault.removePath(pathId);
        // New requests blocked
        vm.prank(CREATOR);
        vm.expectRevert(StonkzVault.PathInactive.selector);
        vault.requestPathTransfer(address(tok), pathId, amt);

        // Pending completes
        vm.warp(block.timestamp + 3 hours);
        vault.executePathTransfer(id);
        assertEq(path.received(address(tok)), amt);
    }

    function test_P2_pathRateStamp_andBounds() public {
        StonkzVault.PathBounds memory b = _airdropperBounds();
        uint64 pathId = vault.registerPath(address(path), 0, 10, 1 hours, b);

        vm.expectRevert(StonkzVault.RateOutOfBounds.selector);
        vault.setPathRate(pathId, 0, 200, 1 hours); // maxPerTransfer 200 > bound 100

        vault.setPathRate(pathId, 0, 10, 2 hours);
        (,, uint16 maxBps, uint64 cooldown,, bool active,) = vault.paths(pathId);
        assertEq(maxBps, 10);
        assertEq(cooldown, 2 hours);
        assertTrue(active);
    }
}
