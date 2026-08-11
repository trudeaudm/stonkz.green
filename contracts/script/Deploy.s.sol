// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {DeployControls} from "../src/DeployControls.sol";

/// @title Deploy — one-command scripted deploy (spec sec 10 / MAINNET PATH)
/// @notice Full stack wiring lands with the rehearsal chain. This file owns the
///         RIDER A soft-launch gate assertion so every future deploy path shares it.
///
/// REQUIREMENTS (standing):
/// - all config in code, no interactive steps
/// - admin roles at construction; deployer ends powerless after handoff
/// - DeployControls birth / post-config: deploysEnabled + nonempty allowlist (deployer)
///
/// RUNBOOK (rehearsal / official — fold into concrete run() when MAINNET PATH lands):
/// - [ ] Re-check ETH `refPriceWad[sideTokenRef][address(0)]` against spot at deploy time.
///       Birth default 2.5e11 pair-wei/side-token ≈ $0.001 at $4k ETH; update via
///       `setRefPrice(sideTokenRef, address(0), …)` before first createSidePool=true file/list.
/// - [ ] Seed USDG ref: `setRefPrice(sideTokenRef, USDG, 1e15)` (or Express pair seed) before USDG launches.
/// - [ ] Soft-launch gate: `_assertSoftLaunchGate` after each factory construct.
abstract contract DeploySoftLaunchGuard is Script {
    /// @dev Call after each factory construct (or after intentional allowlist config).
    ///      Reverts if the soft-launch gate is not closed (RIDER A).
    function _assertSoftLaunchGate(DeployControls factory, address expectedDeployer) internal view {
        factory.assertSoftLaunchGate(expectedDeployer);
        console2.log("soft-launch gate OK", address(factory), expectedDeployer);
    }
}

/// @dev Placeholder concrete script — rehearsal/official `run()` fills this in later.
contract Deploy is DeploySoftLaunchGuard {
    function run() external pure {
        // Intentionally empty until MAINNET PATH / rehearsal deploy script lands.
        // Soft-launch assertion is exercised by DeployControlsPhase1 tests +
        // `_assertSoftLaunchGate` when factories are constructed in a real run.
    }
}
