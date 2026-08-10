// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager as ICanonPM} from "@v4-core/src/interfaces/IPoolManager.sol";

import {StonkzToken} from "../src/StonkzToken.sol";
import {DeployControls} from "../src/DeployControls.sol";
import {IPoolManager} from "../src/v4/IPoolManager.sol";
import {V4Adapter} from "../src/v4/V4Adapter.sol";
import {CTOGovernor} from "../src/CTOGovernor.sol";
import {ICTOGovernor} from "../src/interfaces/IStonkzGovernance.sol";
import {StonkzFeeHook} from "../src/StonkzFeeHook.sol";
import {HookVanity} from "../src/HookVanity.sol";
import {FeeLockerV2} from "../src/FeeLockerV2.sol";
import {BuybackAccumulator} from "../src/BuybackAccumulator.sol";
import {LadderSettlement} from "../src/ladder/LadderSettlement.sol";
import {StonkzVault} from "../src/vault/StonkzVault.sol";
import {VaultConstants} from "../src/vault/VaultConstants.sol";
import {StonkzExpressFactory} from "../src/StonkzExpressFactory.sol";
import {StonkzLadderFactory} from "../src/ladder/StonkzLadderFactory.sol";

/// @title DeployPhase0 — in-process mirror of Deploy.s.sol wiring (no broadcast, no keys)
/// @notice Uses V4Adapter → RH PM pin (constructor only; no RPC). Hook CREATE2 mined to
///         flag bits 0x088 (validateHookPermissions). Full 0x4663+0x088 vanity is required
///         by Deploy.s.sol via HOOK_CREATE2_SALT (JS miner) — too expensive for unit CI.
///         MockPoolManager is NOT on this path.
contract DeployPhase0 is Test {
    address internal constant CUSTODY = address(0xC05D);
    address internal constant TREASURY = address(0x7A5E);
    address internal constant USDG = address(0x55534447);
    address internal constant RH_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;

    function test_P0_fullManifest_wiring_softLaunch_parkedSupply() public {
        StonkzToken stonkz = new StonkzToken(CUSTODY);
        V4Adapter adapter = new V4Adapter(ICanonPM(RH_POOL_MANAGER));
        IPoolManager pm = IPoolManager(address(adapter));
        CTOGovernor gov = new CTOGovernor();

        StonkzFeeHook hook = _deployVanityHook(pm, address(gov));
        hook.bindCanonManager(ICanonPM(RH_POOL_MANAGER));
        hook.validateHookAddress(address(hook));
        gov.setRegistry(hook);

        FeeLockerV2 locker = new FeeLockerV2(pm, hook);
        BuybackAccumulator acc = new BuybackAccumulator(address(0), address(stonkz), address(0));
        LadderSettlement settlement = new LadderSettlement(pm, hook, address(0));
        settlement.setStonkzRef(address(stonkz));
        settlement.setFeeLocker(locker);
        StonkzVault vault = new StonkzVault(VaultConstants.LAUNCH_RATE_SECONDS_PER_BPS, 1, 10_000);
        StonkzExpressFactory express =
            new StonkzExpressFactory(pm, locker, hook, acc, gov, address(0), address(stonkz));
        StonkzLadderFactory ladder = new StonkzLadderFactory();
        ladder.setVaultRef(address(vault));
        ladder.setStonkzRefPrice(USDG, 1e15);

        express.assertSoftLaunchGate(address(this));
        ladder.assertSoftLaunchGate(address(this));
        assertTrue(express.deploysEnabled());
        assertEq(express.allowlistCount(), 1);
        assertTrue(express.isDeployerAllowed(address(this)));

        assertEq(express.stonkzRef(), address(stonkz));
        assertEq(address(express.poolManager()), address(adapter));
        assertEq(ladder.vaultRef(), address(vault));
        assertEq(settlement.stonkzRef(), address(stonkz));
        assertEq(address(settlement.feeLocker()), address(locker));
        assertEq(address(gov.registry()), address(hook));
        assertEq(acc.stonkz4663(), address(stonkz));
        assertEq(address(adapter.manager()), RH_POOL_MANAGER);
        assertEq(address(hook.canonManager()), RH_POOL_MANAGER);
        assertEq(HookVanity.flagsOf(address(hook)), HookVanity.HOOK_FLAGS);

        assertEq(express.stonkzRefPriceWad(address(0)), 2.5e11);
        assertEq(ladder.stonkzRefPriceWad(address(0)), 2.5e11);
        assertEq(ladder.stonkzRefPriceWad(USDG), 1e15);

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

    function _deployVanityHook(IPoolManager pm, address gov) internal returns (StonkzFeeHook h) {
        bytes memory creation =
            abi.encodePacked(type(StonkzFeeHook).creationCode, abi.encode(pm, TREASURY, ICTOGovernor(gov)));
        bytes32 initCodeHash = keccak256(creation);
        bytes32 salt;
        address predicted;
        uint256 freemem;
        assembly {
            freemem := mload(0x40)
        }
        bool found;
        for (uint256 i; i < 1_000_000; ++i) {
            assembly {
                mstore(0x40, freemem)
            }
            salt = bytes32(i);
            predicted = HookVanity.predict(address(this), salt, initCodeHash);
            if (HookVanity.flagsOf(predicted) == HookVanity.HOOK_FLAGS) {
                found = true;
                break;
            }
        }
        require(found, "no flag salt");
        h = new StonkzFeeHook{salt: salt}(pm, TREASURY, ICTOGovernor(gov));
        require(address(h) == predicted, "hook create2");
        h.validateHookAddress(address(h));
    }
}
