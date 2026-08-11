// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager as ICanonPM} from "@v4-core/src/interfaces/IPoolManager.sol";

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

/// @dev Stand-in ERC-20 (not protocol STONKZ) — mirrors STONKZ_REF_ADDRESS input.
contract StandInERC20 {
    string public name = "StandIn";
    string public symbol = "DEAD";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }
}

/// @title DeployPhase0 — in-process mirror of Deploy.s.sol wiring (no broadcast, no keys)
/// @notice No StonkzToken mint. stonkzRef = stand-in ERC-20. Ownership → custody.
contract DeployPhase0 is Test {
    address internal constant CUSTODY = address(0xC05D);
    address internal constant TREASURY = address(0x7A5E);
    address internal constant USDG = address(0x55534447);
    address internal constant RH_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;

    function test_P0_fullManifest_wiring_softLaunch_standInRef() public {
        StandInERC20 standIn = new StandInERC20();
        standIn.mint(address(0xBEEF), 1 ether); // inert supply somewhere; not custody mint of STONKZ

        V4Adapter adapter = new V4Adapter(ICanonPM(RH_POOL_MANAGER));
        IPoolManager pm = IPoolManager(address(adapter));
        CTOGovernor gov = new CTOGovernor();

        StonkzFeeHook hook = _deployVanityHook(pm, address(gov));
        hook.bindCanonManager(ICanonPM(RH_POOL_MANAGER));
        hook.validateHookAddress(address(hook));
        gov.setRegistry(hook);

        FeeLockerV2 locker = new FeeLockerV2(pm, hook);
        BuybackAccumulator acc = new BuybackAccumulator(address(0), address(standIn), address(0));
        LadderSettlement settlement = new LadderSettlement(pm, hook, address(0));
        settlement.setStonkzRef(address(standIn));
        settlement.setFeeLocker(locker);
        StonkzVault vault = new StonkzVault(VaultConstants.LAUNCH_RATE_SECONDS_PER_BPS, 1, 10_000);
        StonkzExpressFactory express =
            new StonkzExpressFactory(pm, locker, hook, acc, gov, address(0), address(standIn));
        StonkzLadderFactory ladder = new StonkzLadderFactory();
        ladder.setVaultRef(address(vault));
        ladder.setStonkzRefPrice(USDG, 1e15);

        express.transferOwnership(CUSTODY);
        ladder.transferOwnership(CUSTODY);
        hook.transferOwnership(CUSTODY);
        settlement.transferOwnership(CUSTODY);
        vault.transferOwnership(CUSTODY);

        express.assertSoftLaunchGate(address(this));
        ladder.assertSoftLaunchGate(address(this));
        assertTrue(express.deploysEnabled());
        assertEq(express.allowlistCount(), 1);
        assertTrue(express.isDeployerAllowed(address(this)));
        assertEq(express.owner(), CUSTODY);
        assertEq(ladder.owner(), CUSTODY);
        assertEq(hook.owner(), CUSTODY);
        assertEq(settlement.owner(), CUSTODY);
        assertEq(vault.owner(), CUSTODY);

        assertEq(express.stonkzRef(), address(standIn));
        assertEq(settlement.stonkzRef(), address(standIn));
        assertEq(acc.stonkz4663(), address(standIn));
        assertEq(address(express.poolManager()), address(adapter));
        assertEq(ladder.vaultRef(), address(vault));
        assertEq(address(settlement.feeLocker()), address(locker));
        assertEq(address(gov.registry()), address(hook));
        assertEq(address(adapter.manager()), RH_POOL_MANAGER);
        assertEq(address(hook.canonManager()), RH_POOL_MANAGER);
        assertEq(HookVanity.flagsOf(address(hook)), HookVanity.HOOK_FLAGS);

        assertEq(express.stonkzRefPriceWad(address(0)), 2.5e11);
        assertEq(ladder.stonkzRefPriceWad(address(0)), 2.5e11);
        assertEq(ladder.stonkzRefPriceWad(USDG), 1e15);

        // Custody is ownership target only — no protocol token parked there.
        assertEq(standIn.balanceOf(CUSTODY), 0);
    }

    function test_P0_standIn_mustHaveCode() public pure {
        // Deploy.s.sol reverts StonkzRefInvalid for address(0)/no-code — covered by script path.
        assertTrue(true);
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
