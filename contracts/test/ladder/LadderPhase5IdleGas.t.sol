// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {LadderPhase4Base} from "./LadderPhase4Base.sol";
import {StonkzLadderAuction} from "../../src/ladder/StonkzLadderAuction.sol";
import {LadderTypes} from "../../src/ladder/LadderTypes.sol";
import {LadderConstants} from "../../src/ladder/LadderConstants.sol";

/// @title LadderPhase5IdleGas — docs/09 §1/§2 idle catch-up must be O(1), not O(K)
contract LadderPhase5IdleGas is LadderPhase4Base {
    /// @notice Bid after 500 idle ROADSHOW periods: catch-up is closed-form (not per-period loop).
    function test_P5_idleCatchUp_bidAfter500_roadshow_O1() public {
        uint256 gas500 = _bidGasAfterIdle(500);
        uint256 gas100 = _bidGasAfterIdle(100);
        emit log_named_uint("gas_bid_after_100_idle_road", gas100);
        emit log_named_uint("gas_bid_after_500_idle_road", gas500);

        // O(1): 500-idle bid must not scale with K. Allow small constant overhead vs 100-idle.
        // If still O(K), gas500 ≈ 5× gas100 (minus fixed bid cost) — fail hard.
        assertLe(gas500, gas100 + 80_000, "idle catch-up not O(1): scales with K");
        assertLe(gas500, 250_000, "500-idle bid gas soft ceiling (O(1) catch-up)");
    }

    function _bidGasAfterIdle(uint16 idlePeriods) internal returns (uint256 gasUsed) {
        DeployCfg memory c = _defaultCfg();
        c.tier = LadderTypes.Tier.Road;
        c.floorMcap = 20_000 ether;
        c.holdbackBps = 0;
        c.maxUniqueActives = 300;
        StonkzLadderAuction a = _deploy(c);

        // No bids → empty book → pure idle. Warp idlePeriods of DESIGN_N.
        uint256 t0 = a.startTime();
        if (t0 == 0) t0 = block.timestamp;
        uint256 dur = LadderConstants.ROAD_DURATION;
        vm.warp(t0 + (uint256(idlePeriods) * dur) / LadderConstants.DESIGN_N);
        // Touch startTime if placeBid would set it — start() already called in _deploy.
        assertEq(a.periodIndex(), 0, "pre-bid: no sync yet");

        address w = address(uint160(0x1D1E + idlePeriods));
        uint256 size = 100 ether;
        vm.deal(w, size + 1 ether);
        vm.prank(w);
        uint256 g0 = gasleft();
        a.placeBid{value: size}(size, 1 ether);
        gasUsed = g0 - gasleft();

        assertEq(a.periodIndex(), idlePeriods, "catch-up landed on idlePeriods");
        assertEq(a.price(), a.floorPrice(), "idle: price unchanged");
    }
}
