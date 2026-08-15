// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Hooks} from "@v4-core/src/libraries/Hooks.sol";

import {V4DualBackend} from "./V4DualBackend.sol";
import {IPoolManager} from "../src/v4/IPoolManager.sol";
import {StonkzFeeHook} from "../src/StonkzFeeHook.sol";
import {HookVanity} from "../src/HookVanity.sol";
import {FeeLockerV2} from "../src/FeeLockerV2.sol";
import {BuybackAccumulator} from "../src/BuybackAccumulator.sol";
import {CTOGovernor} from "../src/CTOGovernor.sol";
import {ICTOGovernor} from "../src/interfaces/IStonkzGovernance.sol";
import {StonkzDirectListing} from "../src/StonkzDirectListing.sol";

/// @title ListingAdapterPhase2 — DirectListing against Mock | Real V4Adapter
abstract contract ListingAdapterPhase2Base is V4DualBackend {
    address internal constant TREASURY = address(0x7A5E);
    address internal constant CREATOR = address(0xCEEE);
    address internal constant PAIR = address(0); // native

    uint256 internal constant SUPPLY = 1_000_000 ether;
    uint256 internal constant TIER_4K = 4000e18;

    StonkzFeeHook internal hook;
    FeeLockerV2 internal locker;
    BuybackAccumulator internal acc;
    CTOGovernor internal gov;

    function _wire() internal {
        gov = new CTOGovernor();
        if (backend == Backend.Mock) {
            hook = new StonkzFeeHook(pm, TREASURY, ICTOGovernor(address(gov)), address(this));
        } else {
            hook = _deployFlagHook();
            hook.bindCanonManager(manager);
        }
        gov.setRegistry(hook);
        locker = new FeeLockerV2(pm, hook);
        acc = new BuybackAccumulator(PAIR, address(0x4663), address(0));
    }

    function _deployFlagHook() internal returns (StonkzFeeHook h) {
        bytes memory creation = abi.encodePacked(
            type(StonkzFeeHook).creationCode,
            abi.encode(pm, TREASURY, ICTOGovernor(address(gov)), address(this))
        );
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
            predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash))))
            );
            if ((uint160(predicted) & Hooks.ALL_HOOK_MASK) == HookVanity.HOOK_FLAGS) {
                found = true;
                break;
            }
        }
        require(found, "no flag salt");
        h = new StonkzFeeHook{salt: salt}(pm, TREASURY, ICTOGovernor(address(gov)), address(this));
        require(address(h) == predicted, "flag create2");
    }

    function _params(bool side) internal pure returns (StonkzDirectListing.ListingParams memory p) {
        p = StonkzDirectListing.ListingParams({
            startMcap: TIER_4K,
            totalSupply: SUPPLY,
            creatorReserveBps: 0,
            deliveryMode: 0,
            vestDuration: 0,
            declaredUse: bytes32(0),
            creator: CREATOR,
            name: "Stonk",
            symbol: "STK",
            createSidePool: side,
            sidePoolBps: side ? 500 : 0,
            liquidityLocked: true,
            refPriceWad: side ? 2.5e11 : 0
        });
    }

    function test_list_lockStamp_mainPool() public {
        StonkzDirectListing listing =
            new StonkzDirectListing{value: 1 ether}(pm, locker, hook, acc, gov, PAIR, address(0), _params(false));
        assertTrue(locker.liquidityLocked(address(listing.token())));
        assertEq(locker.unlockRecipient(address(listing.token())), CREATOR);
        assertGt(listing.mainLiquidity(), 0);
        (,,,, address hooks) = listing.mainPoolKey();
        assertEq(hooks, address(hook));
    }
}

contract ListingAdapterPhase2Mock is ListingAdapterPhase2Base {
    function setUp() public {
        vm.etch(address(0x4663), hex"00");
        _setBackend(Backend.Mock);
        _wire();
    }
}

contract ListingAdapterPhase2Real is ListingAdapterPhase2Base {
    function setUp() public {
        vm.etch(address(0x4663), hex"00");
        _setBackend(Backend.Real);
        _wire();
    }
}
