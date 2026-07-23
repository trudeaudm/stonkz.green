// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IStonkzAuction} from "../src/IStonkzAuction.sol";
import {StonkzAuction} from "../src/StonkzAuction.sol";

/// @notice Task Q'/F1': warm unconstrained clear must SSTORE globals only (≤16).
///         Measured: 8 warm SSTOREs (accT/accU/sold/raised/idx/lastSold/weightDustAccum/…).
contract WriteBudgetTest is Test {
    uint256 internal constant BID_FEE = 1e18 / 10;
    uint256 internal constant MIN_BID = 10 ether;
    uint256 internal constant N = 300;
    /// @dev Documented constant: per constraint event, bound on extra SSTOREs.
    uint256 internal constant C_PER_CONSTRAINT = 40;

    function test_writeBudget_warmClear_zeroConstraints() public {
        StonkzAuction a = _deploy(1);
        _seed(a, N);
        // First clear warms slots / may create zero→nonzero; burn it.
        uint256 t0 = block.timestamp;
        vm.warp(t0 + 1);
        a.poke();
        assertEq(a.auctionIndex(), 1);
        emit log_named_uint("tw_after_clear1", a.totalWeight());
        emit log_named_uint("accT", a.accTokensPerWeight());

        // Warm clear with live book, no price-outs (maxPrice=max), fat budgets.
        vm.warp(t0 + 2);
        emit log_named_uint("pending", a.pendingClears());
        vm.record();
        a.poke();
        (, bytes32[] memory writes) = vm.accesses(address(a));
        emit log_named_uint("warm_clear_sstores", writes.length);
        emit log_named_uint("idx_after", a.auctionIndex());
        assertEq(a.auctionIndex(), 2, "clear did not advance");
        assertLe(writes.length, 16, "unconstrained clear exceeds global write budget");
    }

    function test_writeBudget_K_constraints_linear() public {
        // Small N so we can force price-outs as constraints
        StonkzAuction a = _deploy(1);
        // 5 bidders; 2 with low maxPrice will price out when price steps
        for (uint256 i = 1; i <= 5; i++) {
            address who = address(uint160(i));
            uint256 maxP = i <= 2 ? 1 : type(uint256).max; // will price out if price rises
            vm.deal(who, MIN_BID + BID_FEE + 1 ether);
            vm.prank(who);
            a.placeBid{value: MIN_BID + BID_FEE}(MIN_BID, maxP);
        }
        // Advance until price steps (fully sold gates)
        for (uint256 k = 0; k < 20 && a.auctionIndex() < 10; k++) {
            vm.warp(block.timestamp + 1);
            vm.record();
            uint256 before = a.auctionIndex();
            a.poke();
            (, bytes32[] memory writes) = vm.accesses(address(a));
            if (a.auctionIndex() > before) {
                // Bound: globals + c*K — K unknown precisely; soft check vs huge N writes
                assertLe(writes.length, 16 + C_PER_CONSTRAINT * 5, "constraint write blowup");
            }
        }
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

    function _seed(StonkzAuction a, uint256 n) internal {
        for (uint256 i = 1; i <= n; i++) {
            address who = address(uint160(i));
            vm.deal(who, MIN_BID + BID_FEE + 1 ether);
            vm.prank(who);
            a.placeBid{value: MIN_BID + BID_FEE}(MIN_BID, type(uint256).max);
        }
    }
}
