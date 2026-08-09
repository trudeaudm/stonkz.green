// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StonkzVault} from "../../src/vault/StonkzVault.sol";
import {VaultConstants} from "../../src/vault/VaultConstants.sol";
import {VaultMockToken} from "./VaultMockToken.sol";

/// @title VaultPhase3 — splitting invariance fuzz + invariants + gas (docs/10)
contract VaultPhase3 is Test {
    StonkzVault internal vault;
    VaultMockToken internal tok;

    address internal constant CREATOR = address(0xCE0);
    address internal constant DEST = address(0xD57);

    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    function setUp() public {
        vault = new StonkzVault(VaultConstants.LAUNCH_RATE_SECONDS_PER_BPS, 1, 10_000);
        tok = new VaultMockToken();
        tok.mint(CREATOR, SUPPLY);
    }

    function _depositAll(uint256 amt) internal {
        vm.startPrank(CREATOR);
        tok.approve(address(vault), amt);
        vault.deposit(address(tok), amt);
        vm.stopPrank();
    }

    /// @notice Total exit time for N% equals sum of parts regardless of split.
    function testFuzz_P3_splittingInvariance(uint8 partsRaw, uint16 bpsRaw) public {
        uint256 parts = bound(partsRaw, 1, 8);
        uint256 totalBps = bound(bpsRaw, 100, 800); // 1%..8%
        // Split totalBps into `parts` positive chunks.
        uint256[] memory chunks = new uint256[](parts);
        uint256 remaining = totalBps;
        for (uint256 i; i < parts - 1; i++) {
            uint256 leave = parts - 1 - i;
            uint256 maxChunk = remaining - leave;
            uint256 chunk = bound(uint256(keccak256(abi.encode(i, bpsRaw))), 1, maxChunk);
            chunks[i] = chunk;
            remaining -= chunk;
        }
        chunks[parts - 1] = remaining;

        uint256 depositAmt = (SUPPLY * totalBps) / 10_000;
        _depositAll(depositAmt);

        uint256 t0 = block.timestamp;
        uint256 lastId;
        vm.startPrank(CREATOR);
        for (uint256 i; i < parts; i++) {
            uint256 amt = (SUPPLY * chunks[i]) / 10_000;
            (lastId,) = vault.requestDirectRelease(address(tok), amt, DEST);
        }
        vm.stopPrank();

        uint256 etaLast = vault.directEta(lastId);
        uint256 expected = t0 + (totalBps * uint256(VaultConstants.LAUNCH_RATE_SECONDS_PER_BPS));
        assertEq(etaLast, expected, "split-invariant total exit time");
    }

    function testFuzz_P3_reflowOnCancel(uint8 cancelIdxRaw) public {
        uint256 n = 4;
        uint256 cancelIdx = bound(cancelIdxRaw, 0, n - 1);
        _depositAll((SUPPLY * 4) / 100); // 4%

        uint256[] memory ids = new uint256[](n);
        vm.startPrank(CREATOR);
        for (uint256 i; i < n; i++) {
            (ids[i],) = vault.requestDirectRelease(address(tok), SUPPLY / 100, DEST);
        }
        uint256 etaLastBefore = vault.directEta(ids[n - 1]);
        vault.cancelDirectRelease(ids[cancelIdx]);
        vm.stopPrank();

        // Find last still-pending id
        uint256 lastPending;
        for (uint256 i = n; i > 0; i--) {
            (,,,,,, bool exec, bool canc) = vault.requests(ids[i - 1]);
            if (!exec && !canc) {
                lastPending = ids[i - 1];
                break;
            }
        }
        uint256 etaLastAfter = vault.directEta(lastPending);
        assertEq(etaLastBefore - etaLastAfter, 3 hours, "reflow by cancelled 1%");
    }

    function test_P3_invariant_noEarlyExecute_noDouble() public {
        _depositAll(SUPPLY / 100);
        vm.prank(CREATOR);
        (uint256 id,) = vault.requestDirectRelease(address(tok), SUPPLY / 100, DEST);

        vm.expectRevert(StonkzVault.NotReady.selector);
        vault.executeDirectRelease(id);

        vm.warp(block.timestamp + 3 hours);
        vault.executeDirectRelease(id);
        vm.expectRevert(StonkzVault.NotPending.selector);
        vault.executeDirectRelease(id);
    }

    function test_P3_invariant_lockedNeverExceedsCustody_excludesMatured() public {
        _depositAll((SUPPLY * 2) / 100);
        vm.prank(CREATOR);
        (uint256 id,) = vault.requestDirectRelease(address(tok), SUPPLY / 100, DEST);

        assertLe(vault.lockedBalance(address(tok)), vault.custody(address(tok)));
        vm.warp(block.timestamp + 3 hours);
        // Matured but unexecuted — still excluded from locked
        assertEq(vault.lockedBalance(address(tok)), SUPPLY / 100);
        assertEq(vault.custody(address(tok)), (SUPPLY * 2) / 100);
        vault.executeDirectRelease(id);
        assertLe(vault.lockedBalance(address(tok)), vault.custody(address(tok)));
    }

    function test_P3_ownerCannotExtract_negative() public {
        _depositAll(10_000_000 ether);
        // Every owner surface: rate/path/ownership — none move creator tokens.
        vault.setDirectRate(200);
        address other = address(0x0);
        // transferOwnership to zero reverts
        vm.expectRevert(StonkzVault.ZeroAddress.selector);
        vault.transferOwnership(other);

        MockPath p = new MockPath();
        StonkzVault.PathBounds memory b = StonkzVault.PathBounds({
            minRateSecondsPerBps: 0,
            maxRateSecondsPerBps: 10,
            minMaxPerTransferBps: 1,
            maxMaxPerTransferBps: 50,
            minCooldownSeconds: 0,
            maxCooldownSeconds: 1 days
        });
        uint64 pathId = vault.registerPath(address(p), 0, 10, 0, b);
        vault.setPathRate(pathId, 0, 10, 1 hours);
        vault.removePath(pathId);

        assertEq(vault.balanceOf(address(tok), CREATOR), 10_000_000 ether);
        assertEq(tok.balanceOf(address(this)), 0);
    }

    function test_P3_gas_request_cancelReflow_execute_depth20() public {
        _depositAll((SUPPLY * 20) / 100);
        uint256[] memory ids = new uint256[](20);
        vm.startPrank(CREATOR);
        uint256 g0 = gasleft();
        (ids[0],) = vault.requestDirectRelease(address(tok), SUPPLY / 100, DEST);
        uint256 gasRequest = g0 - gasleft();

        for (uint256 i = 1; i < 20; i++) {
            (ids[i],) = vault.requestDirectRelease(address(tok), SUPPLY / 100, DEST);
        }
        // Cancel middle at depth — reflow
        g0 = gasleft();
        vault.cancelDirectRelease(ids[10]);
        uint256 gasCancel = g0 - gasleft();
        vm.stopPrank();

        vm.warp(block.timestamp + 3 hours);
        g0 = gasleft();
        vault.executeDirectRelease(ids[0]);
        uint256 gasExec = g0 - gasleft();

        emit log_named_uint("gas_request_head", gasRequest);
        emit log_named_uint("gas_cancel_reflow_depth20", gasCancel);
        emit log_named_uint("gas_execute", gasExec);

        // Sanity caps — not load-bearing economics, catch runaway.
        assertLt(gasRequest, 250_000);
        assertLt(gasCancel, 150_000);
        assertLt(gasExec, 150_000);
    }
}

contract MockPath {
    function onVaultPathReceive(address, uint256, address) external {}
}
