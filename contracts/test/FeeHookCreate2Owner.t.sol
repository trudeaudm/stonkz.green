// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager as ICanonPM} from "@v4-core/src/interfaces/IPoolManager.sol";

import {StonkzFeeHook} from "../src/StonkzFeeHook.sol";
import {HookVanity} from "../src/HookVanity.sol";
import {V4Adapter} from "../src/v4/V4Adapter.sol";
import {IPoolManager} from "../src/v4/IPoolManager.sol";
import {CTOGovernor} from "../src/CTOGovernor.sol";
import {ICTOGovernor} from "../src/interfaces/IStonkzGovernance.sol";

/// @dev CREATE2 deployer (test contract or Arachnid proxy) is NOT the intended owner —
///      constructor takes explicit initialOwner; V4Adapter.manager() auto-binds canon.
contract FeeHookCreate2Owner is Test {
    address constant RH_PM = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant TREASURY = address(0xEF2F);

    function test_create2_initialOwner_autoBindsCanon_andTransferWorks() public {
        address intendedOwner = address(0xBEEF);
        V4Adapter adapter = new V4Adapter(ICanonPM(RH_PM));
        CTOGovernor gov = new CTOGovernor();

        bytes memory creation = abi.encodePacked(
            type(StonkzFeeHook).creationCode,
            abi.encode(IPoolManager(address(adapter)), TREASURY, ICTOGovernor(address(gov)), intendedOwner)
        );
        bytes32 initHash = keccak256(creation);

        bytes32 salt;
        address predicted;
        bool found;
        for (uint256 i; i < 200_000; ++i) {
            salt = bytes32(i);
            predicted = HookVanity.predict(address(this), salt, initHash);
            if (HookVanity.flagsOf(predicted) == HookVanity.HOOK_FLAGS) {
                found = true;
                break;
            }
        }
        require(found, "flag salt");

        StonkzFeeHook hook = new StonkzFeeHook{salt: salt}(
            IPoolManager(address(adapter)), TREASURY, ICTOGovernor(address(gov)), intendedOwner
        );
        assertEq(address(hook), predicted, "create2 addr");
        // CREATE2 site is address(this); owner must still be intendedOwner (not the CREATE2 site).
        assertEq(hook.owner(), intendedOwner, "owner is initialOwner not create2 site");
        assertEq(address(hook.canonManager()), RH_PM, "ctor auto-bound adapter.manager()");

        vm.prank(intendedOwner);
        hook.bindCanonManager(ICanonPM(RH_PM));
        address custody = address(0xC001);
        vm.prank(intendedOwner);
        hook.transferOwnership(custody);
        assertEq(hook.owner(), custody);
    }
}
