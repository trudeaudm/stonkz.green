// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IHooks} from "@v4-core/src/interfaces/IHooks.sol";
import {IPoolManager as ICanonPM} from "@v4-core/src/interfaces/IPoolManager.sol";
import {Deployers} from "@v4-core/test/utils/Deployers.sol";
import {Hooks} from "@v4-core/src/libraries/Hooks.sol";

import {IPoolManager} from "../src/v4/IPoolManager.sol";
import {V4Adapter} from "../src/v4/V4Adapter.sol";
import {MockPoolManager} from "../src/mock/MockPoolManager.sol";
import {PoolKey, PoolIdLibrary} from "../src/v4/types/PoolKey.sol";
import {Currency} from "../src/v4/types/Currency.sol";
import {TickMath} from "../src/v4/TickMath.sol";

/// @title V4DualBackend - Phase 0 dual-backend test base (Mock | real-in-test PM)
/// @notice Parameterize pool-touching suites: `backend = Mock` (fast vectors) or
///         `Real` (Deployers manager + V4Adapter). Real path proves unlock netting.
abstract contract V4DualBackend is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    enum Backend {
        Mock,
        Real
    }

    Backend internal backend;
    IPoolManager internal pm; // MockPoolManager or V4Adapter (as IPoolManager)
    V4Adapter internal adapter; // non-zero only on Real
    MockPoolManager internal mockPm;

    /// @dev Hook address placeholder for Real pools (flags may be etched in Phase 1).
    address internal hookAddr;

    function _setBackend(Backend b) internal {
        backend = b;
        if (b == Backend.Mock) {
            mockPm = new MockPoolManager();
            pm = IPoolManager(address(mockPm));
            adapter = V4Adapter(payable(address(0)));
            hookAddr = address(0);
        } else {
            deployFreshManagerAndRouters();
            deployMintAndApprove2Currencies();
            adapter = new V4Adapter(manager);
            pm = IPoolManager(address(adapter));
            mockPm = MockPoolManager(payable(address(0)));
            // Minimal flag-valid hook address for initialize (no callbacks needed for Phase 0 liq).
            hookAddr = address(uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG));
        }
    }

    function _ourKey(address a, address b, address hooks) internal pure returns (PoolKey memory key) {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: 0,
            tickSpacing: 60,
            hooks: hooks
        });
    }
}
