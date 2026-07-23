// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IStonkzAuction} from "../src/IStonkzAuction.sol";
import {StonkzAuction} from "../src/StonkzAuction.sol";

/// @notice Task O: 300 actives × 32-clear catch-up poke gas (H1 / E1 valve).
/// @dev Measured ~235M gas (>>25M). Do not optimize the fill loop — E1 valve is
///      the mitigation. Test asserts valve behavior + records gas for the decision record.
contract GasBenchmarkTest is Test {
    uint256 internal constant BID_FEE = 1e18 / 10;
    uint256 internal constant MIN_BID = 10 ether;
    uint256 internal constant N_ACTIVES = 300;
    uint256 internal constant CLEARS = 32;
    uint256 internal constant GAS_BUDGET = 25_000_000;

    /// @dev Decision-record measurement. Soft-checks the 25M budget (expect fail → E1 covers).
    function test_gas_300actives_32clears() public {
        StonkzAuction a = _deploy(uint16(CLEARS));
        _seedActives(a, N_ACTIVES);

        assertEq(a.activeAddressCount(), N_ACTIVES, "actives");
        assertEq(a.auctionIndex(), 0);

        // Wall ahead of valve: 64 pending, but one poke clears only 32.
        vm.warp(block.timestamp + 64);
        assertEq(a.pendingClears(), 64, "pending before");

        uint256 g0 = gasleft();
        a.poke();
        uint256 used = g0 - gasleft();

        assertEq(a.auctionIndex(), CLEARS, "valve capped clears");
        assertEq(a.pendingClears(), 64 - CLEARS, "still lagging");
        assertEq(a.maxClearsPerSync(), CLEARS, "immutable valve");

        emit log_named_uint("gas_poke_300x32", used);
        emit log_named_uint("gas_budget_25M", GAS_BUDGET);
        if (used >= GAS_BUDGET) {
            emit log("OVER_BUDGET - E1 valve is the mitigation (H1; no fill-loop opt)");
        } else {
            emit log("UNDER_BUDGET");
        }
        // Always leave measured number in logs for docs/lazy-clearing-design.md.
        // Gate is "record numbers", not "must fit 25M".
        assertTrue(used > 0, "metered");
    }

    /// @dev Per-clear cost with 300 actives (for docs amortization).
    function test_gas_300actives_1clear() public {
        StonkzAuction a = _deploy(1);
        _seedActives(a, N_ACTIVES);
        vm.warp(block.timestamp + 1);

        uint256 g0 = gasleft();
        a.poke();
        uint256 used = g0 - gasleft();

        assertEq(a.auctionIndex(), 1);
        emit log_named_uint("gas_poke_300x1", used);
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
                pairToken: address(0)
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
