// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StonkzToken} from "../src/StonkzToken.sol";
import {DeployControls} from "../src/DeployControls.sol";
import {MockPoolManager} from "../src/mock/MockPoolManager.sol";
import {IPoolManager} from "../src/v4/IPoolManager.sol";
import {CTOGovernor} from "../src/CTOGovernor.sol";
import {ICTOGovernor} from "../src/interfaces/IStonkzGovernance.sol";
import {StonkzFeeHook} from "../src/StonkzFeeHook.sol";
import {FeeLockerV2} from "../src/FeeLockerV2.sol";
import {BuybackAccumulator} from "../src/BuybackAccumulator.sol";
import {LadderSettlement} from "../src/ladder/LadderSettlement.sol";
import {StonkzVault} from "../src/vault/StonkzVault.sol";
import {VaultConstants} from "../src/vault/VaultConstants.sol";
import {StonkzExpressFactory} from "../src/StonkzExpressFactory.sol";
import {StonkzLadderFactory} from "../src/ladder/StonkzLadderFactory.sol";

/// @title DeployPhase0 — in-process mirror of Deploy.s.sol wiring (no broadcast, no keys)
/// @notice Proves manifest wiring + soft-launch + parked supply without RPC.
contract DeployPhase0 is Test {
    address internal constant CUSTODY = address(0xC05D);
    address internal constant TREASURY = address(0x7A5E);
    address internal constant USDG = address(0x55534447);

    function test_P0_fullManifest_wiring_softLaunch_parkedSupply() public {
        // Mirror Deploy.s.sol order (local, chain-id unrestricted in tests).
        StonkzToken stonkz = new StonkzToken(CUSTODY);
        MockPoolManager pm = new MockPoolManager();
        CTOGovernor gov = new CTOGovernor();
        StonkzFeeHook hook = new StonkzFeeHook(IPoolManager(address(pm)), TREASURY, ICTOGovernor(address(gov)));
        gov.setRegistry(hook);
        FeeLockerV2 locker = new FeeLockerV2(IPoolManager(address(pm)), hook);
        BuybackAccumulator acc = new BuybackAccumulator(address(0), address(stonkz), address(0));
        LadderSettlement settlement = new LadderSettlement(IPoolManager(address(pm)), hook, address(0));
        settlement.setStonkzRef(address(stonkz));
        settlement.setFeeLocker(locker);
        StonkzVault vault = new StonkzVault(VaultConstants.LAUNCH_RATE_SECONDS_PER_BPS, 1, 10_000);
        StonkzExpressFactory express = new StonkzExpressFactory(
            IPoolManager(address(pm)), locker, hook, acc, gov, address(0), address(stonkz)
        );
        StonkzLadderFactory ladder = new StonkzLadderFactory();
        ladder.setVaultRef(address(vault));
        ladder.setStonkzRefPrice(USDG, 1e15);

        // Soft-launch closed + deployer-only (this contract is msg.sender at construct).
        express.assertSoftLaunchGate(address(this));
        ladder.assertSoftLaunchGate(address(this));
        assertTrue(express.deploysEnabled());
        assertEq(express.allowlistCount(), 1);
        assertTrue(express.isDeployerAllowed(address(this)));

        // Wiring
        assertEq(express.stonkzRef(), address(stonkz));
        assertEq(ladder.vaultRef(), address(vault));
        assertEq(settlement.stonkzRef(), address(stonkz));
        assertEq(address(settlement.feeLocker()), address(locker));
        assertEq(address(gov.registry()), address(hook));
        assertEq(acc.stonkz4663(), address(stonkz));

        // Ref defaults
        assertEq(express.stonkzRefPriceWad(address(0)), 2.5e11);
        assertEq(ladder.stonkzRefPriceWad(address(0)), 2.5e11);
        assertEq(ladder.stonkzRefPriceWad(USDG), 1e15);

        // Token: fixed supply parked, official name/ticker, no mint surface beyond ctor.
        assertEq(stonkz.TOTAL_SUPPLY(), 100_000_000 ether);
        assertEq(stonkz.balanceOf(CUSTODY), 100_000_000 ether);
        assertEq(stonkz.balanceOf(address(this)), 0);
        assertEq(stonkz.name(), "STONKZ");
        assertEq(stonkz.symbol(), "STONKZ4663");
        assertEq(stonkz.allowance(CUSTODY, address(this)), 0);
    }

    function test_P0_stonkz_rejectsZeroCustody() public {
        vm.expectRevert(StonkzToken.ZeroCustody.selector);
        new StonkzToken(address(0));
    }
}
