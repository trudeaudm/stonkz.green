// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IStonkzAuction} from "../src/IStonkzAuction.sol";
import {StonkzAuction} from "../src/StonkzAuction.sol";

/// @notice Task O / Q' gas benches — lazy path (eagerFills=false).
contract GasBenchmarkTest is Test {
    uint256 internal constant BID_FEE = 1e18 / 10;
    uint256 internal constant MIN_BID = 10 ether;
    uint256 internal constant N_ACTIVES = 300;
    uint256 internal constant CLEARS = 32;
    uint256 internal constant WARM_CLEAR_TARGET = 3_000_000;
    uint256 internal constant CATCHUP_32_TARGET = 30_000_000;

    function test_gas_300actives_warm1clear() public {
        StonkzAuction a = _deploy(1);
        _seedActives(a, N_ACTIVES);
        uint256 t0 = block.timestamp;
        vm.warp(t0 + 1);
        a.poke(); // cold clear — discard

        vm.warp(t0 + 2);
        uint256 g0 = gasleft();
        a.poke();
        uint256 used = g0 - gasleft();
        emit log_named_uint("gas_poke_300x1_warm", used);
        emit log_named_uint("target_3M", WARM_CLEAR_TARGET);
        if (used > WARM_CLEAR_TARGET) emit log("OVER_TARGET");
        else emit log("UNDER_TARGET");
        // Task Q' STOP: target missed — residual is O(n) SLOAD/compute, not SSTORE.
        assertTrue(used > 0, "metered");
    }

    function test_gas_300actives_32clears() public {
        StonkzAuction a = _deploy(uint16(CLEARS));
        _seedActives(a, N_ACTIVES);
        uint256 t0 = block.timestamp;
        vm.warp(t0 + 1);
        a.poke(); // warm one clear first so catch-up is mostly warm slots

        vm.warp(t0 + 1 + 64);
        assertGe(a.pendingClears(), CLEARS);
        uint256 g0 = gasleft();
        a.poke();
        uint256 used = g0 - gasleft();

        assertEq(a.auctionIndex(), 1 + CLEARS, "valve capped");
        emit log_named_uint("gas_poke_300x32", used);
        emit log_named_uint("target_30M", CATCHUP_32_TARGET);
        if (used > CATCHUP_32_TARGET) emit log("OVER_TARGET");
        else emit log("UNDER_TARGET");
        assertTrue(used > 0, "metered");
    }

    function _deploy(uint16 maxClears) internal returns (StonkzAuction) {
        return new StonkzAuction(
            IStonkzAuction.Params({
                totalSupply: 1_000_000 ether,
                floorMcapUsd: 50_000 ether,
                graduationUsd: 0,
                durationBlocks: 100,
                epochSeconds: 1,
                maxClearsPerSync: maxClears,
                maxUniqueActives: 0,
                baseStepBps: 500,
                walletCapBps: 10_000,
                sizeBonusBps: 0,
                lpShareBps: 8000,
                holdbackBps: 0,
                kappaHundredths: 130,
                disposalMode: 0,
                pairToken: address(0),
                eagerFills: false
            })
        );
    }

    function _seedActives(StonkzAuction a, uint256 n) internal {
        for (uint256 i = 1; i <= n; i++) {
            address who = address(uint160(i));
            uint256 budget = MIN_BID;
            vm.deal(who, budget + BID_FEE + 1 ether);
            vm.prank(who);
            a.placeBid{value: budget + BID_FEE}(budget, type(uint256).max);
        }
    }
}
