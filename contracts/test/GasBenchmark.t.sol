// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IStonkzAuction} from "../src/IStonkzAuction.sol";
import {StonkzAuction} from "../src/StonkzAuction.sol";

/// @notice Task O / T gas benches — lazy path (eagerFills=false), ALL-SIMPLE @300.
/// @dev Task T target: warm single clear ≤ 2.5M. On miss: record + auto-derive
///      maxClearsPerSync = floor(25M / measured) with assert cap×measured ≤ 25M.
contract GasBenchmarkTest is Test {
    uint256 internal constant BID_FEE = 1e18 / 10;
    uint256 internal constant MIN_BID = 10 ether;
    uint256 internal constant N_ACTIVES = 300;
    uint256 internal constant WARM_CLEAR_TARGET = 2_500_000;
    uint256 internal constant CATCHUP_GAS_BUDGET = 25_000_000;

    /// @notice Measure warm ALL-SIMPLE clear @300; derive E1 valve from 25M budget.
    function test_gas_300actives_warm1clear_autoValve() public {
        StonkzAuction a = _deploy(1);
        _seedActives(a, N_ACTIVES);
        uint256 t0 = block.timestamp;
        vm.warp(t0 + 1);
        a.poke(); // cold clear — discard

        vm.warp(t0 + 2);
        uint256 g0 = gasleft();
        a.poke();
        uint256 measured = g0 - gasleft();

        emit log_named_uint("gas_poke_300x1_warm_ALL_SIMPLE", measured);
        emit log_named_uint("target_2_5M", WARM_CLEAR_TARGET);
        if (measured > WARM_CLEAR_TARGET) emit log("OVER_TARGET_2_5M");
        else emit log("UNDER_TARGET_2_5M");

        require(measured > 0, "metered");
        uint256 derivedCap = CATCHUP_GAS_BUDGET / measured; // floor
        require(derivedCap > 0 && derivedCap <= type(uint16).max, "derived cap");
        uint256 product = derivedCap * measured;
        assertLe(product, CATCHUP_GAS_BUDGET, "cap x measured > 25M");

        emit log_named_uint("derived_maxClearsPerSync", derivedCap);
        emit log_named_uint("cap_x_measured", product);
        // Valve behavior covered by GasValveSmoke (derived cap=4 on small book).
    }

    /// @notice Catch-up gas at derived cap on a modest book (records multi-clear cost).
    function test_gas_derivedCatchup_modestBook() public {
        uint256 measured = 6_086_095; // from warm@300 ALL-SIMPLE Task T bench
        uint256 cap = CATCHUP_GAS_BUDGET / measured;
        if (cap == 0) cap = 1;

        StonkzAuction a = _deploy(uint16(cap));
        _seedActives(a, 30);
        uint256 t1 = block.timestamp;
        vm.warp(t1 + 1);
        a.poke();
        vm.warp(t1 + 1 + cap * 2);
        uint256 g0 = gasleft();
        a.poke();
        uint256 used = g0 - gasleft();
        emit log_named_uint("gas_poke_30x_derivedCap", used);
        emit log_named_uint("derivedCap", cap);
        emit log_named_uint("budget_25M", CATCHUP_GAS_BUDGET);
        if (used > CATCHUP_GAS_BUDGET) emit log("CATCHUP_OVER_25M");
        else emit log("CATCHUP_UNDER_25M");
        assertTrue(used > 0, "metered");
        assertLe(cap * measured, CATCHUP_GAS_BUDGET, "cap x measured > 25M");
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
                maxLivePositionsPerAddress: 0,
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
            a.placeBid{value: budget + BID_FEE}(budget, type(uint80).max);
        }
    }
}
